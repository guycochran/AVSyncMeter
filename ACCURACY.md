# Accuracy and uncertainty

AV Sync Meter reports an **audience-position** offset between a visual flash (seen by the phone camera) and an audio pulse (heard by the phone microphone). It is not a laboratory instrument. First measure. Do not prematurely compensate inside the app.

## What the number is

```
offsetMilliseconds = audioTimestamp - videoTimestamp
correctedOffset    = measuredOffset - calibrationOffset
```

Live timestamps are **unified host seconds**: each stream’s presentation timestamp is mapped through the capture session’s master clock onto the host clock. That mapped PTS is the pairing time. `CaptureClock` freezes its slope once settled and does not fit against callback arrival time. Pairing never subtracts raw video PTS from raw audio PTS.

The result includes:

- Program path delay (Mitti, I/O, SDI/HDMI, projector processing)
- Acoustic travel from the PA to the seat
- Phone camera and microphone processing that is **not** the house system

Acoustic travel is intentional. Sound is about 343 m/s (~1.1 ft/ms). Ten feet of extra path is about 9 ms. The app never subtracts distance automatically.

## What this rewrite will and will not claim

**Will claim (and tests enforce):**

- On a **constant true offset**, 30+ synthetic events stay flat: walk ≪ 1 ms/event, span a few milliseconds, median near the true value.
- A synthetic audio delay of **N ms** moves the reported median by about **N ms**.
- A 1000 ppm relative PTS-rate error (the old ~1 ms per 1 Hz beep walk) is removed by `CaptureClock`.

**Will not claim:**

- Phone loopback (camera on the phone’s own screen, mic on the same phone’s speaker) equals a venue measurement. Sensor and ISP delay remain.
- USB / Focusrite audio vs UltraStudio SDI video on **unlocked source clocks** is a locked house. A leftover constant bias is honest. A 1 ms-per-beep ramp on a constant delay is a meter bug, not a house truth.
- 0 ms on the phone means 0 ms at the console. Calibration 0 is **none applied**, not zero sensor latency.
- Agreement with Sync-One2, Hitomi Glass, MatchBox, or another phone.
- Sub-frame accuracy on a 30 fps camera.

**How to use a pass:** RESET, PCM stereo from the start of the file (10 s lead-in), 15 beeps, STOP, read the **median**. Last-25 is individual samples — they should not climb a millisecond per beep. Then type a known Mitti Audio Output delay and re-measure: the median should move by about that amount.

Prefer Harkwood Sync-One2 **PCM** from the beginning of the file. AAC adds decoder delay (often tens of milliseconds) on top of the house. Those files are external only and are not bundled.

## Why repeats help

A single pair can be wrong (missed flash, late onset, a reflected beep, a camera frame that straddled the flash). The UI shows current, mean, median, min, max, standard deviation, and **WALK ms/beep**. Outliers use median + MAD. Prefer the **median of several valid pairs**. SYNC STABLE is a variation check, not a certificate of truth. WALK near 0 is the check that the meter is not drifting under you.

## What calibration does

`correctedOffset = measuredOffset - calibrationOffset`

Default is **0 ms**, shown as “none applied”. That is not a claim of zero sensor latency. If you later measure a known-good loop you can store that constant as a known correction. It is a user-entered offset, not an automatic factory cal.

## The old walking number (fixed)

The previous engine subtracted `CMTimeGetSeconds(audioPTS) − CMTimeGetSeconds(videoPTS)` and treated those as one clock. On iPhone they are not. Camera PTS and mic PTS can run hundreds to ~1000 ppm apart (NTSC 1000/1001 family, unlocked device clocks, frame-index/30 vs wall). At 1 Hz that is **~0.3–1.0 ms per beep**, always climbing, on a constant delay — PCM near-field, AAC, and UltraStudio+PA alike. The absolute offset changed with the chain (AAC decoder delay, HDMI/PA latency); the **ramp** was the meter.

`CaptureClock` rate-maps each stream to a stable host (tests) or uses session-mapped PTS as both axes (live). **Pairs are held until both stream fits are settled** — slope then freezes; force-settle at ~2.5 s if chatter would keep CLOCK SETTLING forever; the first two events per stream after the gate are dropped. Detectors stamp the first reliable edge (flash) and the beep onset (backtracked to the noise floor), then stay deaf ~400 ms and re-arm on quiet so ring-down / projector double-flash is one onset. Pairing is chronological 1:1 plus a ±250 ms max |offset| so extra pulses expire unpaired instead of stealing the next flash. AE/AWB/focus are locked while measuring so a flash cannot pump exposure.

Honest leftover from unlocked **source** clocks (Mitti video vs Mitti audio on separate interfaces) can still sit in the median. That is house, not a 1 ms/beep walk.

## Error sources (not compensated)

### Frame duration
Camera frames are typically 16.7 ms (60 fps) or 33.3 ms (30 fps). A flash that starts between frames is quantized to the first frame that sees it. Worst-case one-sided error is about one frame period.

### Exposure
A long exposure averages the flash with the dark field. A short flash may look dimmer or land in the “wrong” frame. Auto-exposure can hunt in a dark venue.

### Rolling shutter
CMOS rows are not exposed at the same instant. A flash occupying the central region is still smeared in time across the readout. This is usually a few milliseconds, not tens, but it is not zero.

### Screen refresh and projector buffering
The LED wall or projector presents the flash after its own frame store, scan, and LED mapping. That delay is part of **house** sync (you want it). It is not phone error. Phone-vs-screen interaction (aliasing between refresh and camera shutter) can add beat-frequency jitter.

### Microphone latency and iOS audio processing
The built-in mic goes through analog, ADC, and the OS audio path. Unified timestamps are the capture time of the **buffer**, not the acoustic wavefront at the capsule, and not the console’s clock.

### Buffer size and onset
Onset is unified buffer start + sampleIndex / sampleRate. The trigger is high (so noise does not chatter). The stamp is the first sample over a low noise-floor threshold, walked back from the trigger, so AGC cannot slide the reading 1 ms/s.

### Reverb and false pulses
A beep in a room produces a tail. The detector masks ~400 ms after a hit and re-arms on quiet. A leftover replica that still fires expires unpaired (max pair offset ±250 ms) instead of pairing with the next flash. Keep the pattern near 1 Hz (Harkwood).

### Phone thermal / performance
Dropped frames change observed capture fps (shown in Diagnostics). Dropped frames increase the chance of missing a flash.

## Future Pro mode (not built)

A later version can ingest two externally sampled channels on one clock (USB audio, 48 kHz, ch1 photodiode / ch2 mic). The measurement engine already accepts timed events only, so that path does not require changing pairing or statistics. Do not treat the phone sensors as that instrument.

## Warning (also shown in Settings)

Phone camera and microphone processing can introduce measurement bias. For critical systems, verify results against a known reference.
