#!/usr/bin/env python3
"""Compile the production C++ core and NAPI glue for independent Linux-host tests."""
import argparse
import hashlib
import json
import pathlib
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--node-headers", type=pathlib.Path)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    source = pathlib.Path(__file__).resolve().parents[2] / "entry/src/main/cpp"
    tools = pathlib.Path(__file__).resolve().parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    prefix = args.prefix.resolve()
    options = ["-std=c++17", "-O1", "-g", "-fPIC", "-fvisibility=hidden", "-Wall", "-Wextra", "-Werror",
               '-DXDM_MEDIA_ABI="host-test"', "-I" + str(source), "-I" + str(prefix / "include")]
    instrumentation = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if args.sanitize else []
    commands = []

    def run(arguments):
        commands.append(arguments)
        subprocess.run(arguments, check=True)

    core_objects = []
    for name in ("MediaJob", "MediaProcessor"):
        target = output / (name + ".o")
        run(["g++", *options, *instrumentation, "-c", str(source / "media" / (name + ".cpp")), "-o", str(target)])
        core_objects.append(str(target))
    libraries = [str(prefix / "lib" / ("lib" + name + ".a"))
                 for name in ("avformat", "avcodec", "swresample", "avutil", "mp3lame")]
    link = ["-Wl,--start-group", *libraries, "-Wl,--end-group", "-lm", "-pthread"]
    runner_object = output / "media_runner.o"
    run(["g++", *options, *instrumentation, "-c", str(tools / "media_runner.cpp"), "-o", str(runner_object)])
    run(["g++", *instrumentation, *core_objects, str(runner_object), *link, "-o", str(output / "media_runner")])
    if args.node_headers and not args.sanitize:
        native_object = output / "napi_init.o"
        run(["g++", *options, "-DXDM_HOST_NAPI_TEST", "-DNAPI_VERSION=8", "-I" + str(args.node_headers.resolve()),
             "-c", str(source / "napi_init.cpp"), "-o", str(native_object)])
        run(["g++", "-shared", "-Wl,--exclude-libs,ALL", *core_objects, str(native_object), *link,
             "-o", str(output / "xdm_media.node")])
    inputs = [source / "media/MediaJob.cpp", source / "media/MediaProcessor.cpp", source / "media/MediaProcessor.h",
              source / "napi_init.cpp", tools / "media_runner.cpp"]
    manifest = {
        "scope": "Host execution of production C++/NAPI code; not OHOS runtime acceptance",
        "sanitizers": args.sanitize,
        "compiler": subprocess.check_output(["g++", "--version"], text=True).splitlines()[0],
        "commands": commands,
        "sources": [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in inputs],
    }
    (output / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"built": str(output), "sanitizers": args.sanitize}), flush=True)


if __name__ == "__main__":
    main()
