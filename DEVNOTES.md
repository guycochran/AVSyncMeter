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

Video PTS and audio PTS are no longer subtracted raw. `CaptureClock` maps each stream onto host seconds. Detectors stamp the first flash edge and the beep onset (not a lagging adaptive baseline). Pairing is chronological 1:1. Build 6: do not publish pairs until CaptureClock is settled; 400 ms audio refractory; ±250 ms max pair offset. Build 7: freeze slope at settle, do not fit callback hostNow, 400 ms video holdoff. Build 8: do not lock AE (it killed FLASH). Install with devicectl only — do not launch. Do not upload TestFlight until Guy says so.


## Build 6 (clock settle + one onset per beep)

On-device 0.1.2 (5) SHA 9497a4d published unlocked CaptureClock hits (first readings +20…+55 / −7…−11 / +40) and retriggered the audio detector on ring-down (mask 220 ms, threshold 0.001 above env). Later true pairs were ~+6 ms. Build 6 holds pairs until both stream fits are settled, uses 400 ms dead time + quiet re-arm, and expires extra pulses outside ±250 ms.

## Build 7 (freeze + video holdoff + AE lock)

On-device 0.1.2 (5) still informs this pass: first unlocked hits +55/−11 SPAN 65 were garbage; later ~+6 ms was real residual; extra AUDIOPULSE was ring-down. Build 6 gated unsettled clocks and audio, but (6) still slope-fit session-mapped PTS against callback hostNow (double map), kept blending slope after settle (4 s half-life), used an 8-frame (~133 ms) video holdoff, and never locked AE/AWB/focus. Build 7 freezes slope at settle (force at 2.5 s, drop two events per stream after the gate), uses mapped PTS as both axes on the live path, 400 ms video holdoff + dark re-arm, and locks metering while measuring. Do not hide the ~+6 ms phone residual. Do not install from this tree unless Guy plugs in for install-without-launch.

## Build 8 (do not lock AE; re-arm on relative drop)

On-device 0.1.2 (7) SHA 1370425: AUDIOPULSE every ~1 s, REJECTEDUNPAIRED ~3 s later, **no FLASH, no PAIRED**. Audio worked; video flash detector was dead. Previous builds logged FLASH luma ~0.87. Cause: `applyMeteringLock()` froze AE/AWB/AF on session start. Locking exposure on the dark monitor (or mid-flash) crushes ISO/exposure so the white flash never crosses thr ~0.124, and/or re-arm-on-absolute-dark never sees dark after the 400 ms holdoff. CLOCK SETTLING dropping two events cannot explain a whole pass with zero FLASH.

Build 8 keeps CaptureClock freeze, session-mapped PTS, 400 ms audio refractory, ±250 ms pair window, CLOCK SETTLING gate, sign convention, median headline, last-25, ZERO, cal 0 default. Stops locking AE/AWB (focus lock only; HDR/low-light boost still off). Video still holds ~400 ms so persistence is one event, but re-arms on a relative drop from the flash peak toward the pre-flash floor. Do not hide the ~+6 ms phone residual. Install with devicectl only — do not launch. No TestFlight.

## Build 9 (relative A−V rate-lock after host-map)

On-device 0.1.2 (8) SHA 9d80961: FLASH+AUDIO working, AE lock off. Headline AUDIO LATE −43, WALK +0.06, SPAN +32.3, VAR +9.6, SYNC UNSTABLE, capture 30.0 fps, 29.97 selected. Last-25 climbed ~+1 ms/beep in two clusters (−34→−23, then −55→−43); overall WALK near 0 was the step cancelling the climb. Capture 30.000 vs file 29.97 is exactly 1000 ppm. Build 7 froze each stream slope at 1.0 after host-map (pts == host), which threw away relative A−V rate correction; HostHarness never simulated 30 vs 29.97 on already-mapped PTS.

Build 9 keeps AE off, callback-hostNow freeze gone, ±250 ms pair window, sign/median/last-25/ZERO/cal 0. After both streams are host-mapped, fit d(audioUnified)/d(videoUnified) and freeze that relative slope (not 1.0 unless they match). PTS discontinuity still re-locks. Do not hide the ~+6 ms phone residual. Do not install.

## Build 10 (lock capture to NTSC 1001 family)

Leftover risk of (9) **is** the downstairs fail: capture reported 30.0 fps with 29.97 selected. Integer 30.000 vs a 29.97 file is 1000 ppm; last-25 climbs ~1 ms/beep even if both stream clocks are true host. Relative A−V on unified buffers stays 1.0, so (9) will not flatten that.

`CaptureManager.lockFrameRateIfPossible` used to force `CMTime(value: 1, timescale: 60)` whenever 59+ was available, and did nothing (default 30.0) when it was not. Build 10 reads the program picker: 29.97/59.94 → 60_000/1001 if 59+ is available, else 30_000/1001. Integer 30/60 pickers still use 1/60 or 1/30. `RelativeAVFit.snapVideoPeriod` now includes 1001-family periods so a true-host 29.97/59.94 capture is not treated as 1000 ppm vs 30/60. AE stays off. (9) relative rate-lock stays. Residual ~+6 ms stays honest. Sign, median, last-25, ZERO, cal 0 unchanged.

HostHarness: integer-30 capture vs 29.97 events walks ~1 ms/beep until this lock is on; with NTSC lock the same constant-delay pass goes FLAT. Keep +164 step, ring-down, extra flash, unsettled empty, (9) already-mapped 1000 ppm tests. Do not install (9).

