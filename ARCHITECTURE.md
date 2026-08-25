# Architecture

The raw measurement engine is independent of SwiftUI. UI observes `MeasurementSession`. Tests inject timestamps into `SyncMeasurementEngine` with no capture hardware, and drive detectors with synthetic luma / PCM.

## Pipeline

```
AVCaptureSession (one session)
        │
        ├── AVCaptureVideoDataOutput  →  CaptureClock (.video)  →  VideoFlashDetector
        │         PTS → master → host         unified seconds            │
        │                                                               ▼
        └── AVCaptureAudioDataOutput  →  CaptureClock (.audio)  →  AudioPulseDetector
                  PTS → master → host         unified seconds            │
                                                                        ▼
                                                              SyncMeasurementEngine
                                                                        │
                                                                        ├── chronological 1:1 pair
                                                                        ├── MeasurementStatistics
                                                                        └── DiagnosticEvent log
                                                                        │
                                                                        ▼
                                                              MeasurementSession  →  SwiftUI
```

## Capture (`CaptureManager`)

- One `AVCaptureSession`.
- Back wide camera + built-in microphone.
- Video: bi-planar full-range YUV (`420f`). Luma is read from plane 0. 60 fps is requested when the active format allows it.
- Audio: `AVCaptureAudioDataOutput` as 48 kHz mono float32.
- **Timing rule:** `CMSampleBufferGetPresentationTimeStamp` (or output PTS), converted with `CMSyncConvertTime` from `session.masterClock` onto `CMClockGetHostTimeClock()`. That session-mapped PTS *is* unified time. `CaptureClock` may rate-map a synthetic PTS vs a stable host (tests / 1000 ppm), but the live path never slope-fits mapped PTS against callback `hostNowSeconds()`. No `Date()`, no UI timestamps, no independent timers for the offset.
- Focus may lock while measuring. **Do not lock auto-exposure** — locking AE on a dark monitor or mid-flash flattens luma so the white flash never crosses the detector threshold. 400 ms video holdoff swallows AE-recovery double-pumps. AWB stays continuous. HDR and low-light boost stay off.
- Observed capture fps is estimated from a short run of video PTS deltas (display only).

## Unified clock (`CaptureClock`)

Each stream keeps a running timebase:

```
unified += (pts − lastPTS) × slope
slope   = d(host) / d(pts)   // locked after ~0.6 s, frozen at settle
```

On the live path, session-mapped PTS is already host time (`pts == host`), so each stream slope freezes at 1.0 and cannot see capture-30.000 vs file-29.97. After both stream fits freeze, a second fit rate-locks **audio vs video unified times**: each stream's unified time vs observation index, divided by a snapped nominal period (integer fps for video, standard audio buffer sizes — not 29.97, or the 1000 ppm would snap away). `relativeSlope = rate_audio / rate_video`. Video then advances on a running timebase with that slope. Freeze the *fitted* A−V slope after settle (not 1.0 unless they actually match). Do not fit callback `hostNow`. The relative intercept is not applied, so a ~+6 ms phone residual is not absorbed.

Pairs are **not published** until both stream fits *and* the relative A−V fit are *settled* (locked, ≥1 s span, slope stable — or force-settled after ~2.5 s). Slope **freezes** at settle so a 15–25 beep pass cannot walk. The first two detector events per stream after the gate opens are dropped; settling-period events are never queued. A PTS discontinuity (backwards jump) resets and re-locks. Unlocked hits never enter last-25 or the median. The UI shows CLOCK SETTLING / WALK — (clock settling).

Audio is the high-resolution reference in the sense that onset is sample-accurate on that timebase; video is mapped onto the same rate. A 1000 ppm relative PTS-rate error (30.000 vs 29.97, ≈ 1 ms per 1 Hz beep) becomes a relative slope ≠ 1 and is removed. Residual mean sensor delay is a constant (ZERO / SET TRUE).

Diagnostics shows video/audio slope, ppm vs host, and relative A−V ppm.

## Visual flash (`VideoFlashDetector`)

No computer vision. Each frame:

1. Average luminance in a configurable central square (overlaid on the preview).
2. Maintain a **dark floor** updated only on quiet frames (not during the flash, not during holdoff).
3. Fire on the **first** frame whose rise vs the previous frame clears the threshold *and* sits above the dark floor.
4. Latch + **~400 ms** holdoff, re-arm on a **relative drop from the flash peak** toward the pre-flash floor (not an absolute dark that locked AE may never reach). One flash is one event. (8 frames at 60 fps was ~133 ms and let a ~150 ms double-flash steal the next pulse.)

