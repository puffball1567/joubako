#!/usr/bin/env python3
"""Build and soak the JSON C ABI against a real Prologue server."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
PROLOGUE_PACKAGES = (
    "prologue",
    "httpx",
    "ioselectors",
    "wepoll",
    "cookiejar",
    "unicodedb",
    "regex",
    "logue",
    "nimcrypto",
    "cligen",
)


def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, cwd=ROOT, text=True, check=True, **kwargs)


def nimble_path(package: str) -> Path:
    completed = subprocess.run(
        ["nimble", "path", package],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    for line in completed.stdout.splitlines():
        candidate = Path(line.strip())
        if candidate.is_absolute() and candidate.exists():
            return candidate
    raise RuntimeError(
        f"could not resolve Nimble package {package!r}:\n{completed.stdout}"
    )


def compile_prologue(output: Path, cache: Path) -> None:
    paths: list[str] = []
    for package in PROLOGUE_PACKAGES:
        root = nimble_path(package)
        source = root / "src"
        paths.append(f"--path:{source if source.is_dir() else root}")
    run(
        [
            "nim",
            "c",
            "-d:release",
            "--mm:arc",
            "--skipParentCfg:on",
            "--skipProjCfg:on",
            f"--nimcache:{cache}",
            f"--out:{output}",
            *paths,
            "examples/frameworks/prologue/server.nim",
        ]
    )


def compile_c_abi(work: Path, memory_manager: str) -> tuple[Path, Path]:
    if sys.platform == "darwin":
        library = work / "libjoubako.dylib"
    elif os.name == "nt":
        library = work / "joubako.dll"
    else:
        library = work / "libjoubako.so"
    client = work / ("joubako-cabi-client.exe" if os.name == "nt" else "joubako-cabi-client")
    run(
        [
            "nim",
            "c",
            "--app:lib",
            "-d:release",
            f"--mm:{memory_manager}",
            "--path:src",
            f"--nimcache:{work / 'cabi-nimcache'}",
            f"--out:{library}",
            "src/joubako/cabi.nim",
        ]
    )
    if os.name == "nt":
        raise RuntimeError("the Prologue soak runner currently requires POSIX")
    run(
        [
            os.environ.get("CC", "cc"),
            "-std=c11",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Iinclude",
            "tests/cabi/client.c",
            f"-L{work}",
            f"-Wl,-rpath,{work}",
            "-ljoubako",
            "-o",
            str(client),
        ]
    )
    cpp = work / "joubako-cabi-cpp"
    run(
        [
            os.environ.get("CXX", "c++"),
            "-std=c++17",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Iinclude",
            "tests/cabi/header_cpp.cpp",
            f"-L{work}",
            f"-Wl,-rpath,{work}",
            "-ljoubako",
            "-o",
            str(cpp),
        ]
    )
    run([str(cpp)])
    return library, client


def wait_for_server(process: subprocess.Popen[str], port: int) -> None:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Prologue exited before accepting connections")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Prologue did not start within 30 seconds")


def select_port(requested: int) -> int:
    if requested != 0:
        return requested
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def process_sample(process: subprocess.Popen[str]) -> dict[str, int] | None:
    status = Path(f"/proc/{process.pid}/status")
    if not status.exists():
        return None
    rss_kib = 0
    for line in status.read_text(encoding="utf-8").splitlines():
        if line.startswith("VmRSS:"):
            rss_kib = int(line.split()[1])
            break
    fd_dir = Path(f"/proc/{process.pid}/fd")
    fd_count = len(list(fd_dir.iterdir())) if fd_dir.exists() else 0
    return {"rss_kib": rss_kib, "fd_count": fd_count}


def summarize(samples: list[dict[str, int]]) -> dict[str, int] | None:
    if not samples:
        return None
    rss = [sample["rss_kib"] for sample in samples]
    fds = [sample["fd_count"] for sample in samples]
    return {
        "samples": len(samples),
        "rss_initial_kib": rss[0],
        "rss_final_kib": rss[-1],
        "rss_peak_kib": max(rss),
        "rss_span_kib": max(rss) - min(rss),
        "fd_initial": fds[0],
        "fd_final": fds[-1],
        "fd_peak": max(fds),
        "fd_span": max(fds) - min(fds),
    }


def stop(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration-seconds", type=int, default=10_800)
    parser.add_argument("--delay-ms", type=int, default=20)
    parser.add_argument("--sample-seconds", type=int, default=60)
    parser.add_argument("--warmup-seconds", type=int, default=30)
    parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="server port; 0 selects an available loopback port",
    )
    parser.add_argument("--memory-manager", choices=("arc", "orc"), default="arc")
    parser.add_argument("--max-rss-span-kib", type=int, default=65_536)
    parser.add_argument("--max-fd-span", type=int, default=8)
    parser.add_argument("--result-json", type=Path)
    args = parser.parse_args()
    if args.duration_seconds < 1 or args.sample_seconds < 1 or args.warmup_seconds < 0:
        parser.error("duration and sample intervals must be positive")

    work = Path(tempfile.mkdtemp(prefix="joubako-cabi-prologue-"))
    port = select_port(args.port)
    server: subprocess.Popen[str] | None = None
    client_process: subprocess.Popen[str] | None = None
    server_log = None
    started_at = time.time()
    try:
        _, client = compile_c_abi(work, args.memory_manager)
        server_binary = work / "prologue-server"
        compile_prologue(server_binary, work / "prologue-nimcache")
        server_log = (work / "prologue.log").open("w", encoding="utf-8")
        server_env = os.environ.copy()
        server_env["JOUBAKO_DEMO_PORT"] = str(port)
        server = subprocess.Popen(
            [str(server_binary)],
            cwd=ROOT,
            env=server_env,
            text=True,
            stdout=server_log,
            stderr=subprocess.STDOUT,
        )
        wait_for_server(server, port)
        client_process = subprocess.Popen(
            [
                str(client),
                f"http://127.0.0.1:{port}/",
                "0",
                str(args.duration_seconds),
                str(args.delay_ms),
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

        client_samples: list[dict[str, int]] = []
        server_samples: list[dict[str, int]] = []
        monotonic_start = time.monotonic()
        next_sample = monotonic_start + min(args.warmup_seconds, args.duration_seconds)
        deadline = monotonic_start + args.duration_seconds + 60
        while client_process.poll() is None:
            now = time.monotonic()
            if now >= deadline:
                raise RuntimeError("C ABI client exceeded its duration deadline")
            if now >= next_sample:
                client_value = process_sample(client_process)
                server_value = process_sample(server)
                if client_value is not None:
                    client_samples.append(client_value)
                if server_value is not None:
                    server_samples.append(server_value)
                next_sample += args.sample_seconds
            time.sleep(min(1.0, max(0.05, next_sample - now)))

        output = client_process.communicate(timeout=10)[0]
        if client_process.returncode != 0 or "failures=0" not in output:
            raise RuntimeError(f"C ABI client failed:\n{output}")
        summary_line = next(
            line for line in reversed(output.splitlines()) if line.startswith("completed ")
        )
        fields = dict(item.split("=", 1) for item in summary_line.split()[1:])
        client_summary = summarize(client_samples)
        server_summary = summarize(server_samples)
        for label, summary in (("client", client_summary), ("server", server_summary)):
            if summary is None:
                continue
            if summary["rss_span_kib"] > args.max_rss_span_kib:
                raise RuntimeError(f"{label} RSS span exceeded the configured limit")
            if summary["fd_span"] > args.max_fd_span:
                raise RuntimeError(f"{label} FD span exceeded the configured limit")

        result = {
            "result": "passed",
            "memory_manager": args.memory_manager,
            "duration_seconds": int(fields["elapsed_seconds"]),
            "cycles": int(fields["cycles"]),
            "requests": int(fields["requests"]),
            "failures": int(fields["failures"]),
            "prologue_version": "0.6.10",
            "client_process": client_summary,
            "server_process": server_summary,
            "rss_span_limit_kib": args.max_rss_span_kib,
            "fd_span_limit": args.max_fd_span,
            "started_unix": int(started_at),
        }
        rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
        print(rendered, end="")
        if args.result_json is not None:
            args.result_json.parent.mkdir(parents=True, exist_ok=True)
            args.result_json.write_text(rendered, encoding="utf-8")
        return 0
    finally:
        if client_process is not None:
            stop(client_process)
        if server is not None:
            stop(server)
        if server_log is not None:
            server_log.close()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
