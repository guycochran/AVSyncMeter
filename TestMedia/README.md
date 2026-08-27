# AVSyncMeter test media

`AVSyncMeter-Test-29.97.mov` is an original MIT-licensed flash+click movie for Mitti playout. It is **not** derived from Harkwood Sync-One2 or any third-party test pattern.

- Filename: `AVSyncMeter-Test-29.97.mov`
- 1920×1080, timebase `30000/1001`, 1800 frames, 60.060 s
- Video: H.264 High 4.1 8-bit yuv420p (not High 4:4:4 Intra)
- Audio: pcm_s16le 48 kHz stereo
- Lead-in 300 black frames (10.010 s). First event frame 300 = 10.010 s = audio sample 480480
- Period 30 frames / 1001 ms / 48048 samples. 50 events
- 5 full-white frames then black
- 2 ms (96 sample) 3 kHz click, −3 dBFS, cosine taper
- First sample of click = first sample of first white frame (A=V)
- Photodiode-equivalent is flash onset (first white frame), not 50% white

Regenerate from the repo root:

```
python3 Scripts/generate_avsyncmeter_test_movie.py
```

Requires ffmpeg. The iOS app target does not copy this file into the IPA.
