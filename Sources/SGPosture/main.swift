import AppKit
import CoreMotion
import Foundation

// MARK: - Tunables (tweak these and rebuild)

/// If posture reads inverted (sitting tall shows red), flip this to -1.0.
let kSlouchSign: Double = 1.0
/// Forward/down tilt (degrees from your calibrated upright) still counted as good.
let kGoodMax: Double = 10.0
/// Above this many degrees = slouching.
let kSlightMax: Double = 18.0
/// Seconds you must hold a slouch before it nudges you.
let kSlouchHold: TimeInterval = 8
/// Minimum seconds between nudges.
let kNudgeCooldown: TimeInterval = 60
/// Low-pass smoothing for the raw signal (0..1, higher = snappier, noisier).
let kSmoothing: Double = 0.15
/// System sound played on a nudge. Try Submarine, Funk, Pop, Tink, Hero.
let kNudgeSound = "Submarine"
/// When the end-of-day report is delivered, on the local 24-hour clock.
let kEODHour = 21
let kEODMinute = 0
/// A pause longer than this between motion samples means the AirPods are not
/// being worn, so that gap is not counted toward worn time.
let kWornGap: TimeInterval = 2.0

enum PostureState { case noMotion, uncalibrated, good, slight, slouch }

final class AppDelegate: NSObject, NSApplicationDelegate, CMHeadphoneMotionManagerDelegate {

    let motion = CMHeadphoneMotionManager()
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let nudgeOverlay = NudgeOverlay()
    let calibrationOverlay = CalibrationOverlay()
    var calibrating = false
    var calibrationTimer: Timer?

    // live state
    var hasData = false
    var seeded = false
    var smoothedPitch: Double = 0
    var baseline: Double?
    var nudgesEnabled = true
    var state: PostureState = .uncalibrated
    var slouchSince: Date?
    var lastNudge: Date?

    // daily logging: seconds per state, keyed by yyyy-MM-dd
    var log: [String: [String: Double]] = [:]
    var lastSample: Date?
    var lastFlush = Date.distantPast
    var logDirty = false

    // menu items we keep references to so we can update their titles
    var statusLine: NSMenuItem!
    var connLine: NSMenuItem!
    var calibrateItem: NSMenuItem!
    var nudgeItem: NSMenuItem!

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        let d = UserDefaults.standard
        if d.object(forKey: "baseline") != nil { baseline = d.double(forKey: "baseline") }
        if d.object(forKey: "nudges") != nil { nudgesEnabled = d.bool(forKey: "nudges") }
        state = baseline == nil ? .uncalibrated : .good

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        statusItem.menu = menu
        render()

        loadLog()
        motion.delegate = self
        FileHandle.standardError.write(Data("[SGPosture] launch. motionAvailable=\(motion.isDeviceMotionAvailable) auth=\(CMHeadphoneMotionManager.authorizationStatus().rawValue)\n".utf8))
        startMotion()

