"""Run the real-network E2E suite on the host without Docker."""

from __future__ import annotations

import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import URLError
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "tests" / "e2e" / "backend" / "server.py"


def unused_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def start_server(role: str, port: int, redirect_url: str) -> subprocess.Popen:
    environment = os.environ.copy()
    environment.update(
        {
            "JOUBAKO_E2E_HOST": "127.0.0.1",
            "JOUBAKO_E2E_PORT": str(port),
            "JOUBAKO_E2E_ROLE": role,
            "JOUBAKO_E2E_REDIRECT_URL": redirect_url,
        }
    )
    return subprocess.Popen(
        [sys.executable, "-u", str(SERVER)],
        cwd=ROOT,
        env=environment,
    )


def wait_until_ready(process: subprocess.Popen, port: int) -> None:
    deadline = time.monotonic() + 10
    url = f"http://127.0.0.1:{port}/health"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited before becoming ready: {url}")
        try:
            with urlopen(url, timeout=0.25) as response:
                if response.status == 200:
                    return
        except (OSError, URLError):
            time.sleep(0.05)
    raise TimeoutError(f"server did not become ready: {url}")


def stop_server(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def main() -> None:
    backend_port = unused_port()
    redirect_port = unused_port()
    while redirect_port == backend_port:
        redirect_port = unused_port()

    with tempfile.TemporaryDirectory(prefix="joubako-e2e-host-") as work:
        work_path = Path(work)
        client = work_path / "joubako-e2e-client"
        subprocess.run(
            [
                "nim",
                "c",
                "-d:release",
                "--mm:arc",
                "--path:src",
                f"--nimcache:{work_path / 'nimcache'}",
                f"--out:{client}",
                "tests/e2e/client.nim",
            ],
            cwd=ROOT,
            check=True,
        )

        redirect_url = f"http://127.0.0.1:{redirect_port}/inspect"
        redirect = start_server("redirect", redirect_port, redirect_url)
        backend = start_server("backend", backend_port, redirect_url)
        try:
            wait_until_ready(redirect, redirect_port)
            wait_until_ready(backend, backend_port)
            environment = os.environ.copy()
            environment.update(
                {
                    "JOUBAKO_E2E_BASE_URL": f"http://127.0.0.1:{backend_port}/",
                    "JOUBAKO_E2E_REDIRECT_HOST": f"127.0.0.1:{redirect_port}",
                    "JOUBAKO_E2E_TOPOLOGY": "host-process",
                }
            )
            subprocess.run([str(client)], cwd=ROOT, env=environment, check=True)
        finally:
            stop_server(backend)
            stop_server(redirect)


if __name__ == "__main__":
    main()
