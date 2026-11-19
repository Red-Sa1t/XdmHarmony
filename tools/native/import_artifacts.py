#!/usr/bin/env python3
"""Package previously verified OHOS archives; never build or modify upstream sources."""
import argparse
import hashlib
import json
import pathlib
import shutil

SOURCE_ARCHIVES = [
    {
        "name": "FFmpeg", "version": "n6.0", "license": "LGPL-2.1-or-later",
        "url": "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n6.0.tar.gz",
        "file": "FFmpeg-n6.0.tar.gz",
        "sha512": "da1b836c8f51cf69f95db750d5da5191a71d534fa7b0f019d6d6454f8dd6db5598789576b4fe5ad983dcd0197b9a7e8f9d43f10707b6d40ac31425da23da35b2",
    },
    {
        "name": "LAME", "version": "3.100", "license": "LGPL-2.0-or-later",
        "url": "https://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz",
        "file": "lame-3.100-verified.tar.gz",
        "sha512": "0844b9eadb4aacf8000444621451277de365041cc1d97b7f7a589da0b7a23899310afd4e4d81114b9912aa97832621d20588034715573d417b2923948c08634b",
    },
]


def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def build_records(source):
    manifests = {}
    for abi in ("arm64", "x86_64"):
        path = source / ("build-" + abi + "-manifest.json")
        if path.exists():
            manifests[abi] = json.loads(path.read_text(encoding="utf-8"))
    if manifests:
        if len(manifests) != 2:
            raise SystemExit("Both arm64 and x86_64 build manifests are required for packaging")
        records = [record for manifest in manifests.values() for record in manifest["artifacts"]]
        flags = {abi: [value for value in manifest["ffmpegCommand"] if value.startswith("--")]
                 for abi, manifest in manifests.items()}
        toolchains = {abi: manifest.get("toolchain", {"details": "See this build's configure logs"})
                      for abi, manifest in manifests.items()}
        return records, flags, toolchains
    records = json.loads((source / "artifacts.json").read_text(encoding="utf-8"))
    flags = [line.strip().rstrip("\\").strip()
             for line in (source / "build-ffmpeg.sh").read_text(encoding="utf-8").splitlines()
             if line.strip().startswith("--")]
    return records, {"originalSpikeScript": flags}, {
        "originalSpike": {"sdk": "OpenHarmony native API24 / 6.1.1.125; clang 15.0.4"}
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spike", type=pathlib.Path, required=True)
    parser.add_argument("--destination", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[2] / "entry/src/main/cpp/thirdparty")
    parser.add_argument("--verify-only", action="store_true", help="Verify source/build inputs without copying")
    args = parser.parse_args()
    spike, destination = args.spike.resolve(), args.destination.resolve()
    artifacts, flags, toolchains = build_records(spike)
    for source in SOURCE_ARCHIVES:
        path = spike / source["file"]
        if digest(path, "sha512") != source["sha512"]:
            raise SystemExit(f"Source archive verification failed: {path.name}")
    for artifact in artifacts:
        if not artifact["path"].endswith(".a"):
            continue
        source = spike / pathlib.Path(artifact["path"].replace("\\", "/"))
        if digest(source) != artifact["sha256"] or source.stat().st_size != artifact["bytes"]:
            raise SystemExit(f"Static artifact verification failed: {source}")
    expected = {f"prefix/{abi}/lib/lib{library}.a"
                for abi in ("arm64", "x86_64")
                for library in ("avformat", "avcodec", "avutil", "swresample", "mp3lame")}
    declared = {artifact["path"].replace("\\", "/") for artifact in artifacts if artifact["path"].endswith(".a")}
    if not expected.issubset(declared):
        raise SystemExit(f"Missing verified dual-ABI libraries: {sorted(expected - declared)}")
    if args.verify_only:
        print(json.dumps({"verifiedStaticLibraries": len(expected), "verifiedSources": len(SOURCE_ARCHIVES)}))
        return

    destination.mkdir(parents=True, exist_ok=True)
    for source_abi, target_abi in (("arm64", "arm64-v8a"), ("x86_64", "x86_64")):
        source = spike / "prefix" / source_abi
        target = destination / target_abi
        shutil.copytree(source / "include", target / "include", dirs_exist_ok=True)
        (target / "lib").mkdir(exist_ok=True)
        for name in ("avformat", "avcodec", "avutil", "swresample", "mp3lame"):
            library = source / "lib" / ("lib" + name + ".a")
            shutil.copy2(library, target / "lib" / library.name)
            if digest(library) != digest(target / "lib" / library.name):
                raise SystemExit(f"Copied artifact verification failed: {library.name}")
    shutil.copytree(spike / "licenses", destination / "licenses", dirs_exist_ok=True)
    files = []
    for abi in ("arm64-v8a", "x86_64"):
        for path in sorted((destination / abi).rglob("*")):
            if path.is_file():
                files.append({"path": path.relative_to(destination).as_posix(),
                              "bytes": path.stat().st_size, "sha256": digest(path)})
    manifest = {
        "sources": SOURCE_ARCHIVES,
        "sourceModifications": "None. WSL-to-Windows path adaptation is confined to the compiler wrapper.",
        "toolchains": toolchains,
        "targets": {"arm64-v8a": "aarch64-linux-ohos", "x86_64": "x86_64-linux-ohos"},
        "gplComponents": False, "nonfreeComponents": False, "version3Components": False,
        "ffmpegFlagsByBuild": flags,
        "files": files,
    }
    (destination / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"verifiedPackagedFiles": len(files), "destination": str(destination)}))


if __name__ == "__main__":
    main()