        // Periodically persist the log and check whether the EOD report is due.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.flush()
            self?.deliverEODReportIfDue()
        }

        // Self-test: launch with `--selftest` (via `open --args`) to show an overlay
        // and, after it dismisses, write proof the app is still alive to
        // /tmp/sgposture_selftest.txt. Verifies it no longer quits when its last
        // window closes. Must run via `open` so it has full bundle context.
        if CommandLine.arguments.contains("--selftest")
            || ProcessInfo.processInfo.environment["SGPOSTURE_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.nudgeOverlay.show() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                try? "ALIVE after overlay show+dismiss\n".write(toFile: "/tmp/sgposture_selftest.txt",
                                                               atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) { flush(force: true) }

    // This is a menu-bar app: it must NOT quit when a transient overlay window
    // (nudge countdown / calibration panel) closes. Without this, the app exits
    // the moment a nudge's overlay dismisses.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func buildMenu() {
        statusLine = disabled("Posture: starting…")
        connLine = disabled("")
        calibrateItem = action("Calibrate good posture", #selector(calibrate), "c")
        nudgeItem = action("Nudge me when I slouch", #selector(toggleNudges), "")
        let clearItem = action("Clear calibration", #selector(clearCalibration), "")
        let quitItem = action("Quit SG Posture", #selector(quit), "q")
        let hint = disabled("Wear AirPods Pro / 3 / 4 / Max, sit tall, then Calibrate.")

        menu.addItem(statusLine)
        menu.addItem(connLine)
        menu.addItem(.separator())
        menu.addItem(calibrateItem)
        menu.addItem(clearItem)
        menu.addItem(nudgeItem)
        menu.addItem(.separator())
        menu.addItem(action("Today's posture report…", #selector(showReport), "r"))
        menu.addItem(action("Show test nudge", #selector(testNudge), ""))
        menu.addItem(.separator())
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    // MARK: Motion

    func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            state = .noMotion
            render()
            // AirPods may connect after launch — keep polling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startMotion() }
            return
        }
        if state == .noMotion { state = baseline == nil ? .uncalibrated : .good }
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            self.handle(m)
        }
    }

    func handle(_ m: CMDeviceMotion) {
        let pitch = m.attitude.pitch
        if !seeded { smoothedPitch = pitch; seeded = true }
        else { smoothedPitch += (pitch - smoothedPitch) * kSmoothing }
        hasData = true
        if calibrating { calibrationOverlay.update(pitch: m.attitude.pitch, roll: m.attitude.roll) }
        evaluate()
        // Count worn time: add the gap since the last sample to the current state,
        // but only if samples are arriving continuously (AirPods actually on).
        let now = Date()
        if let last = lastSample {
            let dt = now.timeIntervalSince(last)
            if dt > 0 && dt < kWornGap { accumulate(dt) }
        }
        lastSample = now
        render()
    }

    func evaluate() {
        guard let base = baseline else { state = .uncalibrated; return }
        let tilt = kSlouchSign * (base - smoothedPitch) * 180 / .pi  // + = head down/forward
        if tilt <= kGoodMax {
            state = .good; slouchSince = nil
        } else if tilt <= kSlightMax {
            state = .slight; slouchSince = nil
        } else {
            state = .slouch
            if slouchSince == nil { slouchSince = Date() }
            maybeNudge()
        }
    }

    func maybeNudge() {
        guard nudgesEnabled, let since = slouchSince else { return }
        guard Date().timeIntervalSince(since) >= kSlouchHold else { return }
        if let last = lastNudge, Date().timeIntervalSince(last) < kNudgeCooldown { return }
        lastNudge = Date()
        bumpNudgeCount()
        NSSound(named: kNudgeSound)?.play()
        nudgeOverlay.show()
    }

    func notify(title: String, body: String) {
        // Shell out to osascript so we get a real Notification Center banner
        // without notification entitlements.
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        let safeBody = body.replacingOccurrences(of: "\"", with: "'")
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        p.arguments = ["-e", "display notification \"\(safeBody)\" with title \"\(safeTitle)\""]
        try? p.run()
    }

    // MARK: Actions

    @objc func calibrate() {
        guard hasData, !calibrating else { return }
        calibrating = true
        calibrationOverlay.show()
        calibrationOverlay.setCountdown(3)
        var n = 3
        calibrationTimer?.invalidate()
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            n -= 1
            if n > 0 { self.calibrationOverlay.setCountdown(n) }
            else { t.invalidate(); self.finishCalibration() }
        }
    }

    func finishCalibration() {
        calibrating = false
        baseline = smoothedPitch
        UserDefaults.standard.set(smoothedPitch, forKey: "baseline")
        slouchSince = nil
        let deg = abs(smoothedPitch * 180 / .pi)
        calibrationOverlay.finish(angle: deg)
        evaluate(); render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.calibrationOverlay.dismiss()
        }
    }

    @objc func clearCalibration() {
        baseline = nil
        UserDefaults.standard.removeObject(forKey: "baseline")
        state = hasData ? .uncalibrated : (motion.isDeviceMotionAvailable ? .uncalibrated : .noMotion)
        render()
    }

    @objc func toggleNudges() {
        nudgesEnabled.toggle()
        UserDefaults.standard.set(nudgesEnabled, forKey: "nudges")
        render()
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func testNudge() { nudgeOverlay.show() }

    // MARK: Delegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in self?.startMotion(); self?.render() }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasData = false; self.seeded = false; self.slouchSince = nil
            self.lastSample = nil
            self.state = .noMotion
            self.render()
        }
    }

    // MARK: Rendering

    func currentTilt() -> Double? {
        guard let base = baseline, hasData else { return nil }
        return kSlouchSign * (base - smoothedPitch) * 180 / .pi
    }

    func render() {
        guard let btn = statusItem.button else { return }
        let color: NSColor
        let symbols: [String]
        switch state {
        case .noMotion:     color = .systemGray;   symbols = ["airpods.gen3", "airpods", "headphones"]
        case .uncalibrated: color = .systemGray;   symbols = postureSymbols
        case .good:         color = .systemGreen;  symbols = postureSymbols
        case .slight:       color = .systemYellow; symbols = postureSymbols
        case .slouch:       color = .systemRed;    symbols = postureSymbols
        }
        // Render the symbol in a literal, solid color (non-template) at a clear size,
        // so it is always visible regardless of menu-bar template-tinting quirks.
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let base = symbol(symbols), let img = base.withSymbolConfiguration(cfg) {
            img.isTemplate = false
            btn.image = img
        } else {
            btn.image = dotImage(color)   // fallback: a plain solid dot
        }
        btn.contentTintColor = nil
        btn.imagePosition = .imageLeading
        btn.title = " " + shortLabel()

        statusLine.title = "Posture: " + stateText()
        connLine.title = connText()
        nudgeItem.state = nudgesEnabled ? .on : .off
        calibrateItem.isEnabled = hasData
    }

    /// A guaranteed-visible solid dot, used if an SF Symbol ever fails to load.
    func dotImage(_ color: NSColor) -> NSImage {
        let d: CGFloat = 13
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    let postureSymbols = ["figure.seated.side.right", "figure.seated.side", "figure.stand", "person.fill"]

    func symbol(_ names: [String]) -> NSImage? {
        for n in names {
            if let i = NSImage(systemSymbolName: n, accessibilityDescription: "posture") { return i }
        }
        return nil
    }

    func shortLabel() -> String {
        switch state {
        case .noMotion: return "—"
        case .uncalibrated: return "set"
        default:
            if let t = currentTilt() { return String(format: "%.0f°", abs(t)) }
            return "—"
        }
    }

    func stateText() -> String {
        switch state {
        case .noMotion: return "no sensor"
        case .uncalibrated: return "not calibrated"
        case .good: return "good (" + dirText() + ")"
        case .slight: return "leaning (" + dirText() + ")"
        case .slouch: return "slouching (" + dirText() + ")"
        }
    }

    func dirText() -> String {
        guard let t = currentTilt() else { return "—" }
        return String(format: "%.0f° %@", abs(t), t >= 0 ? "down" : "up")
    }

    func connText() -> String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied: return "Motion access denied — System Settings ▸ Privacy ▸ Motion & Fitness"
        case .restricted: return "Motion access restricted on this Mac"
        default: break
        }
        if !motion.isDeviceMotionAvailable { return "No motion AirPods detected (needs Pro / 3 / 4 / Max)" }
        if !hasData { return "AirPods found — move your head to start streaming" }
        return "AirPods connected"
    }

    // MARK: Daily logging & reports

    let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func dayKey(_ d: Date = Date()) -> String { dayFmt.string(from: d) }

    var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SGPosture", isDirectory: true)
    }
    var logURL: URL { supportDir.appendingPathComponent("posture-log.json") }
    var reportsDir: URL { supportDir.appendingPathComponent("reports", isDirectory: true) }

    func ensureDirs() {
        try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
    }

    func loadLog() {
        ensureDirs()
        guard let data = try? Data(contentsOf: logURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var out: [String: [String: Double]] = [:]
        for (day, v) in obj {
            guard let inner = v as? [String: Any] else { continue }
            var bucket: [String: Double] = [:]
            for (k, num) in inner { if let d = (num as? NSNumber)?.doubleValue { bucket[k] = d } }
            out[day] = bucket
        }
        log = out
    }

    func flush(force: Bool = false) {
        guard logDirty || force else { return }
        if !force && Date().timeIntervalSince(lastFlush) < 20 { return }
        ensureDirs()
        if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: logURL, options: .atomic)
            lastFlush = Date(); logDirty = false
        }
    }

    func accumulate(_ dt: Double) {
        let key: String
        switch state {
        case .good:         key = "good"
        case .slight:       key = "slight"
        case .slouch:       key = "slouch"
        case .uncalibrated: key = "wornUncalibrated"
        case .noMotion:     return
        }
        let day = dayKey()
        var bucket = log[day] ?? [:]
        bucket[key, default: 0] += dt
        log[day] = bucket
        logDirty = true
    }

    /// Count one nudge against today and persist immediately.
    func bumpNudgeCount() {
        let day = dayKey()
        var bucket = log[day] ?? [:]
        bucket["nudges", default: 0] += 1
        log[day] = bucket
        logDirty = true
        flush(force: true)
    }

    func formatDuration(_ s: Double) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    func reportPlain(for day: String) -> String {
        let b = log[day] ?? [:]
        let good = b["good"] ?? 0, slight = b["slight"] ?? 0, slouch = b["slouch"] ?? 0
        let uncal = b["wornUncalibrated"] ?? 0
        let assessed = good + slight + slouch
        if assessed <= 0 {
            return uncal > 0
                ? "Worn \(formatDuration(uncal)) but not calibrated yet.\nOpen the menu ▸ Calibrate good posture to start tracking."
                : "No AirPods wear recorded yet today."
        }
        func line(_ name: String, _ x: Double) -> String {
            String(format: "%@: %@ (%.0f%%)", name, formatDuration(x), x / assessed * 100)
        }
        var s = String(format: "Slouching: %.0f%% of %@ worn (assessed).\n\n",
                       slouch / assessed * 100, formatDuration(assessed))
        s += line("Good", good) + "\n" + line("Leaning", slight) + "\n" + line("Slouching", slouch)
        if uncal > 60 { s += "\n\nNot calibrated: \(formatDuration(uncal)) (excluded)." }
        s += "\n\nNudges shown: \(Int(b["nudges"] ?? 0))"
        return s
    }

    func reportMarkdown(for day: String) -> String {
        let b = log[day] ?? [:]
        let good = b["good"] ?? 0, slight = b["slight"] ?? 0, slouch = b["slouch"] ?? 0
        let uncal = b["wornUncalibrated"] ?? 0
        let assessed = good + slight + slouch
        func pct(_ x: Double) -> String { assessed > 0 ? String(format: "%.0f%%", x / assessed * 100) : "—" }
        var s = "# Posture report — \(day)\n\n"
        if assessed <= 0 {
            s += "No calibrated posture data"
            if uncal > 0 { s += String(format: " (worn %@ but not calibrated)", formatDuration(uncal)) }
            return s + ".\n"
        }
        s += String(format: "**Slouching: %@** of **%@** worn (assessed).\n\n", pct(slouch), formatDuration(assessed))
        s += "| Posture | Time | Share |\n|---|---|---|\n"
        s += "| Good | \(formatDuration(good)) | \(pct(good)) |\n"
        s += "| Leaning | \(formatDuration(slight)) | \(pct(slight)) |\n"
        s += "| Slouching | \(formatDuration(slouch)) | \(pct(slouch)) |\n"
        s += "\n**Nudges shown today: \(Int(b["nudges"] ?? 0))**\n"
        if uncal > 60 { s += "\nWorn but not calibrated: \(formatDuration(uncal)) (excluded from the percentages).\n" }
        s += "\n_Assessed = time wearing AirPods with a calibration set._\n"
        return s
    }

    @objc func showReport() {
        flush(force: true)
        let alert = NSAlert()
        alert.messageText = "Posture — today (\(dayKey()))"
        alert.informativeText = reportPlain(for: dayKey())
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open reports folder")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            ensureDirs(); NSWorkspace.shared.open(reportsDir)
        }
    }

    func deliverEODReportIfDue() {
        let now = Date()
        let cal = Calendar.current
        let h = cal.component(.hour, from: now), mn = cal.component(.minute, from: now)
        guard (h > kEODHour) || (h == kEODHour && mn >= kEODMinute) else { return }
        let today = dayKey(now)
        guard UserDefaults.standard.string(forKey: "lastReportDate") != today else { return }
        let b = log[today] ?? [:]
        let worn = (b["good"] ?? 0) + (b["slight"] ?? 0) + (b["slouch"] ?? 0) + (b["wornUncalibrated"] ?? 0)
        guard worn > 60 else { return }   // nothing meaningful to report yet
        deliverEODReport(for: today)
        UserDefaults.standard.set(today, forKey: "lastReportDate")
    }

    func deliverEODReport(for day: String) {
        flush(force: true)
        ensureDirs()
        try? reportMarkdown(for: day).write(to: reportsDir.appendingPathComponent("posture-\(day).md"),
                                            atomically: true, encoding: .utf8)
        let b = log[day] ?? [:]
        let assessed = (b["good"] ?? 0) + (b["slight"] ?? 0) + (b["slouch"] ?? 0)
        if assessed > 0 {
            let pct = (b["slouch"] ?? 0) / assessed * 100
            notify(title: "Posture report — \(day)",
                   body: String(format: "Slouched %.0f%% of %@ wearing AirPods. Menu ▸ Today's report for detail.", pct, formatDuration(assessed)))
        } else {
            notify(title: "Posture report — \(day)",
                   body: "AirPods worn but no calibration set, so no posture was assessed today.")
        }
    }

    // MARK: Menu helpers

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func action(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }
}

