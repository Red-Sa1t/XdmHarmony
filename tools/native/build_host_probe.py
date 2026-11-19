#!/usr/bin/env python3
"""Build upstream ffprobe from the same verified n6.0 source for host analysis.

Some historical static host distributions crash on MPEG-TS under current WSL;
this source-built program is a test tool and never goes into the application.
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dependency-work", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = args.dependency_work.resolve()
    manifest = json.loads((root / "build-host-manifest.json").read_text())
    command = manifest["ffmpegCommand"] + ["--enable-ffprobe"]
    environment = os.environ.copy()
    environment["TMPDIR"] = str(root / "tmp")
    environment["LC_ALL"] = "C"
    for phase, arguments in (("configure", command), ("build", ["make", "-j1", "ffprobe"])):
        print(json.dumps({"hostFfprobe": phase}), flush=True)
        with (root / ("ffprobe-" + phase + ".log")).open("w") as log:
            result = subprocess.run(arguments, cwd=root / "ffmpeg-host", env=environment,
                                    stdout=log, stderr=subprocess.STDOUT, check=False)
        (root / ("ffprobe-" + phase + ".exit.txt")).write_text(str(result.returncode) + "\n")
        if result.returncode != 0:
            raise SystemExit(f"ffprobe {phase} failed: {result.returncode}")
    destination = root / "test-tools"
    destination.mkdir(exist_ok=True)
    shutil.copy2(root / "ffmpeg-host/ffprobe", destination / "ffprobe")
    (destination / "ffprobe-source.json").write_text(json.dumps({
        "source": manifest["sources"][0], "configureCommand": command,
        "scope": "Source-built Linux host analysis tool; not an application binary",
    }, indent=2) + "\n")
    print(json.dumps({"ready": str(destination / "ffprobe")}), flush=True)


if __name__ == "__main__":
    main()
