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
- Video: bi-planar full-range YUV (`420f`). Luma is read from plane 0. Capture frame duration follows the program picker: 60_000/1001 (or 30_000/1001) when 29.97/59.94 is selected, integer 1/60 or 1/30 when 30/60 is selected. Integer 30.000 vs a 29.97 file is 1000 ppm and last-25 climbs ~1 ms/beep even if both stream clocks are true host — (9) relative A−V stays 1.0 and will not flatten that.
- Audio: `AVCaptureAudioDataOutput` (whatever Linear PCM iOS delivers). Session is `playAndRecord` + `measurement` (not voiceChat), mixWithOthers + defaultToSpeaker, no Bluetooth HFP, echo cancellation off, preferred mic wideSpectrum. Parse uses AudioBufferList, int16/int32/float32, loudest-channel mix so a processed/silent plane cannot meter 0.001 while the PA is on the other channel.
- **Timing rule:** `CMSampleBufferGetPresentationTimeStamp` (or output PTS), converted with `CMSyncConvertTime` from `session.masterClock` onto `CMClockGetHostTimeClock()`. That session-mapped PTS *is* unified time. `CaptureClock` may rate-map a synthetic PTS vs a stable host (tests / 1000 ppm), but the live path never slope-fits mapped PTS against callback `hostNowSeconds()`. No `Date()`, no UI timestamps, no independent timers for the offset.
- Focus may lock while measuring. **Do not lock auto-exposure** — locking AE on a dark monitor or mid-flash flattens luma so the white flash never crosses the detector threshold. 400 ms video holdoff swallows AE-recovery double-pumps. AWB stays continuous. HDR and low-light boost stay off.
- Observed capture fps is estimated from a short run of video PTS deltas (display only).

## Unified clock (`CaptureClock`)

Each stream keeps a running timebase:

```
unified += (pts − lastPTS) × slope
slope   = d(host) / d(pts)   // locked after ~0.6 s, frozen at settle
```

On the live path, session-mapped PTS is already host time (`pts == host`), so each stream slope freezes at 1.0 and cannot see capture-30.000 vs file-29.97. After both stream fits freeze, a second fit rate-locks **audio vs video unified times**: each stream's unified time vs observation index, divided by a snapped nominal period (integer *and* 1001-family fps for video, standard audio buffer sizes). Integer-only video snap made true-host 29.97 capture look like 1000 ppm vs 30. `relativeSlope = rate_audio / rate_video`. Video then advances on a running timebase with that slope. Freeze the *fitted* A−V slope after settle (not 1.0 unless they actually match). Do not fit callback `hostNow`. The relative intercept is not applied, so a ~+6 ms phone residual is not absorbed.

Pairs are **not published** until both stream fits *and* the relative A−V fit are *settled* (locked, ≥1 s span, slope stable — or force-settled after ~2.5 s). Slope **freezes** at settle so a 15–25 beep pass cannot walk. The first two detector events per stream after the gate opens are dropped; settling-period events are never queued. A PTS discontinuity (backwards jump) resets and re-locks. Unlocked hits never enter last-25 or the median. The UI shows CLOCK SETTLING / WALK — (clock settling).

Audio is the high-resolution reference in the sense that onset is sample-accurate on that timebase; video is mapped onto the same rate. A 1000 ppm relative PTS-rate error (30.000 vs 29.97, ≈ 1 ms per 1 Hz beep) becomes a relative slope ≠ 1 and is removed. Residual mean sensor delay is a constant (ZERO / SET TRUE).

Diagnostics shows video/audio slope, ppm vs host, and relative A−V ppm.

## Visual flash (`VideoFlashDetector`)

No computer vision. Each frame:

1. Average luminance in a configurable central square (overlaid on the preview).
2. Maintain a **dark floor** updated only on quiet frames (not during the flash, not during holdoff).
3. Trigger on a flash-like pop (rise vs previous frame clears the threshold *and* sits above the dark floor). Stamp the **first rising frame** of that bright run, not the last white frame of a 2-frame pulse. A dim first frame (rolling shutter / camera phase) can miss `flashLike` and trip only on the second frame; walking back keeps a 0.000 ms file in one cluster instead of −50/+11 SPAN.
4. Latch + **~400 ms** holdoff, re-arm on a **relative drop from the flash peak** toward the pre-flash floor (not an absolute dark that locked AE may never reach). One flash is one event. (8 frames at 60 fps was ~133 ms and let a ~150 ms double-flash steal the next pulse.)

`processLuminance(_:timestampSeconds:)` is the hardware-free test hook.

## Audio pulse (`AudioPulseDetector`)

1. Convert the buffer to mono float (AudioBufferList, loudest channel, int16/int32/float32).
2. Scan short hops for RMS vs a noise floor that updates **only when quiet**.
3. A high trigger (hysteresis) decides that a beep happened.
4. Onset is walked back to the first sample over a **low** noise-floor multiple, so AGC cannot slide the stamp 1 ms/s.
5. Mask for ~400 ms (Harkwood is 1 Hz) and re-arm only after the envelope goes quiet so ring-down is not a second event. Threshold sits on a quiet-only floor with real headroom, not 0.001 above env.

