# zij2d

A top-down 2D adventure for kids where an LLM invents **both the story and the
village it happens in** — terrain, buildings, props, NPCs and enemies — as one
schema-validated JSON document. Godot turns that document into a playable scene.

Sibling of `../zij3d`, which does the same for story only; there the levels were
procedural GDScript. Here the model designs the map too.

## Quick start

Open `project.godot` in Godot 4.6 and press **Play** (F5). That is the whole
procedure. The client starts the backend itself if nothing is listening on
:8000, asks it for a freshly invented village, builds it, runs the layout
review, and drops you into it.

The very first launch spends about a minute generating; after that the backend
keeps a world pre-generated and start-up is about two seconds. The loading
screen says which of the two is happening, with a running second count.

Move with WASD/arrows, interact with **E** (or Space), swing with **J**, open
your journal with **Tab**. Five hearts; slimes bite, three hits kill one, and
running out puts you back at the start with the story you've uncovered intact.
Press **E** on a house to go inside it.

It needs an Anthropic key in `backend/.env` (see `.env.example`). Without one,
or with the backend unreachable, it falls back to the hand-authored village and
canned dialogue rather than failing — so Play always produces something
playable.

Every flag overrides one step of that path:

```bash
godot --path . -- --seed "a well gone silent"          # steer the story
godot --path . -- --world backend/fallback_world.json  # skip generation
godot --path . -- --offline                            # never touch the backend
godot --path . -- --no-critique                        # skip the VLM review
```

First checkout only — the tilesets and prop scenes are generated, not committed:

```bash
python3 tools/tsx_convert.py --verify
```

## How it fits together

```
Godot 4.6 client                      FastAPI @ 127.0.0.1:8000
────────────────                      ────────────────────────
(autostart backend/run.sh if :8000 is dead)
POST /session/new ─────────────────►  claude-sonnet-5 + WORLD_SCHEMA
                  ◄─────────────────  validate_world() → retry → fallback
world_builder.build(world)
capture whole map to PNG
POST /world/critique ──────────────►  vision call → repair ops (≤12)
                     ◄──────────────  re-validated; rejected wholesale if worse
POST /npc/dialogue ────────────────►  claude-haiku-4-5, [BEAT:x] tags
```

The key lives only in the backend process. The model returns **data, never
code**, so there is nothing to sandbox.

### Nothing decides in advance who tells you what

There is no dependency graph and no character owns a fact. The story call
produces a **goal** and a **pool** of independent facts; which villager offers
which one is decided in the conversation itself, from that character's vantage
point (`could_know`) and what the player actually asked.

The predecessor did the opposite and it played badly. Each character was handed
a fixed `knows_beats` list at generation time, and each beat carried `requires`,
so a fact stayed locked until its prerequisites were met *no matter who you
asked*. Free exploration collapsed into a queue: find the one holding fact 1,
then the one holding fact 2. Both mechanisms are gone, along with the
topological-order and "every beat has an owner" validators that existed only to
guarantee that queue.

What replaced them is soft pacing in the director prompt: default to giving the
player something, one fact per reply, answer what they asked, and withhold only
when this character genuinely has no vantage on any of the unknowns. A gift is
context for a conversation rather than a scripted trigger — the character is
told what they were just handed and decides what it earns.

Measured on the fallback village: talking to Sefa **first** now opens the story,
though under the old model she held one late fact gated behind two others. A
single `--auto` pass went from 4–5 of 6 facts to **6 of 6, solved**, because
nothing is waiting its turn.

The one thing still fixed up front is the goal, and it leads the journal — with
no ordering to advertise, the player needs to know what they are working toward
and is then left to find it however they like.

### Buildings are enterable

Press **E** on any house and you are inside it. Interiors are procedural, not
model-authored: it costs nothing, takes no time, and the point of going in is to
be somewhere else, not to read more prose. Layout is seeded off the building id,
so a house looks the same each time you return.

The art packs ship no interior tileset. The floor is the Road terrain painted a
ring wider than the room so its grass-meets-path edge tiles fall *under* the
walls; the walls are drawn slabs that double as their own colliders, so what
stops the player is exactly what they can see. `Tileset_RockSlope` was tried for
walls first and renders nothing for a solid fill — it only contains cliff edges.

