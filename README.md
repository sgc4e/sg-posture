# SG Posture

A tiny macOS menu-bar app that reads your **AirPods' head-motion sensors** and tells you
about your neck posture. Sit tall, calibrate once, and it nudges you when you slouch.

It works with **AirPods Pro (1/2), AirPods 3, AirPods 4, and AirPods Max** (the models
with a built-in motion sensor). Original AirPods and AirPods 2 have no sensor and will
read "no sensor".

## How it works

The head-tilt data does not come from raw Bluetooth. It comes from Apple's CoreMotion
framework (`CMHeadphoneMotionManager`), which reads the accelerometer + gyroscope inside
the AirPods. The app:

1. Reads your head **pitch** angle ~25x/second.
2. You **calibrate** an upright baseline (your personal 0°).
3. It tracks how far your head tilts forward/down from that baseline:
   - under 10° → **Good** (green)
   - 10°–18° → **Leaning** (amber)
   - over 18° held for 8s → **Slouch** (red) + a sound and a notification.

## Build

Needs Xcode Command Line Tools (Swift). No full Xcode required.

```bash
bash build-app.sh          # compile, bundle, sign, install to /Applications, relaunch
INSTALL=0 bash build-app.sh  # compile only, do not install
```

`build-app.sh` installs the fresh build into `/Applications/SGPosture.app` and relaunches
it so the update takes effect. Launch it any time from Spotlight (type "SGPosture"),
Launchpad, or `open /Applications/SGPosture.app`.

> Always launch `SGPosture.app`, never `.build/release/SGPosture` directly. The raw
> binary has no `Info.plist`, so macOS aborts it the moment it touches motion data. The
> bundle carries the required `NSMotionUsageDescription`.

## First run

1. Put your AirPods in.
2. Launch the app. A small posture icon appears in the menu bar.
3. macOS asks for **Motion & Fitness** access → click **Allow**. (If you miss it:
   System Settings ▸ Privacy & Security ▸ Motion & Fitness.)
4. Sit the way you want to hold yourself, click the icon ▸ **Calibrate good posture**.
5. That's it. The icon shows live tilt and turns amber/red as you droop.

## Daily report

The app counts how long you spend in each posture **while the AirPods are actually
on** (it only counts time when motion samples are streaming, so time with the AirPods
in their case or out of your ears is not counted).

- **Headline:** slouching % = slouch time ÷ assessed time, where *assessed time* is the
  time you wore the AirPods with a calibration set.
- **On demand:** menu ▸ **Today's posture report…** shows today's breakdown (good /
  leaning / slouching, with times and shares) any time.
- **End of day:** at **21:00 local** the app posts a notification with the headline and
  writes a Markdown report to
  `~/Library/Application Support/SGPosture/reports/posture-YYYY-MM-DD.md`.
  Keep the app running (add it to Login Items) so the EOD report fires.
- Raw daily totals live in `~/Library/Application Support/SGPosture/posture-log.json`
  (seconds per state, keyed by date) if you want to chart trends later.

## Tuning

All thresholds live at the top of `Sources/SGPosture/main.swift`:

- `kGoodMax` / `kSlightMax` — the angle bands.
- `kSlouchHold` — seconds of slouch before it nudges (default 8).
- `kNudgeCooldown` — seconds between nudges (default 60).
- `kNudgeSound` — system sound name.
- `kEODHour` / `kEODMinute` — when the end-of-day report fires (default 21:00).
- `kSlouchSign` — **if sitting tall shows red instead of green, set this to `-1.0`** and
  rebuild. (Head-down should read as positive degrees; this flips it if your unit's
  reference frame is reversed.)

Rebuild after any change: `bash build-app.sh`.

## Notes

- Posture is inferred from head pitch, which catches "text neck" (head dropping
  forward/down) well. It does not detect a hunched back if your head stays level.
- Calibration persists across restarts. Re-calibrate any time from the menu.
- To launch at login: System Settings ▸ General ▸ Login Items ▸ add SGPosture.app.
