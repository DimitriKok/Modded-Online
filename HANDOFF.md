# Handoff — where this branch stands

Read `LOADER.md` first for what the loader build is. This file covers the bugs
worked on in this branch, plus the state a new session needs before touching any of
them.

## Start here

**Build: `2.0.0-dev55` → `dev76`. The server must be redeployed at `1.0.13`.**
Section 3's fix is half a server fix and does nothing without it (1.0.11 or later).
Section 6 has a server half too, but its client half works on its own. A client on a
server other than the one it expects says so in a toast and in the log. Check with
`py server/server_version.py` (exit 0 = the server matches this pack).

| # | Bug | State |
|---|---|---|
| 1 | A peer kept the room host's progression after leaving | **FIXED**, shipped (`ef0b102`, PR #1) |
| 2 | hdmod's journal crashes the game when hosted | **NOT FIXED.** Workaround works — see section 2 |
| 3 | The tutorial door started an ordinary run | **FIXED**, confirmed in game |
| 4 | The tutorial crashed entering level 2 | **FIXED** in dev62 by windowing, confirmed in game. dev61's fix was tested and failed — see section 2, "Tutorial level 2" |
| 5 | Multiplayer tutorial: floors desynced from 1-2 on | The journal half is **FIXED** in dev63 (no resync at a journal any more). **Still open:** a `POSITION DESYNC` on tutorial 1-2 with a resync at 1-3 — section 5 |
| 6 | After the tutorial, the camp door waited "for everyone to pick a character" | **FIXED** in dev63 / server 1.0.12, confirmed in game (the run after the tutorial started) |
| 7 | Mama Tunnel's donation happened on one machine only (bombs desynced) | **FIXED** in dev64; the dev64 session "seemed to work" — section 7 |
| 8 | The tutorial came back after the first real run | **FIXED** in dev64; the dev64 session "seemed to work" — section 8 |
| 9 | Udjat key and chest on two floors, sometimes two keys | **FIXED** in dev64; the dev64 session "seemed to work" — section 9 |
| 10 | Jungle floors desynced (2-4: one extra frog on a lily pad) | **FIXED** in dev65, not yet confirmed in game — section 10 |
| 11 | Desync logs sent to a Discord channel automatically (opt-in) | **NEW** in dev65 / server 1.0.13. The server side starts configured; no log posted yet — section 11 |
| 12 | A SETTINGS page, with AUTOMATICALLY SEND LOGS and AUTOMATICALLY SYNC DATA | **NEW** in dev66, reported working in game — section 12 |
| 13 | Popups the first time Modded Online starts | **NEW** in dev66, reported working in game; a fourth added in dev67 — section 13 |
| 14 | ENABLE DEBUG MESSAGES, and a RESTART REQUIRED popup | **NEW** in dev67, not yet tried in game — section 14 |
| 15 | MODDED ONLINE as the main menu's ONLINE row, controller input, and the menu probe | **NEW** in dev68. In dev68's game test the takeover switched itself off on the first press; **FIXED** in dev69 and **confirmed in game** (the row opens our menu and stays put). The game-styled look is **NEW** in dev70 and drew correctly in game, with every line of text 1.7 times too big; **sized** in dev71; dev72 puts the menu in the main menu's own font (italic, Title Case); not yet tried in game — section 15 |
| 16 | The other players shown in the camp lobby (climbing down the rope, walking about) | **NEW** in dev73. In its first two-player test nobody saw anybody: not one packet was sent. **FIXED** in dev74, not yet tried in game — section 16 |
| 17 | 2.5's swamp desynced on 2-1: one machine built 2.5's new Wheel of Fortune, the other kept the dice shop | **FIXED** in dev75, not yet confirmed in game. The fix hides the swamp's lily pads online; dev76 **measures** whether they can come back — section 17 |

**Git state:** everything is on `origin/fix/peer-save-restore`; the patch-delivered
commits from the no-push-access session have landed. `git log --oneline
origin/fix/peer-save-restore..HEAD` should be empty before you start.

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

### Tutorial level 2 (dev61)

Before dev61 the workaround **caused** a crash on entering tutorial level 2. hdmod
opens each tutorial story with `show_journal(STORY, start + 1)` — pages 6, 10, 14, 18
for level 1, 2, 3 and after — and Overlunky's `show_journal` writes `current_page`
with **no bounds check** (`src/game_api/screen.cpp`). Clamped to 8, page 10 indexed
off the end of the vector. Level 1 (page 6) only ever survived by fitting.

**dev61 (failed in game):** let hdmod's own longer list through when the page was past
8. That grew the list, and the game died straight after `NOT overriding -- the mod is
opening page 10`. **Growth is fatal when hosted on every path — camp and tutorial. 8
pages has never crashed; 12 and 20 always have.** Do not retry any fix that grows the
list.

