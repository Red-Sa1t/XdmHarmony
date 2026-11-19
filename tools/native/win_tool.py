#!/usr/bin/env python3
"""WSL configure/make adapter for an existing Windows OHOS LLVM installation."""
import os
import pathlib
import re
import subprocess
import sys


def windows_path(value):
    # Only FFmpeg's known out-of-tree source link needs WSL symlink resolution.
    if value == "src" or value.startswith("src/"):
        value = str(pathlib.Path(value).resolve())
    if value.startswith("/mnt/") and len(value) > 7:
        return value[5].upper() + ":/" + value[7:]
    if value.startswith("/tmp/"):
        raise ValueError("Compiler temporary files must stay in the selected Windows-mounted work directory")
    return value


def main():
    sdk = os.environ["XDM_NATIVE_SDK_ROOT"].rstrip("/")
    target = os.environ["XDM_NATIVE_TARGET"]
    tool = sys.argv[1]
    arguments = sys.argv[2:]
    converted = []
    for argument in arguments:
        for prefix in ("--sysroot=", "-I", "-L", "-isystem", "-iquote"):
            if argument.startswith(prefix) and len(argument) > len(prefix):
                argument = prefix + windows_path(argument[len(prefix):])
                break
        else:
            argument = windows_path(argument)
        converted.append(argument)
    if tool in ("clang", "clang++"):
        converted = ["--target=" + target, "--sysroot=" + windows_path(sdk + "/sysroot"), *converted]
    result = subprocess.run([sdk + "/llvm/bin/" + tool + ".exe", *converted], check=False)
    if result.returncode == 0 and "-MF" in arguments:
        dependency = pathlib.Path(arguments[arguments.index("-MF") + 1])
        if dependency.exists():
            source = dependency.read_text()
            dependency.write_text(re.sub(r"\b([A-Za-z]):/", lambda match: "/mnt/" + match[1].lower() + "/", source))
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