Stage-noise: emit isolated house hits on onset. Harkwood measured 1001 ms / 66.7 ms 3 kHz (2 frames), not a 1.000 Hz click; a 200–400 ms periodic tone is still one hit. Dull 15–80 ms PA smear then quiet still events even if the old isBeepLike gate was false. Overlapping/ongoing energy is speech, not a periodic tone; a 1 kHz overlay can still win while speech is held. 400 ms mask after a real beep; quiet re-arm must not fire on the next syllable.

No pitch detection (duration + high-band energy only).

## Pairing (`SyncMeasurementEngine`)

Unpaired flashes stay in a short queue (not keep-latest of one). A 60 fps measure queue can ingest the next 1 Hz flash before a pairable pulse whose onset is still inside the pairing window of the previous flash; dropping that flash as extra was zero pairs with FLASH+AUDIOPULSE marks. Latest pairable pulse still wins; overlapping speech is never queued. They pair only if `|audio − video|` is inside `maxPairOffsetSeconds` (default ±1.00 s). Isolated house hits pair on onset even if the old isBeepLike duration gate was false (Harkwood 1001 ms / 66.7 ms 3 kHz, or a 200–400 ms periodic tone). Overlapping/ongoing speech never pairs, including ±500 ms. Detector 400 ms mask still swallows ring-down. `pairingWindowSeconds` (default 1.00 s) is how long a lone event waits. No accumulating pairing debt.

VU luma/mic and EVT FLASH/AUDIOPULSE/PAIR marks use the same CaptureClock unified seconds as pairing. Wall-clock stamps made 1 Hz spikes look aligned on the strip while `|unified dt|` outside the pairing window never paired. EVT marks follow engine ingest, not a VU envelope threshold.

```
offsetMilliseconds = (audioUnified − videoUnified) * 1000
```

Engine samples are not negated. **Display only:** a>v (offset > 0, beep after flash) → AUDIO LATE / reduce delay; a<v (offset < 0, beep before flash) → AUDIO EARLY / increase delay. ZERO/SET store engine a−v milliseconds. Cal default 0. See `SyncSignConvention` in `SyncTypes.swift`.

`ingestExternalTimedEvents` is the hook for a future dual-channel sampler (USB audio: photodiode + mic, shared 48 kHz clock). That sampler is not implemented.

## Statistics (`MeasurementStatistics`)

Keeps **all** raw paired samples. Recomputes outliers with median + MAD (`k * 1.4826 * MAD`). Snapshot: current, mean, median, min, max, sample stddev, valid count, rejected/unpaired, outlier count, stability flag, calibration, **walk ms/beep** (OLS slope of valid offsets vs index).

Never promotes one event to “the answer.” The main headline uses the median of valid samples minus calibration; the last-25 table still lists each hit.

## Session and UI

`MeasurementSession` owns capture, both detectors, the clock, and the engine. It hops capture callbacks onto a serial measure queue, then publishes to the main thread.

SwiftUI (`MeasurementView`) is dark, low-decoration, venue-friendly: preview + target, huge AUDIO EARLY/LATE + ms, recommended delay, fps/frames, stats, SYNC STABLE/UNSTABLE, WALK ms/beep (green only if walk is flat and SPAN is tight), live LUMA/MIC needles plus a scrolling 1–90 s (default 90 s) peak-held history strip fed from the same live luma/mic as the needles (not from pairs), with FLASH / AUDIOPULSE / PAIR overlay marks (newest at the right). START/STOP/RESET stay pinned on screen (not below the fold). MIC needle/strip use display-only gain (`envelope × 16`); detector thresholds are unchanged. Capture footer is `%.2f` plus NTSC vs integer (MISS stays honest). Version string is on the header. Settings, Diagnostics, and a Phase 2 test signal (generated PCM beep, not the silent-switch click) are sheets.

## Calibration

`correctedOffset = measuredOffset - calibrationOffset`, persisted in `AppSettings`. Default 0 is displayed as none applied.

## Tests

`AVSyncMeterTests/SyncMeasurementEngineTests.swift` and `WalkAndClockTests.swift` are the XCTest target. `HostHarness.swift` + `SyntheticRig.swift` is a macOS `@main` runner used when `xcodebuild test` cannot attach to the installed iOS 27 simulator runtime.

