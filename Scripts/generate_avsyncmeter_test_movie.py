#!/usr/bin/env python3
"""Generate AVSyncMeter-Test-29.97.mov — owned 29.97 flash+click for Mitti.

MIT License. Copyright (c) 2026 Guy Cochran.
Original work for AV Sync Meter. Not derived from Harkwood Sync-One2 or any
third-party test pattern.

Spec (must reproduce exactly)
-----------------------------
- Filename: AVSyncMeter-Test-29.97.mov
- 1920x1080, timebase 30000/1001, 1800 frames, 60.060 s
- Video: H.264 High 4.1 8-bit yuv420p (NOT High 4:4:4 Intra)
- Audio: pcm_s16le 48 kHz stereo
- Lead-in 300 black frames (10.010 s). First event frame 300 = 10.010 s
  = audio sample 480480
- Period 30 frames / 1001 ms / 48048 samples. 50 events
- 5 full-white frames then black
- 2 ms (96 sample) 3 kHz click, -3 dBFS, cosine taper
- first sample of click = first sample of first white frame (A=V)

Requires ffmpeg + ffprobe on PATH.

Usage (from repo root):
    python3 Scripts/generate_avsyncmeter_test_movie.py
"""

from __future__ import annotations

import array
import math
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

WIDTH = 1920
HEIGHT = 1080
TIMEBASE = 30_000
FRAME_TICKS = 1_001  # 30000/1001 = 29.97 fps
TOTAL_FRAMES = 1800  # 60.060 s
LEADIN_FRAMES = 300  # 10.010 s
PERIOD_FRAMES = 30  # 1001 ms
WHITE_FRAMES = 5
EVENT_COUNT = 50
AUDIO_RATE = 48_000
CLICK_SAMPLES = 96  # 2 ms at 48 kHz
CLICK_HZ = 3_000.0
CLICK_AMP = 10 ** (-3.0 / 20.0)  # -3 dBFS
TAPER_SAMPLES = 16  # cosine fade-out; sample 0 stays at full -3 dBFS

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "TestMedia" / "AVSyncMeter-Test-29.97.mov"


def frame_time(frame: int) -> float:
    return frame * FRAME_TICKS / TIMEBASE


def write_wav(path: Path) -> list:
    n_samples = TOTAL_FRAMES * FRAME_TICKS * AUDIO_RATE // TIMEBASE
    # 1800 * 1001 * 48000 / 30000 = 2_882_880 exactly = 60.060 s
    if n_samples != 2_882_880:
        raise SystemExit("sample count formula drifted: %d" % n_samples)

    clicks_at = []
    frame = LEADIN_FRAMES
    while frame < TOTAL_FRAMES:
        t = frame_time(frame)
        idx = int(round(t * AUDIO_RATE))
        if abs(t * AUDIO_RATE - idx) > 1e-9:
            raise SystemExit("flash frame %d t=%s is not an integer sample" % (frame, t))
        clicks_at.append(idx)
        frame += PERIOD_FRAMES

    if len(clicks_at) != EVENT_COUNT:
        raise SystemExit("expected %d events, got %d" % (EVENT_COUNT, len(clicks_at)))
    if clicks_at[0] != 480480:
        raise SystemExit("first click sample %d != 480480" % clicks_at[0])
    if clicks_at[1] - clicks_at[0] != 48048:
        raise SystemExit("period samples %d != 48048" % (clicks_at[1] - clicks_at[0]))

    two_pi_f = 2.0 * math.pi * CLICK_HZ / AUDIO_RATE
    mono = array.array("h", [0] * n_samples)
    peak = 32767.0
    for start in clicks_at:
        for i in range(CLICK_SAMPLES):
            s = start + i
            if s >= n_samples:
                break
            # Cosine carrier so sample 0 is the peak (sine would be 0 at t=0).
            # Cosine taper on the trailing edge only — first sample of the
            # click stays at -3 dBFS so A=V onset is sample 480480, not later.
            if i <= CLICK_SAMPLES - TAPER_SAMPLES - 1:
                env = 1.0
            else:
                k = (CLICK_SAMPLES - 1) - i  # TAPER_SAMPLES-1 .. 0
                env = 0.5 * (1.0 + math.cos(math.pi * (TAPER_SAMPLES - 1 - k) / TAPER_SAMPLES))
            val = CLICK_AMP * env * math.cos(two_pi_f * i)
            mono[s] = int(round(max(-1.0, min(1.0, val)) * peak))

    if abs(mono[480480]) < 20000:
        raise SystemExit("sample 480480 is not a -3 dBFS click onset: %d" % mono[480480])

    stereo = array.array("h")
    stereo.fromlist([v for x in mono for v in (x, x)])

    data_bytes = n_samples * 2 * 2
    with path.open("wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_bytes))
        f.write(b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 2, AUDIO_RATE, AUDIO_RATE * 2 * 2, 4, 16))
        f.write(b"data")
        f.write(struct.pack("<I", data_bytes))
        stereo.tofile(f)
    return clicks_at


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        raise SystemExit("command failed: %s" % cmd[0])
    return r