**dev62 (current, confirmed in game): a window, never growth.** When hdmod
opens a story page past 8, the engine gets 8 pages that *are* the story entries being
shown (`offset = page - 2`), the sandbox's `show_journal` points the journal at
`page - offset` right after the real call, and the sandbox's `game_manager` adds the
offset back to `flipping_to_page` so hdmod's story lock reads full numbering. All in
`src/modHost.lua` (`module.journalWindow`). Locks that open within 8 are still clamped.

If it misbehaves, `mo_journal.txt` says `WINDOW -- ... gets story pages 9..16 ...
opened at engine page 2`. If that line is there and it still crashes, the window is
being handed over but the engine is reading something else past the end — check
whether `current_page` was actually corrected (the proxy is only installed with
`mo_nojournalpages.on`).

Already ruled out from Overlunky's source, do not re-derive: `JournalPageStory::
construct` initialises every meaningful field; backend locks are `recursive_mutex`;
the callback `unordered_map` cannot rehash during play (erase never shrinks it, and
its boot-time capacity sits far above live size); `max_page_count` is `2147483647`
because Overlunky sets it on every override.

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

## 5. The tutorial's floors desynced in multiplayer — journal half FIXED in dev63; a POSITION DESYNC on tutorial 1-2 is STILL OPEN

This one showed up as `FLOOR DESYNC` from 1-2 onward, and later `POSITION DESYNC`,
while the gameplay looked synced. The cause was hdmod's per-floor story journal. Each
player closes it on their own time, and whoever closes first waits for the other. That
wait looked like a desync to the stall detector after 4 s, which then requested a
resync warp. The warp reached the other player while their journal was still open.
hdmod's journal close writes `state.loading = FADE.IN`, which cancelled the warp on
that machine only, so one machine regenerated the floor and the other didn't. The full
chain, with log lines, is in CHANGELOG `2.0.0-dev63`.

Fixed twice. Input packets carry `h = 1` while the sim is held, and the detector
ignores held peers. A resync warp also waits out a mod's own pause.

**To confirm:** play the tutorial with two players and have one of them read each
journal for a long time (more than 10 s). The other player should see "waiting for
players" until the first one closes it, with **no** `RESYNC WARP` line and no
`FLOOR DESYNC` in either log.

**What the dev63 capture showed:** the journal half held. On tutorial 1-2 the host
waited on the peer's journal without a resync. A separate problem remains. At `2:600`
on tutorial 1-2 there is a `POSITION DESYNC`: player 2's hp is 3 on the host's
machine, and the positions differ. Later, at 1-3, the host waited on a peer that was
evidently still on 1-2, and the resync warp fired (`RESYNC WARP -> 1-3, rebase
seq=11`). Two things are still unexplained:

- what moved a player differently on tutorial 1-2;
- why the host's own regeneration of 1-3 (`ent=1863546056`) differs from its first
  generation (`ent=520830476`).

Both need the peer's log from a capture like that one.

**Reading the logs:** the `[time seq:offset]` stamp is cached per engine frame, and
the frame counter stops while the journal holds the game. So every line logged during
a journal shows the time of the frame it opened on. On the host in this session,
`RESYNC WARP` was stamped 18:58:41 but happened about 8 s later. Line it up with the
other log by event, not by stamp.

## 6. "Waiting for everyone to pick a character..." after the tutorial — FIXED in dev63 / server 1.0.12, CONFIRMED IN GAME

Both players finish the run on the same frame, and each sends `endrun` and then
`ready`. The server interleaves the two machines, so one player's `ready` arrived
before the other player's `endrun` reopened the room. The reopen cleared it, and the
client never resent it. Server 1.0.12 keeps a ready sent after leaving the run. The
client also resends its ready whenever the reopened room's lobby list disagrees with
it, so this is fixed even before the server is redeployed.

**To confirm:** finish the tutorial with two players. The lobby should reach
`2 / 2 READY` in the camp, and the host's door should start the run. If it doesn't,
look for `lobby ready RESENT` in the log of the player shown as not ready.

---

## 7. Mama Tunnel's donation happened on one machine only — FIXED in dev64; the dev64 session seemed to work

Her dialog on a TRANSITION, and hdmod's donations on top of it (`lib/shortcut.lua`),
are driven by `game_manager.game_props.input_menu`. That is the engine's MENU input,
read from each machine's own devices, and the gate never touched it. So the dialog
advanced only where the player pressed. hdmod's `donate()` takes from player 1 first,
so one machine took the host's bomb and the other never did.

dev64 sends the menu input along with the gameplay input (above bit 16 of each
frame's record). On every simulated transition frame the engine reads the party's
menu input, and the device's own value is put back at `POST_UPDATE` for the journal
and pause menu. The full design is in CHANGELOG `2.0.0-dev64`.

**To confirm:** one player gives Mama Tunnel a bomb while the other player does
nothing. Both machines should show the same bomb counts afterwards and the same
dialog, and there should be no `POSITION DESYNC` on that transition.

**Known narrow gap:** a player who opens their pause menu at the exact moment the
other player confirms a donation. The other player's press could then land in the
handful of frames already sent before the pause menu opened. The window is the input
delay, about 7 frames.

## 8. The tutorial came back after the first real run — FIXED in dev64; the dev64 session seemed to work

hdmod's prologue is the engine's `savegame.tutorial_state`: 0 nothing, 1 journal got,
2 key spawned, 3 door unlocked, 4 complete. hdmod treats 2 or lower as "prologue
active". The engine advances it when the key unlocks the camp's main exit and the
first run goes through that door. Online that door is inert, so the state stayed at
2. The `hd-prologue-exit` adapter in `src/determinism.lua` now sets it to 4 when a
run starts from the main exit and the door could have opened, which means one of:

- the state is already 3;
- it is the camp right after the tutorial;
- hdmod has a tutorial record.

The host's save today is at 2 with a tutorial record, so the next real run started
from the main exit completes the prologue without redoing the tutorial.

**To confirm:** start a run from the main exit. In the next camp the log's journal
probe should read `prologue=false`, and the line `mod host: hd-prologue-exit: ... 2 -> 4`
should be in the log.

## 9. Udjat key and chest on two floors, sometimes two keys — FIXED in dev64; the dev64 session seemed to work

hdmod switches the game's own Udjat eye off with quest flag 17 (and 18 for the black
market, 19 for the drill) in its run setup. That setup is gated on `QUEST_FLAG.RESET`
in `PRE_LEVEL_GENERATION`. Our `applyFreshRunReset` zeroed `quest_flags` first, so
the setup never ran, and the game placed its own key and chest next to hdmod's.

dev64 shows `RESET` to the hosted mods on the run's first load, between our early
callbacks and a late one that `main.lua` registers after hosting. The engine never
sees the flag.

**To confirm:** run 1-1 to 1-4. Exactly one floor should have one key and one chest,
and the floor dumps' `quest_flags` should include quest flags 17, 18 and 19 (mask `0x70000`)
from 1-1 on.

## 10. Jungle floors desynced: the water snapshot was lost in the move to hosting — FIXED in dev65, NOT YET CONFIRMED IN GAME

Both logs of the dev64 session (room BITO) matched from 1-1 to 2-3. On 2-4 every PRNG
stream was identical at `gen[pre]` and `gen[post]`, and still the peer had one more
frog (`MONS_CRITTERCRAB`) on one more lily pad (`ITEM_LEAF`) at the first frame. The
party had split by `15:720`, with player 2 dead on the host's machine and alive on
the peer's. 3-1 and the resync warp to 3-2 follow from that.

hdmod places lily pads, frogs, kelp and anchovies at `ON.LEVEL`, rolling the PRNG
only where `is_liquid_at` sees open water. The engine simulates water on worker
threads, so two machines disagree on the waterline a frame or two in. The injected
shim fixed this in v21 with a `POST_LEVEL_GENERATION` snapshot. Hosting the mod
instead of injecting into it dropped the fix, and dev65 puts it back in
`src/determinism.lua`.

**To confirm:** play through the Jungle with two players. No `FLOOR DESYNC` should
appear on 2-x, and the per-floor `entities:` lines should match between the two logs.

**If 2-x still differs:** look at whether the extra entities are lily pads or frogs.
`create_lillypad_procedural` also reads where the `FX_WATER_SURFACE` effects are. If
those turn out to differ between machines too, they need the same treatment. The old
shim never needed it, so it isn't done here.

**dev75:** they do differ. 2.5's swamp showed it on 2-1 (section 17), and in a room a
hosted mod's ON.LEVEL no longer sees them. The HD mod's procedural lily pads, and
the frogs on them, are gone online as a result.

## 11. Desync logs to Discord — NEW in dev65 / server 1.0.13

There's an opt-in switch, **AUTOMATICALLY SEND LOGS**, on the SETTINGS page of the
Modded Online menu (`Network.config.autoSendLogs`; dev65 had it in Playlunky's
options instead). When it's on, a run that desynced sends its log to the server at
run end, and the server posts it to a Discord channel. It counts as desynced when
there was a `FLOOR DESYNC`, a `POSITION DESYNC` or a resync warp here, or another
player reported one.

The parts:

- **Client:** `src/logShip.lua`.
- **Server:** `on_logup` and `DiscordForwarder` in `server/server.py`.
- **Setup:** `server/DISCORD.md`.

The bot token goes in `server/discord_config.json` or `MO_DISCORD_BOT_TOKEN`, and
that file is git-ignored.

**No log has been posted to a real Discord yet.** Every test uses a fake HTTP
opener. The operator's server does start configured: on 2026-10-03 it printed the
line in step 2. The bot shows offline in Discord, which is expected, because posting
over REST needs no gateway connection. The first real try:

1. Set up a bot as in `server/DISCORD.md`.
2. Start the server and check that it prints `desync logs from players who opted in:
   posted to Discord by the bot, in channel ...`.
3. Switch on SETTINGS > AUTOMATICALLY SEND LOGS in both games.
4. Force a desync: for example, run with `mo_nodeterminism.on` on one machine only,
   then delete the file afterwards.

**Room for later:**

- A "send my last log now" button, for a run that crashed (the log is on disk as
  `desync_log.prev.txt` after the relaunch).
- Sending logs for runs that didn't desync but felt wrong.

## 12. The SETTINGS page and AUTOMATICALLY SYNC DATA — NEW in dev66, REPORTED WORKING IN GAME

The Modded Online menu's root page is now HOST, JOIN, MATCHMAKING, DISCORD,
SETTINGS and CLOSE. (dev68: CLOSE is gone, since BACK closes the menu, and VANILLA
ONLINE is added while the main menu takeover is in place; see section 15.) SETTINGS
holds:

- HIDE ROOM CODE, TEST PLAYERS and SYNC SAVE DATA, moved there unchanged;
- **AUTOMATICALLY SEND LOGS** (section 11);
- **AUTOMATICALLY SYNC DATA**.

Both new switches are in `config.json` (`autoSendLogs`, `autoSyncSave`), and both
are off by default. The page is in `src/menuUI.lua`.

**AUTOMATICALLY SYNC DATA** is `SaveShare.pollAutoSync`, run every GUI frame after
`SaveShare.poll`. It runs SYNC SAVE DATA once per visit to the main menu
(`SCREEN.MENU`), once the menu has been up for 1.5 s and `loading` is back to
`FADE.NONE`. The wait is there because the game may still be writing its save just
after a run, and the copy reads whole files. Because `poll` runs first, a peer
leaving a room has its own save back before the copy.

`syncToMod` now also refuses while a parked copy (`.mo_mine` or `.mo_absent`) is on
disk, not only while `borrowed` is set. A restore that failed at launch used to
leave the host's file in the pack with `borrowed` unset, and SYNC SAVE DATA would
have copied it into the player's mod.

**To confirm in game:**

1. Switch on AUTOMATICALLY SYNC DATA.
2. Play a run, then quit to the main menu.
3. After a moment, SETTINGS should show `SYNC SAVE DATA  [2 file(s) synced]`.
4. The mod's own `save.dat` and `savegame.sav` should match Modded Online's.

## 13. The first-run popups — NEW in dev66, REPORTED WORKING IN GAME

The first time Modded Online starts, four popups come up over the main menu (and
the title screen). They're drawn with the menu's own panel, banner and rows:

1. How to set mods up (added in dev67), answered with I UNDERSTAND.
2. A notice about the mod itself, answered with I UNDERSTAND.
3. AUTOMATICALLY SEND LOGS: YES or NO.
4. AUTOMATICALLY SYNC DATA: YES or NO.

The code is `FIRST_RUN` and `popupFrame` in `src/menuUI.lua`. The flag is
`firstRunDone` in `config.json`, saved only after the last answer; each answer is
saved as it's given.

The input follows the menu's: ARROWS move, and Z or ENTER selects. Since dev68 a
controller answers them too (section 15). The popups come back on the next visit to
the main menu until they're answered.

**To see them again:** set `"firstRunDone":false` in `config.json`, or delete the
key.

**To confirm in game:**

1. Delete `firstRunDone` from `config.json`, or set it to `false`.
2. Launch. The four popups should show in order.
3. Answer them.
4. SETTINGS should show the two switches as answered.
5. Relaunch. The popups shouldn't come back.

## 14. ENABLE DEBUG MESSAGES and RESTART REQUIRED — NEW in dev67, NOT YET TRIED IN GAME

**ENABLE DEBUG MESSAGES** is a SETTINGS switch (`debugMessages` in `config.json`),
off by default.

- **What it does:** `main.lua` gates the five on-screen printers (`print`,
  `message`, `printf`, `prinspect`, `messpect`) for us and for every hosted mod,
  because they share our Lua state. `MO_DEBUG` overrides it.
- **Early lines:** lines printed before netCore has read `config.json` are held,
  and `FlushHeldMessages()` shows or drops them after the modules load.
- **The exception:** the second-copy warning uses `alwaysPrint` and always shows.
- **When you're debugging:** turn it on. Without it, a player sees no error trace on
  screen, though the desync log still gets them.

**RESTART REQUIRED** is a popup, the `RESTART` sequence in `src/menuUI.lua`.

- **What asks for it:** `setupUI` calls `NetMenuUI.showRestartNotice()` whenever a
  selection is applied (a tick, an untick, or a change found at boot) and on the
  undo button.
- **Where it shows:** anywhere except a level or a transition, and never during an
  online run. The first-run popups go first.

**To confirm in game:**

1. With the switch off, the top left of the screen stays clear at boot and during a
   run, including hdmod's own messages.
2. Turn it on. The `[ModdedOnline]` lines come back.
3. Tick a mod in Playlunky's options. RESTART REQUIRED shows, and OK dismisses it.

## 15. MODDED ONLINE in the main menu, controllers, the menu probe, and the game's look — takeover CONFIRMED IN GAME in dev69; the look NEW in dev70

The menu is meant to feel like part of the game. This build does the mechanics:
MODDED ONLINE is a row of the game's main menu, and a controller drives it. The
game-styled look (Options-screen wood panels and scroll, the game's font) is the
next build, and it needs one measurement from the game first: the probe session
below.

### What changed, and where

- **`src/mainMenuHook.lua`:** the main menu's rows can't be added to from Lua (the
  row list, `menu_tree`, isn't exposed), so the ONLINE row is taken over. Its label
  (string `0xa1023681`) reads MODDED ONLINE on the main menu only. A SELECT on it is
  swallowed and opens our menu. VANILLA ONLINE, the last row of our root page,
  restores the label and hands the game one SELECT on that row. `decide()` holds the
  whole policy and is pure.
- **`src/menuInput.lua`:** the only writer of `game_props.input_menu` outside a run.
  While our menu or a popup is up it turns the input into menu actions and zeroes
  it in `ON.POST_PROCESS_INPUT`, so the game's menu underneath sees nothing. Nothing
  is ever put back (see "What dev68's test showed"). PRE_UPDATE zeroes it again if
  anything refilled it. On a build without POST_PROCESS_INPUT, PRE_UPDATE does all of
  it. `MenuInput.via()` says which.
- **`src/menuUI.lua`:** `open`, `close`, `capturing` and `popupVisible` for the two
  modules above. Keyboard and controller go through one `dispatch`. The new pages
  are CONNECTING and JOINED. CLOSE is gone, and settings change with LEFT and RIGHT.
  The `[O]` chip only shows when the takeover is off.
- **`src/menuProbe.lua`:** the diagnostic, below.

When the takeover is off, the reason is in the desync log as `main menu takeover:
OFF -- ...`, and the `[O]` chip is back. `mo_nomenuhook.on` forces that.

### To confirm in game

1. The main menu's second row reads MODDED ONLINE, and the other rows are as they
   were.
2. SELECT on it opens our menu, with ENTER, Z or a controller's A. The game's own
   highlight doesn't move while you use ours.
3. BACK or ESC on our root page closes it, and the game's menu does **not** go back
   to the title screen.
4. VANILLA ONLINE opens the game's own Online menu, and the row reads "Online"
   there. Backing out brings MODDED ONLINE back.
5. Open OPTIONS, change the language and come back: the row reads MODDED ONLINE.
6. A controller answers the first-run popups (`"firstRunDone":false` in
   `config.json`) and RESTART REQUIRED. RESTART REQUIRED in the camp doesn't walk the
   spelunker.
7. HOST > OFFICIAL SERVER: CONNECTING, then `- ROOM xxxx -`, then character select
   as the screen fades.
8. With `mo_nomenuhook.on`, the `[O]` chip is back and O opens the menu.

### What dev68's test showed (2026-10-05)

MODDED ONLINE showed on the main menu. The first press opened something for a
moment, then the row read ONLINE again and only `[O]` was left. The desync log, at
16:47:25:

```
main menu takeover: OFF -- the game opened its own Online menu after a press that was swallowed
```

dev68 hid the input in PRE_UPDATE and put the device's value back at POST_UPDATE, so
the main menu reads its input somewhere else in the frame. Either it reads before
PRE_UPDATE (too late to hide it), or after POST_UPDATE (the put-back handed it the
press). dev69 hides it in POST_PROCESS_INPUT and never puts it back, which holds
wherever the menu reads. The test stub's menu reads at all four candidate points
(`tests/menu_stub.py`, `ORDERS`), and the takeover is tested in every one.

**If it still switches itself off,** the log line now says where the press was
swallowed and what the menu did next. For example: `(in POST_PROCESS_INPUT, at menu
state 7; 32 ms later the menu was id 0, state 8, moving to 2)`. `the game took the
press before ... ran` means the menu read the press before our callback. Then
`mo_menuprobe.on`'s `menu moved between X and Y` lines say exactly where it reads.
If even POST_PROCESS_INPUT is too late, the press must be blocked earlier:
`ON.PRE_PROCESS_INPUT` returning true skips the game's input processing for the
frame.

### The probe session (needed for the next build)

A flag file made with Explorer's New > Text Document is really `mo_menuprobe.on.txt`
when file extensions are hidden. The probe accepts that name since dev69, after the
first attempt to arm it did nothing for exactly that reason.

The look needs things only the running game can answer: where the Options screen's
wood panels and scroll come from in their sprite sheets, and which hooks draw where.

1. Create `mo_menuprobe.on`, empty. On the main menu, walk every row, and hold a
   controller direction while our menu is open. Open OPTIONS and stay two seconds.
   Go into PLAY and back. Spend five seconds in the camp with the pause menu and the
   journal open, then go into a level.
2. Write `draw` into the file. Take screenshots of the main menu, OPTIONS (wait a
   second), the camp with the pause menu open, a level, a transition and character
   select.
3. Write `capture` into the file. On the main menu, press the arrows across a few
   five-second windows.
4. Send `mo_menuprobe.txt` and the screenshots.

What each answers:

| Probe line or screenshot | Decides |
|---|---|
| `callback order on the main menu: ...` and `menu moved between X and Y` | where in a frame the main menu reads its input (dev68 assumed between PRE_UPDATE and POST_UPDATE, wrongly) |
| `menu id=0 index=N` lines around a press on MODDED ONLINE | that ONLINE is index 1 (the code assumes it and learns otherwise) |
| `menu ... ours=true` lines while a direction is held | whether the game's highlight stays still while we swallow; if `index` moves, `screen_menu.controls` must be zeroed too |
| `options.*` / `panels.*` lines, and the OPTIONS screenshot | the sprite sheet and source rectangle of each wood panel, the scroll, the scarab and the value arrows |
| the `texture ...` lines | the sheet sizes, to turn those rectangles into pixels |
| `post_screen ...` / `post_hud` tags in the screenshots | which hook draws above the HUD and below the pause menu on each screen |
| the strip on the main-menu screenshot | that the game font, its styles and the `<SYS_ACCEPT/>` glyphs render |
| `capture window` / `input now=` lines | whether keyboard presses still reach `input_menu` while the keyboard is taken (`MenuInput.KEYBOARD_IN_MENU_INPUT`) |
| `gui: wantkeyboard at frame start` | whether ImGui resets the flag each frame, which decides whether a Playlunky overlay with keyboard focus can be detected |

### dev69's test (2026-10-05, second session)

The takeover held: MODDED ONLINE opened our menu and the row stayed MODDED ONLINE.
The probe log answered dev68's question directly: `menu moved between POST_UPDATE and
GUIFRAME`. The main menu reads its input after POST_UPDATE, so dev68's put-back is
what handed it the press.

The same log showed `menuUI: closed -- no GUI frame for 7698 ms` right after HOST.
The whole game had frozen while the bridge launched, and the watchdog mistook that for
a menu nobody could see. dev70 fixes that (a gap in the updates themselves is the game
being away).

The probe never reached OPTIONS, so the panels' UVs weren't dumped. They weren't
needed in the end: the sheets were extracted from `Spel2.exe` instead
(`tools/extract_menu_sheets.py`), and every rectangle was measured on them.

### The look (dev70)

`src/vanillaUI.lua` draws with the game's renderer (`set_post_render_screen` on the
menu screens, `ON.RENDER_POST_HUD` in the camp and levels) instead of ImGui.

- **The menu:** a full page like the game's OPTIONS screen. It has the bricks, a top
  wood panel with MODDED ONLINE, the parchment scroll with the rows, and the bottom
  wood panel with the game's button hints. Text is in the game's font.
- **The popups:** a wood-framed dialog from `menu_basic`.
- **The overlays:** the camp plaque, WAITING FOR PLAYERS, the character-select room
  code, the run status line and chat, all in the game's font.
- **Fallback:** the old look stays as the automatic fallback. It's used whenever the
  render callbacks aren't running, for any layer that raised an error, after a
  session that died inside its first vanilla draw (`mo_vanillaui.txt` says
  `drawing` or `crashed`; delete it to try again), or with `mo_novanillaui.on`.

**To confirm in game:**

1. MODDED ONLINE opens a page like the game's Options screen: brick walls, the wood
   panel and parchment scroll with MODDED ONLINE on it, the rows, and the ringed panel
   with "ESC / B Back" and "Z / A Select" at the bottom.
2. The text sits in the middle of its row and of the scroll, at a sensible size. In
   dev70 it was centred but 1.7 times too big. The game's glyph quads give the height
   of a capital, not the whole cell, and dev71 sizes every line as a capital height.
   The measurement is in the log as `vanilla look: text measured (...)`.
3. SETTINGS shows each value between gold arrows on the red bar, and LEFT/RIGHT
   change it.
4. The first-run popups (`"firstRunDone":false`) and RESTART REQUIRED are in a wood
   frame.
5. In the camp the room plaque is on a dark torn box; in a run the status line has a
   shadow; chat (T) types into the game's entry bar.
6. With `mo_novanillaui.on`, everything is back to the old look.

If a layer failed, the desync log has `vanilla look: layer NAME failed, back to the
GUI look for it: ...`, and that part is drawn the old way.

## 16. The other players in the camp lobby (puppets) — NEW in dev73, FIXED in dev74, NOT YET TRIED IN GAME

The camp isn't in lockstep, so until dev73 each player saw only their own spelunker
until the run started. `src/campPuppets.lua` puts the others in it as puppets. A
puppet is an `ITEM_ROCK` wearing that player's character sheet, posed from the
packets they send: position, animation frame, facing, layer and character, up to 20 a
second on the world channel (kind `pp`). Its physics are paused and every interaction
is off. The full description is in CHANGELOG `2.0.0-dev73`.

**dev73's test (2026-10-05):** neither player saw the other. The sender read the
spelunker's position as two numbers from `get_absolute_position`, which returns one
Vec2. Every read failed inside its pcall, so nothing was ever sent, and nothing said
so. dev74 reads the Vec2, and logs each first: packet sent, packet from slot N,
puppet up for slot N. A failed read is logged with its error. The lines go to the
desync log (under the next run's header) and to `mo_menuprobe.txt` while the probe is
armed. If puppets still don't show, those lines say how far it got on each machine.

**To confirm in game (two machines):**

1. Player A is in the camp. Player B joins. A sees B climb down the entry rope, then
   walk about, in B's character, facing the right way, with B's name above.
2. B walks into A's spelunker and A whips B's puppet: nothing happens, to either.
3. B opens the pause menu: B's puppet stays on A's screen.
4. B backs out to the menu: B's puppet goes from A's camp at once.
5. The host starts the run: the run starts as before, with no `FLOOR DESYNC` or
   `POSITION DESYNC` on 1-1 in either log.

**If a puppet looks wrong:**

- **Drawn at the wrong size, or the wrong part of the sheet:** look at
  `ent.width` / `ent.height` (copied from our own spelunker) and the texture's tile
  size first.
- **Jittering:** `FOLLOW` (0.5) and `SEND_MS` (50) are the knobs.
- **Puppets switched off:** the desync log says so with `camp puppets OFF: <why>`, and
  the camp is as before.

**Known gaps:**

- The body only: no held item, whip or back item.
- Test players (`fake_player.py`) send no puppet packets, so they don't show.

## 17. 2.5's swamp desynced on 2-1 (the Wheel of Fortune) — FIXED in dev75, NOT YET CONFIRMED IN GAME

**The capture (room BGNY, dev73, 2026-10-05):** 1-1 to 1-4 matched. 2-1 generated
identically, with all ten streams equal at `gen[pre]` and `gen[post]`. At the first
frame the floors differed in four types:

| | `ITEM_DICE_BET` | `ITEM_DIE` | `ITEM_CONSTRUCTION_SIGN` | `ITEM_LEAF` |
|---|---|---|---|---|
| host (slot 1) | 1 | 2 | 1 | 7 |
| peer (slot 2) | 0 | 0 | 2 | 8 |

The peer had turned the dice shop into 2.5's Wheel of Fortune and the host had not.
A `POSITION DESYNC` at `9:2760`, a `FLOOR DESYNC` on 2-2 and a resync warp to 2-3
followed.

**The chain:**

1. 2.5's swamp lily pads (`hooks/swamp/water.lua`, at ON.LEVEL) stand on the engine's
   `FX_WATER_SURFACE` effects. The liquid system makes those after generation, from
   water the worker threads are already moving, so the two machines hold different
   sets of them.
2. The pads shuffle every surface effect (one `PROCEDURAL_SPAWNS` draw each), and roll
   a one-in-five chance on each well-spaced one. One more effect on the peer gave one
   more pad (the extra `ITEM_LEAF`), and moved the stream.
3. The Wheel of Fortune (`hooks/wheelOfFortune.lua`, `convertShop`) flips its 50/50
   coin on the first playable POST_UPDATE, from that same stream.

**What dev75 changes (`src/determinism.lua`, `src/inputSync.lua`, `src/desyncLog.lua`):**

- **In a room, a hosted mod's ON.LEVEL callbacks see no `FX_WATER_SURFACE` effects,**
  and each one is anchored to the floor base, with the streams restored afterwards.
- **A hosted mod's PRE_UPDATE and POST_UPDATE callbacks are skipped on frames the
  lockstep gate held** (`InputSync.heldFrame()`). They fire once per rendered frame,
  stalls included, so 2.5's wheel would turn further on the machine that stalled
  more. Found reading the code; the capture does not show anyone using the wheel.
- **The local menu pause is cleared during a run's fades too,** not only on gated
  frames. Also found reading the code.
- **Each floor's block in the desync log has a `prng:` line:** the ten streams at
  engage.

**The cost:** no 2.5 swamp lily pads online, and no HD-mod procedural lily pads or the
frogs on them. Both are decoration, but the aim is for nothing about a hosted mod to
change, so dev76 measures whether they can come back (below).

**dev76: measuring the water.** Gameplay is unchanged from dev75. In a room, each
machine fingerprints the liquid and the water-surface effects at generation, as
ON.LEVEL begins (twice, a few ms apart), as the mod's own queries see them, and as
the gate engages. The floor block gets a `water:` line and the surface list, and
the player who is not the world host gets one `WATER PROBE` verdict per floor with
water (`Determinism.waterVerdict`, sent with the floor digest). What each verdict
means for the lily pads:

| Verdict | What differs | The fix it points to |
|---|---|---|
| `MATCH` | nothing the mod would see | stop hiding the surfaces: dev75's anchor was the fix |
| `ORDER` | the order the engine lists them in | sort the answer by position |
| `SETTLING` | the surfaces when the mod looks, not by the first frame | wait for the water to settle before the mod's ON.LEVEL; look at `moving` to see whether it settles while Lua waits |
| `DIFFERENT` | the water itself, still at the first frame | the world host's waterline, sent to everyone before they build the floor |

**To run the measurement:** two players on dev76, through 2.5's swamp (2-1 to 2-4),
and through the HD mod's jungle if you can. Then collect both `desync_log.txt` files.
The `WATER PROBE` lines are in the joining player's log. Decide only on floors where
the mod asked (no "the mod did not ask" in the line); one `DIFFERENT` outweighs any
number of `MATCH`es.

**To confirm in game (two machines, 2.5):**

1. Play into the swamp, over several floors with a dice shop or a Wheel House. No
   `FLOOR DESYNC` on 2-x, and each floor's `entities:` line matches between the two
   logs.
2. The `prng:` lines match between the two logs on every floor.
3. On a floor with water, each log has `hid N water-surface effect(s) from the hosted
   mod's ON.LEVEL`. The two counts may differ; that difference is the reason for it.
