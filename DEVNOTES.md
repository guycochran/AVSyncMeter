# DEVNOTES

Working tree: `/Users/guycochranclawdbot/Developer/AVSyncMeter`  
Bundle ID: `com.guycochran.AVSyncMeter`  
Xcode: 26.6 (17F113) on macOS 27.0. Simulator SDK is **iPhoneSimulator 26.5 (23F81a)**; installed runtime is **iOS 27.0 (24A5408d)**.

## Do not stall on the destination mismatch

`xcodebuild -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'` is **ineligible** on this machine. `actool` also refuses that SDK/runtime pair (asset catalog omitted from the target for that reason). Do **not** reinstall Xcode unless a later stage truly cannot build or run.

Use the launch path that already works:

```bash
cd ~/Developer/AVSyncMeter
xcodebuild -project AVSyncMeter.xcodeproj -target AVSyncMeter \
  -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO build

xcrun simctl boot 3781E203-7DCA-417E-A2DB-77F6A8A823E7   # iPhone 17 Pro, ignore if already booted
xcrun simctl install 3781E203-7DCA-417E-A2DB-77F6A8A823E7 \
  build/Debug-iphonesimulator/AVSyncMeter.app
xcrun simctl launch 3781E203-7DCA-417E-A2DB-77F6A8A823E7 com.guycochran.AVSyncMeter
```

Engine tests (no hardware). A constant offset must stay flat; a synthetic N ms delay must move the median by N:

```bash
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  AVSyncMeter/Engine/FrameRate.swift \
  AVSyncMeter/Engine/SyncTypes.swift \
  AVSyncMeter/Engine/MeasurementStatistics.swift \
  AVSyncMeter/Engine/CaptureClock.swift \
  AVSyncMeter/Engine/VideoFlashDetector.swift \
  AVSyncMeter/Engine/AudioPulseDetector.swift \
  AVSyncMeter/Engine/SyncMeasurementEngine.swift \
  AVSyncMeterTests/SyntheticRig.swift \
  AVSyncMeterTests/HostHarness.swift \
  -o /tmp/AVSyncMeterHostTests && /tmp/AVSyncMeterHostTests
```

`xcodebuild test` cannot attach to the 27.0 sim until SDK and runtime match. The XCTest target still compiles.

Stage 10: installed and launched on Guy Cochran’s iPhone (2) (UDID 00008120-001A6C2E1100201E). Simulator still cannot prove camera/mic measurement.

## External validation (do not bundle)

First live check used an **external** Harkwood Sync-One2 test movie, not shipped with this repo:

- Description: 1080p 29.97 H.264 AAC stereo standard
- Source: https://harkwood.co.uk/products/sync-one2/test-files/

Guy reported it worked and the reading looked right. Do not download, commit, or redistribute that media.

## Mid-show calibrate / zero

On a known-good source, tap **ZERO** on the main meter (not only the Settings slider). That stores `calibrationOffset = measuredOffset − 0` from the median of valid samples (or the current pair) and applies it immediately; displayed offset and Mitti delay use `measured − calibration`. **SET TRUE** uses a known true offset instead of 0. **CLEAR** returns to none applied (0), which is not “sensor latency is zero.” **UNDO LAST CAL** restores the previous stored value once.

## Measurement core rewrite (build 5)

Video PTS and audio PTS are no longer subtracted raw. `CaptureClock` maps each stream onto host seconds. Detectors stamp the first flash edge and the beep onset (not a lagging adaptive baseline). Pairing is chronological 1:1. Build 6: do not publish pairs until CaptureClock is settled; 400 ms audio refractory; ±250 ms max pair offset. Build 7: freeze slope at settle, do not fit callback hostNow, 400 ms video holdoff, lock AE/AWB/focus. Install with devicectl only — do not launch. Do not upload TestFlight until Guy says so.


## Build 6 (clock settle + one onset per beep)

On-device 0.1.2 (5) SHA 9497a4d published unlocked CaptureClock hits (first readings +20…+55 / −7…−11 / +40) and retriggered the audio detector on ring-down (mask 220 ms, threshold 0.001 above env). Later true pairs were ~+6 ms. Build 6 holds pairs until both stream fits are settled, uses 400 ms dead time + quiet re-arm, and expires extra pulses outside ±250 ms.

## Build 7 (freeze + video holdoff + AE lock)

On-device 0.1.2 (5) still informs this pass: first unlocked hits +55/−11 SPAN 65 were garbage; later ~+6 ms was real residual; extra AUDIOPULSE was ring-down. Build 6 gated unsettled clocks and audio, but (6) still slope-fit session-mapped PTS against callback hostNow (double map), kept blending slope after settle (4 s half-life), used an 8-frame (~133 ms) video holdoff, and never locked AE/AWB/focus. Build 7 freezes slope at settle (force at 2.5 s, drop two events per stream after the gate), uses mapped PTS as both axes on the live path, 400 ms video holdoff + dark re-arm, and locks metering while measuring. Do not hide the ~+6 ms phone residual. Do not install from this tree unless Guy plugs in for install-without-launch.