The outdoor world is hidden and frozen rather than rebuilt, so the village is as
you left it when you step out. `{"cmd":"enter","id":"..."}` and `{"cmd":"leave"}`
drive it over the bridge, and the A* grid is invalidated on each transition —
the cache key is the world title, which does not change when you walk through a
door.

Wells and gates are catalogued as buildings too; only `building.house*` is
enterable, because walking into a well would be a surprise of the wrong kind.

### The story is in two places at once, and they must agree

The server builds every director prompt from its own set of revealed facts — it
is what tells a character which unknowns are still on the table and what the
player already worked out. The client reveals facts too, by reading a notice or
opening a chest, and for a while it kept those to itself.

The result was a game that quietly could not be finished. Two of the four ending
conditions in the fallback village are on interactables, so `finale_ready()` was
unreachable by construction; and villagers went on offering facts the player had
already found. `POST /beat/reveal` closes that, and
`GameState.solved()` is exposed over the agent bridge so a playtest can assert
the mystery is actually completable — the one thing `validate_world()` cannot
see.

### The player has to be told what they know

The first playtest found the game unreadable: pressing E printed a line of
flavour text and nothing else, so nothing registered as progress and there was
no way to guess what to try next. The world JSON already carried a premise, a
description per beat and a one-line hint per beat, and none of it was ever
shown.

`ui/journal.gd` shows it: the premise and the goal as an opening card, a toast
per fact as it lands, and a journal on **Tab** with the goal, how many pieces of
it you have, what you are carrying and what you know. The goal leads, because it
is the only thing decided in advance — an earlier version opened with a list of
"leads" derived from which beats had their prerequisites met, which was a reading
order dressed up as a hint. `{"cmd":"journal"}` returns its text over the bridge,
because an empty goal line is exactly the kind of regression that otherwise ships
silently.

### Items are validated for solvability, not just for existence

`items` lives in the **story** call and the placement fields
(`gives_item` / `needs_item` / `locked_text`, plus `wants_item` on a cast
member) live in the village call. Partly because what exists is a story
decision and where it sits is a village one — mostly for grammar budget, since
the combined schema overflowed Anthropic's compiler once already and the
village call is the fuller of the two.

`validate_items()` walks the dependency the way a player would: collect
everything reachable empty-handed, then everything that opens up, repeat.
Anything left over was never obtainable. This matters because the failure it
catches is invisible to every other check — a model asked for a lock and a key
will cheerfully put the key inside the chest it opens, and that world is
geometrically perfect and simply cannot be finished. One generation in the
first batch was rejected for exactly this (`items required but found nowhere`).
`repair_items()` fixes what it can first, and always in the safe direction:
a dangling lock is removed rather than a generation thrown away, because
unlocking can only ever make a world more finishable.

Nothing is consumed. Handing the smith their tongs shouldn't make the tongs
vanish from a child's bag with no explanation, and there is no second use for
anything.

**How many items there are is enforced in code, not in the prompt.** Left alone
the model gives every villager their own errand — five identical fetch-quests in
different hats. Saying so in the system prompt worked, but on fixed seeds that
build also came out 0/2 first-pass where the original wording had been 2/2.
`trim_items()` does it deterministically instead, keeping whichever items carry
weight (one a villager waits for outranks one that opens a box, which outranks
scenery), and the prompt is left alone. After that: 2/2, no rejections, and both
worlds came out with two items, one errand and one real lock.

Tempting conclusion — "prompt budget is scarce, keep the system prompt short" —
and it is **wrong**. Cutting the ITEMS bullet down to two lines was tried next
and came out *worse than either* (0/2, repairs 73–83, including an
`items required but found nowhere` that the fuller wording prevents). Length is
not the variable; that bullet is carrying its weight. The honest reading is only
that the *restraint* wording specifically didn't pay for itself, and that
`trim_items()` gets the same result for free.

Treat single A/B runs here with suspicion. The same configuration on the same
seeds has produced repairs of 15/24 and 33/27 on different days — see
"Generation is noisy" below.

### Two ideas carry most of the design

