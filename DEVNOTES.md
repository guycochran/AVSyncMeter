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

Build 17: PAIR on the onset of each isolated 1 Hz hit, not on tone duration. A Harkwood 2-frame (measured 66.7 ms 3 kHz at 1001 ms, not 1.000 Hz) or a 200–400 ms periodic tone is still one isolated hit — the old ≤85 ms isBeepLike gate classified that as ongoing energy and never queued a pulse. Speech is overlapping/ongoing, not a periodic tone. Engine pairs `isPairable` (isBeepLike OR sharpness ≥ 0.40 OR dull smear ≤ 85 ms) even if the old isBeepLike flag was false. Overlapping/ongoing speech still rejected. EVT FLASH/AUDIOPULSE/PAIR marks only on engine ingest, stamped with the event's unified time. VU samples use CaptureClock unified time, same domain as pairing. Do not bump detector gain. Do not revert (14) mic-path / (16) flash queue. Keep smeared 15–80 ms PA beeps, 90 s pair-independent VU, START pinned, honest NTSC.

HostHarness CANONICAL is the measured Harkwood equation, not a 1.000 Hz click: 1001.000 ms flash (2 frames / 30 at 30000/1001, 0.9990 Hz) + 66.678 ms 3 kHz tone, file A/V offset 0.000 ms, first event t=11.011 s (10.010 title + 1.001 black). Pulse onset +0 ms and +80 ms MUST PAIR. Cadence 1001 ms × N stays flat (treating it as 1.000 Hz would walk −1 ms/beep). Do not require a 10–20 ms click. Isolated smear +80 still pairs if old isBeepLike was false; 200/300/400 ms isolated tone +80 PAIR on onset; overlapping/ongoing speech still rejected (a periodic 66.7 ms tone is not speech); smeared 15–80 ms still pairs; (16) flash-queue still pairs; constant offset still flat; EVT/ingest marks consistent; VU-aligned wall times with different unified times do not pair.

Install with devicectl only — do not launch. No TestFlight.


## Build 18 (2-frame flash stamps first edge, not last)

On-device 0.1.2 (17) 18:01 PT upstairs was MITTI+PA, not Mac speakers. Pairing proved (MEAS 24, WALK +0.09, not 1001 ms wrong-neighbor). SPAN +60.8, clusters −50 vs +11. That SPAN is HOUSE/Mitti residual plus a possible 2-frame flash first vs last edge (~33–67 ms). Do not treat it as laptop display-vs-speaker lag.

A Harkwood 2-frame white (~66.7 ms) can timestamp the first rising frame when that frame is full white, and the second/last frame when the first is a dim partial (rolling shutter / camera phase below flashLike). Mixing those edges splits a 0.000 ms file by ~33–67 ms and can sit on top of a house residual.

Build 18: `VideoFlashDetector` still triggers on a flash-like pop, then walks back to the **first rising frame** of that bright run (like audio onset walkback). Dim-first + full-second, 60 fps smear, and last-peak gradual shapes all stamp the first edge. HostHarness: 2-frame luma (first vs second) + 66.7 ms 3 kHz at +0 is one cluster near 0, not −50/+11. Do not hide house lag in calibration.

Do not install. Do not launch. No TestFlight.


## Build 19 (split-path recipe; first-rising flash; no dual-pulse)

LCD has no sound. Only the PA. HDMI-embed / earliest-pulse-vs-embed was a FALSE heuristic — do not ship it.

Last 4–5 on-device tests were the **SPLIT PATH**, not a laptop screen:
Mitti → Blackmagic UltraStudio SDI out → 50 ft SDI → SDI-to-HDMI converter → small LCD.
Audio: Mitti Audio Output → mixer → amp → PA. He does not delay picture.

(19) keeps (18) first-rising-frame flash stamp. Pairing stays latest pairable pulse (same as 18). On-screen recipe, no embed language:
- Camera on the LCD / projector / LED
- Mic on the PA
- PCM from the start
- When SYNC STABLE, type AUDIO EARLY into Mitti Audio Output (or mixer). Audio is always fast.

Advice: AUDIO EARLY / increase audio delay by X. ZERO / SET TRUE / CLEAR, sign, median, cal 0 unchanged. Do not bump detector gain. START pinned, 90 s VU, honest NTSC, CaptureClock unified EVT=ingest.

HostHarness: DROP PA-at-T−80 + embed-at-T+0 as product proof. KEEP Harkwood 67 ms / 1001 ms PAIR, tone-on-onset 67/200/300/400, 2-frame first-rising one cluster, overlapping speech rejected.

Do not install. Do not launch. No TestFlight. USB likely empty — do not wait. Do not call Guy down.


## Build 20 (pairing window 1.00 s; 500 ms speakers test can show 500)

Guy 22:28 local Mac test: Mitti Audio Output = Mac speakers, 500 ms audio-only, meter still +11 STABLE with 8 pairs. 500 ms is outside (19) ±400 ms pair window — a true 500-only path would fail to PAIR, not read +11. The +11 pairs mean an undelayed beep was heard. Upstairs +200 was INSIDE ±400 and did not move — still routing, not the cap.

(20) widens `pairingWindowSeconds` / `maxPairOffsetSeconds` default to 1.00 s (engine + AppSettings + Settings slider footnote). Legacy stored 0.40 migrates to 1.00. Isolated 66.7 ms 3 kHz pairs at T+0/80/200/300/500/800/T−200/T−500 after the same settle+freeze as the app. Overlapping speech still rejected, including ±500 ms (must not steal the beep median). Detector 400 ms mask still swallows ring-down. First-rising flash, split-path recipe, latest-wins pulse, sign, median, ZERO/SET TRUE/CLEAR, cal 0 unchanged. No SyncCore. No CaptureClock deletion.

