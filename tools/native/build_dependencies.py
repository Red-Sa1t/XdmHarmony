#!/usr/bin/env python3
"""Rebuild exact FFmpeg/LAME static dependencies with GCC (host) or Windows OHOS LLVM via WSL.

Run from existing WSL Python/make. No sudo, system package installs, destructive
clean, or implicit SDK download. Every compilation uses make -j1.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import tarfile
import urllib.request

from import_artifacts import SOURCE_ARCHIVES, digest
from win_tool import windows_path

FLAGS = [
    "--disable-autodetect", "--disable-everything", "--disable-network", "--disable-programs", "--disable-doc",
    "--disable-shared", "--enable-static", "--enable-pic", "--enable-small", "--disable-x86asm",
    "--disable-avdevice", "--disable-avfilter", "--disable-swscale", "--enable-swresample",
    "--enable-protocol=file,pipe", "--enable-demuxer=mov,matroska,mpegts,aac,mp3,wav,ogg",
    "--enable-muxer=mp4,matroska,mpegts,mp3,webm", "--enable-parser=aac,h264,hevc,mpegaudio,ac3,opus,vorbis",
    "--enable-decoder=aac,vorbis,opus,ac3,mp3,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le",
    "--enable-libmp3lame", "--enable-encoder=libmp3lame",
    "--enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb",
]


def run(arguments, cwd, environment, log):
    print(json.dumps({"phase": log.stem, "cwd": str(cwd)}), flush=True)
    with log.open("w", encoding="utf-8") as output:
        output.write(shlex.join([str(item) for item in arguments]) + "\n")
        output.flush()
        completed = subprocess.run(arguments, cwd=cwd, env=environment, stdout=output, stderr=subprocess.STDOUT, check=False)
    log.with_suffix(".exit.txt").write_text(str(completed.returncode) + "\n")
    if completed.returncode != 0:
        raise SystemExit(f"{log.stem} failed with exit {completed.returncode}; see {log}")


def sources(work, archive_directory, download):
    source_root = work / "sources"
    source_root.mkdir(exist_ok=True)
    for item in SOURCE_ARCHIVES:
        print(json.dumps({"phase": "verify-source", "source": item["name"]}), flush=True)
        archive = work / item["file"]
        candidate = archive_directory / item["file"] if archive_directory else archive
        if not archive.exists() and candidate.exists():
            shutil.copy2(candidate, archive)
        if not archive.exists() and download:
            with urllib.request.urlopen(item["url"], timeout=90) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        if not archive.exists() or digest(archive, "sha512") != item["sha512"]:
            raise SystemExit(f"Missing or unverified archive {archive}; provide --archive-dir or --download")
        extracted = source_root / ("FFmpeg-n6.0" if item["name"] == "FFmpeg" else "lame-3.100")
        verified = source_root / (extracted.name + ".archive-sha512")
        if extracted.exists() and (not verified.exists() or verified.read_text().strip() != item["sha512"]):
            raise SystemExit(f"Incomplete or unverified extracted source {extracted}; use a fresh work directory")
        if not extracted.exists():
            print(json.dumps({"phase": "extract-source", "source": item["name"]}), flush=True)
            with tarfile.open(archive, "r:gz") as source:
                # Trusted hashes are mandatory; data filtering also rejects archive path escapes.
                source.extractall(source_root, filter="data")
            verified.write_text(item["sha512"] + "\n")
    return source_root


def build_one(abi, args, source_root, work):
    host = abi == "host"
    native_arch = "arm64" if abi == "arm64-v8a" else abi
    prefix = work / "prefix" / native_arch
    prefix.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(work / "tmp")
    env["CFLAGS"] = "-O2 -fPIC"
    env["LC_ALL"] = "C"
    ffmpeg_tool_flags = []
    lame_cross_flags = []
    if host:
        env.update({"CC": "gcc", "AR": "ar", "RANLIB": "ranlib", "NM": "nm"})
        # GCC 13/binutils 2.42 reject n6.0's old inline shr constraint. This is
        # host-test-only; target LLVM builds retain their original configuration.
        ffmpeg_tool_flags = ["--disable-inline-asm"]
    else:
        if not args.sdk or not pathlib.Path(args.sdk, "llvm/bin/clang.exe").exists():
            raise SystemExit("--sdk must name an existing Windows native SDK via its WSL /mnt path")
        target = "aarch64-linux-ohos" if abi == "arm64-v8a" else "x86_64-linux-ohos"
        env["XDM_NATIVE_SDK_ROOT"] = str(pathlib.Path(args.sdk).resolve())
        env["XDM_NATIVE_TARGET"] = target
        wrappers = work / "bin"
        wrappers.mkdir(exist_ok=True)
        adapter = pathlib.Path(__file__).resolve().parent / "win_tool.py"
        for tool in ("clang", "clang++", "llvm-ar", "llvm-ranlib", "llvm-nm", "llvm-strip"):
            wrapper = wrappers / tool
            wrapper.write_text("#!/bin/sh\nexec python3 " + shlex.quote(str(adapter)) + " " + tool + ' "$@"\n', newline="\n")
            wrapper.chmod(0o755)
        env.update({"CC": str(wrappers / "clang"), "AR": str(wrappers / "llvm-ar"),
                    "RANLIB": str(wrappers / "llvm-ranlib"), "NM": str(wrappers / "llvm-nm")})
        ffmpeg_tool_flags = ["--enable-cross-compile", "--target-os=linux",
                            "--arch=" + ("aarch64" if abi == "arm64-v8a" else "x86_64"),
                            "--cc=" + env["CC"], "--cxx=" + str(wrappers / "clang++"),
                            "--ar=" + env["AR"], "--ranlib=" + env["RANLIB"], "--nm=" + env["NM"],
                            "--strip=" + str(wrappers / "llvm-strip")]
        lame_cross_flags = ["--build=x86_64-pc-linux-gnu",
                            "--host=" + ("aarch64-linux-gnu" if abi == "arm64-v8a" else "x86_64-linux-gnu")]
    lame = work / ("lame-" + native_arch)
    lame.mkdir(exist_ok=True)
    run([str(source_root / "lame-3.100/configure"), "--prefix=" + str(prefix),
         "--disable-frontend", "--disable-shared", "--enable-static", "--with-pic", "--disable-nasm", *lame_cross_flags],
        lame, env, work / ("lame-" + native_arch + "-configure.log"))
    run(["make", "-j1"], lame, env, work / ("lame-" + native_arch + "-build.log"))
    run(["make", "-j1", "install"], lame, env, work / ("lame-" + native_arch + "-install.log"))
    ffmpeg = work / ("ffmpeg-" + native_arch)
    ffmpeg.mkdir(exist_ok=True)
    command = [str(source_root / "FFmpeg-n6.0/configure"), "--prefix=" + str(prefix), *ffmpeg_tool_flags,
               "--extra-cflags=-I" + str(prefix / "include"), "--extra-ldflags=-L" + str(prefix / "lib"), *FLAGS]
    run(command, ffmpeg, env, work / ("ffmpeg-" + native_arch + "-configure.log"))
    run(["make", "-j1"], ffmpeg, env, work / ("ffmpeg-" + native_arch + "-build.log"))
    run(["make", "-j1", "install"], ffmpeg, env, work / ("ffmpeg-" + native_arch + "-install.log"))
    artifact_entries = []
    for library in sorted((prefix / "lib").glob("*.a")):
        reader = ["readelf", "-h", str(library)] if host else [str(pathlib.Path(args.sdk) / "llvm/bin/llvm-readelf.exe"),
                                                              "-h", windows_path(str(library))]
        inspected = subprocess.run(reader, capture_output=True, text=True, check=True).stdout
        machines = re.findall(r"Machine:\s+(.+)", inspected)
        expected = "AArch64" if abi == "arm64-v8a" else "Advanced Micro Devices X86-64"
        if not machines or any(machine.strip() != expected for machine in machines):
            raise SystemExit(f"Unexpected member architecture in {library}")
        artifact_entries.append({"path": library.relative_to(work).as_posix(), "bytes": library.stat().st_size,
                                 "sha256": digest(library), "memberMachines": {expected: len(machines)}})
    (work / ("build-" + native_arch + "-manifest.json")).write_text(json.dumps({
        "sources": SOURCE_ARCHIVES, "abi": abi, "ffmpegCommand": command, "artifacts": artifact_entries,
        "toolchain": {"compilerInvocation": env["CC"], "sdkRoot": None if host else args.sdk,
                      "hostValidationOnly": host},
        "note": "Host artifacts validate shared C++ behavior only, never OHOS runtime acceptance." if host else "OHOS target artifacts",
    }, indent=2) + "\n")
    return artifact_entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", required=True, type=pathlib.Path)
    parser.add_argument("--archive-dir", type=pathlib.Path)
    parser.add_argument("--sdk")
    parser.add_argument("--abi", required=True, choices=("host", "arm64-v8a", "x86_64", "both"))
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    work = args.work.resolve()
    if args.abi != "host" and not str(work).startswith("/mnt/"):
        raise SystemExit("OHOS work must be on a Windows-mounted drive")
    work.mkdir(parents=True, exist_ok=True)
    (work / "tmp").mkdir(exist_ok=True)
    source_root = sources(work, args.archive_dir.resolve() if args.archive_dir else None, args.download)
    architectures = ("arm64-v8a", "x86_64") if args.abi == "both" else (args.abi,)
    artifacts = []
    for abi in architectures:
        artifacts.extend(build_one(abi, args, source_root, work))
    (work / "artifacts.json").write_text(json.dumps(artifacts, indent=2) + "\n")
    licenses = work / "licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copy2(source_root / "FFmpeg-n6.0/COPYING.LGPLv2.1", licenses / "FFmpeg-COPYING.LGPLv2.1")
    shutil.copy2(source_root / "lame-3.100/COPYING", licenses / "LAME-COPYING")
    print(json.dumps({"completed": list(architectures), "libraries": len(artifacts)}), flush=True)


if __name__ == "__main__":
    main()