**The model never emits tile ids.** It describes terrain as a base fill,
rectangles painted in order, and road polylines. Godot autotiles the result
through the wangsets recovered from the Tiled files. A 40×30 map is 1200 cells;
asking for those directly would be slow, expensive and almost always wrong.

**The asset vocabulary is closed and generated.** `tools/tsx_convert.py` emits
`generated/assets_catalog.json`; Godot resolves `id → scene` from it and the
backend builds the prompt's catalogue from the same file, so the two cannot
drift. Note this is enforced by *validation*, not by the grammar: putting all 63
ids in a schema `enum` overflows Anthropic's grammar compiler, so a hallucinated
asset id fails `validate_world()` and triggers a retry rather than being
impossible to emit. For the same reason generation is **two calls** — story
first, then a village laid out for that story.

### Starting is instant after the first time

Generation is two sequential model calls and takes about 65s; there is no
version of that which is fast. So it is off the critical path instead: after
serving a world, the backend generates the **next** one in the background and
leaves it in `backend/cache/`. The first launch ever waits; every launch after
it starts in about two seconds.

```
cold boot   65s  generated 'The Puppet Theatre's Slow Clock'
warm boot    2s  generated 'The Whispering Mosaic' (source: warm)
```

The cache is consumed on read, so two sessions can never be handed the same
village, and a failed generation is never cached — serving the hand-authored
fallback instantly forever would be worse than a slow real one. Exactly one
generation happens per world served, so this is the same API spend as before,
just earlier. Nothing is warmed at startup: that would race the client's own
`/session/new` and pay for two worlds to use one.

One non-obvious requirement fell out of this. The backend outlives the client
that autostarted it — that is the whole point, it has a world to finish — so
`run.sh` sends its output to `backend/backend.log` when it is not attached to a
terminal. With the inherited pipe, the first repair note printed after the
client exited killed the background generation on a broken pipe, silently, and
the cache never appeared.

### Why a boot used to take two minutes and hand you the same village

Because generation was failing. `generate_validated()` tries once, retries once
on the same seed, then serves the hand-authored fallback — so a village that
failed validation twice cost **~65s per attempt** and then dropped the player
into *The Quiet Bell*, silently, every single session. It looked like a slow
loader with no variety; it was actually a generator that never succeeded.

Four distinct bugs were doing it, all in the attachment path:

| | |
|---|---|
| Attachments kept their host's *old* coordinates after repair nudged it | now re-synced after placement |
| Placement could drop the interactable holding an item, stranding a villager's `wants_item` | `repair_items()` runs again after placement |
| `on` naming an object that was never placed → detached into a free-floating copy of a house on top of its neighbours | re-homed onto whatever it overlaps |
| A door emitted as a second copy of the building, with an id no verb-suffix rule matched | building-sized interactables that overlap an object attach to it |

And one self-inflicted: the pass that clears a blocking prop out of a doorway
accepted any move that found a free cell, without checking whether it helped.
Two hosts sharing a blocker shuffled it between the same two tiles — 22 moves in
one village, ending with 112 of 1408 cells reachable. It now reverts a move that
does not open the way and never touches the same object twice.

Measured after: three consecutive boots, **~70s each, all first-pass, three
different stories.** The loading screen also now says plainly when it *is*
serving the fallback, because "you have failed twice, here is the standard
village" must never again be indistinguishable from normal operation.

None of this was visible in batch metrics. It came out of a timestamped boot log:

```bash
( godot --path . 2>&1 | while IFS= read -r l; do printf '[%3ss] %s\n' "$SECONDS" "$l"; done ) | tee boot.log
```

### Generation is noisy — measure before concluding

The same configuration on the same seeds has produced repairs of 15/24 and
33/27. Any A/B here at n=2 is worthless, and two conclusions in this README's
history were drawn from exactly that and had to be withdrawn. Run six worlds and
read the *rejection reasons*, not the repair count:

```bash
backend/.venv/bin/python -u tools/batch_gen.py --count 6 --out test_output/batch
```

That is how the biggest real problem was found. Across 6 worlds / 12 attempts,
**7 of 11 rejections were `interactable ... cannot be reached`**, and every one
was an *attached* interactable. Chasing that down took four passes on the same
six seeds; three of them were only partial fixes, and the fourth was the actual
bug:

