import express from "express";

const app = express();
const port = Number.parseInt(process.env.PORT ?? "3000", 10);

app.use(express.json({ limit: "16kb" }));

app.get("/api/health", (_request, response) => {
  response.json({ ok: true, framework: "Express" });
});

app.get("/api/users/:id", (request, response) => {
  const id = Number.parseInt(request.params.id, 10);
  if (id !== 1) {
    return response.status(404).json({ error: "user not found" });
  }

  return response.json({
    id,
    name: "Express User",
    email: "express@example.test",
  });
});

app.post("/api/messages", (request, response) => {
  const { text, priority } = request.body ?? {};
  if (
    typeof text !== "string" ||
    text.length === 0 ||
    text.length > 200 ||
    !Number.isInteger(priority) ||
    priority < 1 ||
    priority > 5
  ) {
    return response.status(422).json({ error: "invalid message" });
  }

  return response.status(201).json({
    accepted: true,
    text,
    priority,
    framework: "Express",
    client: request.get("x-joubako-demo") ?? "unknown",
  });
});

app.listen(port, "127.0.0.1", () => {
  console.log(`Express demo listening on http://127.0.0.1:${port}`);
});
