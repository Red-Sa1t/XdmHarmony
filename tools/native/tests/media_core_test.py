#!/usr/bin/env python3
"""Execute production C++ and independently inspect/decode its media outputs.

This is host validation. Target/device acceptance remains a separate gate.
"""
import argparse
import array
import hashlib
import json
import math
import os
import pathlib
import re
import resource
import signal
import subprocess
import sys
import time


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=pathlib.Path, required=True)
    parser.add_argument("--fixtures", type=pathlib.Path, required=True)
    parser.add_argument("--ffmpeg", type=pathlib.Path, required=True)
    parser.add_argument("--ffprobe", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    runner, fixtures, output = args.runner.resolve(), args.fixtures.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    ffmpeg, ffprobe = str(args.ffmpeg.resolve()), str(args.ffprobe.resolve())
    input_hashes = {path.name: digest(path) for path in fixtures.iterdir() if path.is_file()}
    evidence = []

    def check_diagnostics(name, stderr):
        # UBSan can recover and return zero. Preserve and inspect stderr as well
        # as the exit status, rather than silently accepting a diagnostic.
        with (output / "native-stderr.log").open("a", encoding="utf-8") as log:
            log.write("[" + name + "]\n" + (stderr if stderr else "<empty>\n"))
        assert not re.search(r"AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:", stderr), (name, stderr)

    def record(name, details):
        evidence.append({"case": name, **details})
        (output / "results.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps({"case": name, "status": "checked"}), flush=True)

    def invoke(name, operation, inputs, format="mp3", options=(), limit_bytes=None):
        target = output / (name + ".part")
        command = [str(runner), operation, name, *[str(fixtures / item) for item in inputs], str(target)]
        if operation == "remux":
            command.append(format)
        command.extend(options)
        preexec = None
        if limit_bytes is not None:
            def limit():
                signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
                resource.setrlimit(resource.RLIMIT_FSIZE, (limit_bytes, limit_bytes))
            preexec = limit
        completed = subprocess.run(command, capture_output=True, text=True, timeout=40, preexec_fn=preexec)
        check_diagnostics(name, completed.stderr)
        if completed.returncode not in (0, 2, 3):
            raise AssertionError(f"{name} exited {completed.returncode}: {completed.stderr}")
        result = json.loads(completed.stdout)
        if result["status"] == "success":
            assert target.is_file() and target.stat().st_size == result["outputBytes"]
            assert result["outputPath"] == str(target)
        else:
            assert not target.exists(), f"Failed/cancelled job retained owned partial: {name}"
            assert result["outputPath"] == "" and result["outputBytes"] == 0
        return target, result

    def probe(path):
        completed = subprocess.run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-show_packets",
                                    "-of", "json", str(path)], capture_output=True, text=True, check=True, timeout=25)
        data = json.loads(completed.stdout)
        for stream in data["streams"]:
            dts = [int(packet["dts"]) for packet in data.get("packets", [])
                   if packet["stream_index"] == stream["index"] and "dts" in packet]
            assert all(second >= first for first, second in zip(dts, dts[1:])), f"Nonmonotonic DTS in {path.name}"
        return data

    def pcm_data(path):
        return subprocess.check_output([ffmpeg, "-v", "error", "-nostdin", "-i", str(path),
                                        "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", "-"], timeout=25)

    def video_hashes(path):
        decoded = subprocess.check_output([ffmpeg, "-v", "error", "-nostdin", "-i", str(path),
                                           "-map", "0:v:0", "-an", "-f", "framemd5", "-"], text=True, timeout=25)
        return [line.split(",")[-1].strip() for line in decoded.splitlines() if line and not line.startswith("#")]

    mp3_cases = [
        ("mp3-mono", "tone-44100-mono.wav", 44100, 1, 1.0, 440),
        ("mp3-stereo", "tone-48000-stereo.wav", 48000, 2, 1.0, 880),
        ("mp3-short-tail", "tone-44100-short.wav", 44100, 1, 0.01, None),
        ("mp3-low-rate", "tone-8000-mono.wav", 8000, 1, 0.12, None),
        ("mp3-downmix", "tone-48000-surround.wav", 48000, 2, 1.0, None),
        ("mp3-aac", "audio.m4a", 44100, 1, 2.0, None),
        ("mp3-opus", "audio.opus", 48000, 2, 1.0, None),
        ("mp3-vorbis", "audio.ogg", 44100, 1, 1.0, None),
        ("mp3-ac3", "audio-ac3.ts", 48000, 2, 1.0, None),
        ("mp3-default-mono", "multi-default-mono.mkv", 44100, 1, 1.0, 440),
        ("mp3-default-stereo", "multi-default-stereo.mkv", 48000, 2, 1.0, 880),
    ]
    for name, source, expected_rate, expected_channels, seconds, frequency in mp3_cases:
        target, result = invoke(name, "mp3", [source])
        assert result["status"] == "success", result
        inspected = probe(target)
        audio_streams = [stream for stream in inspected["streams"] if stream["codec_type"] == "audio"]
        assert len(audio_streams) == 1 and audio_streams[0]["codec_name"] == "mp3"
        stream = audio_streams[0]
        rate, channels = int(stream["sample_rate"]), stream["channels"]
        assert (rate, channels) == (expected_rate, expected_channels)
        raw = pcm_data(target)
        values = array.array("f")
        values.frombytes(raw)
        if sys.byteorder != "little":
            values.byteswap()
        assert values and all(math.isfinite(value) for value in values)
        decoded_seconds = len(values) / channels / rate
        assert abs(decoded_seconds - seconds) < 0.05, (name, decoded_seconds, seconds)
        rms = math.sqrt(sum(value * value for value in values) / len(values))
        assert 0.015 < rms < 1.0, (name, rms)
        measured_frequency = None
        if frequency is not None:
            first_channel = values[::channels]
            crossings = sum(left <= 0 < right for left, right in zip(first_channel, first_channel[1:]))
            measured_frequency = crossings / decoded_seconds
            assert abs(measured_frequency - frequency) < 12, (name, measured_frequency, frequency)
        record(name, {"result": result, "sampleRate": rate, "channels": channels,
                      "decodedSeconds": decoded_seconds, "decodedRms": rms, "measuredFrequency": measured_frequency,
                      "sha256": digest(target)})

    remux_cases = [
        ("remux-mp4", "video.mp4", "audio.m4a", 2.0),
        ("remux-ts-adts", "video.ts", "audio.aac", 2.02),
        ("remux-fragmented", "video-fragmented.mp4", "audio-fragmented.m4a", 2.02),
        ("remux-offsets", "video-offset.mp4", "audio-offset.m4a", 2.02),
        ("remux-unequal", "video.mp4", "audio-long.m4a", 3.0),
    ]
    for name, video, audio, seconds in remux_cases:
        target, result = invoke(name, "remux", [video, audio], "mp4")
        assert result["status"] == "success", result
        inspected = probe(target)
        assert [stream["codec_name"] for stream in inspected["streams"]] == ["h264", "aac"]
        assert abs(float(inspected["format"]["duration"]) - seconds) < 0.12
        assert video_hashes(target) == video_hashes(fixtures / video), name + " changed video frames"
        assert pcm_data(target) == pcm_data(fixtures / audio), name + " changed copied audio"
        first_pts = [min(float(packet["pts_time"]) for packet in inspected["packets"]
                         if packet["stream_index"] == stream["index"] and "pts_time" in packet)
                     for stream in inspected["streams"]]
        assert all(-0.05 <= stamp < 0.15 for stamp in first_pts), (name, first_pts)
        record(name, {"result": result, "duration": inspected["format"]["duration"], "streams": len(inspected["streams"]),
                      "firstPts": first_pts, "decodedVideoAndAudioMatch": True, "sha256": digest(target)})

    target, result = invoke("fallback-mp4", "remux", ["video.mp4", "tone-44100-mono.wav"], "mp4")
    assert result["status"] == "failed" and result["errorCode"] == "UNSUPPORTED_STREAM", result
    record("fallback-mp4-rejected", {"result": result})
    target, result = invoke("fallback-matroska", "remux", ["video.mp4", "tone-44100-mono.wav"], "matroska")
    assert result["status"] == "success", result
    inspected = probe(target)
    assert [stream["codec_name"] for stream in inspected["streams"]] == ["h264", "pcm_s16le"]
    assert video_hashes(target) == video_hashes(fixtures / "video.mp4")
    assert pcm_data(target) == pcm_data(fixtures / "tone-44100-mono.wav")
    record("fallback-matroska-success", {"result": result, "decodedVideoAndAudioMatch": True})
    target, result = invoke("map-all-streams", "remux", ["video.mp4", "multi-default-mono.mkv"], "matroska")
    assert result["status"] == "success", result
    assert [stream["codec_name"] for stream in probe(target)["streams"]] == ["h264", "pcm_s16le", "pcm_s16le"]
    record("map-all-streams", {"result": result, "streams": 3})

    for name, source, expected in (("invalid-input", "invalid.bin", "INVALID_DATA"),
                                    ("empty-input", "empty.bin", "INVALID_DATA"),
                                    ("missing-input", "not-present.wav", "INPUT_NOT_FOUND"),
                                    ("no-audio", "video.mp4", "UNSUPPORTED_STREAM")):
        target, result = invoke(name, "mp3", [source])
        assert result["status"] == "failed" and result["errorCode"] == expected, result
        record(name, {"result": result})
    target, result = invoke("write-limit", "mp3", ["tone-44100-mono.wav"], limit_bytes=1000)
    assert result["status"] == "failed" and result["errorCode"] == "OUTPUT_IO", result
    record("write-limit", {"result": result, "ownedPartialRemoved": not target.exists()})

    for phase in ("validate", "open", "read", "decode", "resample", "encode", "mux", "close"):
        options = ["--cancel-ms", "0"] if phase == "validate" else ["--cancel-phase", phase]
        target, result = invoke("cancel-" + phase, "mp3", ["tone-cancel.wav"], options=options)
        assert result["cancelAccepted"] and result["status"] == "cancelled", result
        record("cancel-" + phase, {"result": result, "ownedPartialRemoved": not target.exists()})

    for action in ("rename", "unlink", "replace"):
        name = "identity-" + action
        target = output / (name + ".part")
        displaced = output / (name + ".displaced.part")
        command = [str(runner), "mp3", name, str(fixtures / "tone-cancel.wav"), str(target)]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 10
        while not target.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.0005)
        assert target.exists(), "Did not observe live owned output"
        if action in ("rename", "replace"):
            target.rename(displaced)
        else:
            target.unlink()
        sentinel = b"foreign replacement: must survive"
        if action == "replace":
            target.write_bytes(sentinel)
        stdout, stderr = process.communicate(timeout=40)
        check_diagnostics(name, stderr)
        assert process.returncode == 2, (action, process.returncode, stderr)
        result = json.loads(stdout)
        assert result["status"] == "failed" and result["errorCode"] == "OUTPUT_IO", result
        assert result["outputPath"] == "" and result["outputBytes"] == 0
        if action == "replace":
            assert target.read_bytes() == sentinel
        else:
            assert not target.exists()
        record(name, {"result": result, "replacementPreserved": action == "replace", "displacedExists": displaced.exists()})

    for name, before in input_hashes.items():
        assert digest(fixtures / name) == before, "An input fixture was mutated: " + name
    record("input-preservation", {"files": len(input_hashes), "allSha256Unchanged": True})
    print(json.dumps({"checked": len(evidence), "output": str(output), "scope": "host only"}), flush=True)


if __name__ == "__main__":
    main()
