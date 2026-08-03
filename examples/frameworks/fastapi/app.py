import os
from typing import Annotated

import uvicorn
from fastapi import FastAPI, Header, HTTPException, status
from pydantic import BaseModel, Field


app = FastAPI(title="Joubako FastAPI demo")


class Message(BaseModel):
    text: str = Field(min_length=1, max_length=200)
    priority: int = Field(ge=1, le=5)


@app.get("/api/health")
async def health():
    return {"ok": True, "framework": "FastAPI"}


@app.get("/api/users/{user_id}")
async def user(user_id: int):
    if user_id != 1:
        raise HTTPException(status_code=404, detail="user not found")

    return {
        "id": user_id,
        "name": "FastAPI User",
        "email": "fastapi@example.test",
    }


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


if __name__ == "__main__":
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=int(os.environ.get("PORT", "8001")),
    )