def generate():
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SystemExit("ffmpeg and ffprobe are required")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="avsync-test-") as td:
        td_path = Path(td)
        wav = td_path / "click.wav"
        video = td_path / "flash.mov"
        clicks = write_wav(wav)
        print("WAV %d bytes, %d clicks, first sample %d" % (wav.stat().st_size, len(clicks), clicks[0]))

        # Two solid-color streams; overlay white for 5 frames every 30 after lead-in.
        # High 4.1 8-bit yuv420p — Mitti-friendly, not High 4:4:4 Intra.
        vf = (
            "[0:v][1:v]overlay=enable='gte(n\\,%d)*lt(mod(n-%d\\,%d)\\,%d)'[v]"
            % (LEADIN_FRAMES, LEADIN_FRAMES, PERIOD_FRAMES, WHITE_FRAMES)
        )
        run([
            ffmpeg, "-y", "-hide_banner",
            "-f", "lavfi", "-i", "color=c=0x000000:s=%dx%d:r=%d/%d" % (WIDTH, HEIGHT, TIMEBASE, FRAME_TICKS),
            "-f", "lavfi", "-i", "color=c=0xFFFFFF:s=%dx%d:r=%d/%d" % (WIDTH, HEIGHT, TIMEBASE, FRAME_TICKS),
            "-filter_complex", vf,
            "-map", "[v]",
            "-frames:v", str(TOTAL_FRAMES),
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-profile:v", "high",
            "-level:v", "4.1",
            "-preset", "medium",
            "-crf", "18",
            "-bf", "0",
            "-g", "30",
            "-x264-params", "bframes=0:keyint=30:min-keyint=30:scenecut=0",
            "-video_track_timescale", str(TIMEBASE),
            "-an",
            str(video),
        ])

        run([
            ffmpeg, "-y", "-hide_banner",
            "-i", str(video),
            "-i", str(wav),
            "-c:v", "copy",
            "-c:a", "pcm_s16le",
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-movflags", "+faststart",
            str(OUT),
        ])

    verify(ffprobe, ffmpeg, clicks)
    print("Wrote %s (%d bytes)" % (OUT, OUT.stat().st_size))


def probe(ffprobe, args):
    r = subprocess.run([ffprobe, "-v", "error"] + args + [str(OUT)], check=True, capture_output=True, text=True)
    return r.stdout.strip()


