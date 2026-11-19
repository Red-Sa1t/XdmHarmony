#!/usr/bin/env python3
"""Synthesize small, redistributable media samples; record commands and SHA256.

All audio and video originate from mathematical signals/test patterns (CC0).
Host FFmpeg generates inputs and ffprobe describes them, never target results.
"""
import argparse
import array
import hashlib
import json
import math
import pathlib
import subprocess
import sys
import wave


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def pcm(path, rate, channels, seconds, frequency):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(rate)
        total = round(rate * seconds)
        for start in range(0, total, rate):
            values = array.array("h")
            for index in range(start, min(start + rate, total)):
                for channel in range(channels):
                    values.append(round(9000 * math.sin(2 * math.pi * (frequency + channel * 53) * index / rate)))
            if sys.byteorder != "little":
                values.byteswap()
            output.writeframesraw(values.tobytes())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", type=pathlib.Path, required=True)
    parser.add_argument("--ffprobe", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    ffmpeg, ffprobe = args.ffmpeg.resolve(), args.ffprobe.resolve()
    commands = []

    def encode(arguments, name):
        command = [str(ffmpeg), "-hide_banner", "-v", "error", "-nostdin", "-y", *arguments, "-threads", "1", str(root / name)]
        subprocess.run(command, check=True, timeout=120)
        commands.append({"output": name, "arguments": command})

    wave_specs = [
        ("tone-44100-mono.wav", 44100, 1, 1.0, 440),
        ("tone-48000-stereo.wav", 48000, 2, 1.0, 880),
        ("tone-44100-short.wav", 44100, 1, 0.01, 660),
        ("tone-8000-mono.wav", 8000, 1, 0.12, 400),
        ("tone-48000-surround.wav", 48000, 6, 1.0, 550),
        ("tone-44100-two-seconds.wav", 44100, 1, 2.0, 440),
        ("tone-48000-three-seconds.wav", 48000, 2, 3.0, 880),
        ("tone-cancel.wav", 48000, 2, 60.0, 440),
    ]
    for name, rate, channels, seconds, frequency in wave_specs:
        pcm(root / name, rate, channels, seconds, frequency)
        commands.append({"output": name, "generator": "PCM16 mathematical sine", "rate": rate,
                         "channels": channels, "seconds": seconds, "baseFrequency": frequency})
    encode(["-f", "lavfi", "-i", "testsrc=size=160x96:rate=25", "-t", "2", "-pix_fmt", "yuv420p",
            "-c:v", "libx264", "-preset", "fast", "-g", "25", "-bf", "2", "-an"], "video.mp4")
    encode(["-i", str(root / "tone-44100-two-seconds.wav"), "-c:a", "aac", "-b:a", "96k", "-vn"], "audio.m4a")
    encode(["-i", str(root / "tone-48000-three-seconds.wav"), "-c:a", "aac", "-b:a", "128k", "-vn"], "audio-long.m4a")
    encode(["-i", str(root / "video.mp4"), "-map", "0:v:0", "-c", "copy", "-bsf:v", "h264_mp4toannexb", "-f", "mpegts"], "video.ts")
    encode(["-i", str(root / "audio.m4a"), "-c:a", "copy", "-f", "adts"], "audio.aac")
    for source, destination in (("video.mp4", "video-fragmented.mp4"), ("audio.m4a", "audio-fragmented.m4a")):
        encode(["-i", str(root / source), "-c", "copy", "-movflags", "+frag_keyframe+empty_moov+default_base_moof"], destination)
    encode(["-i", str(root / "video.mp4"), "-c", "copy", "-output_ts_offset", "5"], "video-offset.mp4")
    encode(["-i", str(root / "audio.m4a"), "-c", "copy", "-output_ts_offset", "7"], "audio-offset.m4a")
    encode(["-i", str(root / "tone-48000-stereo.wav"), "-c:a", "libopus", "-b:a", "64k"], "audio.opus")
    encode(["-i", str(root / "tone-44100-mono.wav"), "-c:a", "libvorbis", "-q:a", "4"], "audio.ogg")
    encode(["-i", str(root / "tone-48000-stereo.wav"), "-c:a", "ac3", "-b:a", "128k", "-f", "mpegts"], "audio-ac3.ts")
    for name, first, second in (("multi-default-mono.mkv", "default", "0"), ("multi-default-stereo.mkv", "0", "default")):
        encode(["-i", str(root / "tone-44100-mono.wav"), "-i", str(root / "tone-48000-stereo.wav"),
                "-map", "0:a:0", "-map", "1:a:0", "-c:a", "pcm_s16le",
                "-disposition:a:0", first, "-disposition:a:1", second], name)
    # A real container incompatibility: n6.0 MP4 rejects PCM16, Matroska supports it.
    # No mock return value participates in the native fallback fixture.
    (root / "invalid.bin").write_bytes(b"This is deliberately not a media container.\x00\xff\x00")
    (root / "empty.bin").write_bytes(b"")
    records = []
    for path in sorted(root.iterdir()):
        if not path.is_file() or path.name == "manifest.json":
            continue
        record = {"path": path.name, "sha256": sha256(path), "bytes": path.stat().st_size,
                  "source": "Locally generated mathematical test signal/pattern", "license": "CC0-1.0"}
        if path.suffix not in (".bin",):
            probe = subprocess.run([str(ffprobe), "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                                   capture_output=True, text=True, check=True, timeout=20)
            record["probe"] = json.loads(probe.stdout)
        records.append(record)
    manifest = {"ffmpegVersion": subprocess.check_output([str(ffmpeg), "-version"], text=True).splitlines()[0],
                "ffprobeVersion": subprocess.check_output([str(ffprobe), "-version"], text=True).splitlines()[0],
                "scope": "Input fixtures; generated by host tools, not OHOS runtime evidence",
                "commands": commands, "files": records}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"fixtures": len(records), "output": str(root)}), flush=True)


if __name__ == "__main__":
    main()