(20) does **not** claim to fix upstairs +200 ms. It only makes a 500 ms Mac test able to show 500 if the delay is really in the speakers.

Do not install. Do not launch. No TestFlight.

## Build 21 (display sign flip only)

Guy 09:25 house path, Mitti Audio Output 300 ms already in. DIAG a>v (+289 to +295) = beep AFTER flash = physically AUDIO LATE. UI said AUDIO EARLY / increase delay — label was inverted.

(21) flips **display mapping only**. Engine `offsetMilliseconds = (audio − video) × 1000` is not negated. ZERO/SET stored milliseconds are not inverted. Cal default stays 0. Median magnitude unchanged.

- a>v (offset > 0): AUDIO LATE, advice “Reduce audio delay by X”
- a<v (offset < 0): AUDIO EARLY, advice “Increase audio delay by X”
- Last-25 EARLY/LATE tags, headline, and Mitti delay copy follow that mapping
- Recipe stays: camera on LCD/projector/LED, mic on PA, type AUDIO EARLY into Mitti Audio Output or mixer. Audio is always fast. At delay 0 on a video chain you should see EARLY / increase. No embed language.

Expected: Mac 0 delay +13 EARLY → ~13 LATE; Mac 200 delay +191 EARLY → ~191 LATE (reduce 191 ≈ undo the 200); house 300: 295 LATE / reduce 295.

HostHarness: same settle+freeze as the app. T+200 DISPLAY LATE/reduce; T−200 EARLY/increase. PAIR table T+0/80/200/300/500/800/−200/−500 still at engine a−v offset. Speech still rejected. 1.00 s pair window, first-rising, latest-wins pulse. No embed heuristic. No gain bump.

Stay 0.1.2, CURRENT_PROJECT_VERSION 21. Park iphoneos Debug. Do not install. Phone stays on (20) until Guy plugs in. Do not launch. No TestFlight.

## Build 22 (pairing window 0.80 s; 1001 ms neighbor must not pair)

Guy 10:01 (21): RESET at Mitti 40 was LATE +32. Then a +984 wild reading. Then Mitti 5 ms → EARLY −12 STABLE SPAN 0.4. +984 is the adjacent Harkwood beep (interval 1001 ms) inside the 1.00 s pair window.

(22) sets maxPairOffset / pairingWindow default to **0.80 s**. 500 ms still pairs. 1001 ms neighbor must not. Stored 0.40 and 1.00 migrate to 0.80.

HostHarness after settle+freeze: T+0/80/200/300/500/800 PAIR; T+980 and T+1001 do NOT pair; T−200/−500 still PAIR. Speech reject holds. Sign flip, first-rising, recipe unchanged. Does **not** claim to fix LCD flash-edge ~33 ms.

Stay 0.1.2, CURRENT_PROJECT_VERSION 22. Park iphoneos Debug. Do not install. Phone stays on (21) until USB.


## Build 23 (rolling-shutter flash interpolation)

Live (22) 0cf5335 on UltraStudio+LCD+Focusrite at Mitti 0: AUDIO LATE +33 STABLE SPAN 11.2 (cluster +32–36). Putting 35 in Mitti hopped to +16 (wrong direction vs a real delay). 33 ms = one 29.97 frame. First-rising-frame stamp was hopping the 2-frame Harkwood flash by ~one frame depending on which rows were white / rolling shutter. Phone PTS is first row; 59.94 roll ~17 ms.

`processLuminance` is still a scalar (central ROI mean) and cannot see which rows are white. (23) keeps that scalar for trigger + VU (do not bump gain; do not re-lock AE). Live `processPixelBuffer` also samples a readout-axis luma profile (full axis, central strip on the other axis; 90° capture rotation → first-in-time is the right edge). Walk back still finds the first rising frame of the bright run; the stamp is then interpolated inside that frame: `PTS + (firstWhiteRow / (rows−1)) × readout`. Last-row-only frames count as bright via the profile so the next full-white frame's PTS does not hop ~17–33 ms.

HostHarness: 2-frame flash at 29.97, 59.94 capture, first-row-white vs last-row-white stamps agree (medians both +1.07 ms, stamp-delta 0.00 ms) — not ±33 ms clusters. T+0/80/200/300/500/800 still PAIR after settle+freeze; T+980/1001 still reject; T+200 LATE/reduce; T−200 EARLY/increase; speech reject; 0.80 s default. Isolated Harkwood 66.7 ms 3 kHz / 1001 ms cadence still pairable. Sign, ZERO/SET/cal 0, CaptureClock freeze / relative A−V / NTSC lock honesty / START pinned / 90 s VU / EVT=ingest unchanged. Recipe unchanged (do not retarget camera to the show surface in this IPA).

This is flash-edge 33 ms on the **same** surface. It does **not** claim to fix LCD-vs-show ~130 ms. If the camera sees the SHOW picture, BM delay is already in the flash; 33 vs a 130 ms “looks better” is likely LCD vs show surface. Copy later: camera on the SHOW surface, not the confidence LCD — only after interpolation is green.

Stay 0.1.2, CURRENT_PROJECT_VERSION 23. Park iphoneos Debug. Do not install. Do not launch. No TestFlight. Phone stays on (22) 0cf5335.
