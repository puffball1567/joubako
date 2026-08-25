# Joubako with Flask

This integration uses a Nim/Joubako client with a small Flask JSON service.
It fits native applications that consume an existing Python backend without
introducing a protocol adapter.

## Backend implementation

The routes return Flask's normal JSON-compatible values and status tuples:

```python
@app.get("/api/health")
def health():
    return {"ok": True, "framework": "Flask"}

@app.post("/api/messages")
def message():
    payload = request.get_json(silent=True) or {}
    text = payload.get("text")
    priority = payload.get("priority")
    if not isinstance(text, str) or not isinstance(priority, int):
        return {"error": "invalid message"}, 422

    return {
        "accepted": True,
        "text": text,
        "priority": priority,
        "framework": "Flask",
    }, 201
```

The complete demo sets `MAX_CONTENT_LENGTH` to 16 KiB and performs stricter
field validation. See [`app.py`](../../examples/frameworks/flask/app.py).

## Run Flask

```sh
cd examples/frameworks/flask
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python app.py
```

## Call Flask from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:5000/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Flask \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Production notes

Do not expose Flask's development server. Use the application's production WSGI
deployment, authentication, TLS, and request limits. The Joubako client code is
unchanged when the base URL moves to that production origin.
