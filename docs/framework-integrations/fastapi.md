# Joubako with FastAPI

This integration pairs Joubako with an asynchronous FastAPI service using
Pydantic request validation.

## Backend implementation

FastAPI converts the Pydantic model and header into the same JSON contract used
by the other examples:

```python
class Message(BaseModel):
    text: str = Field(min_length=1, max_length=200)
    priority: int = Field(ge=1, le=5)

@app.post("/api/messages", status_code=status.HTTP_201_CREATED)
async def message(
    payload: Message,
    x_joubako_demo: Annotated[str, Header()] = "unknown",
):
    return {
        "accepted": True,
        "text": payload.text,
        "priority": payload.priority,
        "framework": "FastAPI",
        "client": x_joubako_demo,
    }
```

See the complete [`app.py`](../../examples/frameworks/fastapi/app.py).

## Run FastAPI

```sh
cd examples/frameworks/fastapi
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python app.py
```

## Call FastAPI from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8001/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=FastAPI \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

FastAPI's validation response is mapped to `jeHttpStatus`; callers can inspect
the status and the bounded response snapshot without treating it as a failed
Nim Future.

## Production notes

Configure authentication dependencies, proxy headers, worker count, TLS
termination, and explicit body limits for the deployed ASGI service. Preserve
Joubako's response and timeout limits on the client side.