The harness requires a constant synthetic offset to stay flat, a +164 ms audio step to move the median by ~164 ms, an already-mapped 30.000 vs 29.97 (1000 ppm) pass whose reported offsets stay flat, and a true-host integer-30 capture vs 29.97-file events pass that walks ~1 ms/beep until capture is locked to 30_000/1001 or 60_000/1001 (then the same constant-delay pass is flat). Integer 30 vs 29.97 content is not visible to relative A−V on unified buffers. Build 11: ±400 ms pair window still rejects 220–350 ms replicas vs the next flash; generated beep PCM exists; WALK is not green on huge SPAN; capture footer distinguishes 29.97 NTSC from integer 30.00. Build 12: voice-like onsets 50/150/250 ms plus a real beep at +80 pair the beep; chatter between 1 Hz flashes does not create pairs; moving luma does not FLASH. Build 13: picker 29.97 selects 1001-family from probed CMTime durations (never silent 1/30; footer says NTSC lock MISS if it cannot); smeared 40–60 ms 1 Hz PA pulse still onsets; 20–40 ms beep at +80 still wins over voice 50/150/250. Build 14: silent-ch0 / int32-as-int16 PA-scale buffers still onset at 89%; crushed env 0.001 does not; smeared 15–80 ms still pairs; speech still rejected; measurement-mode session policy (not voiceChat). Build 15: VU history window clamps 1–90 s (default 90); strip is pair-independent (live luma/mic with zero pairs still plots); FLASH and AUDIOPULSE marks can exist without PAIR; PAIR mark only when paired; 1-frame luma flash and mic pulse peak-hold at the rightmost column; RESET clears the strip. Build 16: 1 Hz FLASH + delayed 1 Hz AUDIOPULSE inside ±400 ms must PAIR (keep-latest one-pending-flash was zero pairs); speech still rejected; smeared 15–80 ms still pairs; constant offset still flat; footer 29.97/59.94 NTSC or NTSC lock MISS (59.98 must not flap to 60.00 integer MISS). Build 17: CANONICAL HostHarness is the measured Harkwood equation — 1001.000 ms flash + 66.7 ms 3 kHz, first event 11.011 s, onset +0 and +80 MUST PAIR, cadence 1001 ms × N stays flat (not 1.000 Hz / not a 10–20 ms click); isolated smear +80 pairs even if old isBeepLike was false; 200–400 ms isolated tones PAIR on onset; overlapping/ongoing speech still rejected; smeared 15–80 ms still pairs; (16) flash-queue still pairs; constant offset still flat; EVT marks match ingest; VU-aligned wall times with different unified times do not pair (strip uses CaptureClock unified time). Build 18: 2-frame luma pulse (first vs second frame, including dim-first / 60 fps smear / last-peak) + 66.7 ms 3 kHz at +0 must stay one cluster near 0 (not SPAN 50+ / −50/+11); stamp is the first rising frame, not the last white frame. Build 19: (18) first-rising-frame flash stamp stays; on-screen recipe is camera on LCD/projector/LED, mic on the PA, PCM from the start, type AUDIO EARLY into Mitti Audio Output (or mixer) — no HDMI-embed copy and no dual-pulse / earliest-vs-embed heuristic. Overlapping speech still rejected; isolated 67/200/300/400 ms tones still PAIR on onset; 2-frame first-rising still one cluster near 0; CANONICAL Harkwood 1001 ms / 66.678 ms 3 kHz still PAIR. Common house advice at delay 0 is AUDIO EARLY / increase audio delay. Build 21 flips display labels only (a>v LATE/reduce, a<v EARLY/increase) without negating stored samples. Build 20: default pairingWindow / maxPairOffset 1.00 s so LED processor + Mitti delay fit; HostHarness settle+freeze then 66.7 ms 3 kHz at T+0/80/200/300/500/800/−200/−500 PAIR at that offset; overlapping speech still rejected at ±500 (does not steal the beep median). (20) does not claim to fix upstairs +200 ms. Build 21: UI display mapping only — T+200 DISPLAY LATE/reduce, T−200 EARLY/increase; engine a−v, ZERO/SET storage, cal 0, median magnitude, 1.00 s window, first-rising, latest-wins, speech reject unchanged.

## File map

| Path | Role |
| --- | --- |
| `Engine/SyncTypes.swift` | Sign convention, events, snapshot |
| `Engine/FrameRate.swift` | 23.976–60 including 1001-family rates; picks capture duration from the program picker |
| `Engine/CaptureClock.swift` | Per-stream PTS → host timebase + relative A−V rate-lock |
| `Engine/VideoFlashDetector.swift` | First-edge luma flash (walk back 2-frame last-edge triggers) |
| `Engine/AudioPulseDetector.swift` | Onset with frozen noise floor; beep-like vs voice |
| `Engine/SyncMeasurementEngine.swift` | Flash queue + one pairable pulse; pair inside ±1.00 s |
| `Engine/MeasurementStatistics.swift` | Stats + MAD + walk |
| `Engine/MeterHistory.swift` | Scrolling LUMA+MIC VU + FLASH/AUDIOPULSE/PAIR marks (display only) |
| `Engine/TestSignalBeep.swift` | Generated 1 kHz PCM / WAV for SIG (not a measurement timestamp) |
| `Engine/AppSettings.swift` | UserDefaults |
| `Engine/MeasurementSession.swift` | Glue (not the algorithm) |
| `Capture/CaptureManager.swift` | Single AVCaptureSession + PTS conversion |
| `UI/*` | SwiftUI + preview overlay |