// MARK: - Guided calibration overlay (live head tracking + confirmation)

final class CalibrationOverlay {
    private var window: NSWindow?
    private var ring: NSView?
    private var dot: NSView?
    private var titleLabel: NSTextField?
    private var subLabel: NSTextField?
    private var countLabel: NSTextField?
    private var ringCenter: NSPoint = .zero
    private var maxOffset: CGFloat = 0

    func show() {
        if window != nil { return }
        guard let screen = NSScreen.main else { return }
        let size = screen.frame.size

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.level = .screenSaver
        w.ignoresMouseEvents = true; w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.hasShadow = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor

        let pw: CGFloat = 520, ph: CGFloat = 460
        let panel = NSView(frame: NSRect(x: (size.width - pw) / 2, y: (size.height - ph) / 2, width: pw, height: ph))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        panel.layer?.cornerRadius = 28

        let t = mklabel("Calibrating posture", 26, .bold, .white)
        t.frame = NSRect(x: 0, y: ph - 66, width: pw, height: 34)
        let s = mklabel("Sit up straight. Move your head to see it track.", 15, .regular, NSColor(white: 0.82, alpha: 1))
        s.frame = NSRect(x: 20, y: ph - 104, width: pw - 40, height: 24)

        let ringD: CGFloat = 220
        let r = NSView(frame: NSRect(x: (pw - ringD) / 2, y: 92, width: ringD, height: ringD))
        r.wantsLayer = true
        r.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        r.layer?.borderWidth = 2
        r.layer?.cornerRadius = ringD / 2
        let hL = NSView(frame: NSRect(x: 0, y: ringD / 2 - 0.5, width: ringD, height: 1))
        hL.wantsLayer = true; hL.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        let vL = NSView(frame: NSRect(x: ringD / 2 - 0.5, y: 0, width: 1, height: ringD))
        vL.wantsLayer = true; vL.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        r.addSubview(hL); r.addSubview(vL)

        let dotD: CGFloat = 32
        let d = NSView(frame: NSRect(x: ringD / 2 - dotD / 2, y: ringD / 2 - dotD / 2, width: dotD, height: dotD))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.systemBlue.cgColor
        d.layer?.cornerRadius = dotD / 2
        r.addSubview(d)

        let c = mklabel("Setting in 3…", 17, .semibold, NSColor(white: 0.92, alpha: 1))
        c.frame = NSRect(x: 0, y: 46, width: pw, height: 26)

        panel.addSubview(t); panel.addSubview(s); panel.addSubview(r); panel.addSubview(c)
        content.addSubview(panel)
        w.contentView = content
        w.orderFrontRegardless()

        window = w; ring = r; dot = d; titleLabel = t; subLabel = s; countLabel = c
        ringCenter = NSPoint(x: ringD / 2, y: ringD / 2)
        maxOffset = ringD / 2 - dotD / 2 - 4
    }

