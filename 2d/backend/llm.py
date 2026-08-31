"""Thin Anthropic wrapper. The API key stays here (server-side), read from the
environment or an `ant auth login` profile by the SDK's default client — it is
never sent to the Godot client.

Model tiering: one strong-model call builds the whole world at session start;
per-turn NPC dialogue runs on a fast model so replies stay snappy and cheap.

Ported from zij3d/backend/llm.py, including two fixes that were paid for the
hard way there — see generate_json.
"""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path

# Loaded here rather than in main.py so every entry point picks the key up —
# the worldgen CLI and the tests import this module without going through the
# FastAPI app.
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent / ".env")
except ImportError:
    pass

try:
    import anthropic
except ImportError:  # let the module import even before `pip install`
    anthropic = None

WORLD_MODEL = os.environ.get("ZIJ_WORLD_MODEL", "claude-sonnet-5")
DIALOGUE_MODEL = os.environ.get("ZIJ_DIALOGUE_MODEL", "claude-haiku-4-5")
CRITIC_MODEL = os.environ.get("ZIJ_CRITIC_MODEL", "claude-sonnet-5")
MAX_TOKENS = 300  # short, in-character lines

_client = None


def _get_client():
    global _client
    if _client is None:
        if anthropic is None:
            raise RuntimeError("anthropic SDK not installed (pip install -r requirements.txt)")
        # Reads ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN or an `ant auth login`
        # profile. No key is ever hard-coded.
        _client = anthropic.Anthropic()
    return _client


def available() -> bool:
    """True if a call could plausibly succeed. Lets the server fall back to the
    hand-authored world instead of throwing on boot with no key configured."""
    if anthropic is None:
        return False
    return bool(os.environ.get("ANTHROPIC_API_KEY")
                or os.environ.get("ANTHROPIC_AUTH_TOKEN"))


def generate_line(system_prompt: str, transcript: list[dict], utterance: str,
                  model: str | None = None) -> str:
    """One in-character line, given recent history."""
    messages: list[dict] = []
    for turn in transcript[-8:]:
        messages.append({"role": "user",
                         "content": turn.get("player") or "(the player approaches)"})
        messages.append({"role": "assistant", "content": turn.get("npc") or "..."})
    messages.append({"role": "user",
                     "content": utterance or "(the player walks up to you)"})

    resp = _get_client().messages.create(
        model=model or DIALOGUE_MODEL,
        max_tokens=MAX_TOKENS,
        system=system_prompt,
        messages=messages,
    )
    return "".join(b.text for b in resp.content if b.type == "text").strip()


def generate_json(model: str, system_prompt: str, user_prompt: str,
                  schema: dict, max_tokens: int = 8000,
                  image_png: bytes | None = None) -> dict:
    """One structured-outputs call; the API guarantees the reply parses against
    `schema`. Streams so large generations can't hit an HTTP timeout.

    Two non-obvious details, both fixes for bugs observed live in zij3d:
      - thinking is DISABLED. This is pure structured extraction, and adaptive
        thinking (on by default on Sonnet 5) eats into max_tokens and truncates
        the JSON mid-string.
      - a max_tokens stop_reason is raised, not returned. Truncated JSON
        otherwise surfaces as an opaque json.loads error much further away.
    """
    content: list[dict] = []
    if image_png is not None:
        content.append({
            "type": "image",
            "source": {"type": "base64", "media_type": "image/png",
                       "data": base64.standard_b64encode(image_png).decode()},
        })
    content.append({"type": "text", "text": user_prompt})

    with _get_client().messages.stream(
        model=model,
        max_tokens=max_tokens,
        thinking={"type": "disabled"},
        system=system_prompt,
        messages=[{"role": "user", "content": content}],
        output_config={"format": {"type": "json_schema", "schema": schema}},
    ) as stream:
        resp = stream.get_final_message()
    if resp.stop_reason == "max_tokens":
        raise RuntimeError(f"generate_json truncated at max_tokens={max_tokens}")
    text = "".join(b.text for b in resp.content if b.type == "text")
    return json.loads(text)
