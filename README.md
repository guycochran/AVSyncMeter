# AV Sync Meter

Independent live-event A/V sync meter. Audience-position measurement: Point the iPhone camera at a projector or LED wall. The microphone hears the PA. Play a flash + beep test pattern. The app reports how far audio leads or lags video, in milliseconds and frames, plus a Mitti audio-delay recommendation.

License: MIT. This is a first prototype. It is **not** laboratory-grade. Phone camera and microphone processing can introduce measurement bias. For critical systems, verify results against a known reference.

Local only. No analytics. No network required. The app does not record or permanently store camera or microphone media. It keeps timing events and statistics in memory for the current session.

## What it measures

From the seat:

`Mitti → Blackmagic UltraStudio → SDI → HDMI → projector` for picture, and console/PA for sound.

Acoustic travel from the loudspeakers **is part of the measurement**. The app does not auto-correct for speaker distance. That is the point of measuring from the audience.

## Sign convention

```
offsetMilliseconds = audioTimestamp - videoTimestamp
```

- **AUDIO EARLY** (positive): sound before picture. Recommended Mitti Audio Delay = **+offset ms**.
- **AUDIO LATE** (negative): picture before sound. **Reduce** existing audio delay by **|offset| ms**.

Example: `+193 ms` at 29.97 fps is about **5.79 frames**. Recommended delay: **+193 ms**.

## How to measure

1. Play a repeating flash + short beep (about 1 Hz works well). A house generator, a timeline in Mitti, or the in-app Phase 2 test signal can be used. Third-party test movies may be used as **external signals only**; they are not bundled or redistributed with this app.
2. Sit where you care about sync.
3. Open AV Sync Meter. Grant Camera and Microphone.
4. Aim the green target at the flash area on the screen.
5. Set program frame rate in Settings (display only; it converts ms → frames).
6. Tap **START**. Status is **LISTENING** until pairs arrive.
7. Watch Current / Average / Median / Variation. Prefer the median of several hits.
8. **SYNC STABLE** means the standard deviation of valid samples is under the Settings threshold (default 8 ms) and you have at least three valid pairs.
9. Apply the recommended delay in Mitti. Re-measure.

Mid-show **ZERO / SET TRUE / CLEAR** live on the main meter. On a known-good source (a reference you trust is actually in sync), tap **ZERO**: the app stores `calibrationOffset = measuredOffset − 0` (median of valid pairs if you have any, otherwise the current pair) and the displayed AUDIO EARLY/LATE and Mitti delay become the corrected value. **SET TRUE** does the same against a known offset (example: this source is actually +40 ms AUDIO EARLY → `calibrationOffset = measured − 40`). **CLEAR** writes 0 = none applied — that is not a claim of zero sensor latency. Phone camera/mic processing can still bias the reading.

## Camera and microphone permissions

On first Start, iOS asks for camera and microphone. The Info.plist strings explain the use. If you denied them, enable Camera and Microphone for AV Sync Meter in iOS Settings.

The simulator has no usable camera. The UI still runs. Diagnostics can inject synthetic pairs so you can see AUDIO EARLY / delay / frames / stats without hardware.

## How to build

Requirements: macOS with Xcode 26 (this project was built with Xcode 26.6 / 17F113). Deployment target iOS 18. Bundle id `com.guycochran.AVSyncMeter`.

```bash
cd ~/Developer/AVSyncMeter
xcodegen generate   # optional if the xcodeproj is already present
xcodebuild -project AVSyncMeter.xcodeproj -target AVSyncMeter \
  -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO build
```

Open `AVSyncMeter.xcodeproj` in Xcode, select an iPhone, Run.

**Note:** this Xcode’s iPhone simulator SDK is 26.5 while the installed simulator runtime is iOS 27.0. `xcodebuild -destination 'name=iPhone 17 Pro,OS=27.0'` may refuse the destination, and `actool` fails if `Assets.xcassets` is compiled against that pair. The project therefore omits the asset catalog from the target. Build with `-sdk iphonesimulator` / `-target AVSyncMeter` as above, then:

```bash
xcrun simctl boot 3781E203-7DCA-417E-A2DB-77F6A8A823E7
xcrun simctl install 3781E203-7DCA-417E-A2DB-77F6A8A823E7 \
  build/Debug-iphonesimulator/AVSyncMeter.app
xcrun simctl launch 3781E203-7DCA-417E-A2DB-77F6A8A823E7 com.guycochran.AVSyncMeter
```

On a physical iPhone, use automatic signing in Xcode.

## Tests

XCTest cases live in `AVSyncMeterTests/SyncMeasurementEngineTests.swift` and cover exact sync, ±200 ms, repeats, jitter, missing/extra events, outliers, and 29.97 / 59.94 frame conversion. The engine is fully injectable without AVFoundation hardware.

Because `xcodebuild test` cannot attach to the iOS 27 runtime with the 26.5 SDK, the same cases also run as a host harness:

```bash
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  AVSyncMeter/Engine/FrameRate.swift \
  AVSyncMeter/Engine/SyncTypes.swift \
  AVSyncMeter/Engine/MeasurementStatistics.swift \
  AVSyncMeter/Engine/VideoFlashDetector.swift \
  AVSyncMeter/Engine/AudioPulseDetector.swift \
  AVSyncMeter/Engine/SyncMeasurementEngine.swift \
  AVSyncMeterTests/HostHarness.swift \
  -o /tmp/AVSyncMeterHostTests
/tmp/AVSyncMeterHostTests
```

## Settings

Frame rate, flash/audio sensitivity, central target size, pairing window (±1 s default), optional manual thresholds, stability threshold, outlier MAD k, and a persisted known-correction (calibration). Default calibration is **0 ms = none applied**, not “sensor latency is zero”.

Distance helper (343 m/s, ~1.1 ft/ms) is **off by default** and never subtracted from the offset.

## Known limitations

See [ACCURACY.md](ACCURACY.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

- Phone ISP, exposure, rolling shutter, mic processing, AGC, and buffer size all add uncertainty.
- Simulator cannot perform a live optical/acoustic measurement.
- In-app test signal is a simple 1 Hz white flash + system click (Phase 2). Prefer a timeline-generated pattern for real work.
- Do not treat a single pair as truth. Use repeats and the median.

## External validation

First device check used an external Harkwood Sync-One2 file (1080p 29.97 H.264 AAC stereo standard) from https://harkwood.co.uk/products/sync-one2/test-files/. The media is **not** bundled. Guy reported it worked and the reading looked right.
