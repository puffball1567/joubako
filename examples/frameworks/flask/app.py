import os

from flask import Flask, request


app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024


@app.get("/api/health")
def health():
    return {"ok": True, "framework": "Flask"}


@app.get("/api/users/<int:user_id>")
def user(user_id: int):
    if user_id != 1:
        return {"error": "user not found"}, 404

    return {
        "id": user_id,
        "name": "Flask User",
        "email": "flask@example.test",
    }


@app.post("/api/messages")
def message():
    payload = request.get_json(silent=True) or {}
    text = payload.get("text")
    priority = payload.get("priority")
    if (
        not isinstance(text, str)
        or not text
        or len(text) > 200
        or isinstance(priority, bool)
        or not isinstance(priority, int)
        or priority < 1
        or priority > 5
    ):
        return {"error": "invalid message"}, 422

    return {
        "accepted": True,
        "text": text,
        "priority": priority,
        "framework": "Flask",
        "client": request.headers.get("X-Joubako-Demo", "unknown"),
    }, 201


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "5000")))