4. Spin the wheel while the other player's connection is stalling (`STALL` lines):
   both screens show the same result, and both players have the same money after.

**If 2-x still differs:**

- **`prng:` differs but `gen[post]` matches:** something between generation and the
  first gated frame drew differently. Compare stream by stream. A hosted POST_UPDATE
  during the fade-in is the next suspect.
- **Entities differ but `prng:` matches:** a spawn decision read something
  machine-dependent without drawing from the streams.

**Known, not fixed:**

- **2.5's worm tongue on black-market swamp levels** (`hooks/swamp/udjatworm.lua`)
  chooses its spot from candidates with no liquid entities near them, at ON.LEVEL and
  again during play. The anchor contains the draw, but the spot can still differ if
  the water does.
- **The swamp's water poison** counts frames a player spends in water as the engine's
  live water sees it. It now counts only simulated frames, but the waterline itself is
  the engine's.
- **A hosted PRE_UPDATE that runs before the gate's** reads the previous frame's
  answer. That only happens after the gate's callback has been revived and
  re-registered behind the mod's.

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
| `mo_menuprobe.on` | logs the script API, the MENU_* textures, the main menu's state and input, and the OPTIONS screen's panels to `mo_menuprobe.txt` (section 15). Contents add modes: `draw` (test drawing for screenshots), `capture` (whether the keyboard reaches the menu input while taken). Costs one file check when absent. |
| `mo_nomenuhook.on` | the main menu takeover stays off: the ONLINE row is the game's own, and the `[O]` chip and key open MODDED ONLINE. |
| `mo_novanillaui.on` | the menu, popups and plaques keep the old ImGui look instead of the game's (section 15). |
| `mo_nojournalpages.on` | probe overrides the journal page list. Contents pick the mode: **empty = `sameids`** (engine's count, ids 601+ — stops the crash AND keeps the mod's content), `restore` = the engine's own list unchanged (the non-crashing control), `grow` = 20 entries with the engine's own ids. |

