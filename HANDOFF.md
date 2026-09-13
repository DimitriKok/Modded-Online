# Handoff — where this branch stands

Written at the end of a long debugging session so the next person (or the next
Claude) does not repeat any of it. Read `LOADER.md` first for what the loader build
is; this file is only about the three things worked on here.

**Short version:** two of the three are fixed and shipped (1 and 3). The journal
crash (2) is not, and is diagnosed a long way down — most of the value there is the
*elimination*, not the code.

---

## 1. A peer kept the room host's progression after leaving — FIXED

Commit `ef0b102`, PR #1.

hdmod keeps character unlocks and shortcut progress in `savegame.characters` /
`savegame.shortcuts` (the engine save), **not** in `save.dat` — its four load
callbacks only carry feats, journal, tutorial records and options. So restoring them
depends entirely on `writeFields(ownFields)` in `src/saveShare.lua`, and `ownFields`
is captured once, in `onSaveFields`, via `readFields()`.

`src/eventSync.lua` runs a **second mechanism over the same two fields**
(`SAVE_SYNC_FIELDS = { "shortcuts", "characters" }`), holding the host's values
across a load. `holdSaveSync` already stood down while saveShare was borrowing — but
only in that direction. Nothing stopped saveShare capturing while eventSync's
override was up, so `readFields()` recorded the **host's** values as the player's
own, in memory and in `mo_own_fields.txt`. After that the borrow was permanent:
leaving "restored" the host's unlocks and a relaunch restored them again.

Fix: `onSaveFields` releases eventSync's override before capturing.

Also fixed alongside it:

* **A hosted mod was overwriting our `meta` table.** The sandbox has `__index` but no
  `__newindex`, so `meta = {...}` lands in the sandbox while `meta.name = "HDMod"`
  mutates *ours*. hdmod does this (`main.lua:67-70`), as does crossoverlunky
  (`main.lua:1-4`). `netCore` builds the lobby compatibility handshake from
  `meta.name`/`meta.version`, so the check that stops two different Modded Online
  builds sharing a room was comparing the hosted mod's version instead of its own.
* **`restoreOwn()` reported success after a restore that failed** — `borrowed` was
  cleared regardless of `failed`, so the `saveshare=` header lied and SYNC SAVE DATA
  became willing to write the host's progression into the mod's own folder.
* **`saveSyncHost` was never cleared on run end**, so the first load of the *next*
  run held the player to the *previous* host's progression.

---

## 2. hdmod's journal crashes the game when hosted — NOT FIXED

### Symptom

Hosted under Modded Online, opening the journal in the camp crashes the game
natively (no Lua error, nothing in `spelunky.log`). Entering the tutorial crashes
too — same thing, because hdmod's tutorial auto-opens the journal on fade-in
(`lib/tutorial/logic.lua:70-71` → `schedule_story_on_fade_in`).

hdmod loaded natively by Playlunky does **not** crash.

### Where it dies

`crash_frame.txt` (needs `mo_trace.on`):

```
OUT mod hdmod_journal.lua:965 | sim 0:0
```

`OUT` means that callback *returned*; the engine died immediately after. Line 965 is
hdmod's `ON.POST_LOAD_JOURNAL_CHAPTER`, which hands the engine a rebuilt page list.
`crash_notes.txt` captured both sides of it:

```
journal chapter 2 | engine pages in: #0 {  }
journal chapter 8 | engine pages in: #8 { 2, 3, 4, 5, 6, 7, 8, 9 }
hdmod_journal.lua:965(8) -> table #20 { 601, 602, 603, 604, 605, 606, 607, 608, ... }
```

Chapter 8 is `JOURNALUI_PAGE_SHOWN.STORY`. The engine offers **8** pages and hdmod
returns **20** with fabricated ids in the 600s (its own comment calls this
"bastardizing the custom journal code"). No page render is ever attempted — hdmod's
own `ON.RENDER_POST_JOURNAL_PAGE` never runs — so the engine dies in page **setup**.

