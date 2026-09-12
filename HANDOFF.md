# Handoff — where this branch stands

Written at the end of a long debugging session so the next person (or the next
Claude) does not repeat any of it. Read `LOADER.md` first for what the loader build
is; this file is only about the three things worked on here.

**Short version:** one bug is fixed and shipped. Two are not. The unfixed ones are
diagnosed a long way down — most of the value in this branch is the *elimination*,
not the code.

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

### The one measurement still missing

**Does the engine offer 8 pages standalone too?** Nobody has looked. It matters
enormously:

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

---

## 3. The tutorial door starts an ordinary run — FIX ATTEMPTED, STILL BROKEN

### The bug

`lib/camp/camp.lua:563` installs `entrance_tutorial` as a per-frame interval watching
for a player overlapping `DOOR_TUTORIAL_UID` in `CHAR_STATE.ENTERING`, and only then
sets `HD_WORLDSTATE_STATE = TUTORIAL`. Room generation, spikes, flags and touchups
all branch on that value.

Online, Modded Online makes every camp door inert on purpose (`pollCampDoor`,
`src/eventSync.lua:3542`) — one player walking through would start a solo run. So the
interval never fires, the state stays `NORMAL`, and the tutorial door builds an
ordinary 1-1. The journal probe confirms it: `worldstate=1` where `TUTORIAL` is 2.

The door is not distinguishable by destination — hdmod spawns it with
`spawn_door(x, y, l, 1, 1, THEME.DWELLING)`, literally a 1-1 target.

### What was tried

A `startDoor(env, dest)` adapter hook (`src/determinism.lua`), dispatched by
`ModHost.runStartedFromDoor` and called from `run_start` on every machine before the
warp is booked. Each machine matches the run's start destination against **its own**
`camplib.DOOR_TUTORIAL_UID` target and sets `HD_WORLDSTATE_STATE = TUTORIAL`.

Unit-tested (`tests/test_tutorial_door.py`, 10 tests) — **and it does not work in
game.** Untested hypotheses for why:

* `payload.start` may not actually carry the destination on this path — verify the
  host's `requestStart(myReadyDest)` really sends `{1,1,DWELLING}` and that
  `parse_start_dest` on the **server** preserves it. The server is a separate process
  and a separate deployment; an older server may drop it.
* Something may reset `HD_WORLDSTATE_STATE` back to `NORMAL` between `run_start` and
  generation. `camp.lua:564` does exactly that on camp setup.
* The adapter may not be matching at all — `detect` requires `worldlib` and `camplib`
  as sandbox globals at the time `detectAdapters` runs.

**Add a `traceNote` inside `runStartedFromDoor` and the adapter before touching
anything else.** It is currently silent, so there is no evidence which of the three
it is.

---

## Diagnostic tooling added this session

All flag files live in the pack folder. They are files, not settings, for the reason
`mo_host.on` is: a mod that kills the game must be recoverable without the game
starting.

| Flag | Effect |
|---|---|
| `mo_trace.on` | per-frame crash trace → `crash_frame.txt` (one line: what was running when the process died) and `crash_notes.txt` (appending, bounded to 400 lines). Writes every frame — expect stutter. |
| `mo_nodeterminism.on` | hosted mods run on raw `pairs` / `math.random` / `get_frame`. **Networked runs desync.** |
| `mo_nowrap.on` | hosted callbacks go to the engine unwrapped. Loses their names in the trace. |
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

492 passing. **16 pre-existing failures** in `tests/test_seeded_run.py` and
`tests/test_world_mailbox.py` — they cover the world mailbox deleted in dev44 and are
unrelated to anything here.

`test_lua_compiles.py` earns its keep: `src/eventSync.lua`'s main chunk is **at Lua's
hard limit of 200 locals**, so anything added there must hang off `module` instead.
Run it after every Lua edit.

## Not committed on purpose

The working tree also holds asset links and per-machine artifacts — `Data/`, `res/`,
`soundbank/`, `mod_info.json`, `strings00_mod.str`, `save.dat`, `savegame.sav`, the
`mo_*.on` flags, `crash_*.txt` and the desync logs. None of them belong in git; see
`.gitignore`.
