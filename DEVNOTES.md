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
  AVSyncMeter/Engine/TestSignalBeep.swift \
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

## Build 11 (PCM beep, 400 ms pair window, fps footer, WALK span)

On-device leftover from (10): SIG still used `AudioServicesPlaySystemSound(1104)` (silent switch mutes it); footer `Capture %.1f` showed 29.970 as 30.0; WALK went green on |walk|<0.2 even when SPAN was 32 ms.

Build 11 generates a ~16 ms 1 kHz PCM beep via AVAudioPlayer. Category is playAndRecord + mixWithOthers + defaultToSpeaker (playback fallback) so it can play with the ringer off while AVCaptureSession owns audio. Flash and beep fire in the same `fire()`. The beep is **not** a measurement timestamp. SIG shows a one-line note that same-phone loopback while measuring the house injects extra AUDIOPULSE.

Pair window default is **±400 ms** (monitor+PA+Mitti). Ring-down 220–350 ms still expires unpaired vs the next 1 Hz flash. +164 still pairs. Footer is `Capture %.2f fps  NTSC|integer  (picker …)`. Version `0.1.2 (11)` is on the header and Settings Info. WALK is green only if slope is flat **and** SPAN is tight (≤8 ms).

AE stays off. (10) NTSC capture lock stays. (9) relative A−V stays. Residual honest. Cal 0. Sign, median, last-25, ZERO, 400 ms audio/video holdoff unchanged.

Leftover risk: SIG beep may still be ducked by the capture session, AVAudioSession category fight, first beep clipped. HostHarness proves PCM + mix policy + pair window; it cannot play through a live AVCaptureSession.

(11) landed without stage-noise rejection and was already installed on the phone. Do not keep shipping (11).

## Build 12 (stage-noise rejection)

Deck speech was stealing the Harkwood/SIG beep: first syllable paired, chatter between 1 Hz flashes created extra pairs, quiet re-arm fired on the next syllable.

Build 12: audio detector emits **beep-like only** (sharp ~10–20 ms then quiet). Sustained voice is held then dropped without a 400 ms mask so a 1 kHz overlay can still win. After a real beep, 400 ms mask + quiet re-arm — speech stays loud, next syllable does not fire. Engine keeps at most one pending flash and one pending pulse; latest beep-like wins; voice/chatter is never queued and never pairs. Extra voice in the 400 ms window cannot steal; pair is the beep (~+80), not the first syllable. Video still uses the central region + 400 ms holdoff + re-arm toward dark, and ignores moving luma (work lights / people) that is not a white flash.

Keeps (11) PCM SIG beep (mixWithOthers, ringer off, not a timestamp), 400 ms pair window, fps footer, WALK span, version on screen. AE off. (10) NTSC lock. (9) relative A−V. Residual honest. Cal 0. Sign, median, last-25, ZERO.

HostHarness: voice 50/150/250 + beep +80 pairs ~+80; chatter between 1 Hz flashes does not pair; integer-30 vs 29.97 still walks until NTSC lock; +164/+200 still pair; ring-down one onset; extra flash 150 ms one event; unsettled publishes nothing.

Leftover risk: a short non-beep click ~30 ms before the house beep can still 400 ms-mask it; PA-smeared beeps longer than ~40 ms may look like voice; high-band overlay vs loud speech is a heuristic. SIG may still duck under capture.

Install with devicectl only — do not launch. No TestFlight.

## Build 13 (NTSC lock actually sticks; PA-smeared beep)

On-device 0.1.2 (12): footer `Capture 30.00 fps integer (picker 29.97)` — lock set 1001/30000 or 1001/60000 on the `.high` format using fps ±0.05 slop, iOS snapped to 1/30. DIAG: FLASH every ~1 s, REJECTEDEXTRAFLASH, **zero AUDIOPULSE**. Beep-like gate (`beepMaxDurationSeconds` 40 ms + 0.05 absolute threshold) classified the downstairs PA-smeared 1 Hz beep as voice.

Build 13 probes every format's CMTime min/max durations, prefers 60_000/1001 then 30_000/1001, reads back, and retries the next format if it snapped to integer. NTSC picker never selects 1/30. If nothing locks, footer is `Capture 30.00 fps  integer  NTSC lock MISS  (picker 29.97)`. Session preset is `inputPriority` so the chosen format sticks.

Audio: isolated 15–80 ms 1 Hz pulse still emits (PA smear, quiet MIC). Do not drop as voice just because duration >20 ms or amplitude is low. Sustained speech/walkie (ongoing energy) still dropped. 400 ms mask after a real beep. Voice 50/150/250 + beep +80 still pairs ~+80. Chatter between flashes still no pairs.

Keeps AE off, (9) relative rate-lock, SIG PCM beep, fps %.2f, version on screen, pair ±400 ms, honest WALK, cal 0, sign/median/last-25/ZERO. Do not change one-pending if audio is fixed.

HostHarness: picker 29.97 selects 1001 family; only-1/30 format does not silently pick 1/30; smeared 40–60 ms 1 Hz pulse onsets; voice+smeared 30 ms +80 still wins; integer-30 vs 29.97 still walks.

Leftover risk: some iPhone formats still snap every 1001 CMTime to 1/30 or 1/60 — footer will say MISS honestly. A short non-beep click ~30 ms before the house beep can still 400 ms-mask it. SIG may still duck under capture.

No install from this tree until Guy is at the Mac. No TestFlight. No launch.