### What narrows it

Using `mo_nojournalpages.on` (see below) to override what the engine receives:

| Returned to the engine | Result |
|---|---|
| the engine's own 8 pages, unchanged | no crash |
| 8 pages, ids 601–608 (`sameids`) | **no crash**, and hdmod drew its own textures correctly |
| hdmod's real 20 pages, ids 601–620 | crash |

So the **id range is innocent** and the **count is the trigger**: growing the list
beyond what the engine passed in.

### What the first real capture proved (dev57, `mo_journal.txt`)

```
[21:58:52] journal probe armed: trace=false override=false probe=true
[21:59:11] journal chapter 2 | engine pages in: #0 {  } | screen=11 (LEVEL=12 CAMP=11)
           level=1 theme=17 loading=0 | fyi.hdmod: prologue=true worldstate=1 tutorial=2
[21:59:11] journal chapter 8 | engine pages in: #8 { 2, 3, 4, 5, 6, 7, 8, 9 } | screen=11 ...
```

Hosted, in the camp, opening the journal. Three things are now settled:

* **The engine offers 8 pages hosted.** Confirmed independently of the tracer.
* **No page render is attempted.** The file ends at chapter 8 — the page-render
  probe writes to this same file and never fired. The process dies in the engine's
  page **setup**, before the first draw. Previously an inference; now measured.
* **hdmod's clamp cannot engage here, and the log says exactly why.**
  `screen=11` is CAMP, not LEVEL (12), and `worldstate=1` is NORMAL, not TUTORIAL
  (2). Two of its four conditions fail, so hdmod returns all 20 pages. `prologue=true`
  and `chapter 8` are the two that hold.

This also means **the camp journal and the tutorial journal are different cases**.
In the tutorial, `screen` IS LEVEL and — since dev55 — `HD_WORLDSTATE_STATE` IS
TUTORIAL, so hdmod's own clamp engages and it never returns the long list. Worth
testing directly: the tutorial journal may already be fine while the camp one is not.

### The one measurement still missing

**Does the engine offer 8 pages standalone too?** Still nobody has looked — the
capture above is HOSTED. It matters enormously:

* If standalone also offers 8, then hdmod grows 8 → 20 there as well, and growth is
  fatal *only when hosted* — chase how Overlunky sizes the page vector for the
  returning script.
* If standalone offers 20, there is no growth natively and the real bug is that
  **hosting shrinks the engine's own list** — a completely different chase, upstream
  of hdmod entirely.

The probe lives in *our* script, so it logs even when hdmod is native. Delete
`mo_nojournalpages.on` first (so the probe is log-only), put hdmod native (see
"Switching configurations"), open the journal, and read the `engine pages in:` line.

`JournalUI` has a writable `max_page_count` field — worth investigating, though
hdmod never touches it.

### Ruled out — do not re-test these

| Suspect | How it was ruled out |
|---|---|
| Anything networked (saveShare, lockstep, seed sync) | crashes offline in single-player |
| Our own callbacks | Modded Online fully loaded + hdmod **native** = no crash, even in a hosted room |
| The determinism layer (`pairs`, `math.random`, clock, `ON.FRAME` remap) | `mo_nodeterminism.on` run — still crashed |
| `Callbacks.hosted` (pcall, extra Lua frame, return truncation) | `mo_nowrap.on` run — still crashed |
| The teardown guard (`clear_callback` ownership) | **zero** refusals in any crashing run; `refused a bare` is zero across the whole log |
| Textures | all 242 `define_texture` calls succeeded; `summarize` prints missing/skipped and printed none; story PNGs + DDS all present in both trees |
| `strings00_mod.str` | byte-identical to hdmod's |
| `save.dat` / `savegame.sav` | crashes with `save.dat` absent (matching standalone); `savegame.sav` byte-identical |
| Double-loading | only `fyi.modded-online-loader` registers as a script mod; hdmod stays `--` disabled |
| Ambiguous module resolution | 0 ambiguous `require`s across the pack |
| hdmod's page-count clamp | both `state.screen == SCREEN.LEVEL` and `HD_WORLDSTATE_STATE == TUTORIAL` fail in the camp — but they fail standalone too, so 20 pages is the correct result there |
| Our `ON.RENDER_PRE_JOURNAL_PAGE` hook | removed it (now session-scoped, see below) — still crashed |

