# RESUME HERE — SG Posture

Start-here note for picking this project back up. Read this first, then `README.md` for the app details.

Last worked: mid-June 2026. Repo: https://github.com/sgc4e/sg-posture (private).

---

## What this is

A macOS menu-bar app that reads your **AirPods' head-motion** (via CoreMotion) and tracks neck posture: shows a live status, logs time in each posture, and throws a red 5-second countdown on screen when you slouch. Installed at `/Applications/SGPosture.app`, launches at login.

## State: working, with one real limitation

**Works (verified):**
- Live posture detection (good / leaning / slouch), color-coded menu-bar icon.
- Guided calibration (blue dot tracks your head, 3-2-1, green "Calibrated"). Baseline persists.
- Red full-screen 5-second countdown nudge on sustained slouch. Counts a daily nudge tally.
- Daily logging + on-demand report + a 9pm end-of-day report.
- It logged ~3 hours of real data in one day, so the full pipeline is proven.

**The one thing that bit us repeatedly (READ THIS):**
> AirPods only send head-motion to the Mac while they are **worn AND the Mac's active audio output**. When they go idle (you pause audio, they hop to your phone, or macOS sleeps them), motion stops and the app has nothing to track. This is an Apple constraint, not an app bug.

The app now **auto-recovers** (resumes within ~15s when the stream returns, no restart). But it can only track during AirPods+Mac audio sessions, **not silently 24/7**.

## The decision waiting for you

Pick one:
1. **Keep the AirPods approach** and accept "tracks during audio sessions" (calls, music, focus time). Good enough if you wear AirPods on the Mac a lot.
2. **Switch the sensor** for reliable all-day tracking: webcam-based posture detection, a dedicated posture wearable, or iPhone-hosted (AirPods motion is more continuous with an iPhone than a Mac).

If you want all-day hands-off tracking, option 2 is the honest path. AirPods-over-Mac fights you on this.

## 30-second "is it working" test

1. AirPods in your ears.
2. Play any audio from the **Mac** through them (Music / a video).
3. The number next to the menu-bar icon should start moving. Nod and watch it change.
4. Click the icon → **Calibrate good posture** (sit tall, hold for the 3-count).

If the number doesn't move: the AirPods aren't streaming to the Mac (not worn, or audio is on another device). That's the limitation above, not a crash.

## Build / run / update

```bash
cd "/Users/sg/Documents/Claude/Projects/sg posture"
bash build-app.sh          # compile, sign, install to /Applications, relaunch
INSTALL=0 bash build-app.sh  # compile only, don't install
```
Needs Xcode Command Line Tools (Swift). No full Xcode. Always launch the `.app`, never the raw binary (it has no Info.plist and macOS will kill it on motion access).

## Where things live

- **Code:** `Sources/SGPosture/main.swift` (the whole app, one file). Tunables at the top (angle bands, nudge hold/cooldown, EOD time, smoothing).
- **Build:** `build-app.sh`.
- **App data (not in repo):** `~/Library/Application Support/SGPosture/`
  - `posture-log.json` — daily seconds per state + nudge count.
  - `reports/` — saved end-of-day markdown reports.
  - `last-launch.txt` — live motion diagnostic (`active` / `samples` / `auth` / `hasData`). **This is your debugging friend**: if data isn't flowing, read this. `samples` climbing = motion is live.

## The 9pm report

A scheduled task (`posture-eod-report`, in the Claude app's Scheduled list) reads the day's log at 21:00 and delivers the slouch % to an **Apple Note "SG Posture - Daily"** + **Telegram**, and to **Roam** if that connector is live in the run. It does NOT auto-write to Roam reliably (the connector isn't always loaded). To make Roam the primary surface, enable the roam connector on the app the task runs in.

## Recent commits (what got fixed, newest first)

- `7bf06be` auto-recover when the motion stream goes silent (no more manual restart).
- `62eda97` fix motion streaming + ~5x time over-counting (subscribe to motion exactly once).
- `1ec3f1e` keep the menu-bar app alive when an overlay window closes (it was quitting after every nudge).

## Gotchas

- **iCloud once wiped the local `.git`** here (this folder is under iCloud-synced `~/Documents`). The GitHub remote is the safety net. Push often. Consider moving the project off the iCloud path.
- **Rebuilds can reset the macOS Motion permission** (ad-hoc signature changes). If it goes quiet after a rebuild, re-grant in System Settings ▸ Privacy & Security ▸ Motion & Fitness.
- Calibration lives in `defaults` under `in.c4e.sgposture`; "Clear calibration" wipes it and you re-calibrate.
