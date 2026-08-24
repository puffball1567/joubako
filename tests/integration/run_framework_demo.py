#!/usr/bin/env python3
"""Run one real framework server against the shared Joubako demo client."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from typing import BinaryIO


def available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_until_ready(process: subprocess.Popen[bytes], port: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited with status {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError(f"server did not listen on 127.0.0.1:{port}")


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def print_log(log: BinaryIO) -> None:
    log.seek(0)
    output = log.read().decode("utf-8", errors="replace")
    if output:
        print("Server output:", file=sys.stderr)
        print(output, file=sys.stderr)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--server-workdir", type=Path, required=True)
    parser.add_argument("--client", type=Path, action="append", required=True)
    parser.add_argument("--startup-timeout", type=float, default=60.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a server command is required after --")
    return args


def main() -> int:
    args = parse_args()
    port = available_port()
    environment = os.environ.copy()
    environment["PORT"] = str(port)

    with tempfile.TemporaryFile() as server_log:
        try:
            process = subprocess.Popen(
                args.command,
                cwd=args.server_workdir,
                env=environment,
                stdout=server_log,
                stderr=subprocess.STDOUT,
            )
        except OSError as error:
            print(f"{args.name} server could not start: {error}", file=sys.stderr)
            return 1

        try:
            wait_until_ready(process, port, args.startup_timeout)
            client_environment = environment.copy()
            client_environment["JOUBAKO_DEMO_BASE_URL"] = (
                f"http://127.0.0.1:{port}/"
            )
            client_environment["JOUBAKO_DEMO_EXPECTED_FRAMEWORK"] = args.name
            for client in args.client:
                completed = subprocess.run(
                    [str(client.resolve())],
                    env=client_environment,
                    check=False,
                    timeout=60,
                )
                if completed.returncode != 0:
                    print(
                        f"{args.name} client failed: {client}",
                        file=sys.stderr,
                    )
                    print_log(server_log)
                    return completed.returncode
        except (OSError, RuntimeError, TimeoutError, subprocess.TimeoutExpired) as error:
            print(f"{args.name} integration failed: {error}", file=sys.stderr)
            print_log(server_log)
            return 1
        finally:
            stop_process(process)

    print(f"{args.name} integration passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