### Current workaround

`mo_nojournalpages.on` containing `sameids` makes the journal open without crashing
and shows the right content. It clamps hdmod's list to the engine's count, so a
longer journal later in the game would be truncated. It is a **diagnostic, not a
fix**.

**It did not work on its own until dev56.** The override lives inside the callback
`installJournalProbe` registers, and that registration was gated on
`DesyncLog.tracing()` alone — so creating the one flag a player is told to create
installed nothing at all, and the crash was unchanged. It needed `mo_trace.on`
alongside it, which is undocumented here and writes a file every frame. Any earlier
report of "the workaround does not help" should be retested.

### Why two captures of this crash came back empty

**The desync log cannot contain this crash.** `DesyncLog.init` is called from
`InputSync.beginSession`, so the log is opened and rotated only when a networked
**run** starts. Opening the journal in the lobby camp happens before any run:
`DesyncLog.line` drops everything while `logPath` is nil, and `earlyEvent` buffers
for a run header that never arrives. Both sinks are empty by construction.

Worse, the pack folder still held a `desync_log.txt` — **the repo shipped one**.
`desync_log.txt` and `desync_log.prev.txt` were listed in `.gitignore` *and tracked
anyway*, which `.gitignore` does not undo, so every clone delivered a stale capture
from somebody else's session (`Modded Online 1.0`, crossoverlunky, server 1.0.10)
that reads exactly like a fresh one. Two rounds of debugging went into that file
before anyone checked its header. They are untracked as of dev57; delete any copy
still sitting in your pack folder.

So for a camp journal crash the file to read is **`mo_journal.txt`** (below), or
`spelunky.log`. Not the desync log.

### Taking the missing measurement (dev56)

The same gate is why nobody has answered the question above. It now has its own flag:

* Create `mo_journalprobe.on` in the pack folder. Logging only — it overrides
  nothing and costs nothing (the callback runs when a journal *chapter* loads, not
  per frame).
* Delete `mo_nojournalpages.on` so the probe stays log-only.
* Put hdmod **native** (see "Switching configurations") and open the journal.
* Read the `engine pages in:` line in **`mo_journal.txt`** in the pack folder. That
  file is opened and closed per line, so it is flushed to disk before the process
  dies, and it is written whether or not a run is in progress. The same lines go to
  `spelunky.log` via `print`, as a second independent sink.

Then run the same thing hosted and compare the two counts. That single comparison
decides which of the two chases above is the real one.

---

## 3. The tutorial door started an ordinary run — FIXED (needs server 1.0.11)

dev55. **This is half a server fix.** A dev55 client against a server older than
1.0.11 behaves exactly as before, and now says so in a toast and in the log.

### The bug

`lib/camp/camp.lua:563` installs `entrance_tutorial` as a per-frame interval watching
for a player overlapping `DOOR_TUTORIAL_UID` in `CHAR_STATE.ENTERING`, and only then
sets `HD_WORLDSTATE_STATE = TUTORIAL`. Room generation, spikes, flags and touchups
all branch on that value. Online every camp door is inert on purpose (`pollCampDoor`)
— one player walking through would start a solo run — so the interval never fires.

### Why the dev54 fix did nothing

All three hypotheses in the previous handoff were guesses. It is the first one, and
it is visible in the source without running the game. `server/server.py`:

```python
if world == 1 and level == 1:
    return None  # the main door: the default start, nothing to carry
```

hdmod spawns its tutorial door with `spawn_door(x, y, l, 1, 1, THEME.DWELLING)`, so
its destination **is** 1-1: the one door the feature exists for is the one door the
server discarded. `payload.start` was absent, `runStartedFromDoor` was called with
`nil`, and the adapter returned false on its first line. The adapter, the dispatch and
all ten unit tests were correct — the field was empty before any of them ran.