    /// Move the dot to reflect live head orientation (radians).
    func update(pitch: Double, roll: Double) {
        guard let dot, window != nil else { return }
        let k = maxOffset / 0.6   // ~34 degrees reaches the rim
        var dx = CGFloat(roll) * k
        var dy = -CGFloat(pitch) * k
        let mag = (dx * dx + dy * dy).squareRoot()
        if mag > maxOffset, mag > 0 { dx *= maxOffset / mag; dy *= maxOffset / mag }
        dot.frame.origin = NSPoint(x: ringCenter.x + dx - dot.frame.width / 2,
                                   y: ringCenter.y + dy - dot.frame.height / 2)
    }

    func setCountdown(_ n: Int) { countLabel?.stringValue = "Hold it. Setting in \(n)…" }

    func finish(angle: Double) {
        titleLabel?.stringValue = "Calibrated ✓"
        titleLabel?.textColor = .systemGreen
        subLabel?.stringValue = "Baseline set. You're being tracked."
        countLabel?.stringValue = String(format: "Captured: head at %.0f° from level", angle)
        if let dot {
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.frame.origin = NSPoint(x: ringCenter.x - dot.frame.width / 2,
                                       y: ringCenter.y - dot.frame.height / 2)
        }
    }

    func dismiss() {
        guard window != nil else { return }
        window?.orderOut(nil)
        window = nil; ring = nil; dot = nil; titleLabel = nil; subLabel = nil; countLabel = nil
    }