`processLuminance(_:timestampSeconds:)` is the hardware-free test hook.

## Audio pulse (`AudioPulseDetector`)

1. Convert the buffer to mono float.
2. Scan short hops for RMS vs a noise floor that updates **only when quiet**.
3. A high trigger (hysteresis) decides that a beep happened.
4. Onset is walked back to the first sample over a **low** noise-floor multiple, so AGC cannot slide the stamp 1 ms/s.
5. Mask for ~400 ms (Harkwood is 1 Hz) and re-arm only after the envelope goes quiet so ring-down is not a second event. Threshold sits on a quiet-only floor with real headroom, not 0.001 above env.

No pitch detection.

## Pairing (`SyncMeasurementEngine`)

Queues unmatched flashes and pulses, sorted by unified time. Oldest flash vs oldest pulse: they pair only if `|audio − video|` is inside `maxPairOffsetSeconds` (default ±250 ms). Otherwise the older head expires unpaired, so a 200–400 ms ring-down replica cannot steal the next 1 Hz flash. `pairingWindowSeconds` (default 1 s) is how long a lone event waits. No nearest-neighbour stealing, no accumulating pairing debt.

```
offsetMilliseconds = (audioUnified − videoUnified) * 1000
```

See `SyncSignConvention` in `SyncTypes.swift`.

`ingestExternalTimedEvents` is the hook for a future dual-channel sampler (USB audio: photodiode + mic, shared 48 kHz clock). That sampler is not implemented.

## Statistics (`MeasurementStatistics`)

Keeps **all** raw paired samples. Recomputes outliers with median + MAD (`k * 1.4826 * MAD`). Snapshot: current, mean, median, min, max, sample stddev, valid count, rejected/unpaired, outlier count, stability flag, calibration, **walk ms/beep** (OLS slope of valid offsets vs index).

Never promotes one event to “the answer.” The main headline uses the median of valid samples minus calibration; the last-25 table still lists each hit.

## Session and UI

`MeasurementSession` owns capture, both detectors, the clock, and the engine. It hops capture callbacks onto a serial measure queue, then publishes to the main thread.

SwiftUI (`MeasurementView`) is dark, low-decoration, venue-friendly: preview + target, huge AUDIO EARLY/LATE + ms, recommended delay, fps/frames, stats, SYNC STABLE/UNSTABLE, WALK ms/beep, Start/Stop/Reset. Settings, Diagnostics, and a Phase 2 test signal are sheets.

## Calibration

`correctedOffset = measuredOffset - calibrationOffset`, persisted in `AppSettings`. Default 0 is displayed as none applied.

## Tests

`AVSyncMeterTests/SyncMeasurementEngineTests.swift` and `WalkAndClockTests.swift` are the XCTest target. `HostHarness.swift` + `SyntheticRig.swift` is a macOS `@main` runner used when `xcodebuild test` cannot attach to the installed iOS 27 simulator runtime.

The harness requires a constant synthetic offset to stay flat, a +164 ms audio step to move the median by ~164 ms, and an already-mapped 30.000 vs 29.97 (1000 ppm) pass whose reported offsets stay flat. Those last cases did not exist when the meter walked ~1 ms/beep on a 29.97 file at 30 fps capture.

## File map

| Path | Role |
| --- | --- |
| `Engine/SyncTypes.swift` | Sign convention, events, snapshot |
| `Engine/FrameRate.swift` | 23.976–60 including 1001-family rates |
| `Engine/CaptureClock.swift` | Per-stream PTS → host timebase + relative A−V rate-lock |
| `Engine/VideoFlashDetector.swift` | First-edge luma flash |
| `Engine/AudioPulseDetector.swift` | Onset with frozen noise floor |
| `Engine/SyncMeasurementEngine.swift` | Chronological 1:1 pairing |
| `Engine/MeasurementStatistics.swift` | Stats + MAD + walk |
| `Engine/AppSettings.swift` | UserDefaults |
| `Engine/MeasurementSession.swift` | Glue (not the algorithm) |
| `Capture/CaptureManager.swift` | Single AVCaptureSession + PTS conversion |
| `UI/*` | SwiftUI + preview overlay |
