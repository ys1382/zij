#!/usr/bin/env python3
"""Client for the in-game agent bridge (test/agent_bridge.gd).

Launch the game with the bridge enabled, then drive it from here:

    godot --path . -- --agent-bridge --world backend/fallback_world.json
    python3 test/playtest_client.py --auto

`--auto` walks a scripted playthrough: visit every interactable, greet every
NPC, screenshot, and report which story beats got revealed. That last number is
the one that matters — a village can pass every validator and still be a story
nobody can actually solve.
"""
from __future__ import annotations

import argparse
import functools
import json
import socket
import sys
import time

HOST, PORT = "127.0.0.1", 8765

# Progress must survive a pipe: a stalled run that printed nothing looked
# identical to one that never started.
print = functools.partial(print, flush=True)  # noqa: A001


class BridgeStalled(RuntimeError):
    pass


class Bridge:
    # Longer than the bridge's own BUSY_TIMEOUT, so its watchdog gets the first
    # chance to answer and we only trip if the whole process is wedged.
    def __init__(self, timeout: float = 50.0) -> None:
        self.sock = socket.create_connection((HOST, PORT), timeout=10.0)
        self.sock.settimeout(timeout)
        self.timeout = timeout
        self.buf = b""

    def send(self, **cmd) -> dict:
        name = cmd.get("cmd", "?")
        self.sock.sendall((json.dumps(cmd) + "\n").encode())
        try:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError(
                        f"bridge closed the connection during {name!r}")
                self.buf += chunk
        except socket.timeout:
            # Silence here used to mean a multi-minute wait with nothing to go
            # on; say which command stalled and give up on it.
            raise BridgeStalled(
                f"no reply to {name!r} after {self.timeout:.0f}s — the game may "
                f"have crashed or the bridge is wedged") from None
        except OSError as exc:
            # e.g. the bridge dropped us because another client held the socket
            # (it serves one at a time). Name the command rather than surfacing
            # a bare traceback from inside recv().
            raise BridgeStalled(
                f"connection lost during {name!r}: {exc}") from None
        line, _, self.buf = self.buf.partition(b"\n")
        return json.loads(line.decode())

    def close(self) -> None:
        self.sock.close()


def _unpause(b: Bridge) -> str:
    """Clear the ending card before every step, and any minions the rival
    spawned along the way. Returns the current phase.

    Solving the mystery pops a card that pauses the tree, and it can happen at
    any point in a run — the beat that completes it might come from the third
    villager of five. A paused player's physics never ticks, so every remaining
    approach reported the target as unreachable, and the run blamed whichever
    NPC happened to be next. Dismissing once at the start was not enough.

    A rival's showdown card is deliberately left alone here: dismissing it is
    what spawns the boss (see journal.gd), so touring the rest of the village
    would drag it into a live fight mid-tour. Callers stop touring instead as
    soon as this stops returning "explore", and the dedicated showdown leg in
    auto() dismisses that card on its own terms.

    `peace` runs every other time: this measures whether the STORY can be
    uncovered, and the rival spawns minions as facts land (see
    GameState._escalate() in ui/game_state.gd) — leaving them in would make a
    story metric depend on combat luck mid-run, exactly the reasoning behind
    the initial `peace` call in auto() below. It is skipped once a showdown is
    pending/underway so it can never accidentally free the boss early.
    """
    phase = b.send(cmd="state").get("phase", "explore")
    if phase not in ("showdown_pending", "showdown"):
        b.send(cmd="dismiss")
        b.send(cmd="peace")
    return phase