Nothing tested the wire. The unit tests call the adapter directly with a destination
they build themselves, so they passed the entire time the bug was live. There are now
tests that import `server.py` and assert the round trip
(`tests/test_tutorial_door.py`, "the wire itself").

### What changed

* **Server:** `parse_start_dest` keeps a 1-1 destination. Safe because the client
  never sends one for the main exit — `pollCampDoor` records `false` for
  `FLOOR_DOOR_MAIN_EXIT` and only reads `get_target()` for
  `FLOOR_DOOR_STARTING_EXIT`, so the main door arrives as an absent field.
  `SERVER_VERSION` 1.0.11, `EXPECTED_SERVER_VERSION` with it.
* **Recognition and consequence are now two steps.** `startDoor` still runs at
  `run_start` (it matches on the camp door, which is gone once we warp) and records
  the adapters that hit; `ModHost.reassertStartDoor` re-applies their state at
  `PRE_LEVEL_GENERATION` while `levelOrdinal == 0`, which is the last write before the
  world is built. That kills hypothesis 2 whether or not it was ever real, and the log
  line says which — `IT HAD BEEN CLEARED` vs `already set`. It deliberately does not
  re-run the door match: the camp is gone by then and the door's uid may have been
  recycled by another entity. `clearRunState` drops the hits so a tutorial cannot leak
  into the next run.
* **Hypothesis 3 was half right and is closed.** `detect` required `camplib` as well
  as `worldlib`, and detection runs ONCE, right after the mod's main chunk — a global
  assigned later than that made the adapter invisible for the whole session.
  `worldlib.HD_WORLDSTATE_STATUS` already names hdmod; `camplib` is resolved where it
  is used.
* **A restart inside the tutorial stays in the tutorial.** The restart re-sends the
  same door, but the camp is gone and `DOOR_TUTORIAL_UID` is a dead entity by then,
  so the match failed. The door's target is now read while the camp is up and
  remembered per sandbox; the comparison no longer needs the entity.
* **The main exit is no longer labelled `1-1`.** It shared the label with any door
  leading there, so `everyoneSameDest` called two different choices agreement and
  pressing one while readied at the other read as un-readying.

### If it still misbehaves, the log now answers it

Three lines, in order, with no flag file needed:

```
camp doors hooked: 12345=main exit, 12346=1-1(theme 1)
mod host: start door 1-1(theme 1) -> 1 recognised | fyi.hdmod/hd-tutorial-door: RECOGNISED
mod host: start door re-asserted | fyi.hdmod/hd-tutorial-door: worldstate 1 -> 2 (IT HAD BEEN CLEARED)
```

* No `camp doors hooked` line with a 1-1 entry → the tutorial door is not a
  `FLOOR_DOOR_STARTING_EXIT` and never reached `campDoors`. Nothing downstream can
  work; that is a different fix (widen the door scan).
* `start door none (the main exit)` after readying at the tutorial door → the server
  is older than 1.0.11. The toast says so too.
* `RECOGNISED` but no `re-asserted` line → generation never ran with `levelOrdinal`
  at 0.
* Both lines present and the run is still ordinary → the state is right at
  generation and something downstream of `HD_WORLDSTATE_STATE` is the problem. That
  is new territory; nothing above is left to suspect.

### Known gap: a MID-RUN JOIN into a tutorial

The server only attaches `start` to a fresh run (`not isinstance(floor, dict)`), and
the join branch of `run_start` never reads it. Someone joining a tutorial in progress
therefore does not get `HD_WORLDSTATE_STATE` set, and their floor generates as an
ordinary level. Untested and out of scope here — it needs the destination carried on
the join path and the hits re-established on the joiner.

## Diagnostic tooling added this session