`resolve_attachments()` copies the host's coordinates onto the attachment once,
at generation time. `repair_village()` then nudges dozens of objects into legal
positions — and **nothing re-synced the attachments**. A door stayed at the tile
its house used to occupy, which by then was solid ground, so validation rejected
it as unreachable. The tell was in the numbers all along: worlds that succeeded
had ~35 repairs and worlds that failed had 73–91. More nudging, more stranded
doors.

Same six seeds, cumulative:

| | first-pass | any success | rejections |
|---|---|---|---|
| before | 0/6 | ~1/6 | 11 |
| move a sealed-in host out of its pocket | 1/6 | 3/6 | 8 |
| clear one blocking prop instead of moving a whole building | 2/6 | 3/6 | 7 |
| fix the `KeyError` that added | 3/6 | 3/6 | 6 |
| **re-sync attachments after nudging** | **4/6** | **6/6** | **2** |

Item mechanics were only 2 of the original 11 rejections. What looked like an
items problem was a long-standing blind spot in the repair pass that more
interactables per world simply made visible.

**Bad generations are repaired, not discarded.** `repair_story()` and
`repair_village()` fix the things that are deterministically fixable — an orphan
beat nobody knows, a tree whose footprint clips the pond by one tile, an actor
standing outside the walkable region — before validation runs. Only what's left
triggers the retry, then the fallback.

`resolve_attachments()` runs first and is the same idea applied earlier. The
schema says an interactable's `asset` may be `""` *when `on` names a host
object*, and the model reliably does half of that: one generation emitted six
interactables — `bulletin_read`, `haystack_look`, `crate_open` — with a blank
asset and a blank `on`, each named `<object_id>_<verb>` after an object it had
placed. All six were dropped as "unknown asset ''", costing that village most of
its interactivity. `_infer_host()` recovers them on an exact id match only, so
it can't invent an attachment that wasn't meant.

## Layout

| Path | What |
|---|---|
| `tools/tsx_convert.py` | Tiled `.tsx` → Godot `TileSet` + per-prop scenes + the catalog |
| `tools/verify_assets.gd` | Headless check that everything generated loads *and* colliders land inside their sprites |
| `tools/make_fallback.py` | Builds and validates `backend/fallback_world.json` |
| `generated/` | Machine-written. Never hand-edit; change the converter and re-run |
| `backend/worldgen.py` | `WORLD_SCHEMA`, seeding, `validate_world()` |
| `backend/critic.py` | The VLM repair pass |
| `world/world_builder.gd` | World JSON → live scene |
| `actors/interactable.gd` | One generic interaction component for every prop |

## Playtesting it as a game

`test/agent_bridge.gd` is an autoload that stays dormant unless the game is
launched with `-- --agent-bridge`. It then opens a TCP JSON-lines server on
127.0.0.1:8765 so a script (or an agent) can *play the real game* — walk the
player with A* over the actual colliders, greet NPCs, use interactables,
screenshot, read revealed beats.

```bash
godot --path . -- --agent-bridge --no-critique --world backend/fallback_world.json
```

```bash
python3 test/playtest_client.py --auto
```

The scripted run visits every interactable, greets every NPC, and reports which
beats it managed to reveal. That last number is what the validator cannot see: a
village can be perfectly well-formed and still be a story nobody can uncover.

It reveals 5 of 6 beats in the fallback village, because it asks each NPC one
generic follow-up; the last beat needs a pointed question. Driving those by hand
over the bridge reaches 6/6 and `"solved": true`.

`--auto` clears the map of enemies before it starts (`{"cmd":"peace"}`). It
measures whether the *story* can be uncovered; leaving slimes in made that
depend on combat luck, and a death mid-`goto` teleports the player to spawn and
fails the run for an unrelated reason.

**The intermittent `UNREACHABLE: ['sefa']` was never about that NPC.** Solving
the mystery pops an ending card, and the card pauses the tree. A paused player's
`_physics_process` never runs, so they do not move and every subsequent approach
reports its target unreachable — the run blames whichever villager happened to
be next. It only showed up once `--auto` started reaching 6/6, and it looked
like flakiness because `_finale_shown` latches: the *first* run to finish the
story broke, and every run after it on the same instance passed.

