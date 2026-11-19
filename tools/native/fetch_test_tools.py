#!/usr/bin/env python3
"""Fetch pinned Linux host-only fixture/probe tools and Node N-API headers.

Nothing here is linked into or packaged with the HarmonyOS application.
Npm integrity values are pinned from the published version metadata.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import shutil
import tarfile
import urllib.request

PACKAGES = [
    {"tool": "ffmpeg", "package": "@ffmpeg-installer/linux-x64", "version": "4.1.0",
     "url": "https://registry.npmjs.org/@ffmpeg-installer/linux-x64/-/linux-x64-4.1.0.tgz",
     "integrity": "sha512-Y5BWhGLU/WpQjOArNIgXD3z5mxxdV8c41C+U15nsE5yF8tVcdCGet5zPs5Zy3Ta6bU7haGpIzryutqCGQA/W8A=="},
    {"tool": "ffprobe", "package": "@ffprobe-installer/linux-x64", "version": "4.1.0",
     "url": "https://registry.npmjs.org/@ffprobe-installer/linux-x64/-/linux-x64-4.1.0.tgz",
     "integrity": "sha512-Id+irHoI+Arq6tb3sHNQyzRrgUVVDgbmwpREDqQ+GDydiCw5ca7VnvRGXE/tBM2mVQ3/6m9wWHR7+xaW3gKJlA=="},
]


def download(url, target):
    if target.exists():
        return
    temporary = target.with_suffix(target.suffix + ".download")
    with urllib.request.urlopen(url, timeout=90) as response, temporary.open("wb") as output:
        shutil.copyfileobj(response, output)
    temporary.replace(target)


def hash_file(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--node-version", default="v18.19.1")
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    records = []
    for item in PACKAGES:
        print(json.dumps({"fetch": item["tool"], "version": item["version"]}), flush=True)
        archive = root / (item["tool"] + "-" + item["version"] + ".tgz")
        download(item["url"], archive)
        actual = "sha512-" + base64.b64encode(hash_file(archive, "sha512").digest()).decode("ascii")
        if actual != item["integrity"]:
            raise SystemExit(f"Host tool integrity mismatch: {archive}")
        binary = root / item["tool"]
        with tarfile.open(archive, "r:gz") as package:
            member = package.getmember("package/" + item["tool"])
            if not member.isfile():
                raise SystemExit("Host tool is not a regular archive member")
            with package.extractfile(member) as source, binary.open("wb") as output:
                shutil.copyfileobj(source, output)
        binary.chmod(0o755)
        records.append({**item, "sha256": hash_file(binary).hexdigest(), "bytes": binary.stat().st_size,
                        "scope": "Linux host fixture generation/analysis only"})
    node_version = args.node_version
    if not node_version.startswith("v") or not all(character.isdigit() or character == "." for character in node_version[1:]):
        raise SystemExit("Invalid Node version")
    archive_name = f"node-{node_version}-headers.tar.gz"
    base_url = f"https://nodejs.org/dist/{node_version}/"
    checksums = root / f"node-{node_version}-SHASUMS256.txt"
    download(base_url + "SHASUMS256.txt", checksums)
    expected = None
    for line in checksums.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == archive_name:
            expected = parts[0]
    archive = root / archive_name
    download(base_url + archive_name, archive)
    if expected is None or hash_file(archive).hexdigest() != expected:
        raise SystemExit("Node headers checksum mismatch")
    with tarfile.open(archive, "r:gz") as source:
        source.extractall(root, filter="data")
    records.append({"tool": "Node N-API headers", "version": node_version, "url": base_url + archive_name,
                    "archiveSha256": expected, "scope": "Host addon tests only"})
    (root / "manifest.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ready": str(root)}), flush=True)


if __name__ == "__main__":
    main()
