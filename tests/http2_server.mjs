import http2 from "node:http2";
import { gzipSync, gunzipSync } from "node:zlib";

const host = "127.0.0.1";
const port = Number(process.env.JOUBAKO_HTTP2_PORT ?? 18942);
const server = http2.createServer();

function decodeSingleCompressedFrame(frame) {
  if (frame.length < 5 || frame[0] !== 1) {
    throw new Error("expected one compressed gRPC frame");
  }
  const length = frame.readUInt32BE(1);
  if (frame.length !== length + 5) {
    throw new Error("invalid compressed gRPC frame length");
  }
  return gunzipSync(frame.subarray(5));
}

function compressedFrame(payload) {
  const compressed = gzipSync(payload);
  const frame = Buffer.alloc(5 + compressed.length);
  frame[0] = 1;
  frame.writeUInt32BE(compressed.length, 1);
  compressed.copy(frame, 5);
  return frame;
}

server.on("stream", (stream, headers) => {
  // Client-side timeout and cancellation legitimately reset a stream.
  stream.on("error", () => {});
  const method = headers[":method"];
  const path = headers[":path"];
  const chunks = [];

  if (path === "/joubako.test.Echo/Bidi") {
    if (method !== "POST" || headers.te !== "trailers" ||
        headers["content-type"] !== "application/grpc+proto") {
      stream.respond({ ":status": 400 });
      stream.end();
      return;
    }
    const responseHeaders = {
      ":status": 200, "content-type": "application/grpc+proto"
    };
    if (headers["grpc-encoding"] === "gzip") {
      responseHeaders["grpc-encoding"] = "gzip";
    }
    stream.respond(
      responseHeaders,
      { waitForTrailers: true }
    );
    stream.on("data", chunk => stream.write(chunk));
    stream.on("wantTrailers", () => stream.sendTrailers({
      "grpc-status": "0", "x-bidi-finished": "yes"
    }));
    stream.on("end", () => stream.end());
    return;
  }

  if (path === "/slow-upload") {
    stream.pause();
    setTimeout(() => stream.resume(), 120);
  }

  stream.on("data", chunk => chunks.push(chunk));
  stream.on("end", () => {
    const requestBytes = Buffer.concat(chunks);
    const requestBody = requestBytes.toString();
    const sendGrpc = (body, trailers = { "grpc-status": "0" },
        contentType = "application/grpc+proto", messageEncoding = "") => {
      const responseHeaders = { ":status": 200, "content-type": contentType };
      if (messageEncoding) responseHeaders["grpc-encoding"] = messageEncoding;
      stream.respond(
        responseHeaders,
        { waitForTrailers: true }
      );
      stream.on("wantTrailers", () => stream.sendTrailers(trailers));
      stream.end(body);
    };
    if (path === "/joubako.test.Echo/Unary") {
      if (method !== "POST" || headers.te !== "trailers" ||
          headers["content-type"] !== "application/grpc+proto" ||
          !headers["grpc-timeout"]) {
        sendGrpc(Buffer.alloc(0), {
          "grpc-status": "3",
          "grpc-message": "invalid%20request%20headers"
        });
      } else {
        sendGrpc(requestBytes);
      }
      return;
    }
    if (path === "/joubako.test.Echo/CompressedUnary") {
      if (method !== "POST" || headers["grpc-encoding"] !== "gzip" ||
          !String(headers["grpc-accept-encoding"] ?? "").includes("gzip")) {
        sendGrpc(Buffer.alloc(0), {
          "grpc-status": "3",
          "grpc-message": "gzip%20negotiation%20required"
        });
        return;
      }
      try {
        const protobuf = decodeSingleCompressedFrame(requestBytes);
        sendGrpc(compressedFrame(protobuf), { "grpc-status": "0" },
          "application/grpc+proto", "gzip");
      } catch {
        sendGrpc(Buffer.alloc(0), {
          "grpc-status": "13",
          "grpc-message": "invalid%20gzip%20frame"
        });
      }
      return;
    }
    if (path === "/joubako.test.Echo/Stream") {
      const responseHeaders = {
        ":status": 200, "content-type": "application/grpc+proto"
      };
      if (headers["grpc-encoding"] === "gzip") {
        responseHeaders["grpc-encoding"] = "gzip";
      }
      stream.respond(
        responseHeaders,
        { waitForTrailers: true }
      );
      stream.on("wantTrailers", () => stream.sendTrailers({ "grpc-status": "0" }));
      const split = Math.min(2, requestBytes.length);
      stream.write(requestBytes.subarray(0, split));
      stream.write(requestBytes.subarray(split));
      stream.end(requestBytes);
      return;
    }
    if (path === "/joubako.test.Echo/ClientStream") {
      let offset = 0;
      let lastFrame = Buffer.alloc(0);
      while (offset + 5 <= requestBytes.length) {
        const length = requestBytes.readUInt32BE(offset + 1);
        const end = offset + 5 + length;
        if (end > requestBytes.length) break;
        lastFrame = requestBytes.subarray(offset, end);
        offset = end;
      }
      sendGrpc(lastFrame, { "grpc-status": "0" },
        "application/grpc+proto",
        headers["grpc-encoding"] === "gzip" ? "gzip" : "");
      return;
    }
    if (path === "/joubako.test.Echo/Failure") {
      sendGrpc(Buffer.alloc(0), {
        "grpc-status": "14",
        "grpc-message": "temporarily%20unavailable",
        "grpc-status-details-bin": Buffer.from("details").toString("base64")
      });
      return;
    }
    if (path === "/joubako.test.Echo/MissingStatus") {
      sendGrpc(requestBytes, { "x-finished": "yes" });
      return;
    }
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
    if (path === "/trailers") {
      stream.respond(
        { ":status": 200, "x-initial": "header" },
        { waitForTrailers: true }
      );
      stream.on("wantTrailers", () => stream.sendTrailers({ "x-final": "trailer" }));
      stream.end("body");
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
    if (path === "/upload-redirect") {
      stream.respond({ ":status": 307, location: "/upload-stream" });
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
    const body = path === "/echo" || path === "/upload-stream"
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