All flag files live in the pack folder. They are files, not settings, for the reason
`mo_host.on` is: a mod that kills the game must be recoverable without the game
starting.

| Flag | Effect |
|---|---|
| `mo_trace.on` | per-frame crash trace → `crash_frame.txt` (one line: what was running when the process died) and `crash_notes.txt` (appending, bounded to 400 lines). Writes every frame — expect stutter. |
| `mo_nodeterminism.on` | hosted mods run on raw `pairs` / `math.random` / `get_frame`. **Networked runs desync.** |
| `mo_nowrap.on` | hosted callbacks go to the engine unwrapped. Loses their names in the trace. |
| `mo_journalprobe.on` | logs what the engine offered the journal-chapter callback and what the mod returned, to `mo_journal.txt` (flushed per line, so it survives a native crash) and `spelunky.log`. Overrides nothing; no per-frame cost. |
| `mo_nojournalpages.on` | probe overrides the journal page list. Contents pick the mode: empty/anything = the engine's own list, `sameids` = engine's count with ids 601+, `grow` = 20 entries with the engine's own ids. |

Each announces itself in `spelunky.log` when active, and `determinism=` appears in the
desync-log header.

Genuine fixes to the tooling itself, worth keeping:

* **The tracer can now arm outside a run.** `traceFileOn` was only assigned inside
  `init()`, which runs when the log opens for a *networked run* — so for a
  single-player or main-menu crash `traceActive()` was false, every `frameMark`
  returned immediately, and `crash_frame.txt` was never created. The flag looked like
  it did nothing. Now read at module load.
* **Lobby log lines survive.** `DesyncLog.line` drops everything while `logPath` is
  nil, and the whole save-share exchange happens in the **lobby** — two captures from
  a failing session contain the string "save share" zero times, and not because
  nothing ran. `DesyncLog.earlyEvent` buffers and flushes under the next run's header.
* **Hosted callbacks are named in the trace**, via the `file:line` the profiler
  already computed.
* **`ModHost.envs` / `envFor(packDir)`** — the sandbox is kept after hosting, so a
  mod's own globals can be read from outside. This is the gap LOADER.md flags for the
  unported 2.5 adapter and nothing previously provided it.
* **The journal render hook is session-scoped** (`pollJournalHook`). It used to be
  registered unconditionally for the whole run of the game, and
  `journalShouldBeHidden` returns false on its first line outside a session — so it
  could never do anything useful offline. Not the crash, but wrong on its own terms.

---

## Switching configurations

The two switches must be in **opposite** positions. Enabling hdmod in both places
mounts its assets twice and crashes on boot.

**Hosted** (normal): hdmod unticked in Modlunky; ticked in the MODDED ONLINE picker
(`mo_host.on` names it).

**Native** (for comparison runs): in the MODDED ONLINE picker **untick hdmod and
quit** — that runs packSetup's teardown and unlinks the assets, which must happen
*before* enabling it in Modlunky. Then enable `fyi.hdmod` in Modlunky.

---

## Working here

```bash
py -m pytest tests/ -q
```

510 passing. **16 pre-existing failures** in `tests/test_seeded_run.py` and
`tests/test_world_mailbox.py` — they cover the world mailbox deleted in dev44 and are
unrelated to anything here.

The server has its own end-to-end suite, and `py -m pytest tests/` DOES NOT RUN IT:

```bash
cd server && py test_server.py
```

Run it after every server change. The tutorial-door bug lived entirely on the wire
and every client-side test passed throughout.

`test_lua_compiles.py` earns its keep: `src/eventSync.lua`'s main chunk is **at Lua's
hard limit of 200 locals**, so anything added there must hang off `module` instead.
Run it after every Lua edit.

## Not committed on purpose

The working tree also holds asset links and per-machine artifacts — `Data/`, `res/`,
`soundbank/`, `mod_info.json`, `strings00_mod.str`, `save.dat`, `savegame.sav`, the
`mo_*.on` flags, `crash_*.txt` and the desync logs. None of them belong in git; see
`.gitignore`.
