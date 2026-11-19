#!/usr/bin/env python3
"""Verify packaged hashes and optional target ELF dependencies without executing target code."""
import argparse
import json
import pathlib
import re
import subprocess

from import_artifacts import digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--thirdparty", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[2] / "entry/src/main/cpp/thirdparty")
    parser.add_argument("--sdk", type=pathlib.Path)
    parser.add_argument("--build-root", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    packaged = args.thirdparty.resolve()
    manifest = json.loads((packaged / "build-manifest.json").read_text(encoding="utf-8"))
    expected = set()
    for record in manifest["files"]:
        path = (packaged / record["path"]).resolve()
        if not path.is_relative_to(packaged):
            raise SystemExit("Manifest path escapes the packaged directory")
        if path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
            raise SystemExit(f"Packaged file differs from verified manifest: {record['path']}")
        expected.add(path)
    actual = {path.resolve() for abi in ("arm64-v8a", "x86_64")
              for path in (packaged / abi).rglob("*") if path.is_file()}
    if actual != expected:
        raise SystemExit("The packaged tree contains missing or unrecorded files")
    native_source = packaged.parent
    evidence = {
        "scope": "Packaged hashes and target ELF inspection; no OHOS runtime acceptance",
        "packagedFiles": len(expected),
        "packageManifestSha256": digest(packaged / "build-manifest.json"),
        "currentNativeSources": [{"path": str(path.relative_to(native_source)), "sha256": digest(path)}
                                 for name in ("CMakeLists.txt", "napi_init.cpp", "media/MediaProcessor.cpp",
                                              "media/MediaProcessor.h", "media/MediaJob.cpp")
                                 for path in [native_source / name]],
        "targets": [],
    }
    if args.build_root:
        if not args.sdk:
            raise SystemExit("--sdk is required when inspecting target builds")
        reader = args.sdk.resolve() / "llvm/bin/llvm-readelf.exe"
        for abi, machine in (("arm64-v8a", "AArch64"), ("x86_64", "Advanced Micro Devices X86-64")):
            path = args.build_root.resolve() / abi / "libxdm_media.so"
            inspected = subprocess.check_output([str(reader), "-h", "-d", "--dyn-syms", str(path)], text=True)
            if not re.search(r"Class:\s+ELF64\b", inspected) or not re.search(r"Machine:\s+" + re.escape(machine), inspected):
                raise SystemExit(f"Unexpected target ELF architecture: {path}")
            needed = sorted(re.findall(r"\(NEEDED\).*?\[(.*?)\]", inspected))
            if needed != sorted(["libace_napi.z.so", "libc++_shared.so", "libc.so"]):
                raise SystemExit(f"Unexpected dynamic dependencies: {path}: {needed}")
            exported = [line for line in inspected.splitlines() if "GLOBAL" in line and " UND " not in line]
            if any(re.search(r"\b(?:av\w+|lame_\w+|swr_\w+)$", line) for line in exported):
                raise SystemExit("Bundled FFmpeg/LAME exports are not hidden")
            target = {"abi": abi, "path": str(path), "bytes": path.stat().st_size,
                      "sha256": digest(path), "needed": needed, "bundledSymbolsHidden": True}
            runner = path.parent / "xdm_media_runner"
            if runner.exists():
                runner_header = subprocess.check_output([str(reader), "-h", str(runner)], text=True)
                if not re.search(r"Machine:\s+" + re.escape(machine), runner_header):
                    raise SystemExit(f"Unexpected standalone runner architecture: {runner}")
                target["standaloneRunner"] = {"path": str(runner), "bytes": runner.stat().st_size, "sha256": digest(runner)}
            evidence["targets"].append(target)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
