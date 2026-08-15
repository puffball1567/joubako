import http from "node:http";

const port = Number(process.env.JOUBAKO_HTTP1_BENCH_PORT ?? 18944);
const body = Buffer.alloc(128, "j");

const server = http.createServer((request, response) => {
  if (request.method === "GET" && request.url === "/") {
    response.writeHead(200, {
      "content-type": "application/octet-stream",
      "content-length": String(body.length),
      "cache-control": "no-store"
    });
    response.end(body);
    return;
  }

  if (request.method === "POST" && request.url === "/echo") {
    const chunks = [];
    let receivedBytes = 0;
    request.on("data", (chunk) => {
      receivedBytes += chunk.length;
      if (receivedBytes > 1024) {
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      const echoed = Buffer.concat(chunks, receivedBytes);
      response.writeHead(200, {
        "content-type": "application/octet-stream",
        "content-length": String(echoed.length),
        "cache-control": "no-store"
      });
      response.end(echoed);
    });
    return;
  }

  response.writeHead(404, { "content-length": "0" });
  response.end();
});

server.keepAliveTimeout = 60_000;
server.headersTimeout = 65_000;
server.listen(port, "127.0.0.1");

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