def auto(b: Bridge, shots: bool) -> int:
    # This run measures whether the STORY can be uncovered. Slimes chase and
    # bite, and a death mid-goto teleports the player back to spawn, so leaving
    # them in would make a story metric depend on combat luck.
    cleared = b.send(cmd="peace").get("removed", 0)
    if cleared:
        print(f"cleared {cleared} enem{'y' if cleared == 1 else 'ies'} for a clean read")

    # The ending card pauses the tree, and a run that solves the mystery leaves
    # it up. Every later run then walks a player whose physics never ticks and
    # reports everything unreachable. Start from a known-unpaused state.
    b.send(cmd="dismiss")

    state = b.send(cmd="state")
    print(f"world: {state['title']!r}  "
          f"{len(state['npcs'])} npcs, {len(state['interactables'])} interactables, "
          f"{state['total_beats']} beats")
    print(f"player starts at {state['player_tile']}\n")

    unreachable: list[str] = []

    print("-- interactables --")
    for it in state["interactables"]:
        if _unpause(b) != "explore":
            print("  (story concluded — skipping remaining checks)")
            break
        tx, ty = it["tile"]
        # Approach from below: x,y is the top-left tile, so the tile under the
        # object's bottom edge is the natural place to stand.
        r = b.send(cmd="goto", x=tx, y=ty + 1)
        if not r.get("ok"):
            print(f"  {it['id']:<22} UNREACHABLE ({r.get('error')})")
            unreachable.append(it["id"])
            continue
        used = b.send(cmd="use")
        if used.get("ok"):
            line = (used.get("line") or "").strip().replace("\n", " ")
            print(f"  {it['id']:<22} {used['used'].get('verb','?'):<5} "
                  f"beat={it['beat'] or '-'}")
            if line:
                print(f"      {line[:96]}")
        else:
            print(f"  {it['id']:<22} nothing in reach after walking there")
            unreachable.append(it["id"])
        b.send(cmd="close")

    print("\n-- npcs --")
    for npc in state["npcs"]:
        if _unpause(b) != "explore":
            print("  (story concluded — skipping remaining greetings)")
            break
        r = b.send(cmd="talk", id=npc["id"])
        if not r.get("ok"):
            print(f"  {npc['name']:<18} UNREACHABLE ({r.get('error')})")
            unreachable.append(npc["id"])
            continue
        line = (r.get("line") or "").strip().replace("\n", " ")
        print(f"  {r.get('speaker', npc['name']):<18} {line[:88]}")
        follow = b.send(cmd="say", text="What happened here? Do you know anything?")
        if follow.get("ok") and follow.get("line"):
            print(f"      -> {follow['line'].strip()[:88]}")
        b.send(cmd="close")

    # A world with a rival ends in a showdown, not an instant card — see
    # GameState._check_finale(). Fight it out here rather than leaving a
    # solved run parked on the taunt card forever.
    mid_state = b.send(cmd="state")
    if mid_state.get("solved") and mid_state.get("phase") == "showdown_pending":
        print("\n-- showdown --")
        b.send(cmd="dismiss")  # unpauses, then spawns the boss (journal.gd)
        b.send(cmd="wait", secs=0.5)
        slain = b.send(cmd="slay")
        print(f"  swings: {slain.get('swings')}  phase: {slain.get('phase')}")
        b.send(cmd="dismiss")  # acknowledge the "Solved!" card

    if shots:
        shot = b.send(cmd="screenshot", name="playtest.png")
        print(f"\nscreenshot: {shot.get('path')}")

    final = b.send(cmd="state")
    revealed = final["revealed_beats"]
    total = final["total_beats"]
    print(f"\nbeats revealed: {len(revealed)}/{total}  {revealed}")
    if final.get("solved"):
        print("SOLVED — every ending condition met")
    if final.get("inventory"):
        print(f"carrying: {final['inventory']}")
    if unreachable:
        print(f"UNREACHABLE: {unreachable}")
    # Leave the game unpaused for whatever runs next, ending card or not.
    b.send(cmd="dismiss")
    # A world you can walk but whose story you cannot uncover is a failure the
    # validator cannot see. A solved run additionally has to actually reach
    # "won" — a rival world that gets stuck on the showdown is exactly the
    # kind of regression the validator can't see either.
    ok = not unreachable and len(revealed) > 0
    if final.get("solved"):
        ok = ok and final.get("phase") == "won"
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


MAX_REACH_TILES = (4, 3)


def regress(b: Bridge) -> int:
    """Pins the interactable reach-box geometry.

    A door attached to an 8x8 house used to inherit a 9x9-tile trigger: it could
    be opened from the roof, and it was big enough to swallow a villager
    standing in front of it, so pressing E opened the building instead of
    greeting the person. Reach boxes are now capped and anchored to the prop's
    base.

    Asserting on the player's *focus* would be flaky — villagers wander into
    range — so this checks the geometry directly.
    """
    state = b.send(cmd="state")
    failures = 0
    print(f"cap is {MAX_REACH_TILES[0]}x{MAX_REACH_TILES[1]} tiles\n")

    for it in state["interactables"]:
        r = b.send(cmd="reach", id=it["id"])
        if not r.get("ok"):
            print(f"  FAIL  {it['id']:<20} {r.get('error')}")
            failures += 1
            continue
        tw, th = r["size_tiles"]
        fw, fh = it["tiles"]
        problems = []
        if tw > MAX_REACH_TILES[0] + 1e-6 or th > MAX_REACH_TILES[1] + 1e-6:
            problems.append(f"exceeds cap ({tw:g}x{th:g})")
        # The box must sit at the prop's foot, not float up its body.
        if r["bottom_below_base"] < 0.0:
            problems.append("does not reach the ground at the base")
        if r["top_above_base"] > MAX_REACH_TILES[1] * 16:
            problems.append("rises too far up the body")
        ok = not problems
        failures += 0 if ok else 1
        print(f"  {'PASS' if ok else 'FAIL'}  {it['id']:<20} "
              f"footprint {fw}x{fh} -> reach {tw:g}x{th:g} tiles"
              + ("  [" + "; ".join(problems) + "]" if problems else ""))

    print(f"\n{'PASS' if failures == 0 else 'FAIL'} — {failures} failure(s)")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--auto", action="store_true", help="scripted playthrough")
    ap.add_argument("--regress", action="store_true",
                    help="interactable reach-box regression checks")
    ap.add_argument("--no-shots", action="store_true")
    ap.add_argument("--cmd", help="send one raw JSON command and print the reply")
    args = ap.parse_args()

    for attempt in range(10):
        try:
            b = Bridge()
            break
        except OSError:
            if attempt == 9:
                print("could not reach the bridge on 127.0.0.1:8765 — is the game "
                      "running with `-- --agent-bridge`?", file=sys.stderr)
                return 2
            time.sleep(1.0)

    try:
        if args.cmd:
            print(json.dumps(b.send(**json.loads(args.cmd)), indent=2))
            return 0
        if args.regress:
            return regress(b)
        if args.auto:
            return auto(b, not args.no_shots)
        print(json.dumps(b.send(cmd="state"), indent=2))
        return 0
    except BridgeStalled as exc:
        print(f"STALLED: {exc}", file=sys.stderr)
        return 3
    finally:
        b.close()


if __name__ == "__main__":
    raise SystemExit(main())