    private func mklabel(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.alignment = .center
        t.drawsBackground = false
        t.isBezeled = false
        return t
    }
}

// MARK: - Full-screen red countdown shown on a nudge

final class NudgeOverlay {
    private var window: NSWindow?
    private var timer: Timer?
    private var number: NSTextField?
    private var count = 5

    func show() {
        // Already on screen? Just restart the countdown.
        if window != nil {
            count = 5
            number?.stringValue = "5"
            timer?.invalidate()
            startTimer()
            return
        }
        guard let screen = NSScreen.main else { return }
        let size = screen.frame.size

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver           // float above normal windows
        w.ignoresMouseEvents = true      // clicks pass through; never blocks work
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.hasShadow = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor

        let boxW = min(640, size.width * 0.45)
        let boxH = boxW * 0.72
        let box = NSView(frame: NSRect(x: (size.width - boxW) / 2, y: (size.height - boxH) / 2,
                                       width: boxW, height: boxH))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.systemRed.cgColor
        box.layer?.cornerRadius = 28

        let title = NSTextField(labelWithString: "SIT UP STRAIGHT")
        title.font = .systemFont(ofSize: 38, weight: .heavy)
        title.textColor = .white
        title.alignment = .center
        title.frame = NSRect(x: 0, y: boxH - 96, width: boxW, height: 52)

        let num = NSTextField(labelWithString: "\(count)")
        num.font = .systemFont(ofSize: 170, weight: .bold)
        num.textColor = .white
        num.alignment = .center
        num.frame = NSRect(x: 0, y: (boxH - 180) / 2 - 24, width: boxW, height: 180)

        box.addSubview(title)
        box.addSubview(num)
        content.addSubview(box)
        w.contentView = content
        w.orderFrontRegardless()

        window = w
        number = num
        count = 5
        num.stringValue = "5"
        startTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.count -= 1
            if self.count <= 0 { self.dismiss() }
            else { self.number?.stringValue = "\(self.count)" }
        }
    }

    func dismiss() {
        guard window != nil else { return }
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
        window = nil
        number = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
