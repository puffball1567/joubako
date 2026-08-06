import http2 from "node:http2";

const host = "127.0.0.1";
const port = Number(process.env.JOUBAKO_HTTP2_PORT ?? 18942);
const server = http2.createServer();

server.on("stream", (stream, headers) => {
  // Client-side timeout and cancellation legitimately reset a stream.
  stream.on("error", () => {});
  const method = headers[":method"];
  const path = headers[":path"];
  const chunks = [];

  if (path === "/slow-upload") {
    stream.pause();
    setTimeout(() => stream.resume(), 120);
  }

  stream.on("data", chunk => chunks.push(chunk));
  stream.on("end", () => {
    const requestBody = Buffer.concat(chunks).toString();
    if (path === "/slow") {
      setTimeout(() => {
        if (stream.destroyed) return;
        stream.respond({ ":status": 200, "content-length": 4 });
        stream.end("slow");
      }, 120);
      return;
    }
    if (path === "/large") {
      const body = "x".repeat(96 * 1024);
      stream.respond({ ":status": 200, "content-length": body.length });
      stream.end(body);
      return;
    }
    if (path === "/chunks") {
      stream.respond({ ":status": 200, "content-type": "text/plain" });
      stream.write("one");
      stream.write("two");
      stream.end("three");
      return;
    }
    if (path === "/headers") {
      const body = Object.entries(headers)
        .map(([name, value]) => `${name}: ${value}`)
        .join("\n");
      stream.respond({ ":status": 200, "content-length": Buffer.byteLength(body) });
      stream.end(body);
      return;
    }
    if (path === "/status") {
      stream.respond({ ":status": 418, "x-test": ["first", "second"] });
      stream.end();
      return;
    }
    if (path === "/redirect") {
      stream.respond({ ":status": 302, location: "/" });
      stream.end();
      return;
    }
    if (path === "/redirect-loop") {
      stream.respond({ ":status": 307, location: "/redirect-loop" });
      stream.end();
      return;
    }
    if (path === "/multipart-redirect") {
      stream.respond({ ":status": 307, location: "/multipart" });
      stream.end();
      return;
    }
    if (path === "/multipart-redirect-get") {
      stream.respond({ ":status": 303, location: "/echo" });
      stream.end();
      return;
    }
    if (path === "/set-cookie") {
      stream.respond({
        ":status": 302,
        location: "/headers",
        "set-cookie": "session=h2; Path=/; HttpOnly"
      });
      stream.end();
      return;
    }
    const body = path === "/echo"
      ? `${method}:${requestBody}`
      : path === "/multipart"
        ? `${headers["content-type"]}\n${requestBody}`
        : path === "/multipart-method"
          ? `${method}\n${headers["content-type"]}\n${requestBody}`
        : "ok";
    stream.respond({
      ":status": 200,
      "content-type": "text/plain",
      "content-length": Buffer.byteLength(body)
    });
    stream.end(body);
  });
});

server.listen(port, host, () => console.log("JOUBAKO_HTTP2_READY"));

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
