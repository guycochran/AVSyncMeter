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

Engine tests (no hardware):

```bash
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  AVSyncMeter/Engine/FrameRate.swift \
  AVSyncMeter/Engine/SyncTypes.swift \
  AVSyncMeter/Engine/MeasurementStatistics.swift \
  AVSyncMeter/Engine/VideoFlashDetector.swift \
  AVSyncMeter/Engine/AudioPulseDetector.swift \
  AVSyncMeter/Engine/SyncMeasurementEngine.swift \
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
