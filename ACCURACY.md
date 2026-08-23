# Accuracy and uncertainty

AV Sync Meter reports an **audience-position** offset between a visual flash (seen by the phone camera) and an audio pulse (heard by the phone microphone). It does **not** claim laboratory-grade accuracy. First measure. Do not prematurely compensate inside the app.

## What the number is

```
offsetMilliseconds = audioMediaTimestamp - videoMediaTimestamp
correctedOffset    = measuredOffset - calibrationOffset
```

Timestamps are the capture session’s presentation times, plus a sample index for audio onset. The result includes:

- Program path delay (Mitti, I/O, SDI/HDMI, projector processing)
- Acoustic travel from the PA to the seat
- Phone camera and microphone processing that is **not** the house system

Acoustic travel is intentional. Sound is about 343 m/s (~1.1 ft/ms). Ten feet of extra path is about 9 ms. The app never subtracts distance automatically.

## Why repeats help

A single pair can be wrong (missed flash, late onset, a reflected beep, a camera frame that straddled the flash). The UI shows current, mean, median, min, max, and standard deviation. Outliers use median + MAD. Prefer the **median of several valid pairs**. SYNC STABLE is a variation check, not a certificate of truth.

## What calibration does

`correctedOffset = measuredOffset - calibrationOffset`

Phase 1 default is **0 ms**, shown as “none applied”. That is not a claim of zero sensor latency. If you later measure a known-good loop (for example a speaker next to the phone and a flash on a low-latency display) you can store that constant as a known correction. It is a user-entered offset, not an automatic factory cal.

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
The built-in mic goes through analog, ADC, and the OS audio path (possible AGC, high-pass, sample-rate conversion). AVCapture audio timestamps are better than `Date()`, but they are still the timestamp of the **captured buffer**, not the acoustic wavefront at the capsule, and not the console’s clock.

### Buffer size and onset
Onset is `bufferPTS + sampleIndex / sampleRate`. Large buffers without the sample offset would be worse (whole-buffer error). Residual error is on the order of the hop used to scan RMS (small) plus threshold placement on the attack.

### AVCapture synchronization
Video and audio share one `AVCaptureSession`. Apple’s presentation timestamps are the clock used here. Cross-clock comparisons (`Date()`, UI events, `CACurrentMediaTime` vs PTS) are avoided. Residual A/V clock skew inside the session is possible and unmeasured.

### Timestamp precision
`CMTime` is rational and typically sample-accurate for audio and frame-accurate for video. Conversion to `Double` seconds is used for pairing; error from that conversion is negligible next to a frame period.

### Reverb and false pulses
A beep in a room produces a tail. The detector masks after a hit. A louder reflection after the mask can still create an extra event, which pairing may reject or mis-pair. Keep the pairing window tight enough for your pattern rate (default ±1 s at 1 Hz).

### AGC / SRC
Automatic gain can inflate the ambient baseline or squash dynamics. Sample-rate conversion between hardware and the session can shift apparent onset by a fraction of a millisecond to a few milliseconds.

### Phone thermal / performance
Dropped frames change observed capture fps (shown in Diagnostics). Dropped frames increase the chance of missing a flash.

## What this app cannot guarantee

- Agreement with a dual-channel audio analyzer, a dedicated hardware sync probe, or another phone.
- Correctness if the flash is off-target, too small, or the PA pulse is buried in music.
- That 0 ms on the phone means 0 ms at the console.
- Sub-frame accuracy on a 30 fps camera.

## Future Pro mode (not built)

A later version can ingest two externally sampled channels on one clock (USB audio, 48 kHz, ch1 photodiode / ch2 mic). The measurement engine already accepts timed events only, so that path does not require changing pairing or statistics. Do not treat the phone sensors as that instrument.

## Warning (also shown in Settings)

Phone camera and microphone processing can introduce measurement bias. For critical systems, verify results against a known reference.
