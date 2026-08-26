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
  AVSyncMeter/Engine/MeterHistory.swift \
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

## Build 14 (mic path: loud PA must onset at 89%)

On-device 0.1.2 (13) upstairs ~16:16 PT: room loud, sensitivity 89%, DIAG live audio env 0.001 vs threshold 0.009, valid 0 / rejected 26, MIC sliver, audio slope n=1544 (buffers arriving). FLASH 1 Hz luma 0.98. SIG next to a Mac speaker DID produce AUDIOPULSE (env 0.005–0.009 vs thr 0.011). A loud house PA must not read as env 0.001.

Cause in code: CaptureManager never configured AVAudioSession (AVCapture auto-config + SIG `playAndRecord` + `mode.default` + `defaultToSpeaker` is speakerphone AEC / voice processing). `parseMono` took channel 0 of non-interleaved (or averaged) so a processed/silent plane meters 0.001. Detector floor at 89% sat at 0.009. Rearm had a hard 0.02 quiet floor that would freeze pairing in a truly loud room once DSP is off.

Build 14: `playAndRecord` + **measurement** (not voiceChat), mixWithOthers + defaultToSpeaker, no allowBluetooth, echo cancellation off, preferred mic **wideSpectrum**. Capture owns the session (`automaticallyConfiguresApplicationAudioSession = false`). SIG uses the same activate. Parse via AudioBufferList, int16/int32/float32, **loudest-channel mix**. 89% floor ~0.003 so a distant smeared PA still triggers; constant 0.001 still does not. Rearm quiet is relative, not 0.02 hard.

Keeps AE off, CaptureClock freeze / relative A−V, pair ±400 ms, clock gate until settled, NTSC lock MISS honest, SIG PCM not a timestamp. Do not install. Do not launch. No TestFlight.

HostHarness: silent-ch0 stereo recovers PA-scale RMS; int32 true scale; 89% PA-scale onsets; crushed 0.001 does not; smeared 15/80 ms pairs; speech still rejected; constant offset / 30 vs 29.97 still hold.


## Build 15 (scrolling LUMA + MIC VU)

Guy asked for a history strip so a pass is not just a live needle: did luma flashes and mic pulses actually happen. A failed pairing pass must not look empty. Measure screen keeps the live LUMA/MIC bars and adds two compact peak-held traces of the last 1–90 s (default 90 s, newest at the right), fed from the same live luma/mic as the needles — never from valid pairs. Overlay FLASH / AUDIOPULSE / PAIR marks so a full-green beep that did not pair is visible (MIC spike + AUDIOPULSE mark, FLASH mark, no PAIR). Duration lives in SET → Meters. RESET clears the strip. Display only — does not feed pairing.

This is spike-then-pair debug, not a deaf-mic fix: upstairs MIC was live (full green on every PA beep; DIAG 0.001 is between hits, UI is liveAudioLevel × 4). Fail is pairing/gating. Do not bump gain. Do not revert (14) mic-path files.

Keeps (14) mic path (loudest-channel mix, measurement session, 89% PA onset), stage-noise reject, honest NTSC lock, SIG PCM beep, CaptureClock freeze / relative A−V, pair ±400 ms, no AE lock. Do not install. Do not launch. No TestFlight.

HostHarness: default window 90 s (clamp 1–90); live luma/mic recorded with zero pairs; FLASH+AUDIOPULSE marks without PAIR; PAIR mark only when paired; 1-frame luma flash and mic pulse peak-hold at NOW (right); 90 s window keeps a spike from 90 s ago; samples older than the window vanish; RESET clears samples and marks; traces stay independent.


## Build 16 (pairing: keep flashes, not keep-latest)

On-device 0.1.2 (15): FLASH 1 Hz, AUDIOPULSE less often, REJECTEDEXTRAFLASH keep-latest every ~1 s, MEAS 0, no PAIR. Both detectors fired. Mic was not deaf. Keep-latest of one pending flash dropped the flash that a later-ingested beep-like pulse (60 fps measure-queue lag) still sat inside ±400 ms of.

Build 16 keeps unpaired flashes until they pair or age out; pairs the nearest flash inside the window; latest beep-like pulse still wins; voice still never queues. START/STOP/RESET are pinned on screen. MIC needle/strip display gain is envelope × 16 (not a detector threshold). Footer is 29.97/59.94 NTSC or “NTSC lock MISS” — a short FPS window must not flap 59.94 NTSC into silent 60.00 integer. Do not change Guy's 65/70/35/±400.

HostHarness: 1 Hz FLASH + delayed 1 Hz AUDIOPULSE inside ±400 ms must PAIR (fails on keep-latest); in-order 1 Hz still pairs; speech still rejected; smeared 15–80 ms still pairs; constant offset / 30 vs 29.97 still hold.

Install with devicectl only — do not launch. No TestFlight.


## Build 17 (isolated 1 Hz must PAIR; EVT = ingest; unified VU)

On-device 0.1.2 (16) 17:22 PT IDLE: VU 1 Hz LUMA green + MIC blue spikes aligned; EVT green FLASH + blue AUDIOPULSE, zero yellow PAIR; DIAG FLASH then REJECTEDUNPAIRED ~3 s later (maxQueueAge); no AUDIOPULSE / REJECTEDEXTRAPULSE in the crop. START above fold. Capture still 59.99 integer NTSC lock MISS (not this ticket).

Two live bugs in (16):

1. `ingestPulse` dropped `!isBeepLike` without queueing. Isolated 1 Hz MIC next to a FLASH is not speech — speech is overlapping/ongoing energy. A smeared/dull 1 Hz pulse the old gate marked `isBeepLike = false` never sat in `pendingPulse`, so flashes aged out unpaired.
2. VU luma/mic and EVT marks were stamped with `CFAbsoluteTimeGetCurrent()` (wall-clock) while pairing uses CaptureClock unified seconds. Wall-clock makes 1 Hz spikes look aligned on the strip and never pair if `|unified dt| > 400 ms`. EVT blue was also painted on detector-fire / wall-clock, not engine ingest.

Build 17: PAIR on the onset of each isolated 1 Hz hit, not on tone duration. A Harkwood 2-frame (~67 ms) or a 200–400 ms periodic 1 kHz tone is still one isolated hit — the old ≤85 ms isBeepLike gate classified that as ongoing energy and never queued a pulse. Speech is overlapping/ongoing, not a periodic tone. Engine pairs `isPairable` (isBeepLike OR sharpness ≥ 0.40 OR dull smear ≤ 85 ms) even if the old isBeepLike flag was false. Overlapping/ongoing speech still rejected. EVT FLASH/AUDIOPULSE/PAIR marks only on engine ingest, stamped with the event's unified time. VU samples use CaptureClock unified time, same domain as pairing. Do not bump detector gain. Do not revert (14) mic-path / (16) flash queue. Keep smeared 15–80 ms PA beeps, 90 s pair-independent VU, START pinned, honest NTSC.

HostHarness: 1 Hz flash + pulse +80 ms pairs even if old isBeepLike was false; isolated 1 Hz next to FLASH pairs; 67 ms tone +80 PAIR on onset; 200/300/400 ms tone +80 PAIR on onset; overlapping speech still rejected; smeared 15–80 ms still pairs; (16) flash-queue still pairs; constant offset still flat; EVT/ingest marks consistent; VU-aligned wall times with different unified times do not pair.

Install with devicectl only — do not launch. No TestFlight.
