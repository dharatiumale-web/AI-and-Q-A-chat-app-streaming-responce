import os
import json
from typing import List
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from starlette.status import HTTP_500_INTERNAL_SERVER_ERROR
from openai import OpenAI

app = FastAPI(title="AI Q&A Chat Streaming Backend (FastAPI)")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
if not OPENAI_API_KEY:
    raise RuntimeError("Please set OPENAI_API_KEY environment variable before running")

client = OpenAI(api_key=OPENAI_API_KEY)

class Message(BaseModel):
    role: str
    content: str

@app.exception_handler(Exception)
async def all_exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=HTTP_500_INTERNAL_SERVER_ERROR,
        content={"error": "Internal server error", "details": str(exc)},
    )

def sse_event(data: str, event: str | None = None) -> bytes:
    lines = []
    if event:
        lines.append(f"event: {event}")
    for dline in data.splitlines():
        lines.append(f"data: {dline}")
    lines.append("")
    return ("\n".join(lines) + "\n").encode("utf-8")

@app.post("/chat")
async def chat(messages: List[Message]):
    if not messages or not isinstance(messages, list):
        raise HTTPException(status_code=400, detail="messages must be a non-empty list")

    inputs = [{"role": m.role, "content": m.content} for m in messages]

    async def event_generator():
        try:
            stream = client.responses.create(
                model="gpt-4o-mini",
                input=inputs,
                stream=True,
            )
            for chunk in stream:
                try:
                    obj = dict(chunk)
                    text_fragment = None
                    delta = obj.get("delta")
                    if delta and isinstance(delta, dict):
                        text_fragment = delta.get("content") or delta.get("text")
                    if text_fragment is None and "output_text" in obj:
                        text_fragment = obj.get("output_text")
                    if text_fragment:
                        yield sse_event(json.dumps({"type": "delta", "text": text_fragment}))
                except Exception as e_chunk:
                    yield sse_event(json.dumps({"type": "error", "message": str(e_chunk)}))
                    continue
            yield sse_event(json.dumps({"type": "done"}), event="done")
        except Exception as e:
            yield sse_event(json.dumps({"type": "error", "message": str(e)}))

    return StreamingResponse(event_generator(), media_type="text/event-stream")
