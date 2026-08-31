"""The zij2d backend. A small FastAPI proxy that holds the Anthropic API key,
owns the canonical world + story state for a session, and serves both to the
Godot client over 127.0.0.1 only. The key never leaves this process.

Routes:
    GET  /health            liveness + what world is loaded
    POST /session/new       hand over a world, start cooking the next
    GET  /world             the current world JSON
    POST /npc/dialogue      one in-character line
    POST /world/critique    VLM layout review -> repair ops
    WS   /events            server -> client pushes (beats, finale)
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent / ".env")
except ImportError:
    pass

import critic  # noqa: E402
import llm  # noqa: E402
import worldgen  # noqa: E402

app = FastAPI(title="zij2d")

# Beats are signalled by an inline tag the server strips before the line ever
# reaches the client, so the model can mark a reveal without breaking character.
_BEAT_RE = re.compile(r"\[BEAT:([a-z_][a-z0-9_]*)\]")


def _strip_quotes(line: str) -> str:
    """Unwraps a reply the model put in quotation marks.

    The prompt tells the character to speak as if their words were in quotes,
    and models occasionally supply the quotes as well. Cheaper to unwrap here
    than to keep rewording the instruction, and harmless when there are none."""
    for pair in (('"', '"'), ("\u201c", "\u201d"), ("'", "'")):
        if len(line) > 1 and line.startswith(pair[0]) and line.endswith(pair[1]):
            return line[1:-1].strip()
    return line


class Session:
    def __init__(self) -> None:
        self.world: dict = {}
        self.source: str = ""
        self.revealed: set[str] = set()
        self.world_facts: list[str] = []
        self.transcripts: dict[str, list[dict]] = {}
        # Rival escalation state. Mechanics (spawns, the showdown) all run
        # client-side — see GameState._escalate() — because the client always
        # learns of a reveal before this session does (an interactable's beat
        # arrives here as an echo, and an NPC-revealed beat arrives here FIRST,
        # so there is no single moment the server could fire an event from
        # without missing half of them). What the server still owns is purely
        # dialogue flavor: which NPCs are scared, and the rumor lines woven
        # into every director prompt via world_facts.
        self.moods: dict[str, str] = {}
        self.acts_fired: int = 0

    def npc(self, npc_id: str) -> dict | None:
        return next((n for n in self.world.get("npcs", []) if n["id"] == npc_id), None)

    def beat(self, beat_id: str) -> dict | None:
        return next((b for b in self.world.get("beats", []) if b["id"] == beat_id), None)

    def reveal(self, beat_id: str) -> dict | None:
        b = self.beat(beat_id)
        if not b or beat_id in self.revealed:
            return None
        self.revealed.add(beat_id)
        self.world_facts.append(f"It is now known in the village: {b['desc']}")
        self._escalate()
        return b

    def finale_ready(self) -> bool:
        cond = self.world.get("ending", {}).get("condition_beats", [])
        return bool(cond) and all(c in self.revealed for c in cond)

    def _pick_scared_npc(self) -> str | None:
        """A stable pick (not Python's randomized-per-process hash()) so the
        same world always scares the same villagers in the same order,
        restart or no restart."""
        candidates = sorted(
            n["id"] for n in self.world.get("npcs", []) if n["id"] not in self.moods)
        if not candidates:
            return None
        key = f"{self.world.get('seed', '')}:{len(self.moods)}"
        idx = int(hashlib.sha256(key.encode()).hexdigest(), 16) % len(candidates)
        return candidates[idx]

    def _escalate(self) -> None:
        """Deterministic dialogue-flavor side of the escalation table in
        worldgen.escalation_act(): a rumor becomes common knowledge at acts
        1-3, and a couple of villagers grow visibly frightened at acts 2-3.
        A ratchet, like the client-side mechanics it mirrors — restarting
        from an old acts_fired never replays a rumor twice."""
        rival = self.world.get("rival")
        cond = self.world.get("ending", {}).get("condition_beats", [])
        if not rival or not cond:
            return
        n = sum(1 for c in cond if c in self.revealed)
        act = worldgen.escalation_act(n, len(cond))
        rumors = rival.get("rumors", [])
        while self.acts_fired < act:
            self.acts_fired += 1
            if self.acts_fired <= 3:
                i = self.acts_fired - 1
                if i < len(rumors):
                    self.world_facts.append(f"Worried talk in the village: {rumors[i]}")
                if self.acts_fired in (2, 3):
                    scared = self._pick_scared_npc()
                    if scared:
                        self.moods[scared] = "scared"
            else:  # act 4 — the showdown
                self.world_facts.append(
                    f"{rival.get('name', 'the rival')} has finally shown itself.")


SESSION = Session()
_clients: set[WebSocket] = set()

## Where the next session's pre-generated world waits. See "the warm world".
WARM = Path(__file__).resolve().parent / "cache" / "next_world.json"


async def _broadcast(evt: dict) -> None:
    dead = []
    for ws in _clients:
        try:
            await ws.send_text(json.dumps(evt))
        except Exception:  # noqa: BLE001
            dead.append(ws)
    for ws in dead:
        _clients.discard(ws)


def _load_initial() -> None:
    """Boot with the fallback so /world is never empty; the client asks for a
    fresh generation explicitly via /session/new."""
    SESSION.world = worldgen.load_fallback()
    SESSION.source = "fallback"


_load_initial()


# --- world ------------------------------------------------------------------

@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "llm": llm.available(),
        "title": SESSION.world.get("title", ""),
        "source": SESSION.source,
        # Whether the next launch will be instant.
        "warm": WARM.exists(),
    }


class NewSession(BaseModel):
    seed: str = ""


# --- the warm world ---------------------------------------------------------
# Generation is two sequential model calls and takes about a minute; there is
# no way to make that fast. So it is moved off the critical path instead: after
# serving a world, generate the NEXT one in the background and leave it on disk.
# The player then waits ~65s once, ever, and every later launch starts instantly.
#
# On disk rather than in memory so it survives the backend being restarted, and
# consumed on read so two sessions can never be handed the same village.
#
# Exactly one generation happens per world served — the same API spend as
# before, just moved earlier. Nothing is prewarmed at startup, which would
# race with the client's own /session/new and pay for two worlds to use one.

_warming: asyncio.Task | None = None


def take_warm_world() -> dict | None:
    """Consumes the cached world, or None. Corrupt cache is discarded, never
    raised: a bad cache file must not be able to stop the game starting."""
    if not WARM.exists():
        return None
    try:
        world = json.loads(WARM.read_text())
    except (OSError, ValueError) as exc:
        print(f"warm world unreadable ({exc}); discarding", file=sys.stderr)
        world = None
    WARM.unlink(missing_ok=True)
    if not world or not world.get("npcs"):
        return None
    if world.get("version") != worldgen.WORLD_VERSION:
        print(f"warm world is stale (version {world.get('version')!r}, "
              f"want {worldgen.WORLD_VERSION}); discarding", file=sys.stderr)
        return None
    return world


async def _generate_warm_world() -> None:
    try:
        await _warm_once()
    except Exception as exc:  # noqa: BLE001
        # A background task that dies silently leaves every future launch slow
        # with no clue why. Name it and carry on.
        print(f"warm world FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)


async def _warm_once() -> None:
    world, source = await asyncio.to_thread(worldgen.generate_validated, "")
    if source == "fallback":
        # Caching a failure would serve the same hand-authored village instantly
        # for the rest of time, which is worse than a slow real one.
        print("warm world: generation failed, nothing cached", file=sys.stderr)
        return
    WARM.parent.mkdir(parents=True, exist_ok=True)
    WARM.write_text(json.dumps(world))
    print(f"warm world ready: {world['title']!r} ({source})", file=sys.stderr)


def start_warming() -> None:
    global _warming
    if _warming is not None and not _warming.done():
        return
    if WARM.exists():
        return
    _warming = asyncio.create_task(_generate_warm_world())


def _adopt(world: dict, source: str) -> None:
    SESSION.world = world
    SESSION.source = source
    SESSION.revealed.clear()
    SESSION.world_facts.clear()
    SESSION.transcripts.clear()
    SESSION.moods.clear()
    SESSION.acts_fired = 0


@app.post("/session/new")
async def session_new(req: NewSession) -> dict:
    """Hands over a world, and starts cooking the next one.

    Runs generation off the event loop so /health and the WebSocket stay
    responsive while the client holds its loading screen."""
    world = None if req.seed else take_warm_world()
    if world is not None:
        source = "warm"
    else:
        # A named seed always generates: the player asked for that story.
        world, source = await asyncio.to_thread(
            worldgen.generate_validated, req.seed)

    _adopt(world, source)
    start_warming()
    await _broadcast({"type": "world_ready", "title": world["title"], "source": source})
    return {"world": world, "source": source}


class SetWorld(BaseModel):
    world: dict


@app.post("/world/set")
def set_world(req: SetWorld) -> dict:
    """Adopt a world the client already has. Needed because the client can be
    launched with `--world <file>`, and dialogue is answered from SESSION.world
    — if the two diverge every npc_id misses and the whole village replies
    "nobody answers"."""
    world = worldgen.coerce_numbers(req.world)
    if not world.get("npcs"):
        return {"ok": False, "error": "not a world document"}
    worldgen.add_item_fields(world)
    SESSION.world = world
    SESSION.source = "client"
    SESSION.revealed.clear()
    SESSION.world_facts.clear()
    SESSION.transcripts.clear()
    SESSION.moods.clear()
    SESSION.acts_fired = 0
    return {"ok": True, "title": world.get("title", "")}


@app.get("/world")
def get_world() -> dict:
    return {"world": SESSION.world, "source": SESSION.source,
            "revealed": sorted(SESSION.revealed)}


class RevealReq(BaseModel):
    beat_id: str


@app.post("/beat/reveal")
async def beat_reveal(req: RevealReq) -> dict:
    """The client reveals beats too — reading a notice, opening a chest — and
    the server has no way to observe that.

    Without this the two halves of the story desync in the direction that
    silently breaks the game: build_system_prompt() gates what an NPC may say on
    SESSION.revealed, so a beat whose prerequisite came from a chest stays
    locked forever and the villager only ever hints. In the shipped fallback
    world two of the four ending conditions are on interactables, which made
    finale_ready() unreachable by construction."""
    b = SESSION.reveal(req.beat_id)
    if b is not None:
        await _broadcast({"type": "story_beat", "beat": req.beat_id, "npc_id": ""})
    finale = SESSION.world.get("ending", {}).get("finale", "") \
        if SESSION.finale_ready() else ""
    return {"ok": b is not None, "revealed": sorted(SESSION.revealed),
            "finale": finale}


# --- dialogue ---------------------------------------------------------------

def build_system_prompt(npc: dict, just_opened: bool = False,
                        gift: str = "") -> str:
    """The director prompt.

    Nothing here is decided in advance. The character is given the whole pool of
    facts still undiscovered and told to offer one only if this conversation
    earns it, judged against their own vantage point and what the player asked.
    Two villagers approached in the opposite order will therefore tell you
    different things, and no fact is stuck behind a particular person.

    The predecessor did the opposite: each character was handed a fixed list of
    beats at generation time and a beat stayed locked until its prerequisites
    were met, so the player was walked down a queue — find the one who holds
    fact 1, then the one who holds fact 2. The pacing rules below are what
    replace that ordering, and they are all soft."""
    w = SESSION.world
    goal = w.get("goal", {})
    pool = [b for b in w.get("beats", []) if b["id"] not in SESSION.revealed]
    found = [SESSION.beat(b) for b in sorted(SESSION.revealed)]
    found = [b for b in found if b]

    lines = [
        f"You are {npc['name']}, {npc['role']} in the village. Stay in character.",
        f"PERSONA: {npc['persona']}",
        f"THE SITUATION: {w['premise']}",
    ]
    if npc.get("could_know"):
        lines.append(f"WHERE YOU STAND IN IT: {npc['could_know']}")
    if goal.get("summary"):
        lines.append(f"WHAT THE CHILD IS TRYING TO DO: {goal['summary']}")

    lines += [
        "",
        "RULES:",
        "- Speak as this character to a child playing an adventure game. Warm,",
        "  simple language. Two or three sentences at most.",
        "- SPOKEN WORDS ONLY — the words out of your mouth, nothing else, as if",
        "  they were inside quotation marks. No stage directions, no asterisks,",
        "  no brackets, and no PROSE NARRATION either: not '*smiles* Hello',",
        "  and not 'I straighten up from my sweeping as the child approaches'.",
        "  Do not describe yourself, the child, or the scene. Just talk, and do",
        "  not wrap your line in quotation marks.",
        "- Never mention beats, the game, or that you are an AI.",
    ]
    if npc.get("secret"):
        lines.append(f"- You privately know, and do not volunteer: {npc['secret']}")
    rival = w.get("rival")
    if rival:
        motive = rival.get("motive", "").strip().rstrip(".")
        lines.append(
            f"- THE MENACE: {rival.get('name', 'something')}, {rival.get('nature', '')}. "
            f"{motive}. The village has felt it watching. You may allude "
            f"to it in passing, but the facts list below is still the only source of "
            f"real discoveries.")
        if SESSION.moods.get(npc["id"]) == "scared":
            lines.append(
                f"- You are frightened — you saw a sign of {rival.get('name', 'it')} "
                f"last night. Let it show in how you talk, but helping the child feels "
                f"safer than staying quiet about it.")
    if just_opened and npc.get("opener"):
        lines += [
            f"- You have ALREADY said, just now: \"{npc['opener']}\"",
            "  Carry straight on from that. Do not greet them again, do not say",
            "  hello, and do not repeat yourself.",
        ]

    if gift:
        item = next((i for i in w.get("items", []) if i["id"] == gift), {})
        lines += [
            "",
            f"THE CHILD HAS JUST HANDED YOU {item.get('name', gift)} — the very "
            "thing you were waiting for.",
            "This has earned them something real. Say what you have been holding",
            "back, warmly, and tag the fact you reveal.",
        ]

    if found:
        lines.append("")
        lines.append("The child already worked these out; treat them as common talk:")
        lines += [f"  - {b['desc']}" for b in found]

    if pool:
        lines += [
            "",
            "STILL UNKNOWN. You may hand the child ONE of these — at most one, and",
            "only if this particular conversation has earned it. Append its tag",
            "verbatim at the very end of your reply when you do:",
        ]
        lines += [f"  - {b['desc']}  [BEAT:{b['id']}]" for b in pool]
        lines += [
            "",
            "HOW TO DECIDE:",
            "- DEFAULT TO GIVING THEM ONE. Walking over and starting a",
            "  conversation is the effort; it should usually be rewarded. A",
            "  villager who greets a child and volunteers something they noticed",
            "  is normal behaviour, not a plot device.",
            "- Pick whichever unknown your character would raise first, given",
            "  where they stand. There is no correct order and nothing is",
            "  reserved for anybody else.",
            "- If they asked about something directly, answer THAT.",
            "- Withhold only when you genuinely have no vantage on any of the",
            "  unknowns. Then say so in character and point them somewhere",
            "  plausible — never invent a fact that is not on the list.",
            "- One fact per reply, never two, and never recite the list.",
        ]
        pace = "This is their first real lead — be forthcoming." \
            if not found else \
            f"They have {len(found)} already; keep it conversational."
        lines.append(f"- {pace}")
    else:
        lines += [
            "",
            "The child has worked out everything there is to know. Be pleased for",
            "them and say so; there is nothing left to reveal.",
        ]

    if SESSION.world_facts:
        lines.append("")
        lines.append("Already common knowledge in the village:")
        lines += [f"  - {f}" for f in SESSION.world_facts]
    return "\n".join(lines)


class DialogueReq(BaseModel):
    npc_id: str
    player_utterance: str = ""
    ## Item id the player just handed over, if any.
    gift: str = ""


@app.post("/npc/dialogue")
async def npc_dialogue(req: DialogueReq) -> dict:
    npc = SESSION.npc(req.npc_id)
    if npc is None:
        return {"npc_id": req.npc_id, "line": "(nobody answers)", "meta": {}}
    if not llm.available():
        return {"npc_id": req.npc_id, "line": npc.get("opener", "..."),
                "meta": {"display_name": npc["name"], "offline": True}}

    transcript = SESSION.transcripts.setdefault(req.npc_id, [])
    # An empty utterance means the player just walked up and pressed E, so the
    # opener is on screen right now.
    system = build_system_prompt(npc, just_opened=not req.player_utterance,
                                 gift=req.gift)
    try:
        raw = await asyncio.to_thread(
            llm.generate_line, system, transcript, req.player_utterance)
    except Exception as exc:  # noqa: BLE001
        print(f"dialogue failed: {exc}", file=sys.stderr)
        return {"npc_id": req.npc_id, "line": "(they seem lost in thought)", "meta": {}}

    meta: dict = {"display_name": npc["name"]}
    for bid in _BEAT_RE.findall(raw):
        # No unlock check: there is no prerequisite order left to enforce. Any
        # fact the director chose to hand over in character is a real discovery.
        if SESSION.reveal(bid):
            meta["beat"] = bid
            await _broadcast({"type": "story_beat", "beat": bid, "npc_id": req.npc_id})
    line = _strip_quotes(_BEAT_RE.sub("", raw).strip())

    transcript.append({"player": req.player_utterance, "npc": line})
    if SESSION.finale_ready():
        meta["finale"] = SESSION.world["ending"]["finale"]
        await _broadcast({"type": "finale", "text": meta["finale"]})
    return {"npc_id": req.npc_id, "line": line, "meta": meta}


# --- VLM layout critique ----------------------------------------------------

class CritiqueReq(BaseModel):
    png_base64: str
    # The client sends the world it actually rendered. Critiquing SESSION.world
    # instead would review a different map than the screenshot whenever the two
    # have diverged — which they do on the `--world <file>` debug path.
    world: dict = {}


@app.post("/world/critique")
async def world_critique(req: CritiqueReq) -> dict:
    """Godot renders the built world and posts it here. The model looks at the
    image and returns a small list of repair ops, which are applied and then
    re-validated — a patch that fails validation is rejected wholesale, so this
    can only ever make the world more valid."""
    try:
        png = base64.b64decode(req.png_base64)
    except Exception:  # noqa: BLE001
        return {"applied": False, "reason": "bad image", "ops": []}

    subject = worldgen.coerce_numbers(req.world) if req.world else SESSION.world
    if not subject:
        return {"applied": False, "reason": "no world to review", "ops": []}

    world, ops, reason = await asyncio.to_thread(critic.review_and_patch, subject, png)
    if world is not None:
        SESSION.world = world
        return {"applied": True, "ops": ops, "world": world}
    return {"applied": False, "reason": reason, "ops": ops}


# --- events -----------------------------------------------------------------

@app.websocket("/events")
async def events(ws: WebSocket) -> None:
    await ws.accept()
    _clients.add(ws)
    try:
        while True:
            await ws.receive_text()  # client pings location; nothing to do with it yet
    except WebSocketDisconnect:
        pass
    finally:
        _clients.discard(ws)
