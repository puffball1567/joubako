import gzip
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


HOST = os.environ.get("JOUBAKO_E2E_HOST", "0.0.0.0")
PORT = int(os.environ.get("JOUBAKO_E2E_PORT", "8080"))
ROLE = os.environ.get("JOUBAKO_E2E_ROLE", "backend")
REDIRECT_URL = os.environ.get(
    "JOUBAKO_E2E_REDIRECT_URL",
    "http://redirect:8080/inspect",
)
RETRY_LOCK = threading.Lock()
RETRY_COUNT = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "JoubakoE2E/1"

    def log_message(self, fmt, *args):
        print(f"[{ROLE}] {self.address_string()} {fmt % args}", flush=True)

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length)

    def send_bytes(self, status, body, content_type="application/octet-stream", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
            self.wfile.flush()

    def send_json(self, status, value, headers=()):
        body = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()
        self.send_bytes(status, body, "application/json; charset=utf-8", headers)

    def do_GET(self):
        global RETRY_COUNT
        parsed = urlsplit(self.path)

        if parsed.path == "/health":
            self.send_json(200, {"ok": True, "role": ROLE})
        elif parsed.path == "/query":
            self.send_json(200, {"query": parse_qs(parsed.query, keep_blank_values=True)})
        elif parsed.path == "/headers":
            self.send_json(200, {"ok": True}, (("X-Repeat", "one"), ("X-Repeat", "two")))
        elif parsed.path == "/gzip":
            body = gzip.compress("compressed across containers".encode())
            self.send_bytes(200, body, headers=(("Content-Encoding", "gzip"),))
        elif parsed.path == "/chunked":
            chunks = (b"container-", b"stream-", b"complete")
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for chunk in chunks:
                self.wfile.write(f"{len(chunk):X}\r\n".encode())
                self.wfile.write(chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.01)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        elif parsed.path == "/download":
            self.send_bytes(200, b"downloaded-across-container-network")
        elif parsed.path == "/sized":
            requested = int(parse_qs(parsed.query).get("bytes", ["0"])[0])
            size = min(max(requested, 0), 1024 * 1024)
            self.send_bytes(200, b"x" * size)
        elif parsed.path == "/retry":
            with RETRY_LOCK:
                RETRY_COUNT += 1
                attempt = RETRY_COUNT
            if attempt == 1:
                self.send_json(503, {"attempt": attempt}, (("Retry-After", "0"),))
            else:
                self.send_json(200, {"attempt": attempt})
        elif parsed.path == "/redirect-cross":
            self.send_response(302)
            self.send_header("Location", REDIRECT_URL)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif parsed.path == "/inspect":
            self.send_json(200, {
                "authorization": self.headers.get("Authorization", ""),
                "cookie": self.headers.get("Cookie", ""),
                "proxyAuthorization": self.headers.get("Proxy-Authorization", ""),
                "host": self.headers.get("Host", ""),
                "role": ROLE,
            })
        elif parsed.path == "/set-cookie":
            self.send_json(200, {"ok": True}, (("Set-Cookie", "session=e2e; Path=/; HttpOnly"),))
        elif parsed.path == "/cookie":
            self.send_json(200, {"cookie": self.headers.get("Cookie", "")})
        elif parsed.path == "/slow":
            time.sleep(0.5)
            try:
                self.send_json(200, {"late": True})
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_json(404, {"error": "not found", "path": parsed.path})

    def do_POST(self):
        parsed = urlsplit(self.path)
        body = self.read_body()

        if parsed.path == "/echo-json":
            json.loads(body.decode())
            self.send_bytes(200, body, "application/json")
        elif parsed.path in ("/echo-binary", "/echo-bif"):
            self.send_bytes(200, body, self.headers.get("Content-Type", "application/octet-stream"))
        elif parsed.path == "/multipart":
            content_type = self.headers.get("Content-Type", "")
            valid = (
                content_type.startswith("multipart/form-data; boundary=")
                and b'name="title"' in body
                and b"Joubako E2E" in body
                and b'name="document"' in body
                and b'filename="payload.bin"' in body
                and b"binary\x00payload" in body
            )
            self.send_json(200 if valid else 400, {"valid": valid, "bytes": len(body)})
        else:
            self.send_json(404, {"error": "not found", "path": parsed.path})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[{ROLE}] listening on {HOST}:{PORT}", flush=True)
    server.serve_forever()