Three things came out of that:

- `_walk_to()` returns `game_paused` rather than `blocked`, because diagnosing
  a pause from "blocked" is exactly the silent-failure class the watchdog
  exists to prevent.
- `--auto` calls `{"cmd":"dismiss"}` before every step, not just at the start.
  The beat that completes the story can land on the third villager of five.
- Approach was made more robust anyway: candidates are now pre-filtered by an
  actual A* path (an unreachable one used to cost a full `GOTO_TIMEOUT`), the
  NPC's own tile leads the list since the player collides only with the
  environment, ring 2 is included for villagers in nooks, `_walk_to` aborts
  after three consecutive stuck waypoints instead of spending 1.2s on each
  remaining one, and the whole approach shares one `APPROACH_BUDGET`.

Measured after: **5/5 runs pass on a fresh instance each time**, including two
that solved the mystery mid-run — the exact case that used to fail.

```bash
python3 test/playtest_client.py --regress
```

`--regress` pins the interactable reach-box geometry (see below). It asserts on
the boxes rather than on the player's focus, because villagers wander into range
and make focus assertions flaky.

**Dialogue is one line, not two.** Pressing E used to show the NPC's canned
opener immediately and then swap in the model's reply a second later, which read
as the character saying two different things back to back. The interim is now an
ellipsis — plainly "still speaking" rather than a sentence — and the opener is
only ever shown as the actual line, when there is no model to ask. A failed
request emits an empty line rather than nothing, so the ellipsis cannot stick.

The panel sizes itself to the text via `Font.get_multiline_string_size`, which
gives the real wrapped height without needing a layout frame. It used to be a
fixed rect about five lines tall that silently clipped anything longer, so a
villager who ran on lost the end of their sentence. It is capped at 55% of the
screen, past which the body scrolls.

**The bridge always answers.** Any command that fails to reply — a runtime error
mid-coroutine, an await that never resolves — would otherwise latch it busy
forever: it silently ignores everything afterwards while the client sits blocked
on `recv` with no diagnostic. A watchdog force-replies `command_timeout` after
`BUSY_TIMEOUT`, a late reply from the abandoned command is dropped so the stream
cannot desync, and `{"cmd":"_hang"}` exists purely to prove that path works. The
client reports which command stalled instead of just hanging.

It earns its keep. On its first run it found that dialogue was being answered
against the backend's own world rather than the client's, so every villager
replied "nobody answers" — and that an interactable attached to a large building
inherited a trigger the size of the whole building. A door on an 8×8 house got a
9×9-tile reach box: openable from the roof, and big enough to swallow a villager
standing in front of it, so pressing E by the theatre opened the door instead of
greeting the person there.

The first attempt at that one was wrong in an instructive way — "NPCs always beat
scenery" fixed the symptom and made any wandering villager able to block a chest
from ever being opened. The real fix was capping the reach box
(`Interactable.MAX_REACH_TILES`, 4×3) and anchoring it to the prop's base, where
you actually stand to use something. Distances are then comparable again and
plain nearest-wins is correct.

## Verification

```bash
python3 tools/tsx_convert.py --verify && python3 backend/test_worldgen.py
```

```bash
godot --headless --path . --script res://tools/verify_assets.gd
```

Render a whole map to a PNG (needs a real window — `--headless` uses a dummy
renderer and `SubViewport` textures come back empty):

```bash
godot --path . -- --world backend/fallback_world.json --shot test_output/world.png
```

## The asset packs

`assets/` is **gitignored and must not be redistributed.** Mystic Woods is
explicitly non-commercial and "cannot redistribute or resale, even if modified".
The Fan-tasy and Tiny RPG packs ship no licence text at all — terms unverified.

Two things worth knowing:

- **There is no goblin.** Both Mystic Woods skeleton sheets are watermarked
  preview art and the Tiny RPG orc is side-view-only with no up/down rows, so
  the only usable top-down enemy is the slime. It is a real one — it chases,
  bites for a heart, and takes three swings to kill.
- **13 Mystic Woods files carry the `#CF8217` "Premium Version!" watermark**,
  including `objects.png`, `plains.png` and every `water*.png`. Screen for that
  exact colour before using any file from that pack.
