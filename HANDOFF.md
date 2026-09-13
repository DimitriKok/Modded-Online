# Handoff — where this branch stands

Read `LOADER.md` first for what the loader build is. This file covers the three bugs
worked on in this branch, plus the state a new session needs before touching any of
them.

## Start here

**Build: `2.0.0-dev55` → `dev60`. The server must be redeployed at `1.0.11`.**
Section 3's fix is half a server fix and does nothing without it; a client on an
older server now says so in a toast and in the log. Check with
`py server/server_version.py` (exit 0 = the server matches this pack).

| # | Bug | State |
|---|---|---|
| 1 | A peer kept the room host's progression after leaving | **FIXED**, shipped (`ef0b102`, PR #1) |
| 2 | hdmod's journal crashes the game when hosted | **NOT FIXED.** Workaround works — see section 2 |
| 3 | The tutorial door started an ordinary run | **FIXED**, confirmed in game |

**Git state:** commits `9ef9f8a`, `c397867`, `a78d624`, `1bcf49d`, `fda94cf`,
`1d08557` sit on `fix/peer-save-restore` and were delivered to the maintainer as
patches, because the session that wrote them had no push access to
`DimitriKok/Modded-Online` (403 on every path — it is not that account's repo).
Confirm with `git log --oneline origin/fix/peer-save-restore..HEAD` whether they have
landed before assuming anything about what is on the remote.

**Before trusting any log in the pack folder**, read "why two captures came back
empty" in section 2. A stale `desync_log.txt` used to ship *inside the repo* and cost
two rounds of debugging. Delete any copy still sitting in your pack folder.

**Short version:** 1 and 3 are done. 2 is not, but it is now playable, fully measured
on the hosted side, and blocked on exactly one measurement that takes about five
minutes — see "THE ONE MEASUREMENT STILL MISSING".

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

## 2. hdmod's journal crashes the game when hosted — NOT FIXED (workaround works)

### Symptom

Hosted under Modded Online, opening the journal **in the camp** crashes the game
natively — no Lua error, nothing in `spelunky.log`. hdmod loaded natively by
Playlunky does **not** crash.

The tutorial used to crash too, because hdmod's tutorial auto-opens the journal on
fade-in (`lib/tutorial/logic.lua:70-71` → `schedule_story_on_fade_in`). See "the two
cases are different" below — that one may now be fine on its own.

### Play around it today

Create `mo_nojournalpages.on` in the pack folder. **Empty is correct** — that means
`sameids` as of dev59, which stops the crash and keeps hdmod's own page content.

Caveat, and it is why this is a workaround and not a fix: `sameids` clamps to the
engine's **8** pages and hdmod has **20** story pages, so pages 9–20 are not shown.

(Before dev56 this flag installed *nothing* unless `mo_trace.on` was also set, and
before dev59 an empty file meant `restore` — the engine's own vanilla pages. Any
older report of "the workaround does not help" or "the journal looks wrong" is
explained by one of those two and should be retested.)

### What is measured, and how

Everything below is from `mo_journal.txt` (needs `mo_journalprobe.on`, or the
override flag). That file is written per line and closed each time, so it survives
the native crash; the desync log cannot hold this crash at all (see "why captures
came back empty").

| Fact | Evidence |
|---|---|
| The engine offers **8** pages for chapter 8 (`STORY`), ids `{2..9}` | `engine pages in: #8` — hosted, twice |
| hdmod returns **20**, ids 601–620 | `hdmod_journal.lua:965(8) -> table #20` in `crash_notes.txt` |
| The crash is in engine page **setup**, not a draw | the page-render probe writes to the same file and never fires on a crashing run; it fires 400+ times when the list is not grown |
| **Growth is the trigger, not the id range** | returning 8 pages with ids 601–608 does not crash and draws hdmod's textures correctly; returning 20 does crash |
| hdmod's own clamp cannot engage in the camp | `screen=11` is CAMP not LEVEL (12), `worldstate=1` is NORMAL not TUTORIAL (2) — two of its four conditions fail, so it returns all 20 |

`mo_nojournalpages.on` picks what the engine receives, one question per launch:
`restore` = the engine's own list (the non-crashing control), `sameids` = the
engine's count with ids 601+, `grow` = 20 entries with the engine's own ids.

### The two cases are different — test the tutorial separately

hdmod's clamp needs `chapter == STORY`, `is_prologue_active()`, `screen == LEVEL`
**and** `HD_WORLDSTATE_STATE == TUTORIAL`. In the camp the last two fail. In the
tutorial both hold — and the second one only holds at all because of the dev55 fix in
section 3. A capture on the tutorial level confirms `screen=12 worldstate=2`.

So hdmod may well clamp its own list in the tutorial and never hand over the long
one. **Nobody has yet opened the journal in the tutorial with the override flag
removed.** If that does not crash, the bug is camp-only and much less urgent.

### THE ONE MEASUREMENT STILL MISSING

**Does the engine offer 8 pages when hdmod is NATIVE?** Every capture so far is
hosted. This decides between two completely different fixes:

* **Native also offers 8** → hdmod grows 8 → 20 there too *without dying*, so growth
  is fatal only when hosted. Chase how Overlunky sizes the page vector for a
  returning script.
* **Native offers 20** → there is no growth natively, and **hosting shrinks the
  engine's own list**. A different bug entirely, upstream of hdmod.

How to take it (the probe is in *our* script, so it logs with hdmod native):

1. Delete `mo_nojournalpages.on` so the probe is log-only; create
   `mo_journalprobe.on`.
2. Put hdmod native — see "Switching configurations". Getting this wrong mounts the
   assets twice and crashes on boot.
3. Open the journal, read `engine pages in:` in `mo_journal.txt`.

### `get_game_manager()` IS NOT ON THIS BUILD

Every JournalUI field read back `attempt to call a nil value (global
'get_game_manager')`. Not "journal_ui is nil" — **the function is not a global at
all**. Two unrelated features called it inside a bare `pcall` and read the failure as
"no journal is open":

* `pollPlayFlow` waits for the death-recap book to finish animating before launching
  character select. It never waited — which is the wedged endless page-turn on
  CHOOSE ADVENTURER that the wait was written to stop.
* `pollCloseStrayJournal` force-closes a journal drawn over the character select. It
  never closed one.

Neither has ever run on this build. `GameManager()` / `JournalUI()` in `src/util.lua`
now try `get_game_manager()` then the `game_manager` global, latch the miss, and
report which worked via `GameManagerVia()`.

**This parks the `max_page_count` hypothesis.** That field is the leading candidate
for the size a grown list overflows — `JournalUI` exposes it writable and hdmod never
touches it — but it cannot be read until one of those accessors resolves. The next
capture's `n/a(GameManager via ...)` says whether either does. If one does, read
`max_page_count`: if it is 8, the fix is to raise it before returning a longer list
rather than to truncate the journal.

### Why two captures of this crash came back empty

Worth knowing before trusting any log in the pack folder.

**The desync log cannot contain this crash.** `DesyncLog.init` is called from
`InputSync.beginSession`, so the log opens only when a networked **run** starts.
Opening the journal in the lobby camp is before any run: `DesyncLog.line` drops
everything while `logPath` is nil, and `earlyEvent` buffers for a run header that
never arrives.

Worse, the repo *shipped* a `desync_log.txt` — it was in `.gitignore` and tracked
anyway, which `.gitignore` does not undo. Every clone delivered a stale capture from
someone else's session (`Modded Online 1.0`, crossoverlunky, server 1.0.10, clean
`run end`) that reads exactly like a fresh one. Two rounds of debugging went into
that file before anyone checked its header. Untracked as of dev57 — **delete any copy
still in your pack folder.**

For a camp journal crash, read `mo_journal.txt` or `spelunky.log`. Not the desync log.

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
| The page id range | `sameids` (601–608) does not crash and renders correctly |
| Our `ON.RENDER_PRE_JOURNAL_PAGE` hook | removed it (now session-scoped) — still crashed |

## 3. The tutorial door started an ordinary run — FIXED, CONFIRMED IN GAME

dev55. **This is half a server fix.** A client against a server older than 1.0.11
behaves exactly as before, and now says so in a toast and in the log.

Confirmed twice: the maintainer reports the door working, and a `mo_journal.txt`
capture taken on the tutorial level itself reads `screen=12` (LEVEL) with
`worldstate=2` (TUTORIAL) — so the adapter is holding the mod's state where
generation and `hdmod`'s own logic read it, not merely setting it at run start.

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

## Diagnostic tooling (flags and the files they write)

All flag files live in the pack folder. They are files, not settings, for the reason
`mo_host.on` is: a mod that kills the game must be recoverable without the game
starting. Create them empty unless the table says the contents mean something.

| Flag | Effect |
|---|---|
| `mo_trace.on` | per-frame crash trace → `crash_frame.txt` (one line: what was running when the process died) and `crash_notes.txt` (appending, bounded to 400 lines). Writes every frame — expect stutter. |
| `mo_nodeterminism.on` | hosted mods run on raw `pairs` / `math.random` / `get_frame`. **Networked runs desync.** |
| `mo_nowrap.on` | hosted callbacks go to the engine unwrapped. Loses their names in the trace. |
| `mo_journalprobe.on` | logs what the engine offered the journal-chapter callback and what the mod returned, to `mo_journal.txt` and `spelunky.log`. Overrides nothing; no per-frame cost. **This is the one to use for section 2's missing measurement.** |
| `mo_nojournalpages.on` | probe overrides the journal page list. Contents pick the mode: **empty = `sameids`** (engine's count, ids 601+ — stops the crash AND keeps the mod's content), `restore` = the engine's own list unchanged (the non-crashing control), `grow` = 20 entries with the engine's own ids. |

Each announces itself in `spelunky.log` when active, and `determinism=` appears in the
desync-log header.

### Files they write

| File | Written when | Survives a native crash |
|---|---|---|
| `mo_journal.txt` | either journal flag is set | **yes** — opened and closed per line, and mirrored to `spelunky.log`. Bounded at 400 lines; repeated page-render lines collapse to one plus a count, so the budget is not eaten by a second of rendering. |
| `crash_frame.txt` / `crash_notes.txt` | `mo_trace.on` | yes, but costs a file write every frame |
| `desync_log.txt` / `.prev.txt` | **only once a networked RUN starts** | n/a — cannot hold a camp or menu crash at all. See section 2. |

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

535 passing. **16 pre-existing failures** in `tests/test_seeded_run.py` and
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

### Two habits this branch paid for

**A green test suite proves nothing about the wire.** The tutorial-door fix had ten
passing unit tests while being completely broken in game, because every one of them
called the adapter directly with a destination it built itself — and the destination
never arrived. `tests/test_tutorial_door.py` now imports `server.py` and asserts the
round trip. When a fix spans the client and the server, test the seam.

**A `pcall` around a missing global is indistinguishable from a legitimate "nothing
here".** That is how `get_game_manager()` being absent on this build hid two dead
features for the life of the build, and how a diagnostic that printed `?` instead of
the error cost a round. If a read can fail, log *why* it failed.

## Not committed on purpose

The working tree also holds asset links and per-machine artifacts — `Data/`, `res/`,
`soundbank/`, `mod_info.json`, `strings00_mod.str`, `save.dat`, `savegame.sav`, the
`mo_*.on` flags, `mo_journal.txt`, `crash_*.txt` and the desync logs. None of them
belong in git; see `.gitignore`.

`.gitignore` listing a file is **not** the same as the file being untracked —
`desync_log.txt` and `desync_log.prev.txt` were in it and committed anyway for the
life of the repo, and shipped a misleading stale capture to every clone. If you add
an artifact to `.gitignore`, check `git ls-files` as well.

## If you are a new session picking this up

1. Read "Start here" at the top, then section 2.
2. Run both test suites (above) so you know what "unchanged" looks like before you
   touch anything.
3. The single highest-value thing available is **the native page-count measurement**
   in section 2. It is about five minutes of game time, it needs no code, and it
   decides which of two unrelated fixes the journal crash actually needs. Everything
   else in section 2 is already measured — do not re-derive it.