Each announces itself in `spelunky.log` when active, and `determinism=` appears in the
desync-log header.

### Files they write

| File | Written when | Survives a native crash |
|---|---|---|
| `mo_journal.txt` | either journal flag is set | **yes** — opened and closed per line, and mirrored to `spelunky.log`. Bounded at 400 lines; repeated page-render lines collapse to one plus a count, so the budget is not eaten by a second of rendering. |
| `crash_frame.txt` / `crash_notes.txt` | `mo_trace.on` | yes, but costs a file write every frame |
| `mo_menuprobe.txt` | `mo_menuprobe.on` | yes: opened and closed per line. Started fresh at each launch, bounded at 400 lines. |
| `mo_vanillaui.txt` | always: `drawing` before the first vanilla draw of a session, `ok` after it | yes: a `drawing` left behind means that draw killed the game, and the old look is used until the file is deleted (section 15) |
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

On a machine whose Python has no pytest or lupa, uv supplies both for the run:

```bash
uv run --no-project --with pytest --with lupa python -m pytest tests/ -q
```

939 passing, none failing (dev76). The 16 long-standing failures went in dev67, with the two
stale test files they came from: `tests/test_world_mailbox.py` (the world mailbox
deleted in dev44) and `tests/test_seeded_run.py` (the seeded-run flag removed in
dev46). A failure here now means something broke.

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
life of the repo, and shipped a misleading stale capture to every clone. `config.json`
was the second case: ignored but tracked, so every clone got one player's name and
join address. It was untracked in dev66, together with `tools/load_order.backup.txt`
and `save.dat.parked_for_journal_test`. If you add an artifact to `.gitignore`, check
`git ls-files` as well.

## If you are a new session picking this up

1. Read "Start here" at the top, then section 2.
2. Run both test suites (above) so you know what "unchanged" looks like before you
   touch anything.
3. The single highest-value thing available is **the native page-count measurement**
   in section 2. It is about five minutes of game time, it needs no code, and it
   decides which of two unrelated fixes the journal crash actually needs. Everything
   else in section 2 is already measured — do not re-derive it.
