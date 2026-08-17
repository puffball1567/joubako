#!/usr/bin/env python3
"""Build the shared C ABI and compile its public header as C and C++."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--memory-manager", choices=("arc", "orc"), default="arc")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="joubako-cabi-build-") as directory:
        work = Path(directory)
        if os.name == "nt":
            library = work / "joubako.dll"
            cc = os.environ.get("CC", "gcc")
            cxx = os.environ.get("CXX", "g++")
        elif sys.platform == "darwin":
            library = work / "libjoubako.dylib"
            cc = os.environ.get("CC", "cc")
            cxx = os.environ.get("CXX", "c++")
        else:
            library = work / "libjoubako.so"
            cc = os.environ.get("CC", "cc")
            cxx = os.environ.get("CXX", "c++")

        subprocess.run(
            [
                "nim",
                "c",
                "--app:lib",
                "-d:release",
                f"--mm:{args.memory_manager}",
                "--path:src",
                f"--nimcache:{work / 'nimcache'}",
                f"--out:{library}",
                "src/joubako/cabi.nim",
            ],
            cwd=ROOT,
            check=True,
        )
        subprocess.run(
            [
                cc,
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Iinclude",
                "-c",
                "tests/cabi/client.c",
                "-o",
                str(work / "client.o"),
            ],
            cwd=ROOT,
            check=True,
        )
        subprocess.run(
            [
                cxx,
                "-std=c++17",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Iinclude",
                "-c",
                "tests/cabi/header_cpp.cpp",
                "-o",
                str(work / "header_cpp.o"),
            ],
            cwd=ROOT,
            check=True,
        )
        dll_directories = []
        if os.name == "nt" and hasattr(os, "add_dll_directory"):
            compiler = shutil.which(cc)
            search_paths = [work]
            if compiler is not None:
                search_paths.append(Path(compiler).resolve().parent)
            for search_path in search_paths:
                dll_directories.append(os.add_dll_directory(str(search_path)))
        try:
            loaded = ctypes.CDLL(str(library))
            loaded.joubako_abi_version.restype = ctypes.c_uint32
            if loaded.joubako_abi_version() != 1:
                raise RuntimeError("shared library reported an unexpected ABI version")
        finally:
            for directory in dll_directories:
                directory.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
