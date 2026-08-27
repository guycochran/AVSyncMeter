# AV Sync Meter

Independent live-event A/V sync meter. Audience-position measurement: Point the iPhone camera at a projector or LED wall. The microphone hears the PA. Play a flash + beep test pattern. The app reports how far audio leads or lags video, in milliseconds and frames, plus a Mitti audio-delay recommendation.

License: MIT. This is a first prototype. It is **not** laboratory-grade. Phone camera and microphone processing can introduce measurement bias. For critical systems, verify results against a known reference.

Local only. No analytics. No network required. The app does not record or permanently store camera or microphone media. It keeps timing events and statistics in memory for the current session.

## What it measures

From the seat:

`Mitti → Blackmagic UltraStudio SDI out → SDI run → SDI-to-HDMI → LCD / projector / LED` for picture, and `Mitti Audio Output → mixer → amp → PA` for sound.

Acoustic travel from the loudspeakers **is part of the measurement**. The app does not auto-correct for speaker distance. That is the point of measuring from the audience.

## Sign convention

```
offsetMilliseconds = audioTimestamp - videoTimestamp
```

- **AUDIO LATE** (positive, a>v, beep after flash): picture before sound. **Reduce audio delay by offset ms**.
- **AUDIO EARLY** (negative, a<v, beep before flash): sound before picture. **Increase audio delay by |offset| ms** (Mitti Audio Output or mixer). This is the common house case at delay 0 — picture is late, audio is always fast.

Engine samples stay `audio − video` (not negated). Example: `+193 ms` at 29.97 fps is about **5.79 frames** AUDIO LATE — **reduce 193 ms**.

## How to measure

1. Play a repeating flash + short beep (about 1 Hz works well). Prefer the owned `TestMedia/AVSyncMeter-Test-29.97.mov` (PCM, 5-frame white, 2 ms 3 kHz click, A=V) in Mitti, from the start. A house generator, a timeline, or the in-app Phase 2 test signal can be used. Third-party test movies (including Harkwood) may be used as **external signals only**; they are not redistributed with this app.
2. Sit where you care about sync.
3. Open AV Sync Meter. Grant Camera and Microphone.
4. Aim the green target at the flash area on the screen.
5. Set program frame rate in Settings (29.97/59.94 lock capture to 60_000/1001 then 30_000/1001; if the camera cannot, the footer says NTSC lock MISS instead of silent 1/30. 30/60 stay integer). It also converts ms → frames.
6. Tap **START** (START/STOP/RESET stay on screen). Status is **LISTENING** until pairs arrive.
7. Home shows AUDIO EARLY or AUDIO LATE, the ms number (median of valid samples minus calibration), and one matching advice line (Increase / Reduce audio delay by X). Type that into Mitti Audio Output; the app does not push delay. Point the camera at the show (projector/LED), mic at the PA. STABLE is the trust signal (SPAN on the same line). Last-25, VU, RAW/CORRECTED, and the long honesty notes live in DIAG.
8. **SYNC STABLE** means the standard deviation of valid samples is under the Settings threshold (default 8 ms) and you have at least three valid pairs.
9. Apply the recommended delay in Mitti. Re-measure.

Mid-show **ZERO / SET TRUE / CLEAR** live in DIAG and Settings — not the first thing on the home screen. On a known-good source (a reference you trust is actually in sync), tap **ZERO**: the app stores `calibrationOffset = measuredOffset − 0` (median of valid pairs if you have any, otherwise the current pair) and the displayed AUDIO EARLY/LATE and Mitti delay become the corrected value. **SET TRUE** does the same against a known offset (example: this source is actually +40 ms AUDIO LATE / engine a−v → `calibrationOffset = measured − 40`; storage is not inverted). **CLEAR** writes 0 = none applied — that is not a claim of zero sensor latency. Phone camera/mic processing can still bias the reading.

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
  AVSyncMeter/Engine/MeterHistory.swift \
  AVSyncMeter/Engine/CaptureClock.swift \
  AVSyncMeter/Engine/VideoFlashDetector.swift \
  AVSyncMeter/Engine/AudioPulseDetector.swift \
  AVSyncMeter/Engine/SyncMeasurementEngine.swift \
  AVSyncMeter/Engine/TestSignalBeep.swift \
  AVSyncMeterTests/SyntheticRig.swift \
  AVSyncMeterTests/HostHarness.swift \
  -o /tmp/AVSyncMeterHostTests
/tmp/AVSyncMeterHostTests
```

## Settings

Frame rate, flash/audio sensitivity, central target size, pairing window (±0.80 s default), optional manual thresholds, stability threshold, outlier MAD k, VU history window (1–90 s, default 90 s, live LUMA+MIC plus FLASH/AUDIOPULSE/PAIR marks), and a persisted known-correction (calibration). Default calibration is **0 ms = none applied**, not “sensor latency is zero”.

Distance helper (343 m/s, ~1.1 ft/ms) is **off by default** and never subtracted from the offset.

## Known limitations

See [ACCURACY.md](ACCURACY.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

- Phone ISP, exposure, rolling shutter, mic processing, AGC, and buffer size all add uncertainty. Capture timestamps are unified onto one host clock; leftover bias from unlocked *source* clocks (separate video vs audio interfaces) can remain in the median. A 1 ms/beep walk on a constant delay is a meter bug, not house truth.
- Simulator cannot perform a live optical/acoustic measurement.
- In-app test signal is a simple 1 Hz white flash + generated PCM beep (Phase 2). Same-phone loopback while measuring the house injects extra AUDIOPULSE. Prefer a timeline-generated pattern for real work.
- Stage-noise: only beep-like (short sharp) audio pairs. Deck speech in the pairing window must not steal the house beep (including ±500 ms).
- Do not treat a single pair as truth. Use repeats and the median.

## External validation

The reference file we own is `TestMedia/AVSyncMeter-Test-29.97.mov` (1080p 29.97 H.264 + PCM stereo, 5-frame white, 2 ms 3 kHz click, A=V). Generate with `python3 Scripts/generate_avsyncmeter_test_movie.py`. First device check used an external Harkwood Sync-One2 file; that media is **not** bundled or redistributed.
