#!/usr/bin/env python3
"""Smoke-test a media-tools build on the machine it targets.

Checks:
  1. qjs evaluates JavaScript.
  2. ffmpeg is our build ("intersect" in -version).
  3. For every fixture: `ffmpeg -i` exits 1 and prints the "Stream #..: Audio: <codec>" line that
     yt-dlp parses when ffprobe is absent, and yt-dlp's exact extract-audio command (including
     -movflags) produces a ~1 s, non-silent float WAV.
  4. With --ytdlp: downloads the official yt-dlp build for this platform (checked against
     SHA2-256SUMS) and imports fixtures through file:// URLs the way INTERSECT will, with our
     ffmpeg and qjs and no ffprobe. Also confirms yt-dlp detects our QuickJS.

Uses local files only, never a website (CI runners' IPs get bot-checked by video sites).

usage: smoke_test.py --tools <dir> --fixtures <dir> --target <platform> [--ytdlp] [--work <dir>]
Stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

YTDLP_ASSETS = {
    "linux-x64": "yt-dlp_linux.zip",
    "linux-arm64": "yt-dlp_linux_aarch64.zip",
    "macos-arm64": "yt-dlp_macos.zip",
    "macos-x64": "yt-dlp_macos.zip",
    "win-x64": "yt-dlp_win.zip",
    "win-arm64": "yt-dlp_win_arm64.zip",
}
YTDLP_BASE = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
# yt-dlp's own pattern (postprocessor/ffmpeg.py, get_audio_codec without ffprobe).
AUDIO_STREAM_RE = re.compile(
    r"Stream\s*#\d+:\d+(?:\[0x[0-9a-f]+\])?(?:\([a-z]{3}\))?:\s*Audio:\s*([0-9a-z]+)")

failures: list[str] = []


def check(ok: bool, label: str, detail: str = "") -> bool:
    print(f"  [{'ok' if ok else 'FAIL'}] {label}" + (f" -- {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(label)
    return ok


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=timeout)


def wav_stats(path: Path) -> tuple[float, float]:
    """Return (duration_seconds, peak) for a 32-bit float WAV, parsed by hand because Python's
    wave module only reads integer PCM."""
    data = path.read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    pos, fmt, samples = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, channels, rate = struct.unpack_from("<HHI", body, 0)
            bits = struct.unpack_from("<H", body, 14)[0]
            if tag == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE: real tag is the subformat GUID's first word
                tag = struct.unpack_from("<H", body, 24)[0]
            fmt = (tag, channels, rate, bits)
        elif cid == b"data":
            samples = body
        pos += 8 + size + (size & 1)
    if fmt is None or samples is None:
        raise ValueError("missing fmt or data chunk")
    tag, channels, rate, bits = fmt
    if tag != 3 or bits != 32:
        raise ValueError(f"expected 32-bit float, got format tag {tag}, {bits} bits")
    count = len(samples) // 4
    floats = struct.unpack(f"<{count}f", samples[:count * 4])
    return count / channels / rate, max((abs(x) for x in floats), default=0.0)


def check_wav(path: Path, label: str) -> None:
    try:
        duration, peak = wav_stats(path)
    except (OSError, ValueError) as exc:
        check(False, label, str(exc))
        return
    check(0.9 <= duration <= 1.3 and peak > 0.05, label, f"duration {duration:.3f}s, peak {peak:.3f}")


def fetch(url: str, dest: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "intersect-tools-smoke-test"})
    with urllib.request.urlopen(request, timeout=120) as response, open(dest, "wb") as out:
        shutil.copyfileobj(response, out)


def install_ytdlp(target: str, work: Path) -> Path:
    asset = YTDLP_ASSETS[target]
    dl = work / "ytdlp-download"
    dl.mkdir(parents=True, exist_ok=True)
    fetch(YTDLP_BASE + "SHA2-256SUMS", dl / "SHA2-256SUMS")
    fetch(YTDLP_BASE + asset, dl / asset)
    expected = next((line.split()[0] for line in (dl / "SHA2-256SUMS").read_text().splitlines()
                     if line.split()[-1:] == [asset]), None)
    actual = hashlib.sha256((dl / asset).read_bytes()).hexdigest()
    if not check(expected == actual, f"yt-dlp {asset} matches SHA2-256SUMS", f"{actual} != {expected}"):
        raise SystemExit(1)
    dest = work / "ytdlp"
    shutil.rmtree(dest, ignore_errors=True)
    with zipfile.ZipFile(dl / asset) as zf:
        zf.extractall(dest)
    candidates = [p for p in dest.iterdir() if p.is_file() and p.name.startswith("yt-dlp")]
    if not check(len(candidates) == 1, "yt-dlp zip has one top-level executable",
                 ", ".join(p.name for p in candidates)):
        raise SystemExit(1)
    exe = candidates[0]
    if os.name != "nt":
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return exe


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--target", required=True, choices=sorted(YTDLP_ASSETS))
    parser.add_argument("--ytdlp", action="store_true")
    parser.add_argument("--work", type=Path)
    args = parser.parse_args()

    exe = ".exe" if args.target.startswith("win-") else ""
    ffmpeg = (args.tools / f"ffmpeg{exe}").resolve()
    qjs = (args.tools / f"qjs{exe}").resolve()
    if os.name != "nt":
        # Zip extraction (Python's, and JUCE's in the plugin) drops the exec bit; INTERSECT sets
        # it again after installing, so do the same here.
        for tool in (ffmpeg, qjs):
            tool.chmod(tool.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    work = (args.work or Path(tempfile.mkdtemp(prefix="media-smoke-"))).resolve()
    work.mkdir(parents=True, exist_ok=True)
    fixtures = sorted(p for p in args.fixtures.iterdir()
                      if p.is_file() and p.suffix in {".m4a", ".ts", ".webm", ".opus", ".ogg", ".mp3", ".flac", ".mp4"})

    print(f"== tools ({args.target}): {args.tools}")
    result = run([str(qjs), "-e", "print(6 * 7)"])
    check(result.returncode == 0 and result.stdout.strip() == "42", "qjs evaluates JavaScript",
          result.stdout + result.stderr)
    result = run([str(ffmpeg), "-hide_banner", "-version"])
    check(result.returncode == 0 and "intersect" in result.stdout.splitlines()[0], "ffmpeg is the INTERSECT build",
          (result.stdout.splitlines() or [""])[0])

    print(f"== fixtures ({len(fixtures)})")
    for fixture in fixtures:
        probe = run([str(ffmpeg), "-hide_banner", "-i", str(fixture)])
        match = AUDIO_STREAM_RE.search(probe.stderr)
        check(probe.returncode == 1 and match is not None,
              f"{fixture.name}: codec line for yt-dlp ({match.group(1) if match else 'none'})", probe.stderr[-400:])
        out = work / f"{fixture.stem}-{fixture.suffix[1:]}.wav"
        convert = run([str(ffmpeg), "-y", "-nostdin", "-loglevel", "error", "-i", str(fixture),
                       "-vn", "-movflags", "+faststart", "-c:a", "pcm_f32le", str(out)])
        if check(convert.returncode == 0, f"{fixture.name}: converts to WAV", convert.stderr[-400:]):
            check_wav(out, f"{fixture.name}: WAV is ~1 s and not silent")

    if args.ytdlp:
        print("== yt-dlp (official build, file:// imports)")
        ytdlp = install_ytdlp(args.target, work)
        for name in ("tone-opus.webm", "video-h264-aac.mp4"):
            fixture = (args.fixtures / name).resolve()
            dest = work / f"ytdlp-{fixture.stem}"
            shutil.rmtree(dest, ignore_errors=True)
            dest.mkdir()
            result = run([str(ytdlp), "-v", "--ignore-config", "--no-plugin-dirs", "--enable-file-urls",
                          "--no-js-runtimes", "--js-runtimes", f"quickjs:{qjs}",
                          "-f", "bestaudio/best", "-x", "--audio-format", "wav",
                          "--ppa", "ExtractAudio+ffmpeg_o:-c:a pcm_f32le",
                          "--ffmpeg-location", str(ffmpeg), "--fixup", "never",
                          "-P", str(dest), "-o", "dl.%(ext)s",
                          "--print", "after_move:[ix-done] %(filepath)s",
                          "--", fixture.as_uri()], timeout=300)
            ok = check(result.returncode == 0 and "[ix-done]" in result.stdout,
                       f"yt-dlp imports {name}", (result.stdout + result.stderr)[-800:])
            check("JS runtimes: quickjs" in result.stderr, f"yt-dlp detects our QuickJS ({name})",
                  "\n".join(l for l in result.stderr.splitlines() if "JS runtime" in l))
            check("ffprobe" not in next((l for l in result.stderr.splitlines() if "exe versions" in l), ""),
                  f"yt-dlp runs without ffprobe ({name})")
            if ok:
                check_wav(dest / "dl.wav", f"yt-dlp output of {name} is ~1 s and not silent")

    print(f"== {'PASS' if not failures else 'FAIL: ' + ', '.join(failures)}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
