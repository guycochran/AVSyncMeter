# Architecture

The raw measurement engine is independent of SwiftUI. UI observes `MeasurementSession`. Tests inject timestamps into `SyncMeasurementEngine` with no capture hardware.

## Pipeline

```
AVCaptureSession (one session)
        │
        ├── AVCaptureVideoDataOutput  →  VideoFlashDetector
        │         presentation PTS              │
        │                                       ▼
        └── AVCaptureAudioDataOutput  →  AudioPulseDetector
                  PTS + sample offset           │
                                                ▼
                                      SyncMeasurementEngine
                                                │
                                                ├── pair nearest in ±window
                                                ├── MeasurementStatistics
                                                └── DiagnosticEvent log
                                                │
                                                ▼
                                      MeasurementSession  →  SwiftUI
```

## Capture (`CaptureManager`)

- One `AVCaptureSession`.
- Back wide camera + built-in microphone.
- Video: bi-planar full-range YUV (`420f`). Luma is read from plane 0.
- Audio: `AVCaptureAudioDataOutput` sample buffers.
- **Timing rule:** `CMSampleBufferGetPresentationTimeStamp`. No `Date()`, no UI timestamps, no independent timers for the offset.
- Observed capture fps is estimated from a short run of video PTS deltas (display only).

## Visual flash (`VideoFlashDetector`)

No computer vision. Each frame:

1. Average luminance in a configurable central square (overlaid on the preview).
2. Maintain an EMA baseline.
3. Fire on a rapid **positive** luminance step above a sensitivity (or manual) threshold.
4. Latch + holdoff so one flash is one event, then re-arm.

`processLuminance(_:timestampSeconds:)` is the hardware-free test hook.

## Audio pulse (`AudioPulseDetector`)

1. Convert the buffer to mono float.
2. Scan short hops for RMS / envelope versus an ambient baseline.
3. On a sharp rise, refine onset to the first sample over threshold.
4. Onset time = buffer media timestamp + sampleOffset.
5. Mask for ~220 ms so reverb is not a second event.

No pitch detection.

## Pairing (`SyncMeasurementEngine`)

Queues unmatched flashes and pulses. Picks the nearest pair whose `|audio − video|` is inside the search window (default ±1 s). Unmatched events older than the window / max age are rejected and counted.

```
offsetMilliseconds = (audioPTS - videoPTS) * 1000
```

See `SyncSignConvention` in `SyncTypes.swift`.

`ingestExternalTimedEvents` is the hook for a future dual-channel sampler (USB audio: photodiode + mic, shared 48 kHz clock). That sampler is not implemented.

## Statistics (`MeasurementStatistics`)

Keeps **all** raw paired samples. Recomputes outliers with median + MAD (`k * 1.4826 * MAD`). Snapshot: current, mean, median, min, max, sample stddev, valid count, rejected/unpaired, outlier count, stability flag, calibration.

Never promotes one event to “the answer.” The main headline uses the median of valid samples minus calibration; the last-25 table still lists each hit.

## Session and UI

`MeasurementSession` owns capture, both detectors, and the engine. It hops capture callbacks onto a serial measure queue, then publishes to the main thread.

SwiftUI (`MeasurementView`) is dark, low-decoration, venue-friendly: preview + target, huge AUDIO EARLY/LATE + ms, recommended delay, fps/frames, stats, SYNC STABLE/UNSTABLE, Start/Stop/Reset. Settings, Diagnostics, and a Phase 2 test signal are sheets.

## Calibration

`correctedOffset = measuredOffset - calibrationOffset`, persisted in `AppSettings`. Default 0 is displayed as none applied.

## Tests

`AVSyncMeterTests/SyncMeasurementEngineTests.swift` is the XCTest target. `HostHarness.swift` is a macOS `@main` runner used when `xcodebuild test` cannot attach to the installed iOS 27 simulator runtime.

## File map

| Path | Role |
| --- | --- |
| `Engine/SyncTypes.swift` | Sign convention, events, snapshot |
| `Engine/FrameRate.swift` | 23.976–60 including 1001-family rates |
| `Engine/VideoFlashDetector.swift` | Luma flash edge |
| `Engine/AudioPulseDetector.swift` | Envelope onset |
| `Engine/SyncMeasurementEngine.swift` | Pairing |
| `Engine/MeasurementStatistics.swift` | Stats + MAD |
| `Engine/AppSettings.swift` | UserDefaults |
| `Engine/MeasurementSession.swift` | Glue (not the algorithm) |
| `Capture/CaptureManager.swift` | Single AVCaptureSession |
| `UI/*` | SwiftUI + preview overlay |