def verify(ffprobe, ffmpeg, clicks):
    v = probe(ffprobe, [
        "-select_streams", "v:0",
        "-show_entries", "stream=codec_name,profile,level,pix_fmt,width,height,r_frame_rate,avg_frame_rate,nb_frames,duration,bits_per_raw_sample,time_base",
        "-of", "default=nw=1",
    ])
    print("--- video ---")
    print(v)
    if "codec_name=h264" not in v:
        raise SystemExit("video codec is not h264")
    if "profile=High" not in v:
        raise SystemExit("video profile is not High: %s" % v)
    if "High 4:4:4" in v or "4:4:4 Intra" in v:
        raise SystemExit("must NOT be High 4:4:4 Intra")
    if "level=41" not in v and "level=4.1" not in v:
        print("WARN level not 41 (4.1):")
        print(v)
        # still fail — spec says High 4.1
        raise SystemExit("video level is not 4.1")
    if "pix_fmt=yuv420p" not in v:
        raise SystemExit("pix_fmt is not yuv420p")
    if "width=1920" not in v or "height=1080" not in v:
        raise SystemExit("size is not 1920x1080")
    if "r_frame_rate=30000/1001" not in v:
        raise SystemExit("r_frame_rate is not 30000/1001")
    if "nb_frames=1800" not in v:
        raise SystemExit("nb_frames is not 1800: %s" % v)

    a = probe(ffprobe, [
        "-select_streams", "a:0",
        "-show_entries", "stream=codec_name,sample_fmt,sample_rate,channels,duration",
        "-of", "default=nw=1",
    ])
    print("--- audio ---")
    print(a)
    if "codec_name=pcm_s16le" not in a:
        raise SystemExit("audio is not pcm_s16le")
    if "sample_rate=48000" not in a:
        raise SystemExit("audio rate not 48000")
    if "channels=2" not in a:
        raise SystemExit("audio is not stereo")

    dur_v = float(probe(ffprobe, ["-select_streams", "v:0", "-show_entries", "stream=duration", "-of", "default=nw=1:nk=1"]) or "0")
    dur_a = float(probe(ffprobe, ["-select_streams", "a:0", "-show_entries", "stream=duration", "-of", "default=nw=1:nk=1"]) or "0")
    print("duration video %.6fs audio %.6fs (want ~60.060)" % (dur_v, dur_a))
    if abs(dur_v - 60.060) > 0.002:
        raise SystemExit("video duration %s not ~60.060" % dur_v)
    if abs(dur_a - 60.060) > 0.002:
        raise SystemExit("audio duration %s not ~60.060" % dur_a)

    # Frame luma: 299 black, 300-304 white, 305 black.
    sel = "eq(n\\,299)+eq(n\\,300)+eq(n\\,304)+eq(n\\,305)"
    r = subprocess.run(
        [ffmpeg, "-hide_banner", "-i", str(OUT), "-vf", "select='%s',scale=16:16,format=gray,showinfo" % sel,
         "-fps_mode", "vfr", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        raise SystemExit("ffmpeg select/showinfo failed")
    info = r.stderr
    means = []
    for line in info.splitlines():
        if "mean:" not in line:
            continue
        raw = line.split("mean:")[1].strip()
        if raw.startswith("["):
            raw = raw[1:]
        y = float(raw.split()[0].rstrip("]"))
        means.append(y)
    print("selected-frame mean Y (299,300,304,305):", means)
    if len(means) < 4:
        raise SystemExit("could not read 4 selected frames: %s" % means)
    black0, white0, white4, black1 = means[:4]
    if black0 > 24:
        raise SystemExit("frame 299 should be black, mean Y=%s" % black0)
    if white0 < 200:
        raise SystemExit("frame 300 should be white, mean Y=%s" % white0)
    if white4 < 200:
        raise SystemExit("frame 304 should be white, mean Y=%s" % white4)
    if black1 > 24:
        raise SystemExit("frame 305 should be black, mean Y=%s" % black1)

    r = subprocess.run(
        [ffmpeg, "-hide_banner", "-i", str(OUT), "-map", "0:a:0", "-ac", "1", "-f", "s16le", "-c:a", "pcm_s16le", "pipe:1"],
        capture_output=True,
    )
    if r.returncode != 0:
        sys.stderr.write(r.stderr.decode("utf-8", "replace"))
        raise SystemExit("audio decode failed")
    arr = array.array("h")
    arr.frombytes(r.stdout)
    if sys.byteorder != "little":
        arr.byteswap()
    first = None
    for i, s in enumerate(arr):
        if abs(s) > 6000:
            first = i
            break
    print("first loud audio sample %s (want %d = 480480)" % (first, clicks[0]))
    if first is None:
        raise SystemExit("no click found in audio")
    if first != 480480:
        raise SystemExit("first click at sample %s, want 480480" % first)
    print("A=V confirmed: first click sample %d = first white frame t=%.6fs" % (first, frame_time(LEADIN_FRAMES)))
    print("VERIFY OK frames=1800 r_frame_rate=30000/1001 duration~60.060 yuv420p pcm_s16le 48000 stereo first_click=480480")


if __name__ == "__main__":
    generate()
