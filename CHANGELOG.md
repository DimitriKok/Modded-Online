# Changelog

## 2.0.0-dev83

On Linux, dev82 still said "Could not reach the server: the bridge did not start". No
server change: the server stays at **1.0.13**. Both players need dev83 (the lobby only
lets the same version play together).

### What the report narrows it to

dev82 checks that the bridge script is there before it launches it, and that check
passed, so the path is right. Python was found. Yet the bridge never wrote its log,
which it opens in its first lines: whatever Python was started with stopped before it
reached the script. A `py` launcher or a Python install that cannot start under Wine
does exactly that, and what it printed went to a console window, if there was one.
(Checked under Wine 9 here with the same game folder name, space included, and a pack
name in a different case from the folder's: with a working Python the bridge starts
and relays, so the path and the launch line are not it.)

### Fixed

- **Under Wine, a Python must answer before it is used.** Each candidate (each name
  `where` finds, then each install on disk, the launcher first) is asked for its
  version, and the first that answers `Python 3...` runs the helpers. One that does
  not is passed over, and what it said is kept: if none answers, the message is
  `Python for Windows is in Spelunky 2's Proton prefix, but it does not run ... "<py>"
  said <its words>`. Nothing is run to look on Windows, where `python.exe` can be the
  Microsoft Store's placeholder.
- **Under Wine, the helpers' own output is kept**, in `server/client_bridge.out` and
  `server/server.out`: the bridge runs inside `cmd /c` with its output sent there. When
  the bridge's log never appears, the menu's reason is the last thing Python printed:
  `Could not reach the server: the bridge did not start (<what Python said>)`. On
  Windows the launch is what it always was.
- **`modded_online_connect.log`, in the Spelunky 2 folder**, says what the connection
  machinery did: the pack folder and whether the settings file is there and the
  first-run popups answered, which Python was chosen and how (and which did not run),
  the exact command each helper was started with, and how far the bridge got when a
  connection failed. It is written whether or not a run ever starts, so there is always
  something to send. `modded_online_boot.log` names the pack folder too.
- **Settings survive reinstalling.** A copy is kept as `modded_online_settings.json` in
  the Spelunky 2 folder, read when the pack has no `config.json` of its own. Unpacking a
  new build over the old folder took the settings, and the answers to the first-run
  popups, with it, so the popups came back on the first launch of every build. A
  failed save is a toast now, as well as a line in the connection log.

### Tests

Added to `tests/test_python_detect.py` (a launcher that does not run passed over for an
interpreter that does, only broken ones named with what they said, a name `where` found
checked too, nothing run on Windows), `tests/test_bridge_report.py` (the Wine launch
line, the Windows one unchanged, Python's words when there is no log, the connection
log's lines) and `tests/test_pack_root.py` (settings kept through a reinstall, the
pack's own winning over the copy). 1125 passing, 1 skipped, under Lua 5.4 and 5.5; the
server suite passes unchanged.

## 2.0.0-dev82

On Linux: "the bridge did not start", and the first-run popups on every launch. No
server change: the server stays at **1.0.13**. Both players need dev82 (the lobby only
lets the same version play together).

### What was wrong

Those two symptoms have one cause in common: Modded Online looking for its own files in
the wrong folder. The settings file could not be written there, so the answers to the
first-run popups were never kept, and Python was told to run a bridge script that was
not there, so it never ran and never wrote the bridge's log. (A history note in
`util.lua` records the same pair from an earlier version, for the same reason.)

The mod found its folder only one way: by searching `load_order.txt` for an enabled
pack folder holding `src/modHost.lua` directly. If that search misses, every path falls
back to a folder named `fyi.modded-online-loader`. The likeliest way to miss it is a
download unpacked one folder too deep (`Mods/Packs/<zip name>/<folder>/main.lua`):
Playlunky finds and runs a `main.lua` anywhere inside a pack, but the search does not.
Nothing said so: the failed save was a debug line, and `start` succeeds whether or not
the script it is given exists.

### Fixed

- **The pack is found from the file the engine actually loaded.** Playlunky names each
  file it loads (`@Mods/Packs/<pack>/src/util.lua`); our root is that file's folder, and
  the pack is the folder right under `Mods/Packs`, however deep the files are. It is
  believed only if `src/modHost.lua` is there too; otherwise the load-order search runs
  as before. For a pack installed normally both give the same folder, so nothing moves.
- **Settings that cannot be saved are said out loud**, once, with the path and the
  reason, and that the first-run answers will not be kept.
- **A helper script that is not where it should be is named** instead of launched:
  `The connection bridge script is missing: <path>` in the menu, and the folder the mod
  expected its files in, in the log. The same for the server.

### Tests

New: `tests/test_pack_root.py` (a pack unpacked one folder deep, a normal install
unchanged, Windows separators, no load_order.txt needed, the search still used when
there is no file name, a name that does not check out not believed, an unsaveable
config said once, a missing bridge or server script named instead of launched).
1115 passing, 1 skipped, under Lua 5.4 and 5.5; the server suite passes unchanged.

## 2.0.0-dev81

Linux again: Python was found, and every connection then failed with "Could not reach
the server". No server change: the server stays at **1.0.13**. Both players need
dev81 (the lobby only lets the same version play together).

### What was most likely wrong

Every way of playing online except a server on this machine goes through the client
bridge, `server/client_bridge.py`, which the game starts in a window of its own. Under
Wine, a console program started that way whose console gets no window has a dead
stdout, and the bridge's first `print()` raised `OSError: [Errno 9] Bad file
descriptor`. It died a moment after it started, its port closed, and the game's
hellos went nowhere. Reproduced here with Wine 9 (what Proton 9 is built on) and a
Windows Python 3.13: the old bridge never relayed a packet; the new one answered
1.5 seconds after it was launched. Under Wine with a window to put the console in,
both versions relay, so this is the likeliest cause rather than a proven one: nothing
anywhere could say which had happened, because the bridge's window was gone and the
game knew only that no answer had come. If it still fails, the menu now says which
stage was the last one reached.

### Fixed

- **The bridge cannot die of its console.** Everything it says goes to its window if
  it can and to `server/client_bridge.log` next to it, and a write that fails is
  dropped. An uncaught error goes to the log with its traceback.
- **The bridge marks how far it got**: `bridge up`, `the game reached the bridge`,
  `the server answered`.
- **When a connection through the bridge never comes up, the game says why**, from that
  log: `Could not reach the server: the bridge did not start` (no log: Python never
  ran it), `...: the game's messages never reached the bridge`, `...: the server did
  not answer`, `...: the server's reply never reached the game`, `...: the bridge
  cannot send to the server`, or `...: the bridge stopped (<its error>)`. The log line
  the menu's reason came from goes to the desync log. The previous session's log is
  deleted before each launch, so it can never be read as this one's.
- The test players survive a dead console the same way (they already wrote a log).
  The server already did: it writes through `logging`, which drops a failed write.

### Tests

New: `tests/test_bridge_report.py` (each stage the log can end on, a crash named by
its error, a bridge that cannot send, the timeout's message and log line, the stale
log removed before a launch, and the real bridge relaying with its stdout closed,
which the old bridge failed). 1106 passing, 1 skipped, under Lua 5.4 and 5.5; the
server suite passes unchanged.

## 2.0.0-dev80

Playing on Linux: the mod finds a Windows Python installed inside the game's Proton
prefix, and says so in Proton's terms when there is none. Nothing about play changes,
and the server stays at **1.0.13**. Both players still need dev80, because the lobby
only lets the same Modded Online version play together.

### What happened

Spelunky 2 runs on Linux through Proton, as a Windows program in a Wine prefix, and so
does everything the mod starts. A player who had installed Python on Linux (Omarchy's
installer, `/usr/bin/python3`) got "Python is not installed": the game cannot see a
Linux program. It needs the Windows Python, installed inside the prefix.

Even that was not enough before this build. The mod found Python only through Windows'
`where` command, and Wine's `where` is a stub that prints nothing up to Wine 9 (Wine
implements it from 10.0). So on Proton 9 or older a Windows Python in the prefix was
still "not installed".

### Fixed

- **When `where` finds nothing, the mod looks where a Windows install puts Python**:
  the `py` launcher in `C:\Windows` or in the user's `Programs\Python\Launcher`, then
  Python 3.15 down to 3.8 in the user's `Programs\Python`, in `Program Files` (and the
  32-bit ones), in `C:\Python3x`, and in the Python install manager's own folders.
  Nothing is run to look: each place is a file check. A found path is launched quoted.
  On Windows this also finds an install whose "Add python.exe to PATH" was left
  unticked. The Microsoft Store placeholders are still not taken for Python.
- **Under Proton, the message says what to install and where**: `Python for Windows is
  not installed in Spelunky 2's Proton prefix ... e.g. protontricks-launch --appid
  418530 python-3.13.x-amd64.exe`, and points at the README's new "Playing on Linux
  (Proton)". Wine is recognised by the variables it puts in every Windows process's
  environment (`WINECONFIGDIR` and the rest).
- **The desync log says which Python the helpers run on**, once a session:
  `python: py (found by where)`, `python: "C:\windows\py.exe" (found where it was
  installed; where found none) | under Wine (Proton)`, or `python: none found`.

### Tests

New: `tests/test_python_detect.py` (Python on the PATH used by name as before, the Store
placeholder still not Python, an install off the PATH found, the newest first, the
launcher before any one interpreter, worked out once a session, Proton 9 finding the
prefix's Python, Proton 10 through `where`, the Proton message, Windows not taken for
Wine, the log line for each case, a found path launched quoted). 1097 passing, 1
skipped, under Lua 5.4 and 5.5; the server suite passes unchanged.

## 2.0.0-dev79

The crash leaving the summit's second floor, and the Lua error before it that left
nothing in the log. No server change: the server stays at **1.0.13**. Both players
must be on dev79, because what the leak sweep destroys changes, and so do the callback
ids (the new load marks below are callbacks of ours).

### What dev78's capture showed (room UVLQ, 1-1 to 2-2)

- **No desync.** Both runs (1-1 to 1-4, then 1-1 to 2-2) matched on every floor: no
  `FLOOR DESYNC`, no `POSITION DESYNC`, no checksum mismatch, and the two `level order`
  lines agreed on every floor. The dev78 fixes held.
- **The host crashed leaving 2-2.** Both machines reached the door on the same frame
  (11:7502) and ran our PRE_LOAD_SCREEN callback. The peer went on to build the
  transition and waited there for the host. The host's last trace mark was
  `OUT mod helpers2.lua:533`: 2.5's wrapper for its PRE_LEVEL_DESTRUCTION callbacks
  had returned. The process died after that, in 2-2's teardown, before the
  transition's PRE_LEVEL_GENERATION. None of our callbacks run during a teardown, so
  the trace could say no more, and every one of 2.5's PRE_LEVEL_DESTRUCTION callbacks
  is that same function of helpers2.lua's.
- **On 2-1 and 2-2 hosting did one thing solo 2.5 never does.** 2.5 parked about 360
  entities outside the level as each of those floors began, and the leak sweep
  destroyed all of them at frame 450 on both machines (366 on 2-1, 360 on 2-2). Solo,
  2.5 leaves them where they are until the level's teardown takes them, and 2.5 can
  still hold what it parked. Not proven to be the cause: an entity freed and then read
  again crashes one machine and not another, which is what happened here.
- **The Lua error a couple of floors earlier is in neither log.** Since dev77 an error
  raised through our wrapper of a hosted callback goes to the desync log, so this one
  came from somewhere else: one of Modded Online's own callbacks, whose errors were
  never logged, or a callback the engine calls directly. The sound, console,
  render-screen and instagib APIs handed theirs to the engine unwrapped, and a mod's
  entity hooks still do.

### Changed: the leak sweep leaves 2.5's usual parked entities alone

- **It waits for a pile-up.** Parked entities are destroyed only while more than 1000
  are parked on the floor. The lair boss's claws, the leak the sweep was built for, run
  into the thousands. Fewer stay where 2.5 put them, as when playing alone.
- **It never touches an ACTIVEFLOOR.** A push block or a falling platform can be a grid
  entity, and 2.5 parks with `move_entity`, which leaves the level's grid as it was. The
  engine removes a grid entity through `destroy_grid`, not a plain `destroy()`.
- **Each floor's log says what was parked**, once, whether or not any of it is touched:
  `parked outside the level by the mod: 360 at frame 150 (ITEM_ROCK 200, ...) -- left
  where the mod put them, as unhosted (swept past 1000)`. A sweep line says what it
  destroyed, by type.

### The next crash and the next error say more

- **A trace mark says what a hosted callback is for**: the event it was registered for
  or the API, and, where the mod's own wrapper keeps them, the name the mod gave it and
  where the function it wraps is defined:
  `OUT mod helpers2.lua:533 (<2.5's name for it> @ <file>.lua:<line>) PRE_LEVEL_DESTRUCTION`.
  2.5 registers nearly everything through Helpers2's wrappers, which close over a
  `callbackName` or `debugName` and the `callback` they protect; both are read once, at
  registration, and only while a trace or the profiler wants a name. A hosted error in
  the desync log carries the same name.
- **Each phase of a load leaves a mark**: `load:PRE_LEVEL_DESTRUCTION`,
  `load:PRE_LAYER_DESTRUCTION 0`, and so on to `load:POST_LOAD_SCREEN`, and each screen
  change a line in crash_notes.txt (`load: screen 12 -> 13`). Written only with
  `mo_trace.on`. The callbacks are registered on every machine whatever the flags, so
  the callback ids still match between machines.
- **The sound, console, render-screen and instagib callbacks go through the hosted
  wrapper** like the mod's other callbacks: named, run at our depth zero, and their
  errors logged. One registered with a value that cannot be called is named at
  registration (`passed a number, not a function, as the callback to
  set_vanilla_sound_callback(...)`), as dev77 does for the rest. The engine calls a
  sound callback from FMOD's thread whenever the sound plays, so those leave no trace
  mark: the trace is one line, and a sound could overwrite the mark that says where the
  main thread was. Their errors are still logged.
- **An error in one of Modded Online's own callbacks is logged too**, as
  `*** MODDED ONLINE ERROR in eventSync.lua:<line>: ...` with its stack, the first in
  full and then a line every few seconds. Playlunky shows ours and a hosted mod's under
  the same name, so the log can now say whose an error was. A mod's error passing up
  through one of ours (the ordered ON.LEVEL batch, the world capture) is logged once,
  as the mod's. The error still goes on to the engine unchanged.
- A render-screen hook's id is not taken for the mod's in the clear guard: a screen
  counts its own hooks from 1, so the same number can be one of our callbacks.

### Known, not fixed

- **A mod's entity hooks** (`set_pre_update_state_machine`, `set_pre_kill` and the
  rest) still go to the engine directly, so an error in one reaches spelunky.log only.
  2.5 protects its own with its `SafeCall`.
- **2.5's `Helpers2.gameFrame` registers for `ON.GAME_FRAME`**, which the engine does
  not define (it is `ON.GAMEFRAME`), so a callback registered through it never runs as
  a game-frame callback. That is 2.5's to fix, and the registration still goes to the
  engine as it is. The log now names the first such registration
  (`registered a callback (helpers2.lua:501) for an event that does not exist`), so
  the next capture says whether 2.5 ever calls it.

### Tests

New: `tests/test_engine_called_callbacks.py` (the sound callback wrapped in third
place and still the mod's to clear, each API's non-callable named, naming the mod's
arguments never raising, a render-screen hook still skipping the default rendering and
its id not the mod's, instagib's the mod's to clear, the event or API in errors and in
the trace, the mod's own name through one and two Helpers2-style wrappers, a long name
leaving room for the clock, a sound callback leaving the trace alone, a registration
for an event that does not exist named once, a mark per load phase, PRE_LOAD_SCREEN
never skipped, the same registrations with and without the trace, the census line, an
error of ours logged as ours and the error value kept, the mod's error through one of
ours logged once as the mod's). Added to: `tests/test_leak_sweep.py` (a summit-sized
floor left alone, a pile-up past the limit swept in uid order, only what was parked
long enough, never an ACTIVEFLOOR, the census once a floor). 1083 passing, 1 skipped,
under Lua 5.4 and 5.5; the server suite passes unchanged.

## 2.0.0-dev78

The run that desynced on 4-2 and then got stuck, and the Discord logs now go the
moment the "Desync detected" popup appears. No server change: the server stays at
**1.0.13**. Both players must be on dev78, because when a hosted mod's callbacks run,
and what a checksum packet carries, change.

### What dev77's capture showed (room VOYY, 1-1 to 4-2)

- **The lily pads and the ON.LEVEL order held.** Every floor from 1-1 to 4-1 matched on
  both machines, the swamp included, and the two `level order` lines agreed on every
  floor.
- **The first 1-1 after a restart desynced on its pet.** The first run ended at
  15:23:31 and the next 1-1 was built at 15:23:32. The peer had put its own pet setting
  back when the run ended, and the host's next broadcast (every two seconds) had not
  arrived: `gen[pre] ... pet=0` on the peer, `pet=2` on the host, a dog against a
  hamster, `FLOOR DESYNC seq=1`. The run after that matched.
- **4-2 desynced 45 seconds in** (`POSITION DESYNC` at 23:3000 on the host, 23:3120 on
  the peer). Player 2 had died on 4-1 and started 4-2 as a ghost, with a coffin on the
  floor. By the alarm player 2 had a body again on both machines: alive with 3 HP on the
  host, dead on the peer. The log has no event at the moment the two parted. What it
  does have is the profile:
  - the host's own POST_UPDATE callback ran 563 times in one ten-second window, once per
    simulated frame (the lockstep clock moved 563), and its GAMEFRAME profiler ran 600
    times in the same window. **GAMEFRAME fires on frames the lockstep gate holds.**
    The engine's frame counter moves on those frames, and GAMEFRAME fires on any frame
    it moved. Until now the code assumed it did not.
  - the mod's GAMEFRAME callbacks ran at that rate as well: 2.5's
    `custom_entities.lua:599` made 600 calls in that window. That is about forty calls
    more than the world moved on the host, and twenty-five more on the peer. The peer's
    machine was the slower one, so the host waited on it more.
  - hosted ON.FRAME callbacks have always been moved to GAMEFRAME. Unhosted, ON.FRAME
    fires only when `time_level` moves, which a held frame never does. Moved, they got
    the held frames too.
  - so anything 2.5 changes from a GAMEFRAME or ON.FRAME callback, or from a global
    timer (which counts the same frame counter; 2.5 registers one per floor), changed a
    different number of times on each machine. The log cannot say which callback it
    was. All of them are fixed below.
- **Then the stall.** The host had reached the transition after 4-2; the peer was still
  on 4-2. The stall detector resync-warped both to 4-3. The transition barrier on the
  host took its own warp's screen change for the host walking out of the door, and held
  it, waiting for a "ready" from the peer, which had never reached the transition. The
  peer built 4-3 and waited on the host's inputs; the host stood on the transition for
  the barrier's full 20 seconds, and the players left the run.

### Fixed: the mod's per-frame code no longer runs on frames where the world is paused

All of this applies in a room only. Playing alone there are no held frames, and
nothing changes.

- **A hosted mod's GAMEFRAME callbacks are skipped on a frame the gate held**, like its
  PRE_UPDATE and POST_UPDATE since dev75. ON.FRAME callbacks are still moved to
  GAMEFRAME, as they always were, and skip those frames too.
- **A hosted mod's global timers count only the frames the world moved.** Each
  `set_global_interval` and `set_global_timeout` is the engine's own interval, polled
  each frame the counter moves. Held frames do not count. With nothing held it fires
  where the engine's would: an interval at once and then every `frames`, a timeout
  once after `frames`. Clearing it by id, returning false to end an interval, and the
  floor block's count of what the mod registered work as before.
- **The lockstep gate decides each update before any of a hosted mod's PRE_UPDATE code
  runs.** The engine runs PRE_UPDATE callbacks in its hash order, and the ids that order
  comes from differ between machines. VOYY's host registered one more callback than the
  peer while the first floor loaded, and every id after it shifted. A mod's PRE_UPDATE
  callback that came before the gate's read the last update's decision: it ran on the
  first frame of every stall and was skipped on the frame the world moved again. It
  also read the input slots before the gate had written the agreed inputs, so slot 1
  held this machine's own pad. Now whichever comes first, the gate's callback or one of
  the mod's, runs the gate; the rest of the update reuses that decision. modHost wraps
  each hosted PRE_UPDATE callback in `InputSync.gateFirst`. An update ends at
  POST_UPDATE, or at BLOCKED_UPDATE when it was held. If neither arrives, a callback
  that runs a second time marks the next update. A mod that blocks the update from
  PRE_UPDATE still blocks it.

### Fixed: stuck on the transition after a resync

The transition barrier lets our own warps go. A resync, a run start or the trip back
to camp sets `suppressWarpUntil` before it calls `warp()`. While that window is open,
leaving the transition is not a door anyone took. The hold is released and the warp's
screen change stands. The barrier used to put back the door's screen change, which
would cancel the warp. No "ready" is sent either: a machine still holding on that
transition leaves when its own warp arrives, not through its door ahead of it, which
would build the floor twice.

### Fixed: a quick restart built 1-1 with the wrong pet

A peer keeps the room host's pet style from one run to the next while it stays in that
room, and adopts it again before each floor is built. Leaving the room puts the
player's own back, by whichever way they left.

### Fixed: the first input after a stall could be an old one

The late input guard, which folds a mod's write to our input slot into the shared
stream, runs on GAMEFRAME, so it ran on held frames too. Nothing is injected on those
frames. The guard found its own leftover in the slot, without the injection's marker,
and took it for a mod's write. On a machine whose player is not in slot 1, the first
input recorded after every stall was then an older one of ours instead of the pad's. It
now skips held frames.

### Desync logs go to Discord at the popup

- **When the "Desync detected" popup appears, this run's log goes at once**, for a
  player who switched on AUTOMATICALLY SEND LOGS. The room is asked for theirs too.
  Another machine waits up to five seconds for its own popup, so its log has its own
  `POSITION DESYNC` block, then sends. Each floor's desync is sent once per machine.
- While the run goes on, the upload is paced, about thirty parts a second (some
  30 KB/s), so it does not crowd out the lockstep inputs. After the run it goes at full
  speed.
- A FLOOR DESYNC, which only the peers see and which has no popup, still sends the run
  when it ends. So does a report from the room that never became a popup here. The
  resync warp after a popup does not send the run a second time; a new desync after it
  does.
- Our own `desyncseen` report coming back from the server (it sends every event to
  everyone, the sender too) is no longer counted as another player's.

### The checksum, compared on both machines and explained

- **The machine that was behind never compared.** `sendChecksum` stored its own hash
  over an entry where the other machine's had already arrived, and threw that away. So
  only the machine ahead could see a desync. Now whichever side arrives second compares.
- **A checksum carries what went into it**: each player's position, health, layer and
  mount, the level's frame, and the ten engine PRNG streams. The first three mismatches
  of a floor are logged with both machines' values for the SAME simulated frame:
  `CHECKSUM MISMATCH at 23:2760 (streak 1): here t=... p1 ...; p2 ... | there ... |
  prng streams differ: c3`. Until now a desync left a pair of hashes and the positions
  printed at the alarm, 240 frames later and at a different frame on each machine.

### Known, not fixed

- **Callbacks of the same kind still run in the engine's hash order**, and the ids it
  hashes differ between machines. Where two of a mod's callbacks on the same event
  depend on each other (both drawing from one stream, or one reading what the other
  moved), the two machines can still disagree. dev77 fixed this for ON.LEVEL only.
- **A hosted mod's render callbacks** (GUIFRAME, the draw-depth callbacks, entity render
  hooks) run once per rendered frame, a different number of times on each machine. If a
  mod changes the world from one of them, nothing here can make that deterministic.

### Tests

New: `tests/test_lockstep_hosting.py` (gateFirst on hosted PRE_UPDATE only, spawn hooks
keep every argument, global timers in solo and with stalls, timeouts once even when
they throw, clearing by id, the floor block's count, nothing added with the
determinism layer off), `tests/test_checksum_detail.py` (both sides compare, both
machines' values on a mismatch, three lines a floor, the alarm sends the log),
`tests/test_pet_style.py` (the host's pet kept across runs in a room, dropped on
leaving or in another room). Added to: `tests/test_held_frames.py` (GAMEFRAME and
ON.FRAME as the capture shows them, the gate decided once per update whoever asks, the
late guard on held frames), `tests/test_transition_barrier.py` (our own warp is never
held, a hold in place lets it through and keeps its screen change),
`tests/test_log_ship.py` (the popup's log goes at once, the room's follows, once per
floor, paced mid-run, the run end only for something new). 1045 passing, 1 skipped,
under Lua 5.4 and 5.5; the server suite passes unchanged.

## 2.0.0-dev77

The swamp's lily pads are back online, and the next crash will say where it was. No
server change: the server stays at **1.0.13**. Both players must be on dev77, because
what a hosted mod sees at ON.LEVEL, and the order it sees it in, changes.

### What dev76's capture showed (room FVJF, 1-1 to 4-2)

- **Every floor matched.** All 11 floor digests were the same on both machines: no
  `FLOOR DESYNC`, no `POSITION DESYNC`, no resync.
- **The water was the same on every wet floor** (2-1, 2-2, 2-3, 3-1 and 4-2): the
  liquid and the water-surface effects, to a hundredth of a tile and in the same order,
  at generation, at ON.LEVEL and at the first frame. The two logs' surface lists are
  identical, line for line.
- **2-1 read `SETTLING`, and it was not the water.** 2.5 asked twice for surfaces at
  ON.LEVEL. The host's first query got all 117 and its second none; the peer's first
  got none and its second all 117. The host's fingerprint is exactly the peer's times
  1000003, which is one full answer followed by an empty one instead of the other way
  round. dev76's verdict had no word for that, and fell through to `SETTLING`.
- **Why the order differed.** Overlunky keeps a script's callbacks in a
  `std::unordered_map` keyed by callback id, and fires them in the map's hash order,
  not the order they were registered in. The ids come from one counter, shared by
  Modded Online's own callbacks and the mod's, and 2.5 registers its hooks again every
  floor. Two machines that registered different things on the way to a floor (the
  host sat in the camp twice) give the same mod's callbacks different ids, and the map
  runs them in a different order.
- This is very probably what BGNY's 2-1 (dev75) was too: the pads drew from
  `PROCEDURAL_SPAWNS` after a different set of callbacks on each machine. dev75's
  ON.LEVEL anchor already closed that off, so hiding the surfaces was never needed.

### Fixed: the lily pads

Both changes apply in a room only; playing alone is unchanged.

- **A hosted mod's ON.LEVEL gets the engine's own water surfaces again**, so 2.5's swamp
  lily pads, and the HD mod's lily pads and the frogs on them, are back online. The
  probe still watches what each ON.LEVEL query returns.
- **A hosted mod's ON.LEVEL callbacks run in the order the mod registered them, on every
  machine.** Whichever the engine reaches first runs them all, in that order, and the
  rest return when the engine reaches them. The anchor keeps one callback's random draws
  from moving another's; the order keeps what one spawns (the pads) from being seen by
  another on one machine only. Where the engine's own behaviour depends on the map, the
  batch gives one answer on every machine:
  - a callback cleared during the pass, by one that ran before it, does not run;
  - a callback registered during the pass first runs on the next floor;
  - a bare `clear_callback()` clears the callback that made it, not the one the engine
    is running the pass from. One made inside an engine callback nested in it, such as
    an entity hook a spawn set off, is left to the engine, as before;
  - an error in one callback does not stop the others. It is raised when the engine
    reaches the callback that threw, so Playlunky still shows it;
  - each callback's return value is handed to the engine at its own turn.
- **The probe's ON.LEVEL look is taken inside that batch**, before the first of the
  mod's callbacks, because the engine can reach the probe's own callback after them.
- **A value that cannot be called is passed to the engine as it came.** It used to be
  wrapped in a function, which hid the mistake until the event fired and then raised
  the error from inside our wrapper.

### The probe

- **Two new verdicts.** `QUERY ORDER`: the same answers, but the mod's queries came in
  a different order, so its ON.LEVEL callbacks ran in a different order. `QUERIES`: the
  same water, and the mod asked for different things. FVJF's 2-1 now reads `QUERY ORDER`.
- The `water:` line says `seen` where it said `hidden`, and adds `any`, a fingerprint of
  the mod's answers that does not depend on the order of its queries.
- **A `level order:` line in each floor block** names the hosted ON.LEVEL callbacks in
  the order they ran. A non-host logs `ON.LEVEL ORDER seq=N: DIFFERENT` when its order
  is not the host's. In dev77 that can only happen if the mods registered them
  differently, and the two `level order` lines then show where.

### The friend's error on 4-1 and crash on 4-2

What the peer's files say:

- **4-1, 14:15:45** (spelunky.log): `Lua Error: Mod: fyi.modded-online-loader / Error:
  attempt to call a number value`, with an empty stack traceback. A hosted mod runs in
  our script, so its errors carry our name. An empty stack means the engine called the
  value itself: no Lua function was on the stack, so none of ours was. Something had
  registered a number where the engine expected a callback.
- **4-2, 14:16:36** (crash_frame.txt): `OUT mod determinism.lua:1042 | sim 21:115`. The
  last traced callback was one of the hosted mod's update callbacks, and it returned.
  The process died after it, in the engine's own update or rendering, outside any of
  Modded Online's code and outside every traced callback. `determinism.lua:1042` is the
  held-frame wrapper, so the trace could not say which of 2.5's ~200 update callbacks
  it was.

Neither is something this build can fix directly; the trace shows the crash was in the
engine, not here. What it changes is that the next one names itself:

- **The crash trace and the profile name the mod's own function**, not the
  `determinism.lua` wrapper around it. The ON.LEVEL batch marks each callback as it
  runs it.
- **The hosted mod's timers, spawn hooks and tile-code hooks go through the same
  wrapper** as its `set_callback` callbacks, so the trace and the profile see them too.
  Inside them our callback depth is now zero: a spawn hook set off by a spawn of ours
  used to run at our depth, where the mod's own bare `clear_callback()` was refused.
- **A hosted callback's error goes in the desync log**, the first from each callback in
  full with its stack, then one line every few seconds: `*** HOSTED MOD ERROR in
  file.lua:line: ...`. Playlunky still gets the same error.
- **`errorf` lines go in the desync log** as `*** ERROR: ...`, held until a run opens
  the log. A refused teardown, a skipped texture and the rest were printed only with
  ENABLE DEBUG MESSAGES on, and never logged.
- **A callback the engine cannot call is named when it is registered**: the API, the
  value, and the event, once per API.
- **The previous session's `crash_frame.txt` is reported correctly.** It used to be read
  after this session's first mark had overwritten it, so every header named the new
  session's first GUI frame. The FVJF peer's header says exactly that,
  `IN  guiframe:netCore | sim 0:0 | 14:05:36`, at 14:05:36. A session that traces now
  also keeps `crash_frame.prev.txt` and `crash_notes.prev.txt`, so a relaunch no longer
  destroys the evidence.
- **The hosting summary reaches the log**, including every texture the mod asked for
  and did not get. The peer's spelunky.log has 2.5 saying `Unknown texture definition
  key: swamp-king` on every swamp floor, and nothing of ours could say whether we had
  refused it.
- **Each floor block lists what the hosted mods registered since the last floor**, by
  kind (`set_callback +48, set_timeout +2`).

### Fixed: a mod could not clear its own global timeout

`set_global_timeout` was missing from the registration APIs the sandbox counts as the
mod's, so a hosted mod clearing one of its own was refused as though it had reached for
one of ours, and the timeout fired anyway.

### Known, not fixed

- **Every other callback kind still runs in the engine's hash order**: PRE_UPDATE,
  POST_UPDATE, GAMEFRAME, POST_LEVEL_GENERATION and the rest, ours and the mod's alike.
  Registering first never meant running first. One consequence: a hosted PRE_UPDATE
  can run before the lockstep gate's, and read the previous frame's held state.
- **`set_global_timeout` and `set_global_interval` count engine frames**, which advance
  during stalls and loading, so a hosted mod's global timer fires at a different
  simulated moment on each machine. The new per-floor registration line shows whether
  2.5 uses them.

### Tests

`tests/test_level_order.py` (new): two engines that reach the callbacks in different
hash orders run them in one; each runs once a floor; solo play keeps the engine's
order; the probe looks first; a bare clear lands on the callback that made it, through
the real host and registry too, but not when it is made inside a nested engine
callback; clears and registrations during the pass; errors and return values; the trace
names each callback.

`tests/test_error_lines.py` (new): `errorf` and SafeCall in the log, once each; hosted
errors logged under the mod's own name and still raised unchanged; the previous
session's trace survives this session's first mark; global timeouts can be cleared;
a non-callable callback is named once.

`tests/test_water_probe.py` and `tests/test_swamp_wheel_desync.py` are rewritten for the
surfaces coming back: the mod sees them, two machines with the same water grow the same
pads and keep the same coin, and FVJF's own 2-1 numbers read `QUERY ORDER`. Breaking the
new code on purpose (no batch, the wrong bare-clear answer, swallowed errors, the probe
looking late, the surfaces hidden again, an order-dependent fingerprint, the global
timeout unregistered, the previous mark read late) is caught every time.

## 2.0.0-dev76

A measurement build, so the lily pads can come back. Gameplay is exactly dev75's: in
a room, a hosted mod's ON.LEVEL still sees no water-surface effects, so 2.5's swamp
still has no lily pads online. No server change: the server stays at **1.0.13**.
Both players must be on dev76 for the two machines to be compared.

### Why measure

dev75 hides the water-surface effects at ON.LEVEL because the two machines can
disagree about them. Whether the lily pads can come back without that trade-off
depends on how they disagree, and nothing in the logs so far records the water:

- **MATCH:** they no longer do. The 2-1 difference came from the random-number
  streams, which dev75's ON.LEVEL anchor already sealed, and the hiding can go.
- **ORDER:** the same surfaces, listed in a different order. Sorting the answer
  brings the pads back unchanged.
- **SETTLING:** different when the mods look, the same by the first lockstep frame.
  Waiting for the water to settle brings them back.
- **DIFFERENT:** still different at the first frame. Only the world host's
  waterline, sent to everyone, can fix that.

### What it records

On every floor with water, in a room, each machine fingerprints the liquid and the
water-surface effects:

- **at generation,** before the mod's own post-generation hooks;
- **as ON.LEVEL begins,** ahead of every callback the mod registers. It looks twice,
  a few milliseconds apart: anything that changed in between was changed by another
  thread while Lua held the main one;
- **as the mod's own queries see them:** every query the dev75 filter answers, an
  empty one included, in the order the engine listed the surfaces;
- **as the gate engages,** on the first lockstep frame.

The fingerprints travel with the floor digest. Each floor block in the desync log
gets two more lines: `water:` with every fingerprint, and the list of surfaces as the
engine gave them. A player who is not the world host also gets one verdict line per
floor with water, comparing their machine with the host's:

    WATER PROBE seq=9: MATCH: the mod would have seen the same surfaces on both machines | ...

The verdict is about what the mod asked for. 2.5 asks for the front layer only, so a
back-layer surface that differs is shown in the line but does not change the verdict.

The probe only reads: no random-number draw, no spawn, no write to any entity. It
does nothing in solo play.

### Tests

`tests/test_water_probe.py`, on modelled machines:

- the four verdicts, and a dry floor saying nothing;
- the verdict follows what the mod asked for;
- every point is recorded, the probe looks before the mod does, and an empty query
  counts;
- water moving while the mods look is caught, and a clock that never advances
  cannot hang the load;
- each floor starts afresh, two hosted mods share one probe, and solo play is not
  measured;
- the probe draws nothing and changes nothing;
- the joining player says each verdict once, whichever report arrives first; the
  world host never judges itself; a host without water on its report is not judged.

`tests/test_floor_block.py`: the water lines go inside the floor's block. 18
deliberate breaks of the probe are each caught, and dev75's 29 still are.

## 2.0.0-dev75

The 2.5 swamp desync. In room BGNY (on dev73), the two machines built different shops
on 2-1: one kept the dice house, the other turned it into 2.5's new Wheel of Fortune.
No server change: the server stays at **1.0.13**. Both players must be on dev75,
because what a hosted mod sees at ON.LEVEL and on a stalled frame changes, and the
two machines have to agree on it.

### What the capture showed

- **1-1 to 1-4 matched,** and 2-1 generated identically: the seed and all ten PRNG
  streams were equal at `gen[pre]` and `gen[post]`.
- **At the first frame of 2-1, the floors differed in four entity types:**
  - the host: `ITEM_DICE_BET`=1, `ITEM_DIE`=2, `ITEM_CONSTRUCTION_SIGN`=1, `ITEM_LEAF`=7;
  - the peer: `ITEM_DICE_BET`=0, `ITEM_DIE`=0, `ITEM_CONSTRUCTION_SIGN`=2, `ITEM_LEAF`=8.
- **That is the Wheel of Fortune.** Converting a dice shop removes the bet machine and
  both dice, and adds an invisible construction sign (`hooks/wheelOfFortune.lua`). The
  peer had a Wheel House; the host still had the dice game.
- **Then:** a `POSITION DESYNC` at `9:2760`, a `FLOOR DESYNC` on 2-2, and a resync warp
  to 2-3.

### Why the shop differed

Whether a dice shop becomes a wheel is a coin, `prng:random_int(0, 1,
PROCEDURAL_SPAWNS)`, flipped on the first playable POST_UPDATE. The hook reads
nothing machine-dependent. The stream it draws from had already moved, and the extra
`ITEM_LEAF` says where.

- **2.5's swamp lily pads are `ITEM_LEAF`** (`hooks/swamp/water.lua`), placed at
  ON.LEVEL on the engine's `FX_WATER_SURFACE` effects.
- **Those effects are not part of the generated world.** The liquid system makes them
  after generation, out of water its worker threads are already moving; the HD mod's
  author pinned them to between POST_LEVEL_GENERATION and ON.LEVEL. So at ON.LEVEL
  the two machines hold different sets of them.
- **Each one costs draws on `PROCEDURAL_SPAWNS`.** The pads shuffle every surface
  effect (one draw each) and roll a one-in-five chance on each well-spaced one. One
  more surface effect on the peer meant one more pad, and a moved stream for
  everything drawn after it.
- **The coin is drawn from that same stream.** `PROCEDURAL_SPAWNS` is class 0, the
  level-generation stream, so the coin landed the other way.

This is the gap HANDOFF section 10 left open: dev65's snapshot answers `is_liquid_at`,
and these are entities. The HD mod's procedural lily pads, and the frogs it puts on
them, read the same effects.

### Fixed: what a hosted mod sees at ON.LEVEL

Both changes apply in a room only; playing alone is unchanged.

- **No water-surface effects during ON.LEVEL.** Inside a hosted mod's ON.LEVEL
  callbacks, `get_entities_by`, `get_entities_by_type`, `get_entities_at` and
  `get_entities_overlapping_hitbox` leave `FX_WATER_SURFACE` out. Every machine sees
  none, and builds the same floor. Gameplay, and every other callback, still gets the
  engine's own answer.
  - The cost: no swamp lily pads in 2.5 online, and in the HD mod's jungle no
    procedural lily pads or frogs on them. Both are decoration.
  - A query that cannot return them (another type, or a mask without `MASK.FX`) is
    passed straight through.
- **ON.LEVEL is anchored,** as POST_LEVEL_GENERATION already was. Each hosted ON.LEVEL
  callback starts from the floor's lockstep-identical base, and the engine's streams
  are put back afterwards, so nothing after it can tell what it drew. On this capture
  that alone would have kept the coin the same.
- **An anchor restores the streams even when its callback throws.** It used to skip
  the restore and leave our seed in force for the rest of the floor.

### Fixed: the wheel would turn on frames that did not happen

Found reading the wheel's code, not in the capture: nothing in it shows anyone using
the wheel.

ON.PRE_UPDATE and ON.POST_UPDATE fire once per rendered frame. That includes every
frame the lockstep gate holds the world still while it waits for the other machine.
The engine does not tick on those frames, but a hosted mod's callbacks still ran on
them, and how many there are depends on each machine's network.

- **2.5's wheel turns one step per POST_UPDATE,** so on the machine that stalled more
  it would stop, and pay out or open the prize cubby, on an earlier frame.
- **The same shape is elsewhere in 2.5:** the swamp's three-second water-poison count,
  the push the monkey propeller adds before physics, and every `everyNthFrame`
  wrapper.
- **Now** a hosted mod's PRE_UPDATE and POST_UPDATE callbacks are not called on a frame
  the gate held (`InputSync.heldFrame()`), for the same reason ON.FRAME has long been
  moved to ON.GAMEFRAME. Every other frame is untouched, including the engine's own
  pauses, which the mod sees and handles itself.

### Fixed: the menu pause through a fade

Also found reading the code. The gate clears the local menu pause (a player in their
pause menu, or tabbed out) on its own frames, so the shared world keeps running. It
never did during a fade. A tabbed-out player would still have the flag up on the frame
a level finishes fading in, and that frame's POST_UPDATE is where the wheel decides,
gated on `pause == 0`: that machine would decide a frame later, from a different
stream. The flag is now cleared during a run's fades too. Only that flag: the engine's
own fade pause stands.

### The floor block shows the streams at engage

Each floor's block in the desync log now has a `prng:` line, with all ten streams as
the gate engaged, in the `gen[...]` lines' form. `gen[post]` shows generation drew the
same on both machines; this shows whether everything after it did too. On this
capture the two would have disagreed while `gen[post]` matched, pointing straight past
the level generator.

### Tests

- **`tests/test_swamp_wheel_desync.py`:** the 2-1 capture, on two machines that differ
  only in their waterline, with a PRNG that keeps real state. Over 120 seeds they build
  the same shop every time; without the fix the coin lands differently on more than a
  sixth of them. Also covered:
  - every way of asking for the effects;
  - a query that cannot hold them is not touched;
  - solo play is unchanged;
  - the once-a-floor log line;
  - an answer that comes back as a container rather than a table, and one that
    cannot be read at all;
  - a throwing callback;
  - the anchor's base does not depend on callback order.
- **`tests/test_held_frames.py`:** a machine that stalled turns the wheel no further
  than one that did not; PRE_UPDATE is shielded too and keeps its return value; the
  gate's `heldFrame()`; the menu pause through a fade, run against the shipped
  `preUpdate`.
- **`tests/test_floor_block.py`:** the `prng:` line.

29 deliberate breaks of the above are each caught.

## 2.0.0-dev74

The camp lobby's puppets, working. In dev73's first test with two players, neither
player saw the other at all. No server change: the server stays at **1.0.13**.

### Fixed: no puppet packet was ever sent

The sender read our spelunker's position with `local x, y = p:get_absolute_position()`.
That call returns one Vec2, not two numbers, as eventSync's `playerWorldPos` already
reads it (`abs.x, abs.y`). So rounding the "x" was arithmetic on a Vec2, which failed
inside the `pcall` around the read on every frame.

- **Nothing was ever sent,** so nobody received anything and no puppet was ever
  spawned.
- **Nothing said so:** the failure was swallowed, and the camp comes before any run's
  log exists.
- **Why the tests passed:** the test stub's `get_absolute_position` made the same
  mistake. It now returns a Vec2, as `spel2.lua` declares (`fun(self): Vec2`). The
  real position is read from it, falling back to `x`/`y`.

### Never quiet again

- **What is said once a session,** to the desync log (held until the next run's
  header) and the menu probe's log:
  - `camp puppets: first packet sent`;
  - `first packet from slot N`;
  - `puppet up for slot N at (x, y)`;
  - a failed read or spawn, with the error.
- **Never a flood:** a puppet is spawned for the same player at most once a second,
  whatever goes wrong, so the camp can't fill up with rocks.
- **Recognising our puppets:** the marker in a puppet's `user_data` is checked only
  where it reads back at all, so a build where it doesn't can't make every puppet look
  like a stranger.

### Tests

`tests/test_camp_puppets.py`:

- the stub's position is a Vec2;
- the absolute position is what gets sent;
- a failed read is logged once;
- the firsts are logged;
- no respawn flood.

Four more deliberate breaks are each caught: dev73's own read, sending the relative
x/y, no respawn limit, and a failed read kept quiet.

## 2.0.0-dev73

The other players in the camp lobby. No server change: the server stays at
**1.0.13**.

### Everyone in the camp, before the run

Until now the camp was each player alone: the run is in lockstep, but the camp isn't,
so a room of four showed each player only their own spelunker until the host started
the run. Now every player in the camp sees the others there:

- climbing down the entry rope when they arrive;
- walking, jumping and climbing about the camp, facing the way they face;
- in their own character, with their name above them.

New `src/campPuppets.lua`. Each machine sends where its spelunker is and how it is
posed, and every other machine in the camp draws that player as a PUPPET.

**A puppet is a picture, not a player:**

- **What it is:** an item (`ITEM_ROCK`) wearing the player's character sheet, posed
  with their animation frame, at the player's size and draw depth.
- **What it can't do:** its physics are paused, and it passes through everything. It
  can't be picked up, whipped, stomped or hurt.
- **What can't see it:** it is in no player list, so the HUD, the camera, the camp's
  NPCs, the door ready-check and the hosted mods' player hooks don't see it.
- **What it doesn't show:** held items, the whip and back items. It's the body only.

**The stream:**

- **The channel:** packets go on the unreliable world channel, which the server
  already relays to the room in the lobby. No server change. The reliable event
  channel isn't used: it keeps every event for the life of the room, and positions
  would grow it without end and stall the chat behind them.
- **What and how often:** position, animation frame, facing, layer and character, up
  to 20 times a second while something changes. While a player stands still, a
  keepalive every 0.4 s. Positions are rounded to 1/100 of a tile.
- **The other end:** the puppet follows smoothly, and snaps across anything over 3
  tiles (a teleport). It is taken away when its player leaves the camp (they say so),
  leaves the room, or hasn't been heard from for 3 s.
- **Paused games:** sending is done from the GUI frame, so a player with their pause
  menu open keeps their puppet up on everyone else's screen.
- **Layers:** a player in the camp's other layer is out of sight, along with their
  name tag.
- **Name tags:** drawn in the game's font, with the old look as the fallback, like the
  rest.

### The run is never touched

Puppets exist only in the camp, outside any run:

- None is spawned while the camp fades.
- They're destroyed in the camp the moment the run starts, before its first level
  exists.
- They're forgotten when the camp is torn down (PRE_LEVEL_DESTRUCTION, a screen
  change), without touching an entity, because their uids are about to be given out
  again.
- A puppet's uid is checked every update to still be one of ours: the entity type and
  a marker in its `user_data`. A uid the engine has recycled is never written to.
- The camp already differs on every machine (each one's own movement, save and NPCs),
  so this adds nothing new for the run start to reset.

### netCore

`Network.onWorldKind(kind, handler)` takes one kind of world datagram ahead of the
general handler, so the puppets don't go through the run's world-sync code.

### Tests

`tests/test_camp_puppets.py` (new) checks:

- **sending:** what is sent, at most 20 a second, the keepalive, never outside the
  camp lobby or in a run, the "gone" packet;
- **the puppet:** spawned in the right sheet, size, depth, frame and facing;
  untouchable; following smoothly and snapping across a teleport;
- **the layer:** out of sight from the other one;
- **removal:** the stale, departed and gone cases; no puppet of ourselves; an unknown
  character drawn as Ana;
- **the run:** no puppet outside the camp or during the fade, destroyed as the run
  starts, a torn-down camp leaving no handle on its uids, a recycled uid never written
  to;
- **the rest:** the name tag above the puppet, and netCore's routing of the datagram.

Fifteen deliberate breaks of the new code are each caught by at least one test.

## 2.0.0-dev72

The MODDED ONLINE menu in the main menu's own font. No server change: the server
stays at **1.0.13**.

### The main menu's font and casing

The main menu draws Play, Online, Options and the rest in the game's italic style,
in Title Case. The MODDED ONLINE menu and its popups now do the same:

- **The font:** every line of the page and its popups is in the italic style: the
  title, the rows, their values, the text fields, the hints and the popups' text. The
  sizes are unchanged.
- **The casing:** the rows, their values and the popups' buttons are in Title Case,
  as the main menu writes its own. "HIDE ROOM CODE  OFF" reads "Hide Room Code  Off",
  and "I UNDERSTAND" reads "I Understand".
  - "IP" and "OK" stay in capitals.
  - A value with lowercase in it is left as it is ("1 file(s) synced").
  - The title on the scroll stays in capitals, as a heading.
  - The popups' titles are drawn as written ("Restart Required").
- **Unchanged:** the camp plaque, WAITING FOR PLAYERS, the character-select room
  code, the run status line and chat keep the bold upright style, which is what the
  game uses in a level.
- **The old look** (the fallback) is unchanged, in capitals.

### Tests

`tests/test_vanilla_ui.py` checks that the menu and popups are in the italic style,
that the in-level text is bold, and the Title Case rules. Three more deliberate
breaks are each caught: the menu back in bold, no Title Case, and the popups'
buttons in capitals.

## 2.0.0-dev71

The game's look at the right size. dev70's first screenshots showed everything drawn
correctly, and every line of text about 1.7 times too big. No server change: the
server stays at **1.0.13**.

### Fixed: the text was 1.7 times too big

vanillaUI measures the game's font once, from the quads the game lays out for an "H".
Those quads are tight around the capital, so what they give is the height of a
capital. dev70 took it for the whole glyph cell (the line height) and sized every line
for that. "MATCHMAKING", asked for at 44, had capitals 45 px tall.

Every size is now the height of a capital, in 1080p pixels, taken from the mockup the
layout was drawn on:

- the title on the scroll: 44;
- the rows and their values: 24 (25 for the selected row);
- the button hints: 22;
- popup text: 22, with the title at 32 and the buttons at 25;
- the camp plaque: 20, 15 and 17;
- chat: 17;
- the run status line: 15.

The vertical centring was already right and is unchanged.

### Fixed: the hints ran into each other

On SETTINGS, "LEFT / RIGHT  Change" was drawn over both "ESC / B  Back" and "Z / A
Select". The middle hint now gets the space between the other two and is shrunk to fit
it.

### Fixed: arrows on SYNC SAVE DATA

The gold arrows were drawn on any selected row with a value. SYNC SAVE DATA has a
result to show but nothing to step through. They now appear only where LEFT and RIGHT
change the value, and a value without them gets more room ("1 file(s) synced" was
squeezed small).

### Plaques fit their text

The camp plaque, WAITING FOR PLAYERS and the character-select room code are as wide as
their widest line, within limits, instead of a fixed width.

### Tests

`tests/test_vanilla_ui.py` checks that sizes are capital heights, that the middle hint
stays between the other two, that the arrows only appear on rows that change, and that
a plaque grows with its text. Forty-four deliberate breaks of the menu work are each
caught by at least one test.

## 2.0.0-dev70

The MODDED ONLINE menu now looks like the game's own OPTIONS screen. So do its
popups, the camp plaque, the character-select room code, the run's status line and
chat. No server change: the server stays at **1.0.13**.

### The look

Everything is drawn with the game's renderer (`set_post_render_screen`,
`ON.RENDER_POST_HUD`), from the game's own menu sprite sheets, in the game's font
(new `src/vanillaUI.lua`):

- **The menu page:**
  - the OPTIONS screen's layered brick walls (`menu_generic`, `menu_brick2`,
    `menu_brick1`);
  - the wood panel along the top, with the parchment scroll across it carrying the
    page's title;
  - the rows on the dark wall, the selected one on the red options bar;
  - a setting's value between the gold arrows, and text fields in the game's
    text-entry bar;
  - the ringed bottom panel with the button hints, and the connection status or
    error in its middle.
- **Popups:** the game's wood-framed panel, drawn in nine pieces so its border keeps
  its size at any height, with a gold title, the text wrapped to the frame and the
  buttons on the red bar.
- **Plaques:** the camp's room plaque, WAITING FOR PLAYERS and the character-select
  room code are drawn on the game's dark torn box. The status line and chat get a
  shadow over the game, and the line being typed sits in the text-entry bar.
- **The page fades in** over 0.15 s when it opens.

Where it comes from:

- **The sprite rectangles** were measured on the sheets themselves, extracted from
  `Spel2.exe` with the new `tools/extract_menu_sheets.py`.
- **The sheet sizes** are the ones the menu probe read back in game. If a sheet
  isn't that size, for example because a texture mod laid it out differently, the
  old look is kept and the log says which sheet.
- **The text:** the script API doesn't say whether the y given to `draw_text` is the
  top, middle or baseline of the text, so it's measured once from the glyphs the
  game lays out, and every line is centred on its row with that.

### Always a way back

The old look stays as the automatic fallback. It's drawn instead whenever the game's
look isn't actually drawing:

- before the render callbacks have run;
- if they stop;
- for a layer that raised an error. That layer stays on the old look for the session,
  and the error is logged once.

The first vanilla draw of each session is bracketed by a breadcrumb,
`mo_vanillaui.txt`, like modHost's `mo_fatal_calls.txt`. A session that died inside
that first draw leaves `drawing` behind, and from then on the old look is used until
the file is deleted. `mo_novanillaui.on` forces the old look.

### Fixed: the menu closed itself during HOST

In dev69's test, hosting closed the CONNECTING page with `no GUI frame for 7698 ms`.
The whole game had frozen for 7.7 s while the bridge launched, and the first update
afterwards ran before the first GUI frame. The watchdog took that for a menu nobody
could see. It now tells the two apart: a gap in the updates themselves means the whole
game was away, and the menu stays.

### Tests

- `tests/test_vanilla_ui.py` (new) checks:
  - the page is drawn from the right sheets in the right order;
  - the title, the rows, the hints, the moving red bar and the flipped arrow;
  - rectangles cut where they were measured;
  - text centred on its line whatever the font does;
  - long labels shrunk to fit;
  - the fallback before the render calls run and after they stop, and for a failed
    layer;
  - the flag file, a sheet of another size, and the breadcrumb both ways;
  - popups in nine pieces with their text wrapped and unchanged;
  - the camp plaque, the run status line and chat.
- `tests/menu_stub.py`: a recording renderer, texture definitions, quads and a font
  whose glyphs sit somewhere other than where they are drawn.
- `tests/test_menu_takeover.py`: the GUI stopping while the game runs closes the menu.
  The whole game freezing doesn't.

Forty deliberate breaks of the new code are each caught by at least one test: the 27
of dev69, and 13 more of the look and the watchdog.

## 2.0.0-dev69

The fix for dev68's main menu takeover, which switched itself off on the first
press. No server change: the server stays at **1.0.13**.

### Fixed: MODDED ONLINE switched itself off on the first press

In the first test, MODDED ONLINE showed on the main menu. The first press on it
opened something for a moment, then the row read ONLINE again and only the `[O]` key
was left. The desync log said why:

> main menu takeover: OFF -- the game opened its own Online menu after a press that
> was swallowed

That is the self-check working as meant. The mistake was where the press was
swallowed.

- **What dev68 did:** it hid the menu input in PRE_UPDATE and put the device's value
  back at POST_UPDATE. That is right for a transition, which is where inputSync syncs
  it.
- **Why that failed:** the main menu doesn't read its input between those two. Either
  it reads before PRE_UPDATE, so the hiding came too late, or after POST_UPDATE, so
  the put-back value handed it the very press we had hidden. Either way the game's
  menu took the press.
- **Now, the write point:** the input is read and hidden in `ON.POST_PROCESS_INPUT`,
  straight after the game builds it. The script API names that callback as the place
  to edit menu input.
- **Now, no put-back:** nothing is ever put back. Whatever reads the input after
  that, wherever it sits in the frame, reads our zero. The release latch already
  keeps swallowing a button that is still held when we let go, which was the only
  reason for the put-back.
- **Belt and braces:** PRE_UPDATE hides the input again if anything refilled it
  before the update. On the main menu its own direction flags
  (`screen_menu.controls`) are cleared too.
- **A build without POST_PROCESS_INPUT:** PRE_UPDATE does it all, still without the
  put-back.

The case that can't work from where we are is now reported instead of failing
quietly. That is a SELECT on the ONLINE row arriving when the menu is already on its
way to Online, which means the game read the press before our callback ran. It
switches the takeover off with `the game took the press before ... ran`.

### Fixed: the probe's flag file, as Windows names it

The first attempt to arm the menu probe made `mo_menuprobe.on.txt`. Windows Explorer's
New > Text Document does that, and with file extensions hidden it shows as
`mo_menuprobe.on`. The probe looked for the exact name only, so it never armed.
`mo_menuprobe.on` and `mo_nomenuhook.on` now count under either name. `.gitignore`
and the packaging script leave the `.txt` names out too.

### Better failure lines

The self-check's line now says which callback did the swallowing, the menu's state
at the press, and what the menu was doing when the game turned out to have taken it.
For example: `(in POST_PROCESS_INPUT, at menu state 7; 32 ms later the menu was id
0, state 8, moving to 2)`. A second failure would explain itself without a probe
session.

### On the clock

The repeat for a held direction (0.3 s, then every 70 ms) and the takeover's
time-outs now count milliseconds, not calls. How often the input callback runs, per
engine update or per display frame, is not known yet, and the menu should feel the
same either way.

### The probe says where in a frame the menu moves

`mo_menuprobe.on` now also writes down:

- the order its callbacks run in on the main menu, once;
- `menu moved between X and Y`: the two callbacks the main menu's state changed
  between. That is where the menu really reads its input;
- the input refilled before PRE_UPDATE, or changed during the update, if either ever
  happens.

The input it logs is taken in POST_PROCESS_INPUT, before anything of ours touches it.

### Tests

- `tests/menu_stub.py`: the stub's main menu can read its input at any of four places
  in a frame, can linger in its highlight state before moving on, and can have its
  input filled a second time before the update.
- The takeover is tested in every combination of those:
  - SELECT opens our menu and never the game's;
  - BACK never reaches the game's menu;
  - VANILLA ONLINE reaches the game;
  - the input stays hidden while our menu is up.
- Also new:
  - nothing is put back, and the menu's direction flags are cleared;
  - the PRE_UPDATE fallback works;
  - a press taken before our callback is reported, with the [O] chip back;
  - the repeat rate doesn't change with the call rate;
  - the failure line carries its detail;
  - the probe says where the menu moved, and writes the callback order once.

Twenty-seven deliberate breaks of the new code are each caught by at least one test.
The first of them puts the swallow back in PRE_UPDATE.

## 2.0.0-dev68

MODDED ONLINE moves into the game's own main menu, and the menu answers a
controller. It still looks as it did: the game-styled look comes next, once the new
menu probe has measured the game's own sprites in game. No server change: the server
stays at **1.0.13**.

### MODDED ONLINE is the main menu's ONLINE row

The game keeps its main-menu rows in a list the script API doesn't expose, so a row
can't be added. The ONLINE row is taken over instead (`src/mainMenuHook.lua`).

- **The label:** the row reads MODDED ONLINE on the main menu, in the game's casing.
  Everywhere else it's the game's own text: on other screens, in the game's Online
  menu, and once the script is switched off. "Online" (string `0xa1023681`) is used
  nowhere else, so no other text changes.
- **SELECT on it** opens the MODDED ONLINE menu. The press is swallowed before the
  engine's update, so the game's Online menu never opens.
- **VANILLA ONLINE**, the last row of our root page, gives the row back. The label
  is restored and one SELECT on that row is handed to the game, which opens its own
  Online menu. Backing out of that menu brings MODDED ONLINE back. A Modded Online
  room that's still open is left first, with a toast.
- **Which row is ONLINE:** index 1. The strings and the row icons on `menu_basic`
  are both in the order Play, Online, Options, Leaderboards, Player Profile, Quit
  Game. If a press on another row ever opens the game's Online menu, that row is
  used from then on, and the log says so.
- **A language change** reloads the string table and wipes the label. It's put back
  within a second, and the new language's text is what gets restored later.

### When it can't: the [O] chip

The `[O] MODDED ONLINE` chip and the O key are gone, except where the takeover can't
install. Then they come back, and the reason goes to the desync log. That happens
when:

- a piece of the script API is missing: `change_string`, `get_string`,
  `hash_to_stringid`, the main menu's fields, or `ON.PRE_UPDATE`;
- the menu input can't be read or written;
- the game opens its own Online menu after a press we swallowed. This self-check also
  closes our menu, since both menus would answer every press from then on;
- `mo_nomenuhook.on` is in the pack folder. That's the switch to use if the takeover
  misbehaves.

It installs on the title screen or the main menu, never during the logos, where the
string table may not be loaded yet.

### Controllers

The menu and the popups now read the game's own menu input, `game_props.input_menu`
(new `src/menuInput.lua`), so a controller works the way it does in the game's own
menus.

- **Nothing reaches the menu underneath:** while our menu or a popup is up, the input
  is read and then zeroed in PRE_UPDATE, the write point inputSync already uses on a
  transition. The game's menu stays where it was, highlighted on MODDED ONLINE.
  During a run the module does nothing, because inputSync owns the field then.
- **Held directions repeat** after about 0.3 s, counted in engine updates.
- **The keyboard** works as before (arrows, Z, ESC), and ENTER selects too. While our
  menu is up the keyboard is still taken from the game.
- **Closing:** the button that closed the menu is swallowed until it's let go (up to
  a second), so B or ESC can't also send the game's menu back to the title screen.
- **The press that opened the menu** can't pick a row: SELECT and BACK are ignored
  for 0.15 s after it opens.
- **A popup over the camp or character select** also stops the spelunker while it's
  up.
- **A watchdog:** if no GUI frame arrives for 2 s, the menu closes and the game gets
  its input back, so the main menu can never be left deaf behind a menu nobody can
  see.

### The menu

- **No CLOSE row:** BACK closes the menu. The root page is HOST, JOIN, MATCHMAKING,
  DISCORD and SETTINGS, plus VANILLA ONLINE with the takeover.
- **Settings change with LEFT and RIGHT,** like the game's own options. A held LEFT
  or RIGHT changes a setting once. SELECT still works.
- **A CONNECTING page:** hosting, joining and matchmaking used to close the menu at
  once. The menu now waits on a CONNECTING page (with CANCEL), shows the room once
  it's reached (`- ROOM ABCD -`), and closes as the screen fades out for character
  select. An error stays on the page, with BACK.

### Fixed: chat and the popups shared ENTER

In the camp, RESTART REQUIRED could come up while the chat box was open. ENTER then
answered the popup and sent the line at the same time, and T opened the box behind
it. Chat now leaves the keys alone while a popup is up.

### The menu probe (new diagnostic)

`mo_menuprobe.on` arms `src/menuProbe.lua`, which writes `mo_menuprobe.txt` a line at
a time, bounded at 400 lines. It records:

- which script API pieces exist, or the error when one doesn't;
- every MENU_* texture definition;
- the main-menu labels and the button-glyph strings;
- the main menu's state, and the menu input as the engine filled it, as they change;
- the OPTIONS screen's panels: where each sits, and which part of its sheet it shows;
- engine updates per GUI frame, and which render hooks fire on each screen.

Words in the flag file add modes. `draw` puts test text in the game font on the main
menu, and on OPTIONS every MENU_* sheet with the panels outlined on it, for a
screenshot. `capture` checks whether the game still reads the keyboard into the menu
input while the keyboard is taken. HANDOFF section 15 says what to run.

### Tests

- `tests/menu_stub.py` (new, not a test file) is the shared stub. It models the
  engine's update, the main menu, and how the game's menu answers the input its
  update actually read.
- `tests/test_main_menu_hook.py` (new): when a press is swallowed and when the menu
  opens, in every menu state; the label and its casing; the hand-over to VANILLA
  ONLINE and its time-outs; the self-checks; install, and every reason it can fail.
- `tests/test_menu_input.py` (new): edges and repeats; the game seeing nothing while
  our menu is up; nothing written during a run; PRE_UPDATE returning nothing; the
  release latch; the held press that opened the menu; popups in the camp.
- `tests/test_menu_takeover.py` (new) runs the three modules together: opening from
  the ONLINE row, controller and keyboard navigation, VANILLA ONLINE there and back,
  the fallback chip, the self-check, a build where ONLINE is another row, controller
  answers to the popups, LEFT and RIGHT on settings, the CONNECTING page, the
  watchdog, chat against a popup, and the module order in `main.lua`.
- `tests/test_menu_probe.py` (new): inert without the flag, a fresh file per launch,
  errors logged with their text, the line cap and the collapsing of repeats.
- `tests/test_settings_menu.py`: the root page without CLOSE, and ESC closing it.

Twenty-one deliberate breaks of the new code are each caught by at least one test.

## 2.0.0-dev67

Three things for the public test. No server change: the server stays at **1.0.13**.

### ENABLE DEBUG MESSAGES (new setting, off by default)

Every `print()` lands at the top left of the screen. Ours are diagnostics: setup
reports, hosting summaries and error traces. A hosted mod's own debug prints arrive
the same way, because it runs in our Lua state; hdmod's
`message("APPLIED IDOL OWNER ...")` is one. With the new SETTINGS switch off, none
of them show.

- **What it covers:** `main.lua` gates all five functions that print on screen:
  `print`, `message`, `printf`, `prinspect` and `messpect`. `MO_DEBUG` from the
  console still shows everything.
- **Nothing is lost:** the diagnostics still go to the desync log and the boot log.
- **Before the setting is known:** netCore reads `config.json` only after the first
  lines may have printed. Those are held, then shown or dropped once the setting is
  read. If netCore never loaded, they're shown.
- **The one exception:** the warning that a second copy of Modded Online is enabled
  always shows, because nothing else works in that state.
- The SETTINGS page has seven rows now, so they sit slightly closer together. Every
  other page keeps the full spacing.

### Restart Required

Ticking or unticking a mod in Playlunky's options, or pressing "Undo Modded Online's
setup", now brings up a RESTART REQUIRED popup in the menu's style. Before, the only
notice was a printed line, which the new setting now hides by default.

- It shows straight away on any screen except a level or a transition, where it
  would take the keyboard from the game. A change made mid-level waits for the camp
  or a menu.
- It never shows during an online run, because the change itself waits for the run
  to end.
- At a first launch it waits for the first-run popups.
- A change applied at boot (a tick from a session that was closed in the options
  panel) asks too.

### A new first popup

There are four first-run popups now. The new first one says how to set mods up:

> To use modded online, ensure all script mods (other than modded online) are
> disabled. To play a mod, please enable it under playlunky options and restart the
> game.

Players who already answered the popups won't see it. `"firstRunDone":false` in
`config.json` shows them all again.

The first-run popups and the restart notice now share one piece of code
(`popupFrame` in `src/menuUI.lua`). The pause before a press counts re-arms
whenever a popup comes back on screen.

### Removed: the old shim, and the stale tests

Two modules the game hadn't loaded since dev42 and dev44 are deleted:
`src/shimInjector.lua` (the old injected determinism shim, 527 KB) and
`src/optionSync.lua`. The six test files that tested only them went too:
`test_option_sync`, `test_determinism_shim`, `test_shim_boot`, `test_shim_clock`,
`test_world_mailbox` and `test_content_world_state`.

The world mailbox's tests were 8 of the 16 long-standing failures; the other half of
that mechanism left `eventSync` long ago. The other 8 were `tests/test_seeded_run.py`.
It tested the seeded-run flag removed in dev46, whose entry already listed the file
as gone, and it's deleted now too. The suite runs with no failures.

None of this changes anything that runs, because neither module was loaded.
`netCore`'s check for old injected blocks in other mods' `main.lua` stays, because
it matches the markers itself.

### Tests

- `tests/test_debug_messages.py` (new) runs the gate from `main.lua`. It checks
  that:
  - off hides everything, on shows all five printers, and the switch is read live;
  - MO_DEBUG shows everything;
  - early lines are held, then shown or dropped, in order and up to a limit;
  - a hosted mod's prints are gated too;
  - the second-copy warning always shows;
  - the gate is installed before anything can print.
- `tests/test_first_run.py` covers the four popups and the restart notice. For the
  notice it checks:
  - its text and button;
  - that it waits for the first-run popups;
  - where it shows and where it waits;
  - that it never shows during an online run;
  - one notice for two changes, and nothing saved.
- `tests/test_setup_options.py`: ticking, unticking, a change found at boot and the
  undo button all ask for a restart; nothing changing asks for nothing.
- `tests/test_settings_menu.py`: the new switch, its default, and the spacing of
  the seven rows.

Fourteen deliberate breaks of the new code are each caught by at least one test.

## 2.0.0-dev66

A SETTINGS page in the Modded Online menu with two new switches, and three popups
the first time Modded Online starts. No server change: the server stays at
**1.0.13**.

### The first-run popups

The first time Modded Online starts, three popups come up over the main menu, one
after another. They're drawn like the Modded Online menu: the same panel, banner,
rows and footer.

1. **Modded Online 2**: the notice about AI-assisted development, the old version
   corrupting mods, reinstalling them, and reporting bugs to the Modded Online
   Discord. It has one button, I UNDERSTAND.
2. **Automatically Send Desync Errors**: YES switches on AUTOMATICALLY SEND LOGS,
   and NO leaves it off.
3. **Automatically Sync Data**: YES switches on AUTOMATICALLY SYNC DATA, and NO
   leaves it off.

The text is as written. Titles and buttons are in capitals, like every other label
in the menu.

- **Once:** `firstRunDone` in `config.json` is saved after the last answer, and
  they never come back. Each answer is saved as it's given, so closing the game
  half way keeps those answers and shows the popups again from the start next time.
- **The answer is the setting:** NO switches a setting off even if an earlier build
  had it on.
- **Input:** ARROWS move, and Z or ENTER selects. The game's own menu underneath
  doesn't see these keys, and the MODDED ONLINE menu can't be opened until they're
  answered. A press in the first 0.6 s after a popup appears is ignored, so mashing
  through the notice can't answer the next one unread. The keyboard stays blocked
  for 0.3 s after the last answer, so that key press doesn't reach the game's menu.
- **Layout:** the panel is the menu's own width, as tall as its content, and
  centred. The text is 24 point, wrapped to the panel by measuring it, and steps
  down a size if it wouldn't fit the screen. A title too long for the banner steps
  down too.

### Fixed: centred text was never measured

Every centred label in the menu was placed by a rough estimate, never by
measurement. The code asked the draw context for `draw_text_size`, but the
context has no such method; in the script API it's a global (width, then height).
Every call failed, so the code fell back to an estimate that is two to three times
too wide at 1440p.

That put the MODDED ONLINE title, the page subtitles, the footer and the room-code
plaque left of centre. The first test of the popups showed it plainly: the title
and footer were off centre, and the text wrapped at a third of the panel. The
global is used now, and the estimate is kept only for a build without it.

The name tags over the other players during a run (`inputSync.lua`) had the same
bug. Every tag was drawn starting at its player instead of centred over them. They
use the global now, and they're drawn and measured at the same explicit size: 18,
the API's documented default, which their old size 0 stood for. The width measured
is therefore the width drawn. They're display only and don't touch the simulation.
`tests/test_name_tags.py` runs the shipped `guiTick` and `measureName`.
- Release zips leave out `config.json` (`tools/spike2.py`), so a fresh install
  always sees them.

### The menu

- **The root page** is now HOST, JOIN, MATCHMAKING, DISCORD, SETTINGS and CLOSE.
- **SETTINGS** holds HIDE ROOM CODE, TEST PLAYERS and SYNC SAVE DATA, moved there
  unchanged, plus the two new switches below. BACK (or ESC) returns to the root
  page.
- Both new switches are saved in `config.json` with the other settings, and both
  are off by default.

### AUTOMATICALLY SEND LOGS

This switches on the desync-log upload from dev65, which used to be an option in
Playlunky's options panel. That option is gone, since two switches in two places
could only disagree. Anyone who ticked it in dev65 needs to switch this on instead.

### AUTOMATICALLY SYNC DATA

This does SYNC SAVE DATA for you every time the game's main menu comes up.

- **When:** once per visit to the main menu. It waits until the menu has been up
  for 1.5 seconds and has finished fading in. Arriving there often means a run just
  ended, and the game may still be writing its save. The copy reads whole files, so
  it lets that save land first.
- **What:** the same copy as the button. The result shows on the SYNC SAVE DATA row,
  and the mod's own original is still kept once as `.before_mo`. The desync log
  says which of the two ran (`save share: AUTOMATICALLY SYNC DATA -> ...`).
- **When not:** never while this machine holds a room host's save, the same as the
  button.
- **Worth knowing:** it copies Modded Online's progress over the mod's own every
  time. Someone who also plays the mod on its own, outside Modded Online, should
  leave it off, or that progress is overwritten at the next main menu.

### Playlunky's options panel

The "Play <mod> online" checkboxes no longer carry a description each. It was the
same paragraph under every installed mod. The label says what the box does, and
ticking one still prints that Playlunky needs a restart. "Skip hosted mods' custom
textures" and "Undo Modded Online's setup" keep their descriptions, since those say
when to use them.

### The repository

Per-machine files that had been committed are now out of git and in `.gitignore`:

- `config.json`: it was already listed in `.gitignore`, but it had been committed
  before the rule, so every clone got one player's name and join address. The game
  writes its own on first use.
- `tools/load_order.backup.txt`: one machine's load order.
- `save.dat.parked_for_journal_test`: a save parked during a test.

`.gitignore` also covers every `*.log` now, such as the test players'
`test_player_<name>.log`. Test data that came from real logs now uses an address
reserved for documentation (`203.0.113.7`) and a made-up account name.

### Fixed: SYNC SAVE DATA after a restore that failed at launch

Suppose the last session ended while a peer was on the room host's save. At launch,
the player's own files are put back. If one of them can't be written back, the
host's file stays in the pack. Nothing had been borrowed since launch, so SYNC SAVE
DATA didn't know, and it would copy the host's progress into the player's own mod.

It now refuses while any parked copy is still on disk. Those are cleared only once
the player's own files are verifiably back. Without this, the automatic sync would
have made the same copy by itself.

### Tests

- `tests/test_settings_menu.py` (new) runs the real menu. It covers:
  - the root and SETTINGS pages;
  - both switches flipping and being saved;
  - the moved settings still working;
  - BACK and ESC;
  - every row clearing the footer.
- `tests/test_save_share.py` covers the automatic sync:
  - it waits for the menu to settle and fade in;
  - it runs once per visit, and again on the next visit;
  - it does nothing when off, or with a config from before the setting;
  - it runs only on the main menu;
  - it never copies a borrowed save;
  - after leaving a room, it copies the player's own save;
  - the failed-restore case above.
- `tests/test_log_ship.py`: the upload follows the new setting, which is off by
  default, and the Playlunky option is gone.
- `tests/test_first_run.py` (new) runs the real menu through the popups:
  - each one's title, exact text and buttons;
  - YES and NO in every combination, including NO over a setting that was on;
  - each answer saved as it's given, and `firstRunDone` only at the end;
  - ENTER, the pause before a press counts, and the keyboard kept from the game;
  - ESC and O doing nothing while the popups are up;
  - the main menu coming back afterwards, and the popups never returning;
  - closing half way, the title screen, and a config without the flag;
  - the wrapping, the layout order and the long title;
  - the text filling the panel, and the title and footer centred.

  The stubs give `draw_text_size` as a global, as the game does, with a width per
  character that differs from the fallback estimate. A test can therefore tell a
  measurement from a guess, which the old stubs (a method on the draw context)
  never could. Fourteen deliberate breaks of the code are each caught by at least
  one test, including the old method call and a swapped width and height.
- `tests/test_settings_menu.py` also checks that the menu's title and subtitle are
  centred.
- `tests/test_setup_options.py` (new) runs the real `SetupUI.install()`. It checks
  that:
  - the per-mod checkboxes have no description, passed as an empty string and
    not nil;
  - they still start ticked for what is armed;
  - the other two entries keep their descriptions.

## 2.0.0-dev65

A Jungle desync fix and the first version of sending desync logs to Discord.
**Server 1.0.13**: the log upload needs it. On an older server, the game simply
holds on to its log.

### The 2-4 desync: the water snapshot came back

The capture (room BITO) showed:

- **1-1 to 2-3 matched.** Every floor matched, and both machines left 2-3 on the
  same frame (`13:2588`).
- **2-4 generated identically.** All ten PRNG streams were identical at both
  `gen[pre]` and `gen[post]`.
- **The first frame differed.** The peer had one more `MONS_CRITTERCRAB` and one
  more `ITEM_LEAF` (1553 entities against 1551).
- **The party split by `15:720`.** On the host player 2 was dead; on the peer they
  were alive somewhere else. 3-1 then generated differently from a different party,
  and the resync warp to 3-2 followed.

The extra pair is one frog on one lily pad. hdmod's frogs are `MONS_CRITTERCRAB` and
its lily pads are `ITEM_LEAF`. Both are placed at `ON.LEVEL` by `add_jungle_deco`,
which rolls the shared PRNG only where `is_liquid_at` says there is open water.

Spelunky 2 simulates liquid across worker threads, so two machines a frame or two
into a level don't agree on the exact waterline tiles. One tile of difference
changes how many times `LEVEL_DECO` is drawn, and everything after it moves.

This is the bug the injected shim fixed in **v21**. It answered `is_liquid_at` during
a mod's `ON.LEVEL` callbacks from a snapshot taken at `POST_LEVEL_GENERATION`, before
any physics has run. Moving from injecting into the mod to hosting it carried
everything else over (ordered `pairs`, the anchors, the clock, the mod's own
`math.random`) but not this. The log header says `shims=fyi.hdmod=hosted`, and
nothing in `src/` outside the old shim mentioned liquid at all.

`src/determinism.lua` now does it again for hosted mods:

- **The snapshot** is taken at `POST_LEVEL_GENERATION`, registered ahead of every
  callback the mod registers.
- **The mod's `ON.LEVEL` callbacks** read `is_liquid_at` from that snapshot. The
  window closes even if a callback throws.
- **Everything else** still reaches the engine: piranhas, drowning, water a bomb
  displaced.
- **It applies to the same mods as before:** hdmod (by its `POSTTILE_STARTBOOL`
  global) and run-plan mods, and only in a room. A dry floor and solo play keep the
  engine's answer.

### Desync logs to Discord (new, opt-in)

A new option, **Send desync logs to the server's Discord**, lives in Playlunky's
options for Modded Online and is off by default. With it on, a run that desynced
sends its log to the Modded Online server when the run ends. The server posts it as
a `.txt` file to the Discord channel its operator set up, with a bot or a webhook.
Setup is in `server/DISCORD.md`.

- **What counts as desynced:** a `FLOOR DESYNC`, a `POSITION DESYNC` or a resync warp
  on this machine. The first machine to see one tells the room (a `desyncseen` event),
  so every player who opted in sends their side, and the host's log goes too even
  though only peers see a `FLOOR DESYNC`. The pair lands together under the same room
  and seed.
- **What is sent:** this run's own section of `desync_log.txt`, from its
  `=== Modded Online` header. A run longer than 4 MB keeps its start and its end and
  says what it cut.
- **How it travels:** `src/logShip.lua` sends base64 parts of 900 characters over the
  existing UDP connection. The server acknowledges them cumulatively; lost parts are
  resent and parts may arrive in any order. A log waiting for a server that forwards
  logs is kept for 30 minutes (two at most), including across leaving a room.
  Unticking the option stops an upload in progress.
- **Server (`on_logup`):**
  - It accepts only from a room's members, and only when Discord is configured.
    `joined` now tells the client whether it is (`logs`).
  - Limits: 4 MB per log, 6 logs per player per hour, 4 posts in flight.
  - It replaces IPv4 addresses with `x.x.x.x` and the account name in Windows user
    paths with `<user>`, and posts with mentions disabled.
  - The bot token comes from the environment or `server/discord_config.json`, which
    is git-ignored. It is never logged or sent to a client.
  - Discord's rate limit is waited out. A closing server waits up to 20 s for posts
    still in flight.
- **New netCore hooks:** `Network.sendServer` and `Network.onServerMessage` let a
  module talk to the server rather than the room.

### Also

- **`packopts=` ignores Modded Online's own `mo_` options.** These are the mod
  picker, the texture escape hatch and the new log option: per-player choices that
  build nothing. Hashing them made two machines' digests differ whenever two players
  simply chose differently. The count in that line drops accordingly.

### Tests

- `tests/test_liquid_snapshot.py`: two machines whose water settled differently roll
  identically; without the snapshot they would not. Gameplay still sees live water,
  and solo play, mods that don't build levels and dry floors are untouched. The
  window closes on a throw, and each floor gets its own snapshot.
- `tests/test_log_ship.py`:
  - base64 against Python's;
  - what triggers an upload, the room announcement and the option;
  - a full upload with lost parts, the window and per-frame cap;
  - refusal, keeping the log for the next server, stopping when unticked;
  - giving up, asking again for a lost answer;
  - trimming, and this run's section of the log.
- `tests/test_discord_logs.py`: redaction, the message and filename, the
  configuration, the exact HTTP request for a bot and a webhook, rate-limit retries
  and error reporting. Nothing talks to Discord.
- `server/test_server.py`: the upload end to end on the real UDP server:
  - refused with no Discord;
  - parts out of order and repeated, posted once;
  - a lost answer asked for again;
  - a damaged log reported;
  - the hourly limit.

## 2.0.0-dev64

Three bugs from the first full run after hdmod's tutorial, plus one found in the same
capture. The server is unchanged; 1.0.12 is still the build to run.

### Mama Tunnel's donations ran on one machine only

hdmod's shortcut donations (`lib/shortcut.lua`) ride on the vanilla Mama Tunnel dialog
on a TRANSITION, and that dialog is driven by the engine's MENU input,
`game_manager.game_props.input_menu`. The engine fills that field from each machine's own
devices. The lockstep gate fed the player slots and never touched it, so her dialog only
advanced on the machine whose player pressed. hdmod's `donate()` takes the bombs from
player 1 first, so the machine that pressed took the host's bomb and the other machine
never did. The capture shows player 1 with 4 bombs on the host's machine after the
transition, a bomb count that never matched again. It also shows a `POSITION DESYNC` on
that transition (`8:600`), while one machine's party stood in her dialog and the other's
walked.

Fixed in `src/inputSync.lua`. On a transition, the menu input now travels with the
gameplay input:

- **Recorded with the gameplay input.** Each player's menu input goes into the same
  per-frame record, above bit 16. `buttons_gameplay` is 16 bits, so the INPUTS bits
  and the sentinel are untouched. A level's records are bit-for-bit what they were.
- **Applied to the party.** On every simulated transition frame, `input_menu` and
  `input_menu_previous` hold the party's menu input, meaning everyone's presses
  together. This happens in our `PRE_UPDATE`, which runs before the engine's update
  and before hdmod's donation check (callbacks run in registration order).
- **Device value restored after the update.** The journal and pause menu read the
  field after the update (hdmod's own journal lock relies on that), so they still
  answer this player's own presses.
- **Synced buttons:** SELECT, BACK, LEFT, RIGHT, UP and DOWN. JOURNAL, DELETE and
  RANDOM stay local.
- **Presses into a player's own UI are not shared.** Presses made into a player's own
  pause menu, journal or chat box are not recorded. While a player's pause menu is
  open, that frame gets no menu input on any machine, because hdmod only handles a
  donation while `pause_ui.visibility == 0` on its own machine.
- **Taps during a stall are latched.** The gate records each frame once, so a tap
  that came and went while the gate was stalled used to be lost. It now lands in the
  next frame recorded.
- **The transition hold covers it too.** The first second of a transition already
  holds gameplay input neutral; it now holds menu input neutral as well.
- **Both fields are written, or neither.** `input_menu_previous` is written before
  `input_menu`, because overriding the current input without its previous one would
  read a held press as a new press every frame. If this build refuses either write,
  the sync switches itself off for the session and says so in the log, instead of
  overriding half the pair.

### The tutorial came back after the first real run

hdmod's prologue lives in the engine's `savegame.tutorial_state` (0 nothing, 1 journal
got, 2 key spawned, 3 door unlocked, 4 complete), and `camplib.is_prologue_active()` is
`tutorial_state <= 2`. hdmod never writes it; the engine moves it on when the key
unlocks the camp's main exit and the first adventure starts through it. Online that
door is inert (`can_enter` is false), so neither happened. The capture shows
`prologue=true ... tutorial=2` on the death screen after a full run, and every camp
after that replays the rope entry and the journal and keeps the main door locked.

Fixed in `src/determinism.lua` with a new hdmod adapter, `hd-prologue-exit`, beside
`hd-tutorial-door`. A run started from the main exit completes the prologue (state 4),
the way walking through that door would have. It only does so where the door could
have opened:

- **State 3:** the door is already unlocked.
- **State 2, camp right after the tutorial:** this is the camp where hdmod hands the
  party the key (`is_post_tutorial`).
- **State 2, tutorial finished before:** hdmod's tutorial record list is not empty.
  This also rescues a save that already lost the key once, like the host's save now.

States 0 and 1, and a party that never finished the tutorial, are left alone,
because in the game itself the door would still be locked. Every input to that
decision is identical on every machine.

### The Udjat key and chest on two floors, sometimes two keys

hdmod places its own Udjat key and chest (one level of 1-2 to 1-4, chosen once per
run). At the start of each run it also raises quest flags 17, 18 and 19 (Udjat eye,
black market and drill "already spawned"), so the game never places its own on top.
That run setup (`lib/flags.lua`) is gated on `QUEST_FLAG.RESET` in
`PRE_LEVEL_GENERATION`.

`applyFreshRunReset` zeroes `quest_flags` in both `PRE_LOAD_SCREEN` and
`PRE_LEVEL_GENERATION`, and our callbacks run before the hosted mod's, so hdmod never
saw the flag. The game then placed its own key and chest as well. The capture shows
it on the run's floors:

| Floor | Key | Chest | Quest flags | Whose |
|---|---|---|---|---|
| 1-2 | yes | yes | 17 clear | hdmod's pair |
| 1-3 | yes | no | 17 now set | the game's own |

Flag 18 is never set, because hdmod's block never ran.

hdmod's other run setup on that flag was lost the same way: its per-run feat counters,
its character-unlock coffins, its custom-entity carry-over and Yang's turkey pen.

Fixed in `src/eventSync.lua`. On a fresh run's first load, our early `PRE_LOAD_SCREEN`
and `PRE_LEVEL_GENERATION` callbacks raise the flag again after our reset, for the
hosted mods' callbacks (`showRunReset`). A callback that `main.lua` registers after
hosting lowers it again before the engine acts on the load (`installRunResetWindow`).
The engine sees exactly what it did before, every machine raises the flag at the same
point of the same ordered run start, and `POST_LEVEL_GENERATION` is a backstop.

The flag is only raised when all of these hold:

- the level ordinal is 0;
- the load is a LEVEL;
- the machine is in a run, with no restart pending;
- the closing callback is installed.

The other installed packs were checked: Randomizer reads the flag only in
`ON.LOADING`/`ON.TRANSITION` (outside the window), Pit of 100 Trials clears it itself,
and 2.5 resets per-run state on it.

### Also: two camps' doors at once

`campDoors` was emptied when a run ended but not when a camp was rebuilt without one,
for example going back to the menu and character select and then the camp again. The
previous camp's door uids stayed in it, and the capture logged `camp doors hooked:
1561=..., 1567=main exit, 1587=..., 1593=main exit`. Uids are recycled every level,
so pressing UP beside whatever entity inherited one could ready up or start the run.
`pollCampDoor` now empties the table when it hooks a camp.

### Tests

- `tests/test_transition_menu_sync.py`: two simulated machines run the real
  `preUpdate`, exchange records and must see the same menu input on every frame. It
  also covers:
  - one player's press reaching both machines on the same frame;
  - DOWN/LEFT being synced;
  - the hold, the stall latch and the post-update restore;
  - JOURNAL staying local;
  - pause, journal and chat exclusions;
  - the record layout.
- `tests/test_run_reset_window.py`: the engine's dispatch order around our early
  callback, hdmod's run setup and our late callback, every gate condition, and the
  wiring (shown after our reset, installed after hosting, the post-generation
  backstop).
- `tests/test_prologue_exit.py`: every `tutorial_state` and key case.
- `tests/test_camp_doors.py`: a rebuilt camp holds only its own doors.

## 2.0.0-dev63

Two bugs from the first full two-player run of hdmod's tutorial. **Server 1.0.12.**
The client half of the second fix works against a 1.0.11 server too.

### The tutorial's floors desynced from 1-2 onward

Both logs agreed on 1-1 and on the first generation of 1-2 (`ent=2020350654` on both
machines). What broke it:

1. hdmod opens a story journal at the start of every tutorial floor and holds the game
   in its fade pause until that player closes it. Each player closes theirs whenever
   they finish reading.
2. The peer closed first, engaged sequence 2 and waited for the host's inputs. The host
   was still reading: its gate cannot engage while its sim is held, so it kept
   resending its sequence-1 inputs.
3. After 4 s the peer's stall detector saw a live peer on a different sequence, read it
   as "they're stuck below us" and asked for a resync warp. Nothing had diverged yet.
4. The warp reached the host **while its journal was still open**. When the journal
   closes, hdmod resumes its fade with `state.loading = FADE.IN`, which overwrote the
   `FADE.OUT` that `warp()` had just started. So the host never regenerated 1-2. Its
   gate took hdmod's fade as the warp's load boundary and engaged the rebased sequence
   on the old floor. The peer regenerated (`ent=1257534570`). The logs show
   `FLOOR DESYNC` on 1-2 and 1-3 and `POSITION DESYNC` in between.

Gameplay looked synced because the inputs stayed in lockstep. The two worlds under
those inputs were different, which is why killing the peer still worked but the
desync notices kept coming.

Fixed at both points:

- **A held peer is not a desync** (`src/inputSync.lua`). Input packets now carry
  `h = 1` while the sender's sim is held by a load, a fade or a content mod's own
  pause. `stallDesyncRole` skips a peer that said so within the last 3 s. The 3 s
  covers the packets sent after hdmod reopens its fade but before the new sequence
  engages. A peer that stays on another sequence after its hold ends is detected
  exactly as before, just later. The death screen and other run screens outside the
  gate are not marked held. Packets from a running machine are byte-identical to
  dev62's.
- **A resync warp waits out a mod's own pause** (`src/eventSync.lua`,
  `applyPendingWarp`). It was already deferred while a load fade was in flight. Now it
  also waits while the fade pause (2) is up with no load, which is the same condition
  as inputSync's `modUiPause`. It holds the whole payload, so the rebase and the warp
  still happen together once the journal closes and hdmod's fade finishes.

### "Waiting for everyone to pick a character..." after the tutorial

After the tutorial both players reach the camp on the same frame (both logs show
`run ending` then `lobby ready announced ... roomStarted=true` at `11:1305`). Each
machine sends `endrun` and then `ready`, and the server receives the two machines'
messages interleaved. So the first finisher's `ready` arrived before the last
finisher's `endrun`, and that `endrun` reopened the room and cleared every ready. The
client announces readiness once per camp visit, so it never sent it again. The lobby
stayed at `1 / 2 READY` and the host's door refused to start.

- **Server 1.0.12** (`server/server.py`): `Client.readied_after_leaving` records a
  ready sent after the player left the run. Both reopen paths (everyone ended the
  adventure, and a party wipe) keep that ready and clear the rest, which is still
  True from before the run. `SERVER_VERSION` and `EXPECTED_SERVER_VERSION` are 1.0.12.
- **Client self-heal** (`module.pollReadyHeal`, `src/eventSync.lua`): in the lobby,
  after this camp visit has announced, and only once the room has **reopened**
  (`roomStarted == false`), if the lobby list shows our ready differing from ours,
  resend it, at most once a second. It never resends into a started room, because a
  ready there asks to rejoin the running game. This also covers a lost `ready`
  datagram, since `ready` is one unacknowledged UDP send. It also fixes the bug on a
  server that has not been redeployed.

### Tests

- `tests/test_journal_pause_sync.py`: the detector with a held, a running and a
  formerly held peer; `h` on the wire only when held; `preUpdate`'s held decision
  (mod pause, load, running, death screen); the warp held inside the pause and
  applied after it.
- `tests/test_ready_heal.py`: the resend, its rate limit, never into a started room,
  public-room door votes, malformed lobby lists.
- `server/test_server.py`: "finishing the run together keeps a ready sent from the
  camp". Five of its checks fail against 1.0.11.
- `tests/test_tutorial_door.py`: the version check now asserts the two halves are
  equal and at least 1.0.11, instead of pinning 1.0.11.

## 2.0.0-dev62

Tutorial level 2 still crashed under dev61. **dev61's fix was the wrong shape;
this replaces it.**

### What the capture said

The dev61 log line fired exactly as designed — `NOT overriding -- the mod is opening
page 10 and the engine's list has only 8` — and the game died straight after hdmod
returned its list (`crash_frame.txt`: `OUT mod hdmod_journal.lua:965`). dev61 let
hdmod's own 12-page list through to reach page 10, and that **grew** the engine's list.

So growth is fatal when hosted on the tutorial's path too, not only the camp's. The
measured rule is now unconditional: **8 pages has never crashed, in any context; 12
and 20 always have.**

### The fix: a window, never growth

hdmod only ever *shows* four story pages per tutorial lock, so 8 is always enough room
— it just has to be the right 8. When hdmod opens a story page past the engine's count:

1. **The engine gets 8 pages that are the story entries being shown** — ids
   `600 + offset + 1 .. 600 + offset + 8`, with `offset = page - 2`, so the spread
   being opened is the window's first. hdmod draws every page from its own id
   (`page_number - page_offset`), so the content is right wherever it sits.
2. **The journal is pointed inside the window.** Overlunky's `show_journal` writes the
   full page into `current_page` with no bounds check; the sandbox's `show_journal`
   corrects it to `page - offset` the moment the real call returns, still inside
   hdmod's callback, before the engine runs a frame.
3. **hdmod sees full story numbering.** Its story lock compares
   `journal_ui.flipping_to_page` with `start + 1` and `start + count - 1`, so the
   sandbox's `game_manager` adds the offset back on the way out, while the window is
   in force and the story chapter is what is on screen.

`offset` is always even (hdmod only opens even pages), so no page changes side.
Window pages past hdmod's 20 entries (post-tutorial only) sit beyond the lock, where
it never lets the player flip.

### Why the proxy is safe

Audited against hdmod before writing it. hdmod only ever reads `game_manager.<field>`
— seven fields — and never calls a method on `game_manager` or `journal_ui`, passes
either to a function, writes a page field, or uses `type`, `pairs`, `rawget`,
`tostring` or a comparison on them. Everything except the two page fields is the real
object, and everything is the real object while no window is in force. It is installed
only with `mo_nojournalpages.on`; without the flag hdmod sees exactly what it always
did.

The camp (journal pickup, page 2) and tutorial level 1 (page 6) fit in 8 and are still
clamped exactly as before.

## 2.0.0-dev61

The tutorial crashed on entering level 2. **Caused by the journal workaround itself.**

### What the log said

`mo_journal.txt` from a fresh-save run, identical on both captures:

| Where | Engine offers | Override returned | Result |
|---|---|---|---|
| camp (`screen=11`) | 8 | 8 | fine |
| tutorial level 1 (`screen=12 level=1`) | 8 | 8 | fine |
| tutorial level 2 (`screen=12 level=2`) | 8 | 8 | **crash** |

The page list is the same on both levels, so the list is not what changed. What
changes is the page hdmod OPENS: `schedule_story_on_fade_in` calls
`show_journal(STORY, start + 1)`, and the tutorial locks are `{5,4}`, `{9,4}`,
`{13,4}`, then `{17,4}` after it — pages **6, 10, 14, 18**.

### Why that kills it

Overlunky's `show_journal` (`src/game_api/screen.cpp`) ends with

```cpp
gm->journal_ui->current_page = page;
gm->journal_ui->flipping_to_page = page;
```

and **no check against how many pages the chapter has**. `sameids` clamps the story
chapter to the engine's 8, so level 2 set the journal to page 10 of 8 and the engine
indexed off the end of the vector. Level 1 opens at 6, which is the only reason it
ever survived.

No mode of the flag could have fixed this: every mode returns the engine's count.

### The fix

The sandbox wraps `show_journal`, so the page being opened is known while the chapter
loads — Overlunky loads it synchronously and only writes the page afterwards, so the
chapter callback is the one moment the list is decided and nothing else can tell. The
override no longer clamps when that page is past the engine's count; the mod's own
list stands, since it is the only one that contains the page.

Every hdmod lock that opens within the engine's 8 also ENDS within it (journal pickup
`{1,4}`, tutorial level 1 `{5,4}`, replay `{1,8}`), so those are still clamped exactly
as before and the camp is unchanged. A test reads hdmod's own lock table and fails if
that ever stops being true.

### What is still not known

Level 2 onward now **grows** the story chapter (8 → 12 / 16 / 20) on the tutorial's
path. The only growth ever captured crashing is the camp's, which goes through
hdmod's chapter-0 hook and opens the story chapter from *inside* an Overlunky journal
callback. The tutorial opens it from an ordinary `POST_UPDATE`. Growth on that path
has never been tested — the clamp always got there first. If level 2 still crashes,
the last line of `mo_journal.txt` will read `NOT overriding -- the mod is opening page
10`, and that says growth itself is the problem on any path.

Also ruled out while reading Overlunky's source, so nobody re-derives them:
`JournalPageStory::construct` initialises every field that matters (the only one it
leaves is padding); backend locks are `recursive_mutex`, so re-entry is safe; and
although `set_callback` inserts straight into the `unordered_map` every dispatch loop
iterates, cleared callbacks are erased and `erase` never shrinks the bucket array, so
the map's capacity is fixed at boot far above its live size and cannot rehash during
play. `max_page_count` reads `2147483647` — Overlunky sets it on every override — so it
is not the limit either.

## 2.0.0-dev60

dev59 verified in game, and the verification turned up a much older bug that had
nothing to do with the journal crash.

### Confirmed working

`mode=sameids` on an empty flag, the engine's count with hdmod's own page ids; the
render probe collapsed to one line instead of four hundred; and — on the tutorial
level itself — `screen=12` (LEVEL) with `worldstate=2` (TUTORIAL), which is dev55's
adapter doing its job at the point that actually matters rather than only at run
start.

`sameids` still truncates hdmod's 20 story pages to the engine's 8. It remains a
workaround.

### get_game_manager() is not on this Playlunky build

Every JournalUI field in the capture read back `attempt to call a nil value (global
'get_game_manager')`. Not "journal_ui is nil" — the function is not a global at all.

Two real features called it inside a bare `pcall` and took the failure as "no journal
is open": `pollPlayFlow`, which waits for the death-recap book to finish animating
before launching character select, and `pollCloseStrayJournal`, which force-closes a
journal drawn over the character select. Neither has ever run on this build. The
wedged endless page-turn on CHOOSE ADVENTURER that the first one was written to
prevent was never actually being prevented.

A `pcall` around a missing global is indistinguishable from a legitimate "nothing
here", which is why this survived so long — it took a probe that printed the message
instead of swallowing it. `GameManager()` and `JournalUI()` in `src/util.lua` now try
`get_game_manager()` and then the `game_manager` global, latch the miss so a dead
lookup is not repeated every frame, and report which accessor worked.

It also parks the `max_page_count` hypothesis: that field cannot be read at all until
one of those accessors resolves on this build.

## 2.0.0-dev59

The tutorial door is confirmed working in game, and the journal now opens hosted
rather than killing the process. Four fixes, every one of them forced by a real
capture rather than guessed at.

### An empty override flag did the wrong useful thing

A player who creates `mo_nojournalpages.on` to stop the crash got `mode=restore` —
the engine's own page list, which is the non-crashing **control** for an experiment.
The crash stops, and the journal silently shows *vanilla* pages instead of hdmod's.
Empty now means `sameids`: the engine's count with the mod's own ids, which stops the
crash *and* keeps the mod's content. `restore` is still there by writing it in.

### The page-render probe burned the whole capture budget

It fires every frame the journal is open, so the first non-crashing capture spent all
400 lines on one identical line repeated — about a second of rendering. Useless by
itself, and actively harmful: a crash after that point would have had nowhere left to
write. Repeats are collapsed to one line plus a count.

### journal_ui cannot be read when the chapter loads

Every field came back `attempt to index a nil value` — the UI does not exist yet at
`POST_LOAD_JOURNAL_CHAPTER`. `max_page_count`, the leading candidate for the size a
grown list overflows, is now read at RENDER time, which is the one point it
demonstrably exists because it is drawing.

### An error message that was 87% path

`ERR(Mods/Packs/Modded Online DEV/src/modHost.lua:245: attempt to` — sixty
characters, fifty-two of them the path to the file doing the reporting. Lua's
`file:line:` prefix is stripped and the message kept.

## 2.0.0-dev58

The first real capture of the journal crash arrived, and it settles three things and
leaves one open. See HANDOFF.md #2 for the log and the reading.

Settled: the engine offers **8** pages hosted; **no page render is ever attempted**
(the page-render probe writes to the same file and never fired, so the process dies
in the engine's page *setup*, not in a draw — previously an inference, now measured);
and hdmod's own page clamp cannot engage in the camp because `screen` is CAMP not
LEVEL and `HD_WORLDSTATE_STATE` is NORMAL not TUTORIAL, which is why it returns all
20 pages there.

That last point means the camp journal and the tutorial journal are different cases.
In the tutorial both of those conditions hold — the second one only since dev55 — so
hdmod clamps its own list and never hands over the long one.

### Two fixes to the probe, from what the capture could not say

* `journal_ui state=? page_shown=?` — a `?` says the read failed and not what it
  failed on, which is a diagnostic that cannot itself be debugged. It now reports the
  error, so "no such field on this build" and "journal_ui is nil at this point in the
  load" stop looking identical.
* **`max_page_count` is now read.** It is the leading hypothesis for the mechanism
  and HANDOFF.md has flagged it unread for two sessions: the engine offers 8, hdmod
  returns 20, and returning 8 with hdmod's own ids does not crash — so the growth is
  what kills it, and something downstream is sized for the incoming count. If that
  field reads 8, the fix is to raise it before returning a longer list rather than to
  truncate the journal.

## 2.0.0-dev57

Two captures of the journal crash came back with the same file in them, from a
session in May, and neither of us noticed for two rounds. Both reasons are fixed.

### The repo was shipping a stale desync log

`desync_log.txt` and `desync_log.prev.txt` are listed in `.gitignore` — and were
committed anyway, which `.gitignore` does not undo. So every clone put a capture from
somebody else's session into the pack folder, where it reads exactly like a real one:
right filename, right format, plausible contents. Its header says `Modded Online 1.0`,
hosts crossoverlunky rather than hdmod, talks to server 1.0.10, and ends with a clean
`run end`. Now untracked.

### The desync log could not have held this crash anyway

`DesyncLog.init` runs from `InputSync.beginSession` — the log is opened and rotated
only when a networked **run** starts. Opening the journal in the lobby camp happens
before any run, so `DesyncLog.line` drops every line (`logPath` is nil) and
`earlyEvent` buffers for a run header that never comes. The dev56 change routed the
journal measurement to `earlyEvent`, which for this crash meant writing it into a
buffer that dies with the process.

`mo_journal.txt` is the sink that survives: opened and closed per line so it is
flushed before the process dies, written whether or not a run is in progress, bounded
at 400 lines, and mirrored to `spelunky.log` via `print` as a second independent sink.
Journal *chapter* loads are rare, so a file handle per line costs nothing.

It also records that the probe armed at all, so an empty file no longer means both
"never armed" and "armed, journal never opened"; and the page-render probe writes
there too, so whether the engine got as far as drawing a page — the fact that
separates page SETUP from the first DRAW — leaves the dying process.

## 2.0.0-dev56

The journal crash is still not fixed. What is fixed is that **the workaround for it
did nothing**, and that the one measurement needed to fix it properly no longer costs
a file write every frame.

### The documented workaround was inert

HANDOFF.md tells you to create `mo_nojournalpages.on` to stop hdmod's journal killing
the game. That override lives inside the callback `installJournalProbe` registers —
and the registration was gated on `DesyncLog.tracing()` alone:

```lua
if not armed or rawget(_G, "ON") == nil or ON.POST_LOAD_JOURNAL_CHAPTER == nil then
    return false
end
```

So creating the flag you are told to create installed **nothing**: no callback, no
override, the same crash, and no way to tell that apart from "the workaround does not
work". It silently required a second, undocumented flag (`mo_trace.on`) that writes
every frame. It now arms on its own flag.

### The missing measurement has its own flag

HANDOFF.md has called the same question open for two sessions — *does the engine
offer 8 pages standalone too?* — and it decides which of two completely different
chases is the real one. Nobody has taken it because the probe that answers it needed
the per-frame tracer.

`mo_journalprobe.on` arms the logging half alone. It overrides nothing, and the
callback runs when a journal *chapter* loads rather than per frame, so it costs
nothing to leave on. The `engine pages in:` line now goes to the **desync log** as
well as the trace, so it survives without `mo_trace.on` at all.

No flag and no tracer still installs nothing: the probe registers a
`POST_LOAD_JOURNAL_CHAPTER` callback, and leaving that on for everyone would change
the exact code path the crash lives in.

## 2.0.0-dev55

hdmod's tutorial door puts the party in the tutorial. **Both players need dev55, and
the SERVER needs 1.0.11** — this is half a server fix and it does nothing without it.

### The server was throwing the answer away

dev54 already had the whole client-side mechanism: the camp door's destination rides
along in `run_start`, and each machine matches it against its own
`camplib.DOOR_TUTORIAL_UID` and sets `HD_WORLDSTATE_STATE = TUTORIAL`. Ten unit tests
covered it. It never worked once in game, and nothing said why.

`parse_start_dest` in `server/server.py`:

```python
if world == 1 and level == 1:
    return None  # the main door: the default start, nothing to carry
```

hdmod spawns its tutorial door with `spawn_door(x, y, l, 1, 1, THEME.DWELLING)`. Its
destination **is** 1-1 — so of every door in the game, the one door this feature
exists for was the one the server discarded. `run_start` carried no `start`, every
machine's adapter was handed `nil`, and it correctly did nothing. The adapter, the
dispatch and the tests were all right; the field was empty before any of them ran.

Dropping the collapse is safe because the client never sends a destination for the
main exit: `pollCampDoor` records `false` for `FLOOR_DOOR_MAIN_EXIT` and only reads
`get_target()` for `FLOOR_DOOR_STARTING_EXIT`. "The main door" arrives as an absent
field, not as `[1, 1, theme]`. A present 1-1 is a real door that leads to 1-1, which
is a different thing and is now kept.

### Recognising the door and acting on it are now two steps

`startDoor` has to run at `run_start`: it matches on the camp door, and the door is
gone the moment we warp. But the mod's own load and reset callbacks run between that
and generation, and hdmod's camp setup writes `HD_WORLDSTATE_STATE = NORMAL`. So
recognition happens where the evidence is, and the *consequence* is re-applied at
`PRE_LEVEL_GENERATION` while `levelOrdinal` is 0 — the last write before the world is
built, gated exactly like the fresh-run kit reset and for the same reason. It never
re-runs the door match: by then the camp is gone and the door's uid may have been
recycled by another entity. The hits are dropped in `clearRunState`, so a recognised
tutorial cannot leak into the next run.

### It is no longer possible for this to fail silently

The three things that made a whole session of work produce no evidence:

* **`runStartedFromDoor` logged only a hit.** A dispatch that found nothing was
  indistinguishable from one that never happened. Every outcome now reaches the
  desync log, naming the destination that arrived and why each adapter said no.
* **`pollCampDoor` never said what it hooked.** Now one line per camp listing each
  door and its target — the other half of the pair, so "the door was never hooked"
  and "the destination was lost on the way" can be told apart.
* **An out-of-date server looks exactly like this bug.** A machine that readied at a
  door and gets a `run_start` with no destination now says so, in a toast and in the
  log, and names the server. It is deliberately NOT worked around by substituting our
  own door: only the machine that pressed it knows it, so the peers would build a
  different world. A wrong-but-identical run beats a right-for-one-player one.

### Restarting inside the tutorial stays in the tutorial

An instant restart re-sends the door the run began at — the server keeps it on the
room so a restart returns to the same shortcut — but by then the camp is gone and
`DOOR_TUTORIAL_UID` names a dead entity, so the match failed and the restart landed
in an ordinary run. Reading the door's target is only possible while the camp is up;
comparing against it is not, so the two are separated and the target is remembered
per sandbox. It is a target, not a licence: a normal run started afterwards still
sends no destination and is still left alone.

### Two smaller things found on the way

* **The adapter required `camplib` to be detected.** Detection runs once, right after
  the mod's main chunk, so a global assigned any later made the adapter invisible for
  the rest of the session. `worldlib.HD_WORLDSTATE_STATUS` already names hdmod;
  `camplib` is what the adapter works on, not what identifies it, and is now looked up
  where it is used.
* **The main exit and a door leading to 1-1 shared the "1-1" label.** So
  `everyoneSameDest` called them agreement, and pressing one while readied at the
  other read as un-readying instead of moving your vote. The main exit is now `main`.

## 2.0.0-dev54

The pack goes back to a WORKING state, not an empty one. **Both players need dev54.**

### What the log said

The `saveshare=` line added in dev53 answered it on the first try:

```
saveshare=BORROWING the room host's save | 2/2 file(s) present, 0 parked, 2 marked absent
```

**Zero parked, two marked absent**: the peer's pack held NEITHER save file before
joining. dev53 therefore did exactly what it was told and deleted both on leaving --
which is why `savegame.sav` vanished. `save.dat` came back because Playlunky writes it
again on the next ON.SAVE, so the one file that looked "kept" was simply recreated.

Deleting was a faithful undo and a useless one. hdmod NEEDS its `savegame.sav`:
without it the game hands hdmod the player's real save and the HD campaign opens with
everything already unlocked.

### Why the files were missing at all

dev50 moved `savegame.sav` out of packSetup's `COPY_FILES` and into seeding, and
seeding only runs when packSetup APPLIES -- when the armed selection changes. A player
who armed the mod under an older build was never seeded, so the pack held nothing to
park, which is how a peer came to borrow with nothing of its own to give back.

That is the root cause of all three failed attempts at this: the restore was correct
each time, and there was nothing for it to restore.

### Two changes

* **Seeding runs at boot**, for every hosted pack, copy-if-missing. A pack can no
  longer be short of the files it needs, whatever it was armed under.
* **Restoring an absent-marked file re-seeds it from the mod** instead of leaving a
  hole, and the mod is then reloaded from that file rather than from nothing. A
  parked copy still wins: a player who HAD a save gets their save, not a fresh one.

### One thing to expect on the first launch

Seeding fixes the FILE. The engine reads `savegame.sav` at launch, so a pack that was
missing it gets the right file on this launch and actually uses it on the next. The
live field sync covers what matters in the meantime.

330 tests, 61 in `tests/test_save_share.py`.


## 2.0.0-dev53

The peer's save really does come back now. **Both players need dev53.**

### What was actually wrong

`adopt()` parked a copy of the peer's file **only if that file already existed**:

```lua
if fileExists(mine) and not fileExists(kept) then ... park it ... end
```

A parked copy cannot exist for a file that was never there, so for a peer with no
`save.dat` of their own nothing was recorded, nothing was restored, and the host's
save simply stayed -- permanently. Putting such a file back means DELETING it, and
that case was never handled.

That is not a rare corner. **The packaged zip deliberately ships neither save file**,
so a freshly installed loader has neither until packSetup happens to seed them: a peer
installing a new build and joining a room is exactly this case.

Worse, it was **silent**. With nothing parked the restore path had nothing to do and
logged nothing, so the peer left holding somebody else's progression with no trace of
why -- which is why two rounds of this were spent on the wrong mechanisms.

Verified by reproducing it: with the dev52 code, a peer that had no save file keeps
`HOST-dat` after leaving.

### The fix

A file that did not exist before the borrow gets a `.mo_absent` marker, and restoring
it means removing it. The marker is a file, so it survives closing the game, and it is
retired with the parked copies -- never before.

### ...and it can be seen now

The desync log header carries a `saveshare=` line every session: whose save this is,
how many of the two files are present, how many are parked, how many are marked
absent. The previous two fixes were both correct and both invisible; this one can be
checked from a log rather than reasoned about.

325 tests, 56 in `tests/test_save_share.py` -- including a peer that never had a save,
a mix of one parked and one absent, and the marker surviving a restart.


## 2.0.0-dev52

Giving the peer's save back now survives anything, including simply closing the game.
**Both players need dev52.**

### Why restoring the file was not restoring anything

Two writers put the borrowed state back after we had undone it:

* **Playlunky reads a pack's `save.dat` and hands it to ON.LOAD before any of our Lua
  runs.** So a restore done when saveShare loads fixed the FILE while the mod in
  memory still held the host's state -- and the mod's next ON.SAVE wrote that straight
  back over the file we had just fixed. The parked copy was already deleted by then.
* **The engine writes `savegame.sav` from its own memory whenever it saves**,
  including on the way out. Closing the game while borrowing therefore left the host's
  field values in the player's savegame.sav, and the next launch loaded them back
  into engine memory before we could restore the file.

Both of those undo a correct restore, quietly, and neither leaves a trace.

### The restore is now two-phase and idempotent

At load the parked copies go back and are **verified by reading them back**, but they
are NOT retired. `main.lua` then calls `SaveShare.finishStartupRestore()` after
hosting -- the first moment the mod exists to be re-run -- which re-runs its loader
from the restored file and only then deletes the parked copies. A crash between the
two phases simply means the next launch does it again.

A file that cannot be written back keeps its parked copy and says so, rather than
losing the player's progression to a failed write.

### The field values are parked on disk as well

`mo_own_fields.txt` holds the player's own `savegame` scalars from the moment the
borrow starts. After a restart it is the only record of what they were, so it is what
puts them back into engine memory before the engine can write them out again. It is
retired with the parked files, never before.

### One list

`SaveShare.artifacts()` names every per-machine file this can leave behind. packSetup's
teardown and `--package` both read it, so neither can drift from the other -- which is
the failure the packaging test already exists to catch.

320 tests, 51 in `tests/test_save_share.py`.


## 2.0.0-dev51

The shared save applies immediately. No restart. **Both players need dev51.**

dev50 shipped the file transfer and said a peer would get parity at their next
launch. That is not a solution -- least of all for somebody who just matchmaked into
a lobby -- so the swap now has three parts, and the files are only one of them.

### 1. The live `savegame` fields

The engine parses `savegame.sav` at launch and then works from memory, so writing the
file changes nothing in the session in progress. The host now also publishes the
scalar fields straight out of its in-memory `savegame`, and a peer writes them where
a running mod actually reads them: `shortcuts` (Mama Tunnel), `characters` and
`players` (the HD mod's unlock rolls), `tutorial_state`, `deepest_area`, and the
completion flags. Booleans are written as booleans -- assigning a number to one is a
native type error, not a Lua one.

Not live: the journal arrays (`places`, `people`, `items`, `bestiary`). They are
per-entry bitfields that change what the journal DISPLAYS and nothing that generates,
so they ride the file and land at the next launch.

### 2. The mod's own loader, re-run

Playlunky hands a pack's `save.dat` to ON.LOAD once, at script load. That is the
other half of why a file arriving mid-session used to mean nothing.

Hosting removes the problem entirely. The mod's ON.LOAD handler is an ordinary Lua
function in OUR state, so `ModHost.reloadSaveData` simply calls it again with the new
contents. The context it hands over only has to answer `:load()`, and the HD mod's
handler (`lib/save.lua`) does exactly that -- decode the JSON, then re-run its own
migration, load and post-load callbacks. That is a full reload of its save state in
place, which is as close to a soft reset as the mod itself has.

Each handler is pcall'd: one mod's loader throwing must not strand the rest, and this
runs on a peer that has just joined somebody else's room.

### 3. The files, as before

They make the borrow persistent and let it be handed back exactly.

### Leaving undoes all three

Own fields back, own `save.dat` handed to the mod's loader again, own files restored.
A test pins the last one specifically, because a mod left holding the host's save
state after leaving is the same bug as never restoring the file.

### Also

`eventSync`'s dev47 load-window hold now stands down while saveShare is borrowing.
Both were managing `shortcuts` and `characters`; saveShare holds them for the whole
room rather than just across a load, and two mechanisms taking turns to own one field
is how they end up fighting.

313 tests, 42 of them in `tests/test_save_share.py`.


## 2.0.0-dev50

Shared save data for the hosted mod. **Both players need dev50.**

### The rule

While you are in a room, everyone plays on the ROOM HOST's save. The host publishes
`save.dat` and `savegame.sav`, every peer borrows them, and a peer's own copies come
back the moment it leaves. The host's own progress is never touched, so it
accumulates normally.

`src/saveShare.lua` is new. The files travel base64-encoded over the reliable event
channel in 800-character chunks, four per frame -- hdmod's two files are about 17 KB,
roughly 24 chunks, and posting them in one frame would hand the channel a burst it
would then have to resend as a burst. A peer asks once on joining; the host answers.

### What is and is not written

Only files inside **Modded Online's own pack**. The mod's folder is never written
except by SYNC SAVE DATA, which is a button. That boundary is deliberate: a loader
that quietly edits other packs is what stopped those packs booting on their own.

Before a peer's files are replaced they are copied aside, and the swap is **abandoned
if that copy cannot be written** -- it fails closed, because the failure it guards
against is another player's progression sitting permanently in this player's save.
The parked copy is also restored at load, so a session that crashed while borrowing
does not leave the host's save behind.

### SYNC SAVE DATA

In the Modded Online menu. Everything played under Modded Online writes to OUR pack,
not the mod's, so the mod on its own never sees it; this is how a player claims it.
The mod's own copy is kept once, as `save.dat.before_mo`, so it is undoable by hand.
It refuses while the host's save is borrowed -- that progress is not this player's to
keep -- and the button's label reports what happened.

### Seeding, and why the files left COPY_FILES

`savegame.sav` used to be in packSetup's `COPY_FILES`, which is copied on **every**
apply. That would throw away everything played under Modded Online each time the same
mod was re-armed. Both files are now seeded once, only when we do not already have a
copy. They are still removed on teardown, so switching mods still starts the new one
clean.

### When it takes effect -- read this

These files are read by the engine and by Playlunky **at launch**. Writing them
mid-session fixes the NEXT launch, not the one in progress; the engine also rewrites
`savegame.sav` from memory when it next saves. So a peer who joins mid-session gets
parity from their next restart.

What already keeps the CURRENT session honest is the separate in-memory sync added in
dev47, which pushes the host's `savegame.shortcuts` and `savegame.characters` for the
moment a mod reads them -- the two fields that actually steer generation. The two
mechanisms are complementary: one makes this run deterministic, the other makes the
progression itself shared and persistent.

### Tests

`tests/test_save_share.py`, 29 of them, against an in-memory filesystem -- nothing
touches disk. Base64 round-trips every byte value and every length modulo 3; a 14 KB
file survives chunking; no chunk can fragment a datagram; the peer's save is set
aside first, comes back byte-for-byte, and is **left alone entirely** when it cannot
be backed up; a crashed session restores at load; only the room host is authoritative;
a half-delivered generation changes nothing; seeding never overwrites; and the button
refuses while borrowing.

Two of those tests were written wrong first and said so: `publish()` only queues and
`poll()` sends, and Lua tables cannot cross between lupa runtimes.


## 2.0.0-dev49

Fixes the deadlock dev48 shipped. **Both players need dev49.**

### The barrier ran exactly once

`holdTransitionExit` sets `screen_next` back to `SCREEN.TRANSITION` to hold the
machine -- and its own early return at the top,
`if state.screen_next == SCREEN.TRANSITION then return end`, then matched on the
very next frame. So the barrier evaluated ONCE per transition: readiness was never
re-checked, the once-a-second resend never fired, and the 20-second give-up timer
never ran.

All three symptoms are in the two dev48 logs, and all three are that one guard:

* both machines announce the hold on the **identical** frame (`2:75` and `2:75`,
  `4:71` and `4:71`) and neither ever releases;
* the single release reads **99130 ms**, far past a 20-second give-up that should
  have fired first -- it happened only because the player walked into the door
  again, which set `screen_next` back to LEVEL and re-entered the logic;
* the held peer reports `next cseq out 3` -- three outbound events for a whole
  session, i.e. the resend never ran.

That is the "50% of the time", and it is every transition, Mama Tunnel or not:
whether it worked depended on whether you happened to re-trigger the door after the
other player's signal had landed.

### Releasing now puts the screen change back

Dropping the override was never enough. We had overwritten the engine's own
`screen_next` and `loading`, so releasing left the transition it had already
committed to simply gone, and the player had to walk into the door a second time to
start a new one. Both values are captured once when the hold begins and restored on
release and on give-up.

Giving up also latches, so the barrier cannot immediately re-hold the transition it
just abandoned.

### The tests that shipped the bug

They called a `leaving()` helper repeatedly, and that helper re-set `screen_next` to
LEVEL every time -- which papered over the early return, because real frames never
do that. They now drive plain frames, and the new
`test_the_barrier_keeps_evaluating_while_it_holds` fails against the dev48 code.
Verified by patching the guard back out in memory: still held after readiness
arrives, one `tready` for the session, still held after 100 seconds -- all three
observed symptoms, reproduced.


## 2.0.0-dev48

Nobody leaves a transition alone. **Both players need dev48.**

### What the two logs showed

Both machines entered the transition at seq:offset **7:873** -- perfect lockstep --
and then the peer left at **8:259** while the host was still standing there, stalling
at 8:265 on inputs that were never coming.

Entering a transition is lockstepped. **Leaving one was not**: each machine walks out
when its own player finishes with Mama Tunnel, and a dialogue takes as long as the
person reading it. dev47 synchronised her STATE so both machines get the same
encounter. That was necessary and not sufficient -- the same encounter still takes
two different amounts of time to dismiss, and the dev47 note claiming no waiting
screen was needed was simply wrong.

The damage was not the gap. In order: the peer generated 2-1 alone on its own
evolved seed; the stall detector resync-warped the party to 2-1 on the host's seed;
and the peer generated 2-1 **a second time**. The HD mod builds its levels in Lua and
advances its own state while doing it, so the peer's second 2-1 was a different world
-- `FLOOR DESYNC seq=17`, seed matching (544689640 on both) and entities not
(586027692 vs 1409357526): Jungle frogs and a tikiman on one machine, jiangshi, a
vampire and an eggplant altar on the other.

### The barrier

A machine that reaches the exit announces `tready` for that transition and is then
held until every slot still in the run has done the same, with the existing WAITING
FOR PLAYERS plaque shown while it waits.

The hold is the same one `suppressMenuScreens` uses for the settings screen: refuse
the screen change on the frame the engine commits to it, from inputSync's PRE_UPDATE
because that is the only callback that fires during a fade. That keeps the lockstep
gate engaged and keeps the held machine recording and sending input, so holding
cannot cause the stall it exists to prevent -- to everyone else the player is simply
standing on the transition, which is what they are.

It gives up after 20 seconds and says so in the log. A player who crashed or alt-F4'd
will never signal, and the resync is a worse outcome than the hold but a much better
one than a party frozen with no way out.

### Two initialisation bugs found by writing the tests

Both were "0 means unset" mistakes on values that can legitimately BE 0, since
`get_ms()` is milliseconds since launch:

* `heldMs == 0` meant "not holding", so a hold beginning in the first millisecond
  after launch would never start its give-up timer. Now an explicit flag.
* `sentMs = 0` meant "announced at time zero", which skipped the FIRST announcement
  whenever the clock was within a second of the reset -- the barrier would then hold
  until the resend a second later. Now `nil`.

### And one that did not compile at all

The first draft declared eleven new locals in eventSync's main chunk. Lua's hard
limit is 200 per chunk and the file was within a handful of it, so it failed outright
-- caught by `tests/test_lua_compiles.py`, which exists because `luaparser` is more
permissive than real Lua. All of the barrier's state is on one table now.


## 2.0.0-dev47

Mama Tunnel works in co-op. **Both players need dev47** -- this changes what a
peer's machine reads while a floor is built.

### What was actually wrong

The dev46 capture desynced at the **1-4 -> 2-1 transition**, not at 1-2: the
sequence jumps 7 -> 17 there, with 34 lockstep stalls, a resync warp, and a
position desync on the floor after. dev44, with QUEST_FLAG.SEEDED still set, ran
1-1 to 3-4 with zero of any of those.

The cause is not the interaction, it is the STARTING STATE of the transition
screen. Mama Tunnel's encounter is decided from `savegame.shortcuts` -- the local
player's own shortcut progress. One player got the cutscene, the other walked
straight through, and two machines on different screens holding different entities
cannot be held together by lockstep. Removing QUEST_FLAG.SEEDED is what re-enabled
the shortcut flow at all; a seeded run has neither that nor the unlock branch.

### The fix

The room host publishes `savegame.shortcuts` and `savegame.characters`, and every
peer adopts them for the moment a mod reads them. Same shape as the pet-style sync
that already existed, and it leaves the lockstep core untouched.

`characters` is in there because it is the other half of the same problem: the HD
mod picks a per-floor character unlock from it and draws from the level-generation
PRNG to do it, so two players with different unlocks consume a different number of
draws. That is the 1-2 / 2-1 desync predicted when the flag came out.

With the transition identical on both machines, the interaction is just button
presses -- which are lockstepped already -- so no waiting screen is needed. Both
players see her, the party's decision plays out the same way on both machines, and
progress lands in each player's own save afterwards.

### The dangerous part is the restore, and it is what the tests are about

`set_setting` (the pet style) is documented as temporary. `savegame` is EXACTLY
what the game serialises into `savegame.sav`, so an override left standing is one
that writes the HOST's progress into a PEER's file.

It is therefore held only across a load and released the moment the screen settles
-- the same technique the HD mod uses on this very field, where
`prevent_shortcut_encounter` sets `savegame.shortcuts` and restores it on the next
`ON.POST_UPDATE`. The release runs every frame rather than on a hook, there is a
five-second watchdog behind it for a load that never completes, and the run-end
path releases too. No write can happen while the override is up, and if the process
dies mid-override the file on disk was never touched: we only ever wrote memory.

`tests/test_save_sync.py` covers all of it -- restore on settle, the watchdog, the
host never overriding itself, only the room host being authoritative, every field
restored rather than just the first, and a second hold being unable to record the
host's value as the player's own.

### One placement worth naming

The hold sits ABOVE `onPreLoadScreen`'s `screen_next ~= SCREEN.LEVEL` check. A Mama
Tunnel encounter is a `SCREEN.TRANSITION`, so a hold placed below that line would
have been skipped for precisely the screen it exists for. A test pins the ordering.


## 2.0.0-dev46

`QUEST_FLAG.SEEDED` is no longer set. Requested explicitly, with the cost stated
and accepted. **Both players must be on dev46** -- one machine setting the flag and
the other not is a generation mismatch by itself.

### What changes

The seed stops appearing in the top-right HUD; the run presents as an ordinary
adventure run again. Networked runs will also start RECORDING progress to your save
once more, which is the other half of what the flag suppressed.

`markRunSeeded`, `clearRunSeeded`, `QUEST_SEEDED_BIT` and the three call sites are
gone, along with `tests/test_seeded_run.py`.

### The risk this reopens, stated plainly

The flag was not cosmetic. Unseeded, the HD mod picks a per-floor **character
unlock** from the LOCAL player's own unlocked roster, and draws from the
level-generation PRNG to make the choice. Two players with different unlocks
therefore consume a different number of draws, and everything generated afterwards
lands somewhere else: same seed, same mods, same settings, completely different
level. It is gated on `world == unlocked + 1` plus a per-world theme, so it breaks
at the FIRST eligible floor of each world -- **1-2** in Dwelling and **2-1** in
Jungle. Two separate captures desynced on exactly those floors before the flag was
added.

If that returns, it will look like an unexplained generation desync at 1-2 or 2-1.

### The instrument is deliberately kept

`seeded=` stays in the `gen[pre]`/`gen[post]` lines of the desync log. It no longer
echoes something we did -- it now reports what the engine and other mods left the
flag as, which makes it worth more than before, not less. A desync at 1-2 or 2-1
with `seeded=0` on both machines is this, confirmed.


## 2.0.0-dev45

The pinned test seed is gone. Nothing about how a normal run is seeded changes:
the server still rolls an adventure seed and hands it to every machine, which is
the whole basis of lockstep.

### What went

`config.testSeed`, the **TEST SEED** field in the menu, `Network.parseSeed`,
`Network.pinnedSeed`, and the server's `parse_pinned_seed` / `Room.pinned_seed`.

It existed to make a floor that crashed reproducible on demand -- pin a seed, and
instant restart replays the same run instead of rolling a new one. It never
reliably did that; `netCore` still carried a note about "a pinned seed that a
restart re-rolled" as a known symptom, and the pin had to be re-sent on every
restart to work around the room forgetting it.

The server now IGNORES a `seed` field on `start` and `restart`. That is worth a
test rather than an assumption: the public server sees clients of several
versions, and one from before this release still sends the field. `test_server.py`
checks it cannot steer a run.

`seed` remains a parameter of `start_run` -- it carries the host's seed on a
MID-RUN JOIN, which is unrelated and load-bearing.

### Also removed

`config.autoShim`, a default with no readers since injection was replaced by
hosting in dev42.

### QUEST_FLAG.SEEDED stayed in this release

...and was removed in dev46 at the user's request, after the trade-off below
was put to them. See that entry.

## 2.0.0-dev44

The profiler paid for itself on its first session: it named the two most expensive
things Modded Online does, and one of them was a module already suspected of being
dead. Server unchanged. Determinism unchanged except where stated.

### What the capture said

An eleven-minute hdmod run, 60fps, with 9-19 frames per ten seconds over 20ms --
small, frequent hitches rather than big stalls, which is what "stuttery" describes.
Modded Online's own callbacks came to about 5% of wall time in total. Two entries
stood out, and both were spikes rather than averages:

```
PROFILE   0.6% of window,     600 calls, worst   34ms, spikes   1  ours eventSync.lua:4059
PROFILE SPIKE worst   16ms,   1 over 8ms,    4149 calls  ours optionSync.lua:392
```

### optionSync is gone (397 lines)

It published the host's mod settings so everyone in a room played on the same
values. It could not have worked since dev42: the half that *applied* them ran
inside each pack's own Lua state and arrived there in the injected block. What was
left wrote a file nothing reads, from a callback on every GUI frame, spiking 14-16ms.

**A real gap comes with it, and it is not new to this release.** Mod options feed
level generation, and they are now neither synchronised nor gated -- `netCore`
deliberately left them out of the join key *because* optionSync was syncing them.
Two players whose hosted-mod settings differ will generate different worlds from the
same seed. Set them the same on both machines. The comment in `loadOrderSignature`
now says this instead of the opposite, the README says it where players will see it,
and closing it properly means gating on a filtered subset of options -- a design
decision rather than a tidy-up, because the mod-picker checkboxes are options too
and legitimately differ between two players with different mods installed.

### The world mailbox is gone (80 lines)

Four bytes smuggled through `state.arena.player_lives` to carry a content mod's own
world counter between machines, because "Playlunky gives two packs no channel between
them". Hosting removed that barrier -- the mod runs in our state, and its world
counter is a value in its own module table. The remaining half could not fire: the
producer needed a `MAILBOX_PUB` tag that only the injected block ever wrote, so
`meta.cw` was never set and the write path never ran.

### The leak sweep: every 30 simulated frames -> every 150

The largest spikes in our own code -- not the largest average, which is the input
gate at ~2.3% of wall time, but a 0.6% average hiding a 34ms frame. It walks every
`MONSTER|ITEM|ACTIVEFLOOR|DECORATION|FX|EXPLOSION|ROPE` entity on the floor with a
`get_entity` and a `pcall` each, allocating a uid list and two tables every time,
twice a second -- and it destroyed nothing at all across the whole capture.

**This costs no destruction latency.** An entity is destroyed at the first sweep
where `now - since >= SWEEP_GRACE` (300 frames), and both values are multiples of the
interval: first seen at sweep 150, destroyed at sweep 450, exactly 300 frames later,
which is what an interval of 30 gave too. Only the delay before an entity's *first*
sighting grows, by at most 2.5s, against a grace period deliberately set to 5s.
`tests/test_leak_sweep.py` pins the arithmetic, because an interval that does not
divide the grace would cost latency silently.

It is lockstep-critical: every machine must use the same interval or they destroy
different sets on different frames. Both players must be on dev44.

### ...and it can no longer re-sweep a stalled frame

`POST_UPDATE` fires per rendered frame. While the lockstep gate holds the simulation
still, `state.time_level` stops advancing -- and if it stopped on a multiple of the
interval, the scan ran again on every rendered frame of the stall. Harmless, but it
is most of the work in the worst frames measured, and a stall is when the game can
least afford it.


## 2.0.0-dev43

The profiler can now see a stutter, and is on without anyone arming it. Server
unchanged. No change to gameplay, networking or determinism.

### On by default

It was behind `mo_profile.on`, and three sessions running came back with
`profile=off` in the header. The flag file lives in the pack folder, so installing
a new build replaces the folder and takes the flag with it. A diagnostic that is
only armed when someone remembers to arm it is not armed. `mo_profile.off` turns
it off.

Measured cost with it on: **0.0039 ms per frame** across twelve per-frame
callbacks -- the same as the 0.003 ms measured with it off, because our own
callbacks add no clock reads at all. The registry already stamps `lastRanMs` for
the revival sweep, so the start time is a value we were recording anyway; only a
hosted mod's callbacks add a `get_ms` each.

If `get_ms` is missing the profiler stays quiet rather than reporting all zeros,
which would read as "nothing costs anything" when it means "nothing was measured".

### An average cannot see a stutter

The old report ranked callbacks by share of wall time. A callback costing 25ms once
a second is 2.5% of the window: it ranks near the bottom of the list while being
exactly what the player feels. Every report now carries the worst single call and a
count of calls over 8ms, and anything that spikes without being expensive on
average gets its own line even when it misses the ranking:

```
PROFILE frames=711 in 10.0s  worst=39ms  over-20ms=0  over-33ms=2
PROFILE   7.1% of window,     711 calls, worst    1ms, spikes   0  ours inputSync.lua:2019
PROFILE SPIKE worst   25ms,   2 over 8ms,     711 calls  mod  feats.lua:214
```

### Frame timing, independent of blame

The frames line is measured directly, once per frame, and is not about callbacks at
all. It answers the prior question -- are the frames hitching, and by how much --
and if our callbacks account for none of it, that is itself the answer: the cost is
in the engine or in the hosted mod's own per-entity updates, where a callback
profiler cannot see it. Deltas over 250ms are ignored, since those are levels
generating or the window being alt-tabbed away from, and counting them would put a
4,000ms "worst frame" at the top of every report and bury the 30ms one.

Unlike the revival sweeper, this is registered on GAMEFRAME only: it must run
exactly once per frame or the deltas are meaningless.


## 2.0.0-dev42

**The shim is gone.** Server unchanged.

### 9,636 lines removed

`src/shimInjector.lua` was 41% of the entire codebase: the determinism payload plus
all 27 versions kept verbatim so an old block could be stripped by exact text.
Nothing writes those blocks any more -- hosting replaced injection -- and it had two
live references left, one of which barely worked. Only nine of the twenty-seven
were reachable from the module, which is how hdmod's v21 block sailed through and
ran our determinism a second time inside ours.

`stripPayloads` is now `ourBlockIn`: five lines that find the marker. A mod still
carrying one is refused with an explanation, which is what already happened
whenever stripping failed.

### What else went

* the shim's restart prompt in the menu
* `spike1`'s payload extraction and un-shimming; it refuses a shimmed pack instead
* `spike2`'s `--link`, `--unlink`, `--apply`, `--revert`, `--setup`, and the five
  helpers left orphaned behind them. The mod picker does all of it from inside the
  game, and two ways of arranging the same files is how they came to disagree.
* six test files, 108 tests, whose subject was the shim payload itself

**247 passing**, down from 355. Every removed test was of removed code; the ones
that remain all still pass, and `tools/spike1.py` still hosts 2.5's 633 modules.

### Also

The desync log header now says whether the profiler is on. A log with no PROFILE
lines otherwise means either the flag is missing or the session was shorter than
one ten-second report, and those need different advice.

---

## 2.0.0-dev41

A profiler, because the crash breadcrumb cannot answer "it feels stuttery".
Server unchanged.

### Why the trace came back empty

The log said `frametrace=ON` and contained no trace lines at all. `mo_trace.on` is
a **crash breadcrumb**: it records what was running when the process died, and
reports only frames over a spike threshold. A session of many small hitches
produces exactly what came back -- nothing.

Worse, it writes a line to a file for every marked callback on every frame, so
leaving it on is itself a cause of stutter. It should be deleted when not chasing
a crash.

### mo_profile.on

Every callback wrapped by the registry is timed -- ours and the hosted mod's alike,
since both go through a wrapper already -- and a summary goes to the desync log
every ten seconds. `mod` and `ours` are labelled separately, which is the first
question worth answering: whether the cost is the loader or the mod it is hosting.

*(Superseded in dev43: on by default, and it reports spikes as well as averages.)*

## 2.0.0-dev40

Two pieces of redundant per-frame work removed. Server unchanged.

### Measured first

Over 20,000 frames -- about five and a half minutes of play:

```
our callbacks, unwrapped     3.8 ms total
our callbacks, wrapped      62.5 ms total     ~0.003 ms per frame
sweeper scan, 3x per frame  30.3 ms total
```

So the callback wrapper and the revival scan are **not** a stutter, and neither is
worth removing on performance grounds. Worth knowing before changing anything.

### What was genuinely redundant

**The network tick ran twice a frame.** dev7 added a PRE_UPDATE pump because a
hosted mod's teardown can take the GUIFRAME one away and then nothing drains the
receive queue. That is worth guarding; doing the work twice on every frame of a
healthy session is not. It now runs only when a GUI frame has not been seen for
100ms, so the safety net is intact and the duplication is gone.

**The revival scan ran three times a frame.** It is registered on three callback
kinds so that losing any one still leaves a survivor to revive the rest -- that
part matters. Scanning on each of them did not: the tightest budget is 300ms, so a
scan every 250ms detects everything just as fast.

### If it is still stuttery

The numbers above say it is unlikely to be us. The likelier causes are the
conversion caches cleared in dev39, which make the first launch or two rebuild a
great deal, and the hosted mod itself running in the same Lua state.
`create mo_trace.on` for the per-frame trace if it persists.

**353 passing.**

---

## 2.0.0-dev39

**An image_map patches VANILLA textures, globally.** Server unchanged.

### Where the textures were actually coming from

"Even with no script mods enabled, we saw some hdmod textures" ruled out every
pack, ours included. They were in Playlunky's global generated tree:

```
.db/Data/Textures/   deco_eggplant, deco_extra, deco_ice, floor_babylon,
                     floor_eggplant, floor_sunken, floormisc, floorstyled_pagoda,
                     floorstyled_vlad, floorstyled_wood, fx_rubble,
                     journal_stickers        -- all stamped Aug 27 18:05
```

Twelve files: exactly hdmod's twelve `image_map` targets. A map does not only
affect the pack declaring it -- Playlunky applies it to the **vanilla** texture and
writes the result to a tree shared by every session. Our pack carried hdmod's map,
so hdmod's patches were burned into the vanilla atlases, and taking the map away
gave Playlunky no reason to undo them.

**Nothing inside our own pack could have fixed this**, which is why cleaning it
over and over did not, across five releases.

### Recorded going in, removed coming out

Installing a map now records the atlases it will make Playlunky rewrite; the
teardown deletes exactly those generated files and the global index, and Playlunky
rebuilds them from `.db/Original/` -- the pristine copies it keeps for the purpose.
Only names we recorded are touched; a test asserts an unrelated global texture
survives.

### Also fixed on this machine

The twelve patched atlases have been removed and the index cleared, with copies
kept aside. The next launch regenerates them from the originals.

**353 passing.**

---

## 2.0.0-dev38

Two bugs of mine, both visible in one console screenshot. Server unchanged.

### Every boot tore down its own working setup

```
clearing what an earlier version left in this pack:
  Data/ removed          <- the setup that was working
  res/ removed
  conversion cache cleared
the setup is incomplete (...)   <- because it had just been deleted
  fyi.spelunky-25-2: Data linked  <- rebuilt from scratch
```

`migrate` was made to delegate straight to the teardown in dev33, and stopped
telling an older version's leftovers apart from the setup in use. Playlunky mounts
before any of that runs, so its view was permanently **one boot stale** -- after
switching to 2.5 the game was still showing hdmod's textures, because the ones it
had mounted were what the previous boot rebuilt. It also cleared the conversion
cache every launch, so nothing was ever converted twice in a row.

The `.mo_source` mark tells them apart: assets belonging to the armed mod are the
current setup, anything else is residue. A working setup now survives a boot
untouched.

### "TEXTURES NOT FOUND" for textures that were present

```
TEXTURES NOT FOUND under this pack -- its assets are not linked in:
res/MISC/notexture.png, res/TRAPS/turret.png, res/ATLASES/textures10.png ...
```

All present. 417 files in `res/`, 417 in ours, subdirectories and all. They were
**skipped on purpose** by dev36's rule and filed as missing, which is a different
thing and points at a different cause. Wrong diagnostics have cost more launches
here than wrong code, so the two are counted separately now:

```
  214 texture definitions skipped on purpose (see the line above); the files
  themselves are present
```

**351 passing.**

---

## 2.0.0-dev37

**Found it: Playlunky never converted our copies.** Server unchanged.

### The numbers

```
                raw res    converted res
our pack          205            0
fyi.hdmod         205          176   (including cameo_yang.DDS)
```

Playlunky does not serve a pack's PNGs to the game -- it serves the DDS it builds
from them. hdmod has those; our copies were never built. So hosted,
`define_texture("res/cameo_yang.png")` had nothing to load and killed the process,
while hdmod on its own worked perfectly. That is exactly the pair of facts reported,
and it is not the links, the paths, the setup or the mod.

### res is borrowed; Data is not

dev28 stopped borrowing the mod's converted output because doing so applied its
`image_map` twice -- hdmod's wall decoration came out wrong. That reasoning holds
for `Data/`, which is what a map writes INTO. It does not hold for `res/`, which is
what a map reads FROM: those are the mod's own images, converted plainly, with
nothing baked in.

So `res/` is borrowed and `Data/` is left for Playlunky to build. Both halves of
dev28's finding survive.

Hosting is refused if the borrow did not happen, rather than crashing on the first
texture; and a mod that has never been launched on its own has no converted tree to
borrow, which the setup now says in as many words.

**347 passing**, including one asserting `res` is taken and `Data` is not.

---

## 2.0.0-dev36

Server unchanged.

### What the boot log settled

```
  fyi.hdmod: define_texture res/locked_feat.png
  fyi.hdmod: define_texture res/cameo_yang.png     <- last line
```

The assets are fine. `res/` holds all 205 of hdmod's files, `cameo_yang.png` among
them, hard-linked (`link count 2`) -- and the call before it **succeeded**. So this
is not a missing file, not a broken link and not a stale folder. Particular
`define_texture` calls kill this engine build, and the ones that die are the cameo
textures, which are built by mutating a vanilla definition rather than a fresh one.

### One crash is enough

dev24 remembered the exact call that died and skipped it next boot. hdmod defines
around twenty cameo textures the same way, so that converges at one launch per
texture -- useless.

The first crash is now taken as evidence about the engine, not about the file:
once any `define_texture` has died on this machine, none are attempted again.

```
mod host: not defining fyi.hdmod's textures. A define_texture call has crashed
this machine before, so none are attempted -- the mod runs with vanilla sprites
and everything else intact. Delete mo_fatal_calls.txt in this pack to try again.
```

World generation, callbacks, levels, sounds and multiplayer are untouched. One
crash, then a mod that runs.

**344 passing.**

---

## 2.0.0-dev35

**Removes `fyi.modded-online-assets`, a pack dev32 created and dev33 abandoned.**
Server unchanged.

### The wrong textures were coming from a pack of ours

dev32 moved a hosted mod's assets into their own pack. That could not work --
Overlunky resolves a relative asset path against the pack root of the script that
ASKS, and the asking script is ours -- so dev33 reverted it.

The revert stopped *creating* that pack and left the one already on disk. Still a
folder, still a `load_order.txt` line, still a converted tree, still full of hdmod's
files -- and Playlunky went on mounting it in every session afterwards, including
ones where nothing was hosted. Disabling it by hand is what finally fixed the
textures, which is the correct diagnosis: it was ours, and it should never have
outlived the release that made it.

### Removed on sight

The folder, its converted tree and its load_order line, at boot and in
`--clean`. Two tests cover it, one for the folder and one for the line: a pack
removed but still listed is only half a fix.

### A rule this should have followed

A revert has to undo what the change DID, not just stop it doing it again. dev33
described itself as a revert while leaving its predecessor's artefact in place on
both machines, and cost two more sessions of wrong textures for it.

**343 passing.**

---

## 2.0.0-dev34

**The mix of two mods' textures, explained and refused.** Server unchanged.

### What was happening

`rmdir` fails **silently** on a directory Playlunky has mounted -- and it mounts
every one of these at startup. So pressing *Undo Modded Online's setup* removed
nothing, reported nothing, and ticking the next mod then mirrored its files **on
top** of the previous mod's. One folder, two mods' textures. That is the mix.

This constraint has been in the code's own comments since dev20 and the teardown
never checked for it: `clearAssets` called `rmdir` and moved on without asking
whether anything had actually gone.

### Refused, not blended

Every removal is verified now. If the previous mod's files are still held open, the
swap is **abandoned whole**:

```
NOTHING CHANGED YET. Close Spelunky and start it again -- the swap finishes on
the next launch, before anything is mounted.
```

Nothing is half-done: no new files are mirrored, the armed selection is left
pointing at the mod that IS set up, and the load order is untouched. The next boot
retries the whole thing from a clean state. Blending is worse than doing nothing,
because doing nothing says so.

### Note on the in-game button

It can write files and edit the load order from inside the game. It cannot delete
asset folders the running game has mounted, and no version of it ever could. When
that is what is needed it now says so rather than appearing to succeed.

With the game closed, `py tools/spike2.py --clean` has no such limit.

**341 passing.**

---

## 2.0.0-dev33

**dev32's separate assets pack was wrong. Reverted; the discipline is kept.**
Server unchanged.

### Why it crashed

Overlunky resolves a relative asset path against the pack root of **the script that
asks**: `list_dir` is documented "relative to the script root", `create_sound`
"relative to this script". Hosting means the script asking is ours, so hdmod's
opening `define_texture("res/locked_feat.png")` is looked for in OUR folder.

That constraint is the entire reason the assets were there. I moved them for
tidiness without re-checking it, and the first texture died.

### What is kept

The separate pack was the wrong answer to a real problem -- state outliving the mod
it belonged to. The answer is the teardown, not the location.

`clearAssets` removes **all** of it: linked folders, copied files, the sprite map,
the source mark, Playlunky's converted output for this pack, and its `mod.db`. It
runs before every build. Nothing is kept because it looks current -- deciding what
to keep is how one mod ended up serving another mod's files, four separate times.

Also kept from dev32: leftovers from older versions cleared automatically at boot,
the deletion boundary, hard links rather than junctions, never borrowing a mod's
converted output, and determinism only while a room is live.

### Honest note

This reverts a design change I recommended and you approved on that recommendation.
The reasoning was right about the problem and wrong about the constraint -- which
was written in `packSetup.lua`'s own first line, by me, and which I did not re-read
before proposing to move the assets.

**339 passing.**

---

## 2.0.0-dev32

**A hosted mod's assets live in a disposable companion pack.** Server unchanged.

### Why the links are needed at all

Hosting means running the mod's Lua in OUR state. If the mod stays enabled,
Playlunky runs its `main.lua` a second time in its own VM -- two live copies, every
callback and texture doubled. So hosting requires disabling it, and disabling it
stops Playlunky mounting its assets. There is no assets-only mode in
`playlunky.ini`: a pack is loaded whole or not at all.

The links are required *by hosting itself*. Enabling the mod normally means not
hosting it, and hosting is the only way to reach the mod's own `math.random` and
`pairs` without editing its `main.lua`.

### fyi.modded-online-assets

Every bug here had one shape: state accumulating in the pack that also holds our
code, and outliving the switch that should have removed it. A stale `mod_info.json`
applying one mod's sprite map to another's textures. Converted output surviving in
`.db/Mods/<us>/Data/Textures` with no `Data` behind it -- still served, with Modded
Online switched off. Four of those were fixed one at a time and a fifth appeared.

The companion holds the hard links, the copies and the sprite map, and **no
`main.lua`**, so Playlunky serves its assets and runs no script. It exists only
while a mod is hosted, and its line in `load_order.txt` appears and disappears with
it.

Stopping is now **one delete**: the folder and its converted tree. Not the reversal
of half a dozen changes -- nothing survives a step that was missed, because there
are no steps to miss. Our own pack holds only our code again.

### Old state is cleared on sight

Both machines have assets and converted output in the loader pack from earlier
versions. The first boot removes them and says what it removed. No commands to run.

### Kept

Hard links rather than junctions; the deletion boundary; the one-asset-mod rule;
never claiming a `load_order` line the player commented themselves.

**339 passing** -- fewer than dev31 because tests of the old layout were replaced,
not deleted: the ones that matter now assert the companion holds the assets, our
pack holds none, and neither mod's own files are ever touched.

---

## 2.0.0-dev31

Two bugs, both of them ours. Server unchanged.

### Every 1-1 with the same level feeling

`determinism.lua` had no reference to `Network` or `isInRun` anywhere. It seeded the
mod's `math.random` from the floor base on **every** floor -- in a room or not. So
single-player runs repeated themselves.

Determinism is for agreeing with another machine. Outside a room there is no other
machine, and forcing it there is not neutral. It is gated on a live run now, and
**hosting a mod no longer changes how it plays alone**.

### A hosted mod's textures in a different mod, with Modded Online off

Our pack held no `Data` folder at all, and this was still on disk and still being
served:

```
.db/Mods/fyi.modded-online-loader/Data/Textures/base_eggship.DDS
```

Playlunky's converted output for our pack outlives the assets it was built from. It
is keyed to the pack folder, not to the load order, so disabling Modded Online does
not stop it being used -- which is how one mod's textures reached another with the
loader switched off on both machines.

Clearing now removes that whole tree including its `mod.db`, and leftover converted
output counts as a leftover, so the boot-time clean catches it too. That folder is
ours end to end -- Playlunky's output for our own pack -- so it is inside the
boundary dev30 drew.

### The "globals not found" lines are not errors

`item_draw_info`, `sp25DebugLogging`, `Sp25GameStateClass` and the rest are names the
mod READ that were not defined at that moment -- either engine APIs this Playlunky
build does not have, or the mod's own globals it sets later. Both mods report
`LOADED` on the same line, with 199 and 633 modules. It is a report, not a failure.

**353 passing.**

---

## 2.0.0-dev30

**We destroyed other mods' converted textures.** Server unchanged.

### What happened

Versions before dev28 junctioned `.db/Mods/<us>/res` and `.db/Mods/<us>/Data` at
another pack's converted output, and the teardown then deleted recursively THROUGH
those junctions.

```
fyi.hdmod/Data/Textures        34 files   (source, untouched)
.db/Mods/fyi.hdmod/Data/...     0 files   (converted, deleted)
fyi.hdmod/res                 205 files   (source, untouched)
.db/Mods/fyi.hdmod/res          1 file    (converted, deleted)
```

No mod's own files were lost. What was destroyed is the DDS Playlunky builds from
them -- and `mod.db` still listed every one as converted, so Playlunky rebuilt
nothing. The mod then would not boot **on its own, with Modded Online switched
off**, which is exactly the report.

The junction check meant to prevent this was added in dev26 and was not enough.

### A boundary, not a check

`removeMirror` now refuses any path that is not inside our own pack or our own
`.db` folder, whatever shape it turns out to be. `--clean` refuses the same way.
Detection can be wrong; a boundary cannot. Modded Online has no business writing in
another pack's folder at all, which is the whole promise of not editing mods.

### Repairing what was already broken

```
py tools/spike2.py --repair
```

Finds packs whose converted tree is far emptier than their source and clears their
conversion cache, so Playlunky rebuilds from the mod's own files on its next launch.
That launch is slow; nothing is lost.

**352 passing**, including one asserting that switching mods leaves both mods'
source AND converted files untouched.

---

## 2.0.0-dev29

**A hosted mod's assets must not outlive the hosting.** Server unchanged.

### The failure

Host a mod, play, quit, then launch that mod normally with Modded Online switched
off: one machine would not boot at all, the other booted wearing the wrong textures
-- with the loader disabled.

Playlunky serves what is in a pack folder. Our mirrored copy of the mod's `Data`,
`res` and `soundbank`, and the copied `mod_info.json` and string files, were all
still sitting there. Re-enable the mod and two packs supply the same files.

This is the state `spike2.py`'s old `incoherent()` guard was written for, back when
the setup was a script. The in-game picker never learned it.

### Cleared as soon as nothing is hosted

If the loader boots with no mod selected but its folder still holds one's assets, it
clears them and says so. Unticking a mod is now enough on its own.

### And a way out with the game closed

```
py tools/spike2.py --clean
```

Removes the mirrored folders, the copies, the host flag and the converted output,
and puts back exactly the `load_order.txt` lines we commented. Written for the case
the in-game button cannot reach: nothing can run inside a game that will not start.

It checks each folder's shape before deleting it. `shutil.rmtree` on hard links
removes those names only; the same call THROUGH a junction destroys the mod it
points at, and anyone who set up before dev26 still has junctions. A test asserts
the mod's files survive.

### Still open

Textures not updating when switching between mods. dev27 clears the copies and dev28
stopped borrowing converted output, so the next switch should be clean -- but the
first boot after one has a lot of converting to do and is slow, not stuck.

**351 passing.**

---

## 2.0.0-dev28

**The wall decoration was patched twice.** Server unchanged.

### What was happening

hdmod's `image_map` slices its own `res/*.png` INTO twelve vanilla atlases:

```
Data/Textures/deco_ice.png    <- res/boulder.png
Data/Textures/deco_extra.png  <- res/bouldertrap_deco.png
Data/Textures/floormisc.png   <- res/tikitrap.png, res/elevator.png, ...
```

The setup hard-linked hdmod's **already-converted** `.db` output into our pack. That
output has the image_map baked in. Playlunky then read our copy of the same map and
applied those patches a second time, on top of themselves -- so precisely the
twelve patched atlases came out wrong, and everything served whole looked right.

### The converted tree is no longer borrowed

It was only ever borrowed because junction-linked assets were invisible to Playlunky
-- it catalogued them and converted nothing, so the mod's own DDS had to stand in.
dev26's hard links made the raw files visible, which fixed the crash and made this
workaround harmful in the same stroke.

Playlunky converts our pack from the mirrored raw files now, applying the map
exactly once. **The first boot after a switch has real work to do** -- 124 MB of
PNGs for hdmod -- and takes noticeably longer for it.

### Two requirements that came with it are gone

A mod no longer has to have been played normally first. That refusal existed because
a mod that had never been enabled had no converted output to borrow; nothing needs
it now.

**349 passing.**

---

## 2.0.0-dev27

**The crash is gone** -- dev26's hard-link mirror did it. Server unchanged.

### The leftovers

```
Custom image mapping from file res/worm_deco.png is registered for mod
fyi.modded-online-loader, but the file does not exist in the mod
```

That is hdmod's `image_map` being read against 2.5's `res/`. Switching mods cleared
the mirrored folders and `savegame.sav`, but **not** `mod_info.json` and the string
mods -- neither is in COPY_FILES, both were handled separately on the way in and
forgotten on the way out.

So the previous mod's sprite remapping and text stayed behind and were applied to
the next mod. That is the 2.5 run wearing some of hdmod's textures, and the missing
sounds and text in a 2.5-only boot.

Both are cleared on a switch now.

### And the state that is already on disk

Fixing the teardown does nothing for a pack that is *already* holding the wrong
copies -- which both machines are right now. `mo_assets_from.txt` records which mod
the root copies came from, and the setup check reports a mismatch:

```
the copied mod_info.json and string files came from fyi.hdmod, not
fyi.spelunky-25-2 -- untick the mod and tick it again to rebuild them
```

Copies from a different mod are worse than copies that are missing: they are applied,
silently and wrongly, rather than simply being absent.

**349 passing.**

---

## 2.0.0-dev26

**Assets are mirrored as hard links now, not junctioned.** Server unchanged.

### The one fact that survived every wrong theory

`io.open` reads `res/locked_feat.png` through our junction perfectly on the machine
that crashes -- that is *why* the dev21 guard let the call through -- and the engine
still cannot find it.

A junction is a reparse point. Lua's `io.open` follows one without noticing. A
directory walk that skips reparse points, as file-system code often does to avoid
loops, never sees the files at all. That is precisely a texture Lua can read and the
engine cannot, which is the crash.

### Hard links have nothing to traverse

A hard link is not a reparse point; it is another name for the same file. Nothing to
skip, nothing to follow, and no extra disk -- the two names share the data. hdmod is
499 files and about 160 MB, which takes a moment and no more.

Each mirrored folder carries a `.mo_source` file naming the mod it was built from,
which is a plainer answer to "whose files are these?" than parsing `dir /al` for a
bracketed target -- and does not depend on the word JUNCTION, which is localised.

### The upgrade hazard, handled

`rmdir /s` on a folder of hard links deletes those names only; the mod keeps its own
and the data survives. On a **junction** the same command deletes straight through
it and destroys the player's mod -- and anyone upgrading from the previous layout
has exactly that on disk. So the shape is checked before the command is chosen, and
a test asserts the mod's files are still there afterwards.

### If it works

`mo_notextures.on` can be deleted and the custom textures come back. If it does not,
that file still gets the game running.

**347 passing.**

---

## 2.0.0-dev25

Server unchanged.

### Both escape hatches needed a boot to survive first

The dev24 log has neither a `previous boot stopped after:` line nor a
`skipping hosted textures` line. So the sticky list was never seeded and the
checkbox was never on -- and both were shipped for a machine that crashes during
boot, which is the one situation where a player cannot reach an options panel or
complete a launch. That was the wrong shape for the problem twice over.

### mo_notextures.on

An empty file in the pack folder. If it exists, every `define_texture` from a
hosted mod returns -1 without reaching the engine. No menu, no saved setting, no
surviving boot required -- the same reasoning as `mo_host.on` itself, and for the
same reason: *if hosting a mod takes the game down before a menu can be drawn,
a file is the only thing that still works.*

The boot trace names which way it went, so a log answers "was it actually on?"
without anyone having to ask:

```
hosted textures: DISABLED (mo_notextures.on)
```

The mod runs with vanilla sprites. World generation, callbacks, saves and
multiplayer are untouched.

**347 passing.**

---

## 2.0.0-dev24

Server unchanged.

### Why dev22's skip never fired

The dev22 log has no `previous boot stopped after:` line, so `unfinished` was nil
and there was nothing to skip. The boot trace is **truncated every launch**: reading
the previous run's last line only tells you anything if that run was the crash. One
successful boot in between -- or moving the file somewhere to send it -- and the
record is gone. Depending on it was the wrong design.

### A list that only grows

A call found to have killed a boot is now appended to `mo_fatal_calls.txt` in the
pack, and consulted on every boot from then on. It survives good boots, moved logs
and reinstalls of the mod. Delete the file to try the call again.

### And a switch that depends on nothing

**Skip hosted mods' custom textures** -- a checkbox under Modded Online. Every
`define_texture` from a hosted mod returns -1 without reaching the engine. The mod
runs with vanilla sprites; world generation, callbacks and multiplayer are
untouched.

Everything else added for this crash needs to survive a boot before it can learn
anything. This does not, which is the whole reason it exists: a machine that will
not start has no way to tell you why.

Read straight from the option rather than through the picker, so it still works if
the picker itself failed to load.

**345 passing.**

---

## 2.0.0-dev23

Server unchanged.

### The gap the raw-file check left

dev21's guard let `define_texture(res/locked_feat.png)` through, which it only does
when the file is present under our pack. So the raw file was reachable and the call
still killed the process.

Playlunky does not serve a pack's PNGs to the game. It writes DDS into
`.db/Mods/<pack>/` and the engine reads textures from **there**. `setupProblems`
checked the raw `Data`/`res`/`soundbank` links and whether the MOD had a converted
tree -- but never whether OUR converted links exist or point at the right mod.
Which is exactly the check that would have caught a machine where the raw file is
reachable and the converted one is not.

It checks both now, and refuses:

```
mod host: NOT hosting fyi.hdmod -- its setup is incomplete: the converted res/ was
never linked into fyi.modded-online-loader -- the game reads textures from there,
not from the raw files.
```

### Why the first boot works and the second does not

Boot 1 has nothing selected, so nothing is hosted and nothing asks for a texture.
It also creates the links. Boot 2 hosts, and asks -- and Playlunky may not have
produced our converted tree yet, because on boot 1 our pack had no assets for it to
convert.

If that is the shape of it, the refusal above appears instead of a crash, and the
boot AFTER it should work: Playlunky will have converted by then.

**343 passing.**

---

## 2.0.0-dev22

Server unchanged.

### What dev21 established

```
  fyi.hdmod: define_texture res/locked_feat.png     <- last line
```

The guard let that call through, which it only does when the file IS present under
our pack. So the junction is right, the texture is there, and `define_texture`
kills the process anyway. Two theories dead: not a missing texture, not a stale
link.

What still fits, and fits 2.5 equally: **the mod is running twice.** Hosting
requires it disabled in load_order.txt. If that edit did not take -- read-only
file, a name that did not match, or the player re-enabled it in Modlunky after --
then Playlunky runs the mod as its own script AND we run it inside ours. Every
texture gets defined twice, and the second one is not something the engine
survives.

So hosting now refuses a pack that is still enabled:

```
mod host: NOT hosting fyi.hdmod -- it is still ENABLED in load_order.txt, so
Playlunky is running it too. Running it twice defines every texture twice and
crashes the game. Disable fyi.hdmod in Modlunky, leaving Modded Online enabled.
```

### A native crash cannot be caught, only avoided

The trace records each call BEFORE it is made, so the previous boot's last line
names the call that never returned. That line is now handed to the host, and the
call it names is **not made again**:

```
mod host: SKIPPING define_texture(res/locked_feat.png) -- it is what the previous
boot died on. This mod will be missing that texture; the game should now start.
```

Only that exact call is skipped; every other texture goes through untouched. A mod
missing one sprite is a great deal better than a game that will not launch, and it
gets the second machine past the wall while the underlying cause is settled.

**342 passing.**

---

## 2.0.0-dev21

Server unchanged.

dev20's junction fix did not change the second machine's outcome -- the trace ends
on the same line. So either the link was already right, or something else is wrong.
`define_texture` was still not mediated at all, which meant the diagnosis was still
inference from where the trace stopped rather than from the call itself.

### define_texture is checked now, and named

It is the one engine call known to take the process down. Overlunky resolves a
relative `texture_path` against the pack root of the script that ASKS -- hosted,
that is ours, not the mod's -- and if the file is not there the call dies in native
code with nothing a `pcall` can catch.

The path is now checked before the call. If it is not under this pack the call is
skipped and `-1` returned, which is the value hdmod itself initialises its texture
handles to, and the console says:

```
mod host: fyi.hdmod asked for the texture res/locked_feat.png, which is not at
Mods/Packs/fyi.modded-online-loader/res/locked_feat.png. Its assets are not linked
into this pack, or are linked to a different mod. Skipping it -- letting the call
through crashes the game.
```

Every call is traced with its path either way, so the boot log now says which
texture, not just which file was running. Absolute paths are left alone: those are
the engine's business.

The host summary lists everything skipped, so a mod that loads with the wrong assets
linked says so rather than looking fine and rendering wrong.

**340 passing**, including one test each way: a missing texture must be refused, and
a present one must still reach the engine.

---

## 2.0.0-dev20

Server unchanged.

### What dev19's trace showed

```
  fyi.hdmod: .../lib/state_dev_section.lua [done]
  fyi.hdmod: set_callback function: ...
  fyi.hdmod: .../lib/feelings.lua [done]        <- last line
```

`feelings.lua [done]`, so the option registrations were fine -- the dev19 nil
hypothesis was wrong, and the trace said so rather than costing another guess. No
`feats.lua [done]` either, so the process died inside `feats.lua`, and its only
load-time act is:

```lua
tdef.texture_path = "res/locked_feat.png"
LOCKED_FEAT_TEXTURE = define_texture(tdef)
```

Overlunky resolves that against the CALLING script's pack root, which when hosting
is ours. So it needs `fyi.modded-online-loader/res/locked_feat.png`, through the
junction.

### The bug

`linkAssets` only ever asked whether `res/` **exists**, never what it points at. And
the unlink that should have re-aimed it is `rmdir`, which **fails silently on a
directory Playlunky has mounted** -- which is every one of these, from boot.

So a junction can be left aimed at the previously hosted mod. It reads as present,
passes every check, and then the mod being hosted asks for one of ITS files through
it. A missing file at `define_texture` is a native crash: no Lua error, no log.
That is why it happened with 2.5 as well -- nothing to do with either mod.

### The fix

Junction targets are read now, not just their existence. A link aimed at another
mod is removed and re-pointed; if the game has it open and `rmdir` fails, hosting
refuses and says so:

```
res/ is linked to .../fyi.spelunky-25-2/res, not to fyi.hdmod -- the previous
mod's link could not be removed while the game had it open
```

The bracketed target is parsed rather than the word JUNCTION, which is localised.

**338 passing.**

---

## 2.0.0-dev19

Server unchanged.

### Where the trace pointed

```
  fyi.hdmod: .../lib/feelings.lua
  fyi.hdmod: .../lib/state_dev_section.lua      <- last line
```

`state_dev_section.lua` cannot crash: its whole body is one `table.insert`. So it
finished, and the process died in whatever ran next -- which is `feelings.lua`,
line 5, immediately after the require that pulled it in:

```lua
optionslib.register_option_bool(
    "hd_debug_feelings_toast_disable",
    "Feelings - Disable script-enduced toasts",
    nil,      -- long_desc
    false, true)
```

A `nil` arriving where the binding wants a string is a native crash on some builds:
no Lua error, no log, nothing a `pcall` of ours can see. It does not crash on every
build, which is why one machine hosts hdmod's 199 modules and the other stops at
ten.

### The fix

Option registrations now reach the engine with an empty string where the mod passed
nil. Only the two description slots are touched; the value after them may
legitimately be `false`, nil or a function depending on the API, and is passed
through untouched. The option reads identically either way.

### And if that was not it

The trace now records module COMPLETION as well as start, so a log ending on a
module says whether it died inside that file or in the one that required it. Every
registration call is named before it is made, too -- so if an engine call is what
kills the process, the last line is that call and its argument.

**336 passing.**

---

## 2.0.0-dev18

The boot trace paid for itself immediately. Server unchanged.

### What it said

```
all modules loaded
checking for a second Modded Online
setupUI: registering the mod picker
hosting fyi.hdmod          <- and nothing after it
```

So: everything of ours loaded, and the process died INSIDE hosting -- in native
code, where no `pcall` of ours can see it. And it happens with 2.5 as well, so it
is not about either mod. Hosting itself is running against a setup that is not
actually there on that machine.

The likeliest single cause is `mklink /J` failing quietly. It needs no elevation,
which is why it was chosen, but it still refuses across volumes and on some
configurations -- and a mod whose `Data` and `res` are missing defines its textures
at load against files that do not exist.

### Checked before hosting, not reported after

`PackSetup.setupProblems` now answers whether a pack is actually ready, and hosting
refuses if it is not:

```
mod host: NOT hosting fyi.hdmod -- its setup is incomplete: res/ was never linked
into fyi.modded-online-loader -- mklink failed, or the setup never ran. Untick it
under Modded Online, restart, tick it again and restart once more.
```

It covers the unlinked folders, textures Playlunky has never converted, and files
that were not copied across. The converted-textures case existed already -- as a
*note* in the setup report that hosting then went ahead and ignored.

### And if it still dies there

The trace now names each of the mod's own files as it runs -- 2.5 is 56 modules,
hdmod 199. If one of them takes the process down natively, the last line of
`modded_online_boot.log` is the file that did it.

**334 passing.**

---

## 2.0.0-dev17

**A boot trace that survives the crash it exists to describe.** Server unchanged.

### modded_online_boot.log

Written and **flushed at every step** of loading, into the Spelunky 2 folder:

```
Modded Online 2.0.0-dev17 boot
require src.util
require src.callbacks
... one line per module ...
all modules loaded
checking for a second Modded Online
setupUI: registering the mod picker
hosting fyi.hdmod
hosted fyi.hdmod
READY
```

A file not ending in `READY` is an unfinished boot, and its last line names what
was running. The next launch reads it *before* truncating it and prints the
unfinished step to the console, so the player is told without having to be asked
for a file.

**No file at all is itself an answer**: our script never ran, and the crash is in
Playlunky before any Lua -- asset processing, most likely.

It lives in the game root because it must open before `src.util`, which is where
PackDir lives; it cannot ask which pack it belongs to. Every part of it is pcall'd
and degrades to a no-op, since `io` is absent unless Playlunky granted unsafe mode
-- a diagnostic that breaks the boot to report a boot problem would be worse than
none.

### Two copies of Modded Online

Now detected and called out by name. Both would bind the same UDP port, register
every callback twice, and make `PackDir()` resolve to whichever the load order
reached first. It is an easy state to reach -- install the loader build without
disabling the one already there -- and from outside it looks like the new build
simply crashing on boot.

### Hosting is named one mod at a time

`autoHost` looped internally, so a mod that took the game down left no record of
which mod it was. main.lua drives the loop now and traces each pack before and
after.

Indexing `SetupUI` or `ModHost` at load is guarded too: a module that failed to
load would otherwise kill the boot *while reporting a boot problem*, and the trace
would blame the wrong line.

**329 passing.**

---

## 2.0.0-dev16

**The zip was shipping one machine's mod setup to another.** Server unchanged.

### What was in it

```
fyi.modded-online-loader/mod_info.json      3539   <- image_map for res/boulder.png
fyi.modded-online-loader/savegame.sav      13862   <- a save file
fyi.modded-online-loader/strings00_mod.str  6106
```

All three are hdmod setup artifacts belonging to the machine that built the zip. On
a machine without the `res` junction, Playlunky tries to slice sprites out of images
that are not there during texture processing -- a native crash at boot, before any
Lua runs, which is why the second player had no log and nothing to go on.

### Why it happened

`--package` and `src/packSetup.lua` kept separate lists of what the setup creates.
They agreed until packSetup started carrying three new files across, and then the
zip excluded the old three and shipped the new ones.

They are one list now: `--package` reads `LINK_DIRS`, `COPY_FILES`, `COPY_GLOB` and
`INFO_FILE` straight out of packSetup.lua, and **refuses to build** rather than ship
a partial exclusion list if it cannot read them. Five tests in
`tests/test_packaging.py` hold the two together, including one that fails if
`package()` ever restates a name instead of reading it.

### For the second machine

Unzip into `Mods/Packs`, enable Modded Online in Modlunky, tick the mod under its
options, restart. Nothing else -- the setup is per-machine and deliberately not in
the zip. `--package` now says exactly that when it finishes.

**321 passing.**

---

## 2.0.0-dev15

Server unchanged (1.0.10).

### The jungle snail

Playlunky reads sprite remapping out of a pack's `mod_info.json`. hdmod has 27
entries there, slicing pieces of its own `res/*.png` into the vanilla atlases --
so anything served whole from `Data/Textures` looked right and anything remapped
kept its vanilla sprite.

Only the `image_map` is carried across. The rest of that file is the pack's name,
version and author, and copying it whole would list Modded Online as "HDMod" in
Modlunky. Verified the map round-trips our JSON encoder byte-identically first.

### An update now actually applies

dev14 started carrying `savegame.sav` and the string mods across, but only ever did
that work when the selection CHANGED -- so upgrading and booting did nothing, and
the mod kept running on the wrong save. The selection matching what is armed is not
the same as the arrangement being complete, and the boot check now tests the second
thing too.

It only ever adds. The mod that owns the asset folders has not changed on that path,
so nothing is unlinked and no mounted junction is disturbed.

**316 passing.**

---

## 2.0.0-dev14

hdmod hosts. Server unchanged (1.0.10).

```
mod host: LOADED | 199 modules, 199 chunks, 203 registrations, 1 unknown globals
  modules the mod asks for but does not ship: lib.entities.hdtype
```

### All progression unlocked

hdmod reads its shortcut unlocks straight out of the savegame --
`MET_TERRA_SAVEGAME_VALUE` and friends in `lib/shortcut.lua` -- and ships its own
fresh `savegame.sav`. Playlunky substitutes that for INSTALLED packs, and hosting a
mod means it is no longer installed. So the game handed hdmod the player's real
Spelunky 2 save, which is finished, and the HD campaign opened with every shortcut
already open.

The same applies to `strings00_mod.str`; the log says it outright -- "Successfully
generated a full string file from installed string mods". Both are now copied into
our pack alongside the junctions, `*_mod.str` by pattern.

### Not disturbing what does not need disturbing

Applying a selection used to unlink everything first, unconditionally. Unlinking is
the dangerous half -- it deletes junctions Playlunky mounted at startup, and it
deletes the copied `savegame.sav`, which after a session of play IS the player's
progress. Ticking a second, script-only mod alongside hdmod changes the selection
but not the mod that owns the asset folders, and now leaves both alone.

Switching to a different asset mod still replaces both, which is the point.

### Quieter

hdmod clears callback `-1`, its stand-in for "no callback", and the engine ignores
it. Refusing it changed nothing but put an alarming ERROR line in the log at the
exact moment of an unrelated crash. Ids that cannot exist are a no-op now.

**314 passing.**

---

## 2.0.0-dev13

A module with no file is **nil**, not an error. Server unchanged (1.0.10).

### The evidence

Two independent mods `require` a file they do not ship:

* 2.5 asks for `src.texture`
* hdmod asks for `lib.entities.hdtype` -- the only missing require in its main.lua,
  and the file exists nowhere in the game folder

Both run fine under Playlunky, and hdmod's is a **bare** `require` on line 42 of
main.lua with nothing to catch a throw. So Playlunky hands back nil rather than
raising. Ours raised, which took the host down before hdmod had registered its
options -- and its own options GUI then indexed a nil every frame at
`lib/options.lua:104`. That was never a second bug; it was always this one.

### The rule

Only *"there is no such file"* is tolerated. A module that exists and then fails to
compile, or throws, is still an error and still stops the mod -- hiding a real fault
would be worse than the crash. The distinction has a test each way.

Absent modules are remembered, so a mod asking repeatedly does not re-walk the disk,
and the host summary names them:

```
modules the mod asks for but does not ship: lib.entities.hdtype
```

### spike1 can examine any pack now

It read the engine's API stubs from the pack under test, and only 2.5 bundles
Overlunky's `spel2.lua`. Hosting hdmod therefore died on a nil `ON` two modules in --
a hole in the tool, not in the mod. It now borrows the stubs from whichever pack has
them, checking for the stub FILE rather than the folder, because one installed pack
has an empty `apiFiles` directory and picking it seeded nothing.

**311 passing.**

---

## 2.0.0-dev12

Three fixes. Server unchanged (1.0.10).

### A module may name a sibling

hdmod's `lib/journal/hdmod_journal.lua` does `require("journal_data")` for the file
sitting next to it, and elsewhere requires the SAME file as
`lib.journal.journal_data`. The resolver only ever tried the pack root, so the first
spelling failed -- and one failed `require` took the whole host down:

```
mod host: FAILED | 6 modules, 6 chunks, 6 registrations
  first error: import 'journal_data' -> Mods/Packs/fyi.hdmod/journal_data.lua
```

Six modules in, hdmod's options had not registered yet, so its own options GUI
reached `registered_options["hd_og_bomb_cascade"]`, got nil, and threw every frame
at `lib/options.lua:104`. One root cause, two symptoms.

Modules now resolve from the pack root first and then beside the requiring file, and
the cache is keyed on the **resolved path** rather than the module name -- so both
spellings are one instance. Keyed on the name, hdmod would build its journal data
twice and the second copy is the one its GUI would close over.

A module that fails now names every path it tried.

### Mods switching themselves on in Modlunky

Ours, and precisely this: selecting a mod that was **already** commented out in
`load_order.txt` recorded us as the owner of that line. Deselecting it later then
un-commented it -- enabling a mod the player had disabled themselves, with nobody
having touched it.

We now claim a line only if we were the ones who commented it.

### `src.texture`, again

Still not ours, and still not a crash on its own. There is no `texture.lua` anywhere
in that 2.5 install; `sp25preimports()` asks for a module the pack does not ship and
its own SafeImport swallows the failure. If a machine is crashing, the cause is
further down its log than this line.

**310 passing.**

---

## 2.0.0-dev11

Diagnosis of the two dev10 failures, and one guard. Server unchanged (1.0.10).

### `src.texture` is not ours

```
Sp25 [ERROR] SafeImport(src.texture) failed:
  Mods/Packs/fyi.spelunky-25-2/src/texture.lua: No such file or directory
```

The wording is ours (`modHost.lua` raises it), but the fact is not: that install of
2.5 has no `src/texture.lua`. `src/theming/textures.lua` exists and loads; plain
`src.texture` does not exist anywhere in the pack. 2.5's `sp25preimports()` asks for
a module it does not ship, its own SafeImport catches the failure, and it carries on
-- hosted or not. Nothing to fix here.

### The HD mod's unbootable game

`fyi.hdmod/main.lua` line 1:

```
-- [ModdedOnline-DeterminismShim-v21] auto-added by Modded Online
```

An older shipping build had injected a v21 determinism payload into it, lines 1-507,
with a second option-sync block at 509-748. Hosting ran that block **inside our own
state**, where it re-wraps `set_callback` -- which in this build is the callback
registry itself. The game reached `Game initialized` and died with no Lua error and
nothing in `spelunky.log` to say why.

### The guard

`autoHost` now refuses a mod whose `main.lua` still contains a `[ModdedOnline-...]`
marker, and says which marker and which pack. It only detects: removing the block is
the injector's business, and reinstalling the mod clears it. A boot that fails
silently is the worst outcome available, and this is the difference between that and
one line in the console.

### Noted, not acted on

`stripPayloads` matches archived payloads by exact text, and `shimInjector` exports
only `SHIM_V1`..`SHIM_V9` on the module -- so `injector["SHIM_V21"]` is nil and the
versioned pass silently matches nothing. The option-sync block strips because
`OPT_SHIM` **is** exported. Left alone deliberately.

**305 passing.**

---

 2.0.0-dev10

**Mods are chosen in Playlunky's options panel now.** No terminal, no junctions by
hand, no editing `load_order.txt`, and no longer only 2.5. Server unchanged (1.0.10).

### What you do
Launch with Modded Online enabled. Under its options there is a checkbox per installed
script pack -- *Play `<mod>` online*. Tick one and everything the old
`tools/spike2.py --setup` did happens by itself:

* the mod is commented out in `load_order.txt`, because Modded Online runs it instead
  and two copies would fire every callback twice;
* its `Data`, `res` and `soundbank` are junctioned into our pack, because Overlunky
  resolves a relative asset path against the pack root of the script that asks -- and
  the script asking is ours;
* its **converted** tree under `.db` is junctioned too. Playlunky serves DDS, not the
  mod's PNGs; linking only the source tree is what once changed world generation
  without changing a single texture.

Then **restart Playlunky.** That part cannot be automated away: the load order and the
asset mounts are both read once, at startup. Every message says so.

### More than one mod
Any number of script-only mods can be hosted together. At most **one** mod with assets,
because every hosted mod's `Data` is junctioned into our pack under that exact name and
two cannot both own it. Select a second and it is refused, by name, with the reason.

A mod that has never been booted normally is called out too: Playlunky only converts
textures for an *enabled* pack, so hosting one it has never seen gives you correct world
generation and missing textures. Better said out loud than discovered in the mines.

### Getting back out
An *Undo Modded Online's setup* button unlinks everything and restores the
`load_order.txt` lines. The restore is line-level and remembers exactly which lines we
commented -- a whole-file backup goes stale the moment you install another mod, and
putting it back would silently undo your own edits. Mods you had disabled yourself stay
disabled.

Nothing is applied mid-run: it would delete the junctions the running game has its
textures mounted through. A tick made during a run is held and applied when you leave.

### Also
`mo_host.on` now holds one pack per line. The old reader stripped *all* whitespace,
which would have welded two names into one nonexistent pack rather than failing
visibly.

`tools/spike2.py` keeps `--package`, and stays as the way to recover an install from
outside the game -- the one thing a menu cannot do.

### Testing
`tests/test_pack_setup.py` fakes the whole Windows vocabulary (`dir`, `if exist`,
`mklink`, `rmdir`) over an in-memory tree, because this code edits a file you also edit
by hand and creates and destroys junctions. It proves the reversibility directly.

`tests/test_lua_compiles.py` is new and overdue: every Lua file must **compile** under a
real Lua, not merely parse. `luaparser` twice accepted a string literal containing a raw
newline during this session; a parse check a broken file can pass is not a check.

**304 passing.**

---


## 2.0.0-dev9

**The freeze is gone.** dev8 carried a full four-floor run with lockstep intact and no
hang. Server unchanged (1.0.10).

### What dev8 got wrong
The revival budget. One flat five seconds, applied to every kind.

Three `REVIVED` lines appeared, so callbacks of ours are still being destroyed -- but
the important number is the five-second latency, not the count. Five seconds is ~300
frames. If the callback that died is the lockstep gate, that is 300 frames in which
nothing holds the input slots neutral, so each machine drives its own player and
neither sees the other's input.

The 1-4 floor digest says exactly that happened:

```
host:  time_level=256   p1 30.40,120.05   p2 30.25,120.12  ovl=CHAR_ROFFY_D_SLOTH
peer:  time_level=247   p1 26.00,120.05   p2 26.00,120.05  ovl=none
```

Every earlier floor read `time_level=2` on both machines. So this is not entity
placement and not world generation -- the floor seed matched (`1754640132` on both).
It is the two machines running unlocked across a floor entry, which is the reported
symptom: one player moved before the other loaded in.

### Budgets per kind
PRE_UPDATE and GUIFRAME fire on every frame, including during fades and while the gate
is holding, so they now get **300ms and 600ms**. GAMEFRAME and POST_UPDATE genuinely
pause whenever the simulation does and keep the loose five seconds.

### The rebase guard, which is what makes tight budgets safe
Generating 1-4 (4,023 entities) blocks every callback, ours included. Judged naively,
a tight budget would call all of them dead on every floor. So the sweeper now checks
its **own** clock first: if it has not run for 250ms, the process was away, nothing is
stale, and it re-baselines and judges nothing that pass.

### Naming what died
Six of our registrations are ON.PRE_UPDATE -- the lockstep gate, the crash-trace
marker, two network pumps, chat and eventSync. A line reading only `PRE_UPDATE` cannot
tell a desync from a harmless breadcrumb, and that is exactly the question dev8's logs
could not answer. Revivals now carry the defining source and line.

### Whether the guard is guarding the right door
The `REVIVED` line now also reports how many bare `clear_callback()` calls the depth
guard has refused. If callbacks keep dying while that stays at **zero**, the bare form
is not how they are being reached and the dev8 diagnosis is incomplete.

18 tests in `tests/test_callbacks.py`, **266 passing**.

---

## 2.0.0-dev8

**Root cause found and fixed.** Server unchanged (1.0.10).

### What dev7 proved, and what it disproved
The dev7 watchdog fired, but it also disproved its own label. It said "GUI FRAMES
STOPPED"; meanwhile inputSync's *own* GUIFRAME callback kept printing `.. alive`
throughout. GUI frames were arriving fine.

What actually happened at the 1-2 -> 1-3 transition is that a **subset** of our
callbacks was destroyed:

* `netCore`'s network tick (GUIFRAME) — hence the frozen rx counters in dev6
* the **lockstep gate** (PRE_UPDATE) — hence no `STALL` lines, a frame counter stuck
  at `4:71` for 52 seconds, and the host walking on to 1-4 while the peer stayed on
  1-3
* the floor digest — no `FLOOR seq=` line for 1-3 at all
* the world ordinal, which is why 1-4 logged `levelseed ord=2 SKIPPED`

Name tags and door handling live in those same callbacks. That is the rename to
"Spelunker" and the dead doors — not separate bugs, the same one.

### The cause
`fyi.spelunky-25-2` contains **38 bare `clear_callback()` calls** — the form that
names no id and means *"clear whichever callback is running right now"*.

Under the shim this was harmless: the mod was a separate Playlunky script with a
separate callback id space, so the worst a bare clear could reach was one of the mod's
own. **Hosting merged the id spaces.** The dev2 ownership guard mediates
`clear_callback(id)`, but waved every bare call straight through on the assumption
recorded in its own comment — *"the one currently running, which is the mod's"*. That
assumption is what hosting broke, and it is the only teardown call that never names
what it is destroying.

### The fix — `src/callbacks.lua`
A registry loaded before every other module, which replaces the global
`set_callback` so every registration we make is recorded. Two halves:

* **Depth.** It knows when one of our callbacks is on the stack. modHost now refuses
  a bare clear raised at that moment. Inside the mod's own callbacks the depth is
  zeroed, so the mod's 38 bare clears keep working exactly as they always did.
* **Revival.** Per-frame callbacks that stop firing for 5s during a run are
  re-registered. The clear comes *first*, so a callback that was merely idle can
  never end up registered twice — two lockstep gates would advance the frame counter
  twice, a guaranteed desync.

The sweeper runs from PRE_UPDATE, GUIFRAME *and* GAMEFRAME, because the whole premise
is that any one of them can be taken away; any survivor revives the rest.

14 new tests in `tests/test_callbacks.py` cover both halves, including the two cases
that must NOT regress: the mod clearing its own callback bare, and our never reviving
a callback the mod deliberately retired. **262 passing.**

### Kept from dev7
The PRE_UPDATE network pump stays as second-line insurance, and the watchdog stays as
the report that a teardown reached us — with wording that now matches what it detects.

---

## 2.0.0-dev7

**The freeze is diagnosed.** Server unchanged (1.0.10).

### What the dev6 capture showed
Every receive counter frozen on BOTH machines, identical across nineteen stall lines
covering 54 seconds:

```
host:  rx ... pong=186 state=4753 world=25
peer:  rx ... pong=141 state=4856 world=229
```

`pong` too — and the host's server is on `127.0.0.1`, where a packet cannot be lost.
So nothing was arriving, and it was not the network.

The `.. alive` heartbeat stops at `13:39:01`; the `STALL` lines continue to
`13:39:57`. That difference is the whole diagnosis:

* `STALL` is logged from **ON.PRE_UPDATE** — still running
* `.. alive` and `netCore.tick` are **ON.GUIFRAME** — stopped

**Our GUIFRAME callbacks are being cleared.** Nothing drains the receive queue, so no
state, no pong and no events arrive; `levelseed` is never applied; the menu, chat and
name tags are gone too; and the silence probe added in dev4 could never print, because
it runs from `tick()`, which is itself GUIFRAME. The server's `slot 2 timed out` is a
consequence eight seconds later, not a cause.

Same root as the post-generation callback dying: hosting puts the mod's callbacks and
ours in **one** Playlunky script, and 2.5 runs `Hooks.unhookAll()` on every floor. The
dev2 ownership guard stops `clear_callback(id)` for ids we own; something still gets
through.

### The fix: stop depending on GUI frames
Both halves of the lockstep loop now also run from `ON.PRE_UPDATE`, which survives:

* **`netCore.tick`** — drains the receive queue. Safe to call twice a frame: the drain
  is idempotent and every send inside is already gated on elapsed time.
* **the input resend keepalive** — the other half, and just as necessary. While the
  gate holds, `myRecorded` stops advancing, so that keepalive is the *only* thing
  putting our inputs back on the wire. With GUIFRAME dead neither machine resends, so
  neither can unblock the other and a recoverable stall becomes permanent.

Receiving alone would not have been enough.

### And a watchdog that names it
```
GUI FRAMES STOPPED 3s ago while the sim is still running -- our ON.GUIFRAME
callbacks have been cleared (menu, chat and the network tick all live there;
the network is being pumped from PRE_UPDATE)
```

This does **not** repair the callback loss — the menu and chat are still gone when it
happens. It stops that loss from taking the connection down with it, and it says
plainly when it occurs so the remaining work is visible rather than inferred.

---

## 2.0.0-dev6

Server unchanged (**1.0.10**). Logging only — enough of it to end the guessing.

### What dev5 did establish
The host published every seed again (`levelseed ord=0/1/2 SENT`) and the peer received
none, so delivery remains the failure. And a sharper fact from the stall lines: the
host holds the peer's inputs for offsets **0 through 3** and stops at **4**, with
`inputdelay=4`. Offsets 0-3 are the transition's neutral hold; offset 4 is the first
*real* input of the floor. So no genuine input for that floor crosses in either
direction — it is not that the machines drift apart, it is that the floor never starts.

### Why the silence notice still did not appear
It waited 10 seconds. Both captures end six seconds into the freeze. A diagnostic that
needs more patience than the person staring at a frozen screen is not a diagnostic —
it now fires at 4.

### Three lines that should settle it
* **`STALL` now reports what we hold and what is arriving.** A stall names one missing
  frame; on its own that cannot distinguish "their packets stopped" from "their packets
  arrive and we reject this one":

  ```
  STALL: waiting on slot 2 for seq 5 offset 4 (3000 ms; mine recorded to 8)
      | theirs for this seq: 4 frames, offsets 0..3 | rx state=1873 ack=41 ping=12
  ```

  If `rx state=` climbs between two of these while the offsets do not, packets are
  arriving and being discarded. If it is frozen, they are not arriving.

* **`SEND while stalled: seq 5 offsets 0..8 (9 frames)`** — proof the frames the peer
  is waiting on are still going back on the wire every 40 ms. `REDUNDANCY` covers
  offset 4 comfortably, so a stall with this line present and the peer's `rx` flat
  means the packets are not crossing at all, and the problem is below lockstep.

* **`SEND SKIPPED while stalled`** for the other case: if `sendRecentInputs` bails on
  its own guard, the two machines starve each other by construction and nothing else
  matters.

Together these say, in one capture, whether this is transport or logic. Every previous
session could only infer it.

---

## 2.0.0-dev5

Server **1.0.10**. Answers to two direct questions, and the instrumentation mistake
that has been costing runs.

### Spelunky 2.5 is not being modified
Verified rather than assumed: `fyi.spelunky-25-2/main.lua` contains **zero**
`ModdedOnline-` markers and begins with 2.5's own
`require("src.logging")`. Injection in this build is opt-in (`autoShim == true`) and
nothing turns it on, so the old behaviour is gone. The mod on disk is untouched.

### The seeded-run flag stays
It is set at two lockstep-identical points and both machines log `seeded=1` /
`quest_flags=0x40`, so it is the same on every machine and cannot produce a one-sided
freeze. It is also load-bearing: without it the HD mod takes its unseeded branch,
picks a character unlock from `savegame.characters` — which differs per player — and
draws from `PRNG_CLASS.LEVEL_GEN` to do it, so two players consume a different number
of generation draws and everything after lands elsewhere. It also stops a networked
run recording progress into anyone's save. The top-right icon is the engine honestly
reporting what the run is. Removing it would reintroduce a fixed desync.

### The probe was in a function that cannot run when the thing it watches fails
`applyReadyEvents` is called **only from `handleMessage`, only when an event
arrives**. The silence notice was written inside it — so a channel delivering nothing
never reached the check meant to detect exactly that. It is the same shape as the gap
notice already there, which keys off a non-empty buffer and therefore sees an event
arriving *out of order* while staying quiet when none arrive at all.

Moved to `tick()`, which runs every GUI frame regardless:

```
inbound events SILENT 12s: applied to 4, 0 buffered, next cseq out 31.
    Received: state=1873 ack=41 ping=12
```

### The server dropped events without saying so
`on_event` discards any event whose `cseq` runs ahead of `client.next_client_seq` —
correct, because acking a gapped event loses it forever — but it did so with **no ack
and no log**. The client then re-sends that event forever while every later event on
its reliable channel waits behind it, and neither end says a word. That is
indistinguishable from a relay failure, which is exactly the ambiguity four sessions
have been stuck in. `next_client_seq` is also reset to 1 on rejoin while the client's
outgoing `nextCseq` keeps climbing, so the two can genuinely disagree.

The drop is now logged, rate-limited, naming the room, slot, both sequence numbers and
the event kind.

Between the two, the next run says from both ends whether events reach the peer.

---

## 2.0.0-dev4

The dev3 instrumentation answered its question and exposed a better one.

### Resolved: it is delivery, not publishing
The host published every seed — `levelseed ord=0/1/2/3 SENT`, not one `SKIPPED` — and
the peer logged `no host seed yet` for 1, 2 and 3. So `publishLevelSeed` works and the
events do not arrive.

### Two things I got wrong, and what they cost
* **The queue probe watched the wrong side.** `pendingOut` is the OUTGOING queue. It
  drained normally all run (depth 1, oldest cseq climbing 31 to 70) because the SERVER
  acknowledges us — which it does even when nothing reaches the peer. It could never
  have shown this bug.
* **The alarming "1787674360627 ms old" was not a clock bug.** `sentAt = 0` on enqueue
  is deliberate (`netCore.lua:955`) so the next tick sends immediately, so a
  just-enqueued entry always reads as ~56 years old. A resend-storm theory built on
  that would have been wrong; checking the line that sets it was cheaper than testing
  the theory.

### The blind spot that hid this for four runs
`applyReadyEvents` already has a gap notice — *"inbound events STALLED: waiting on
event N, M later one(s) held back"*. It never fired, and it never could: it keys off a
**non-empty** `bufferedIn`, so it detects an event arriving OUT OF ORDER and is silent
when the channel stops delivering **entirely**. Nothing arrives, nothing is buffered,
nothing is said — while play continues perfectly on the unreliable state channel and
every world event is quietly ignored.

That is the exact failure the file's own comment warns about, minus the one case it
cannot see.

Now watched properly:

```
inbound events SILENT for 12s: applied up to 4, nothing buffered.
    Received so far: state=1873 ack=41 ping=12
```

The type tally is the point — it says whether `event` messages reach this client at
all, which separates a server relay problem from a dispatch problem in one line. The
outgoing-queue notice is gone; it only ever measured the half that works.

---

## 2.0.0-dev3

Instrumentation, not a fix. The previous run left two very different failures
indistinguishable, and guessing between them has already cost one insufficient fix.

### What the dev2 run established
Three floors byte-identical again (`ent=1772184`, `2129043406`, `2137637703`), so
determinism continues to hold. And the callback-ownership guard **fired**:

```
01:18:54  refused a request to clear callback 11, which the hosted mod did not register
```

at the exact moment 1-2 was loading — so 2.5 really is reaching for our callbacks, and
the guard really does block it. But our `ON.POST_LEVEL_GENERATION` handler *still*
stopped firing after the first floor, so blocking clear-by-id is not the whole
mechanism. Only the first refusal is logged, so there may have been many more.

### The fork that the logs cannot resolve
`publishLevelSeed` is called from `onPreLevelGeneration`, which runs every floor, and
`levelOrdinal` advances in `onGateEngaged`, which also runs every floor (the per-floor
digest proves it). So the host either **skips the publish** or **sends into a reliable
stream the peer never drains**. The peer's `no host seed yet for ordinal N` reads
identically either way, and picking wrong means another wasted run.

Two lines settle it:

* `levelseed ord=N SENT` / `levelseed ord=N SKIPPED (already published)` — says which
  branch the host took, instead of leaving it to be inferred.
* `reliable queue: N unacknowledged (oldest cseq C, M ms old)` every five seconds —
  an event that is never acknowledged sits at the head forever and everything behind
  it waits. If that number climbs and never falls, the stream is the answer.

The queue line is computed defensively on purpose: the first draft did
`now - entry.sentAt` with no nil guard, which would have thrown inside the very
diagnostic being added and hidden the result.

---

## 2.0.0-dev2

A two-machine run: four floors byte-identical, then both machines froze on 1-4.

### The good half
```
host:  digest seed=1375211940 ent=1972259484
peer:  digest seed=1375211940 ent=1972259484
```
Four floors, matching down to `MONS_CRITTERSLIME` and `FLOOR_DOOR_EGGPLANT_WORLD` —
2.5's own custom content, generated identically on two machines with the mod hosted
inside Modded Online's Lua state and **nothing injected into any file**. The
determinism core works.

### The freeze, and what shared ownership costs
The stall line added for this run said it immediately, and symmetrically:

```
host:  STALL: waiting on slot 2 for seq 7 offset 6 (9021 ms; mine recorded to 12)
peer:  STALL: waiting on slot 1 for seq 7 offset 6 (6036 ms; mine recorded to 12)
```

Each had produced its own inputs and received none of the other's — a delivery
failure, not a divergence. The cause was upstream, and visible by counting brackets:

| | pre-gen | post-gen |
|---|---|---|
| shim era (log 42) | 18 | 18 |
| hosted (log 44) | 14 | **4** |

**Our `ON.POST_LEVEL_GENERATION` handler stopped firing after the first floor.** That
is where the per-floor seed is captured, so `levelseed` was never published — six
`no host seed yet for ordinal N` lines in the hosted logs against **zero** in the shim
era — and the reliable ordered stream head-of-line stalled behind the missing event
until inputs stopped flowing entirely.

Why: under Playlunky a script can only clear its own callbacks, because **a script is
the unit of ownership**. Hosting dissolves that. 2.5 calls `clear_callback()` in a
dozen places (`helpers2.lua:50,287,611`, `cobraLib.lua:37`, hook files) and clears its
recorded ids from `Hooks.unhookAll()` on **every floor** — and those calls now land in
our callback list.

The host already mediates registration, so it now mediates teardown: the sandbox
records which ids the mod registered and refuses the rest, counting them into the
report. A bare `clear_callback()` still passes through, because it means "the callback
currently running" and the only callbacks running the mod's code are the mod's own.

This is the first thing to go wrong that is *inherent* to hosting rather than
incidental, and it will not be the last: sharing a script means sharing everything
Playlunky scopes per script. Options, saves and callback ids are three so far.

`tests/test_mod_host.py` grew five tests for the boundary, including the exact bug.

---

## 2.0.0-dev1

Spikes 1-3 all passed, and the determinism core is ported.

### Spike 3: it runs
From the log of the boot that worked, with 2.5 disabled in `load_order.txt`:

```
Playlunky :: Mod fyi.spelunky-25-2 registered as a script mod ...   (0 occurrences)
[fyi.modded-online-loader]: [ModdedOnline] mod host: LOADED
    | 633 modules, 633 chunks, 214 registrations, 8 unknown globals
```

Playlunky never loaded 2.5; Modded Online did, in its own Lua state, and the game came
up with 2.5's worlds, art and custom entities. **Nothing was written to any file on
disk.** 633 modules rather than the headless spike's 56, because the real game runs
`game:init()` -> `Hooks.runHooks`, which pulls in every per-world hook module.

### `src/determinism.lua`
The injected payload's guarantees, lifted into the host and made mod-agnostic. The
universal core applies to every hosted mod; per-mod behaviour is an adapter that
feature-detects, so a mod nobody has tested still gets the full core rather than
nothing.

Two things changed shape in the move, and both had to:

* **The mod gets its own generator.** Under the payload each pack had its own Lua
  state, so reseeding was contained. Hosting puts the mod in *our* state, where
  `math.randomseed` reaches the generator `netCore.lua:183` seeds from the wall clock
  to build a client id. Each hosted mod now gets a private xorshift64\*, which is also
  identical across Lua builds — Lua's own generator is not.
* **Ordered `pairs` is on by default.** The payload enabled it only for mods it had
  already watched desync. `orderedPairs = false` is there for a mod that measurably
  cannot afford it.

Callback ordering stopped being a problem rather than being solved: the payload had to
be *prepended* to the mod's file to register ahead of it, which is where v25's
nil-callback bug came from. Inside our own state we simply register first.

### Tests
`tests/test_determinism.py`, 27 tests, written to fail the way the original desyncs
failed. One earned its place immediately: a bucket test caught that masking the
generator state to 63 bits cost the top bit of every output, so `random()` returned
only `[0, 0.5)` — half the range never appeared. Two more assertions in that file were
vacuously true (`is not` between two `lupa` evals compares wrappers, not Lua values)
and now compare inside Lua.

215 tests total.

### The hole hosting opened in the compatibility check
`netCore` built the mod-compatibility signature by walking `load_order.txt`. Hosting a
mod requires that mod to be **disabled** there — that is what stops Playlunky loading
it a second time — so the mod actually being run became invisible to the check whose
entire job is proving both machines run the same mods. Two players on different builds
of 2.5 would have matched, played, and desynced for a reason with nothing to do with
the loader.

Fixed with one shared definition, `Network.syncedScriptPacks()` — enabled script packs
plus hosted ones — used by the signature, by `allPackOptions`, by `optionSync` and by
the desync-log header. All four are asking the same question: what code is *running*.

A hosted pack is tagged `hosted` where the shim version would go, so a machine running
a mod inside our state and a machine letting Playlunky run it with an injected payload
are not treated as compatible. They are not the same execution model. And only a
*successful* host is recorded: if hosting failed here and worked there, the signatures
should differ, because one machine is running that mod and the other is not.

`tests/test_hosted_signature.py`, 10 tests, including the bug itself stated as a test.

### Not done
The **2.5 adapter** — world mailbox, `resetGame` equaliser, world-state capture — is
not ported. Those fixed the last two desyncs before this fork, so a networked run
today would regress to them. And no two-machine run has been attempted, which is the
only test that actually matters.

---

## 2.0.0-dev0

**Fork point.** Copied from `fyi.modded-online` at 1.0.22 / determinism shim v28.
Disabled in `load_order.txt`; the shipping mod is untouched and still the one that
runs.

The goal of this build is to delete `src/shimInjector.lua` — 8,758 lines that prepend
a determinism payload into other packs' `main.lua` on disk, with 27 archived payload
versions kept so an old block can be stripped by exact text on upgrade. Editing
someone else's mod is the design flaw; the payload's *contents* are correct and
field-proven and get carried over.

Instead: read the content mod's Lua and run it in our own Lua state, against an
`_ENV` we build. No file on disk is modified. This is the Forge/Fabric arrangement —
transform at load, never touch the artifact.

### In this commit
* `LOADER.md` — the brief: why, the four facts it rests on (each verified against this
  install, not assumed), the spike plan, what must not regress, and the open questions.
* `src/modHost.lua` — Spike 1. Loads a pack's module graph into a sandbox and reports
  what it loaded, what it tried to register, and which globals it asked for that
  neither we nor the engine had. That last list is the answer the spike exists for:
  it is exactly the set of Playlunky per-pack APIs still to emulate.
* Inert by default. Every registration API is a recorder, so hosting a mod cannot
  reach the engine — which is what makes running the spike safe in a live game.
* `tests/test_mod_host.py` — 14 tests: global isolation both ways, engine
  pass-through, import caching, cycle termination, a missing module skipped and named
  rather than fatal, errors that carry the mod's own file and line, and a check that
  nothing here runs by itself.

### Spike 1 result
`tools/spike1.py` runs the host from the command line — seconds instead of a game
boot — with `_G` seeded from the Overlunky API definitions 2.5 already bundles, so a
global reported missing is genuinely missing. Against `fyi.spelunky-25-2`:

```
stripped a Modded Online payload [ModdedOnline-DeterminismShim-v28] from main.lua
mod host: LOADED | 56 modules, 56 chunks, 24 registrations, 5 unknown globals
skipped: none
```

It reaches `game:init()` and loads `src/hooks/_HOOKS` and `src/items/_ITEMS`. All five
unknowns are 2.5's own read-then-default idiom, verified in its source rather than
assumed — `src/logging.lua:4` does `_G.sp25DebugLogging = _G.sp25DebugLogging or false`
and `src/game.lua:4-7` does `X = X or SafeImport(...)` for the other three. The first
read of each is nil **by design**, and for the game.lua ones that read is what triggers
the import that defines it. Nothing is missing.

**The approach holds.** A total conversion's whole module graph loads inside our Lua
state, in a sandbox, with nothing touched on disk.

Two things the first run got wrong, both found by reading its output sceptically
rather than by anything failing:

* **It was measuring the mod plus our own payload.** `fyi.spelunky-25-2/main.lua` line
  1 is `[ModdedOnline-DeterminismShim-v28]`; 2.5's own `meta` does not start until line
  1118. So 14 of the 38 registrations were ours, and the missing global `is_liquid_at`
  was our payload asking for it, not 2.5. The tool now strips any known payload by
  exact text before hosting — the same archives `shimInjector.lua` keeps for its own
  upgrade path — and says which version it removed.
* **The engine-API extractor required ALL-CAPS names**, so `Color = {}` and every other
  mixed-case class was reported as a global the host had failed to provide. It now also
  reads annotation-only `--- @class` declarations: 86 enums became 611.

A measurement tool that is quietly wrong is worse than none, because its output looks
like a finding. `tests/test_spike1.py` pins both.

And: a harness gap and a hosting gap look identical from outside. With `get_local_state()` stubbed to nil the report read "30
modules, no errors" — because 2.5's first act is `Sp25GameClass:construct()` ->
`resetGame()` -> `get_local_state().screen`, and 2.5 wraps its own startup in a
`SafeCall` that swallows the failure. The tool now stubs it properly and says what the
mod itself printed.

### Not done yet
Assets. Disabling a mod to stop its Lua also unmounts its `Data/`, so Spike 2 is an
assets-only twin pack of directory junctions. Five *enabled* packs on this install
already have no `main.lua` at all, so the shape is known to work.

---

## 1.0.22

Server unchanged (**1.0.9**). Determinism shim **v28**. No behaviour changes — this
release is entirely about the lag and stutter, and every change either removes an
allocation, removes a syscall, or removes work whose result was thrown away.

### The stutter was the crash trace, and it was armed
`mo_trace.on` was still sitting in the mod folder from the 1-4 crash hunt. That file
turns on per-frame crash tracing: 13 callbacks × enter + exit = **26 marked calls per
frame**, each one a `string.format`, a 180-byte pad allocation, a seek, a write and a
**forced flush**. Twelve of those run on GUI frames, which the code itself notes are
uncapped on borderless fullscreen. At 144 Hz that is ~2,500 forced writes a second
into a Defender-monitored path.

Deleted. Beyond that:

* the trace now **disarms itself when a run ends**. It was armed in `init()` and
  never cleared, so after one session the GUI-frame marks — registered at load and
  never removed — kept writing on the main menu, which is exactly where the frame
  rate is uncapped.
* the pad is built once instead of per mark, the `pcall` body is a named function
  instead of a closure, and the newline is a second write argument instead of a
  second string.
* the flush stays. Lua buffers in userspace, and a native crash takes the process
  down with that buffer unwritten — which is the one thing this file exists to
  prevent.

### The floor-entry hitch: ~4000 lines of entity dump per floor
The per-floor log was **98.9% of the file** — 1.6 MB and 30,000 lines for a nine-floor
session, 17,612 of them `FLOOR_BORDERTILE`. Producing it swept every entity a
*second* time (the digest had just swept them), allocated a table per entity, sorted
~4000 of them through a Lua comparator, formatted ~4000 strings and wrote ~190 KB —
inside the frame the floor engaged on.

The full entity list is now **opt-in via `mo_dump.on`**, documented in the README.
What stays by default is what detection and diagnosis actually need: the digest, the
run state that gates generation, every player's kit, and the per-type histogram —
and the histogram is now built from the tally the digest sweep already makes, so the
second sweep is gone entirely. The logger performs **zero** entity sweeps of its own.

### `SafeCall`: three heap objects per call, ~37 calls per frame
`SafeCall` wraps every per-frame callback in the mod. It allocated an `args` table, a
forwarding closure and a `table.pack` result on every call — and all but three call
sites pass no arguments at all. That is ~6,600 allocations a second of pure
bookkeeping, and GC churn is what microstutter is made of.

Zero-argument calls now go straight to `xpcall(fn, handler)` with the handler hoisted
to a file-level local. Measured over 400,000 calls: **289 ms and 27 KB allocated
before, 45 ms and 0 KB after.** The argument path is untouched, the traceback is
still taken at the frame that raised (verified — the report keeps its stack), and
error reporting still fires once then rate-limits.

### Per-frame allocations elsewhere
* **`get_frame` / `get_ms`** (shim v28) — memoized per *simulated* frame. 2.5 calls
  these from per-entity update paths, so they ran once per live custom entity per
  frame, each time paying a `pcall` and a `get_local_state()` crossing to read a
  number that cannot change within a frame. 400 clock calls in one frame now cost
  **one** engine read. The cache is dropped on `ON.GAMEFRAME` and at the three load
  events, so the restart-carries-forward behaviour is observed exactly where it was —
  `tests/test_shim_clock.py` drives the memoized clock and the pre-cache logic
  through a run, a restart and a second run and asserts they agree frame for frame.
* **the shim's PRNG anchor** — `pcall(prng.get_pair, prng, c)` instead of
  `pcall(function() ... end)`: 21 closures per anchored hook, gone. Same calls, same
  values, same order.
* **the shim's per-frame reseed** — one named function and one `ON.GAMEFRAME`
  registration instead of two callbacks and a fresh closure every frame. The counter
  is still bumped before the seed is taken from it.
* **the leaked-entity sweep** — `pcall(readEntityX, e)` instead of a closure per
  entity, several hundred of them twice a second.
* **the JSON encoder** — a plain string now skips the escape `gsub` entirely. Input
  packets go out every frame plus a resend every 40 ms, and every key in the wire
  protocol is one or two letters, so this ran a closure-driven scan hundreds of times
  a second to change nothing. Verified byte-identical over 4000 fuzzed strings.
* **`netCore.tick`** — the resend list is only built and sorted when something is
  actually pending, instead of allocating and sorting every GUI frame to find out it
  is not. The ascending-cseq order inside is untouched; the server stalls without it.
* **name tags** — the measured text width is cached per name string instead of
  re-measured for every remote player on every display frame.
* **the in-run status line** — rebuilt only when the room, player count, ping or the
  hide-room-code toggle changes, rather than formatted at display rate.
* **the typing notice** and the two per-frame state probes (`readOnLevel`,
  `readQuestResetState`) — closures replaced with named functions; the protected
  reads stay inside the protected call, so a bad frame is still skipped silently
  rather than logged.

### Deliberately not touched
`moOrderedPairs` and the per-tile liquid scan are the two genuinely expensive things
the shim can install, and both are gated off for Spelunky 2.5. They are also the
determinism guarantee itself, so making them cheaper means changing iteration order
or a spawn predicate. Likewise the input-transformation body, the fixed 1..4
injection order, the checksum fold order, the resend cadence, the sweep's 30-frame
cadence and sorted destroy order, and `main.lua`'s registration position all stay
exactly as they are.

---

## 1.0.21

Server unchanged (**1.0.9**). Determinism shim **v27**.

### A folded-in player now gets the party's world
This is the desync from log 42: slot 1 left after 1-4, slot 2 played on and walked
into the exit door, slot 1 was folded back in on the same frame. 2-1 generated from
one seed with identical `gen[pre]` on both machines and `gen[post]` differing on four
PRNG streams.

2.5 advances its world **only** when a door is taken (`DoorLib.setupDoor` ->
`SetPostEnter` -> `onSp25WorldTransition`). A player warped into a run in progress
never takes one, so their copy stays on the world they left while the party's has
moved on. `newLevelHooks` then restores the entity db, drops every hook and installs
the set for `self.sp25World` — so the two machines build the same floor with
different world hooks. Hence 1-1's music on 2-1.

It cannot be worked out locally. `Themes.getThemeForSp25World` is many-to-one, so
2.5's own table does not invert: several custom worlds share one engine theme inside
a tier. The joiner has to be **told**, by the machine that took the door.

Playlunky gives two packs no channel — no `package`, no `io` for a mod that is not
`unsafe`, and `user_data` belongs to the script that wrote it. Engine state is the one
thing both Lua states can see, so four bytes of it carry the handoff:

```
state.arena.player_lives  [1] tag  0xA5 "the world I hold" / 0x5A "adopt this one"
                          [2] index into the SORTED list of world ids
                          [3] 2.5's own world counter
                          [4] (index + counter * 31) % 256   guard byte
```

`player_lives` is arena-match scratch: lives left in a deathmatch. It means nothing
during an adventure run, an arena match rewrites it on start, and nothing persists
it. The ids are numbered from a **sorted** list, because `pairs` order is not stable
across Lua states — that is what desynced randomizer.

The route: the shim publishes 2.5's world at every stage of a floor; our snapshot
carries the two bytes host-to-joiner beside the level count and Kali state it already
sends; every machine writes the request at `PRE_LOAD_SCREEN`, which is ahead of the
shim's `ON.LOADING` read, so an adopted world is in place before the floor is themed.
A machine already standing there adopts nothing and logs nothing. Requests are
consumed on read, so a value is never adopted twice, and the guard byte keeps foreign
numbers in those four bytes from being read as a handoff.

This is the first thing that writes 2.5's route directly, and the rule around it
changed rather than disappeared: the value must come from another machine, and
`onSp25WorldTransition` is never called (it would advance the counter, and we are
copying one). Pinned by `test_content_world_state.py`.

**Known gap:** 2.5 also makes one-per-run choices from `prng` draws — the Summit
chapel level is picked once and stored in `globalState`. A joiner never made that
draw, so a rejoin into Summit can still diverge. Four bytes cannot carry that, and it
needs its own answer.

Covered by `tests/test_world_mailbox.py` (15 tests), including the two halves
agreeing on the byte layout — they live in different files and different Lua states,
and nothing but that test couples them.

---

## 1.0.20

Server unchanged (**1.0.9**). Determinism shim **v26**.

### The boot error, and why 1.0.19's fix never actually ran
1.0.19 registered its world-capture callback forty lines above the `local function`
that defines it. The name therefore resolved as a global, `set_callback` was handed
`nil`, Playlunky accepted it, and the first time it fired it raised:

```
Mod: fyi.spelunky-25-2
Error: attempt to call a nil value
stack traceback:
```

The empty traceback is the tell — the call comes from the host, not from Lua.

The same line is why the run still desynced. With the capture never installed,
nothing ever held 2.5's game object, so the reset built on top of it returned early
every single time. The 1.0.19 fix has not yet run once on a real machine.

Fixed by registering below the declarations. `tests/test_shim_boot.py` now executes
every payload the way Playlunky does — in a stub environment with **no** catch-all
`__index`, so a name that has fallen out of scope comes back `nil` exactly as it
does in the game — and asserts nothing but functions reach `set_callback`. v24 and
v25 are kept verbatim and pinned as *still reproducing* the fault: an archive is
stripped from an installed pack by exact text, so editing one would leave the broken
copy in place forever.

### What the 1.0.19 desync logs actually show
Not a fresh-run problem. Reading the two logs side by side:

* both machines generate 1-1 through 1-4 byte-identically
* slot 1 leaves the run after 1-4; slot 2 is promoted world host and plays on alone
  for about seventy seconds, including two layer travels
* slot 1 rejoins at the exact moment slot 2 walks into the 1-4 exit door
* 2-1 `gen[pre]` matches on both machines — same seed, same ten PRNG streams
* 2-1 `gen[post]` differs on streams 0, 2, 5 and 8

So generation itself diverged, on the first floor of a new world, right after a
mid-run fold-in. Slot 2 reached Jungle **through the door**, which is the only thing
that advances 2.5's world. Slot 1 was **warped** in, so its 2.5 was still on the
world it left. Two different sets of world hooks, one seed, different spawns.

This is the mid-run case, and it is still open. The new-run reset cannot help here:
the run seed does not change on a fold-in, which is correct — resetting a joiner to
Dwelling while the party stands in Jungle trades one wrong state for another.

---

## 1.0.19

Server unchanged (**1.0.9**). Determinism shim **v25**.

### The desync that had nothing to do with rejoining
Reported case: one player boots the game and opens a room; the other plays a bit of
singleplayer, returns to the main menu, then joins. The second player desyncs. No
one left, no one rejoined.

Spelunky 2.5 builds **one** game object per launch — its `main.lua` calls
`Sp25GameClass:construct()` once — and that object holds the current world, the
hooks installed for it and the entity-DB tuning. Its resets hang off `ON.RESET`,
`ON.CAMP`, death, and a `QUEST_FLAGS.RESET` seen at `PRE_LOAD_SCREEN`. A machine
that Modded Online **warps** into a run gets none of those. So the player who had
already played that launch started the shared run still carrying the previous run's
world, hooks and tuning, and generated a different floor from the same seed than
the player who had just booted.

This is the same leak as the known singleplayer bug where **textures are wrong
after going to the title and starting another run** — `resetGame()` is what puts
those back, and nothing was calling it.

The fix uses the handle 1.0.18 exposed: on the new-run signal every machine sees on
the same lockstep frame (the adventure seed's first value changing), the shim calls
2.5's **own** `resetGame()`. It runs on every machine, not just the stale one — an
equaliser that runs in one place only moves the difference somewhere else.

That signal is already where two other mods' carried-over run plans get cleared
(randomizer's `level_order`, the HD mod's `POSTTILE_STARTBOOL`). 2.5's game object
is the third instance of the same bug, so the repair sits with them.

Nothing is written to 2.5's route by hand, and mid-run realignment is still not
attempted — a rejoiner folded into floor 3 is a different problem, since 2.5's
custom worlds do not map one-to-one onto engine worlds. The per-floor log line now
carries `resets=N` so two machines' logs diff cleanly.

Covered by `tests/test_content_world_state.py` (16 tests), including the equaliser
property, a reset that raises, and a mod with no `resetGame` at all.

---

## 1.0.18

Server unchanged (**1.0.9**).

### Reading 2.5's world state: third attempt, and the first that can work
The v23 probe reported, out loud, why the previous two attempts found nothing:

```
NOT FOUND | package=false loaded=nil modules=0 keys=[] Sp25GameClass=true GameLib=true
```

Playlunky gives a pack **no `package` table at all**, so looking 2.5's modules up
in a registry was never going to work — v22 and v23 were both built on a premise
that does not hold here. The same line confirmed what does: `Sp25GameClass` is a
global.

Every 2.5 game instance is `setmetatable({}, gameClass)`, so the class is the
`__index` of the live object. The shim (now **v24**) wraps `newLevelHooks` on that
global class — called once per floor from 2.5's own PRE_LEVEL_GENERATION — and the
`self` it receives *is* the instance. No edit to the mod, no `debug` tricks, and
the wrapped method still runs normally. The report moved to
POST_LEVEL_GENERATION so the first floor of a run is covered too.

Still read-only, for the same reason as before: 2.5's custom worlds do not map
one-to-one onto engine worlds, so rewriting its route could do more damage than a
stale one.

### Why this matters beyond rejoining
2.5 carries state across runs within a game launch — the known "textures are wrong
after exiting to the title and starting another run" bug is the visible symptom.
That means **any** two machines whose 2.5 history differs can generate different
worlds from the same seed: a player who played singleplayer before joining is the
same failure as a player who left and rejoined. This handle is what makes that
state comparable between two captures for the first time.

Covered by `tests/test_content_world_state.py`.

---

## 1.0.17

Server unchanged (**1.0.9**).

### The world-state probe looked in one place and then said nothing
v22 read Spelunky 2.5's world state from a hard-coded `package.loaded` key. On a
real run that came back empty and the probe returned quietly, so a whole session
produced no line at all — and a silent miss is indistinguishable from "this mod
keeps no such state". That is the same failure shape that has cost several rounds
here, and it was mine again.

Discovery (shim **v23**) no longer depends on the key. Playlunky may cache a
pack's modules under whatever name it likes, so the probe searches for the SHAPE
instead: a table carrying both `sp25World` and `spelunky2World`, either directly or
one level down under `game`, which is where 2.5 publishes it. It reports where it
found it, and if it finds nothing it now says so **out loud, once**, listing what
it could see — whether `package` exists, how many modules are cached, a sample of
their keys, and whether 2.5's globals are present.

So the next run either prints the world state or prints exactly why it cannot.

Covered by `tests/test_content_world_state.py`.

---

## 1.0.16

Server unchanged (**1.0.9**).

### Spelunky 2.5's own world state is now visible
The rejoin desync comes from state Modded Online could not see. 2.5 keeps its own
idea of which world the run is in, advances it **only when a door is taken**, and
resets it to Dwelling in `resetGame()`. A player folded back into a run is warped
in rather than walking through a door, so their copy stays where the reset left
it: hence 1-1 music on a later floor, and generation decisions that diverge from
the party's from that floor on. Everything we transfer — `level_count`, the aggro
and kali counters, the quest and presence flags — is engine-side and was already
correct.

It turns out to be reachable without editing 2.5 at all. Its `SafeImport` uses
`require`, so every module is cached in `package.loaded`, and 2.5 itself hands the
live game instance to one of them (`CrashDiagnostics.setGame`). The determinism
shim (now **v22**) already runs inside that same Lua state, so it can read it.

Each floor now logs one line to the Playlunky log:

```
[ModdedOnline] content world state: sp25=4 s2world=3 route=2->4 | engine w3-1 th2 lc=6
```

Compare it between two machines and the divergence is explicit rather than
inferred — the rejoiner will show the mod's world counter back at zero while the
engine is several worlds along.

**Deliberately read-only.** Realigning it means choosing the right sp25 world for
an engine world and theme, and 2.5's custom worlds do not map onto those one to
one — two different sp25 worlds both present as a Jungle-themed engine world. A
write there could corrupt the route worse than leaving it stale. This report is
what a correct realignment needs first, and it costs nothing for a mod that keeps
no such state.

Covered by `tests/test_content_world_state.py`.

---

## 1.0.15

Server build **1.0.9** — copy `server/server.py` and **restart the server
process**.

### "server-side fixes are NOT active" was crying wolf
The mod warns when the server it is talking to is not the build it shipped with,
and the constant behind that check had fallen three bumps behind: the server went
1.0.5 -> 1.0.8 while the mod went on expecting 1.0.5. So a correctly updated
server was reported as out of date, which is precisely the opposite of what the
warning is for, and sends you hunting a deployment problem that isn't there.

Both constants are now checked against each other by `tests/test_version_sync.py`,
so they cannot drift apart again — along with the changelog, which must lead with
the version `main.lua` claims.

### Instant restart was refused after the host left
The restart request was gated on the *lowest occupied slot* rather than on whoever
is actually running the run — the same fault as the fold-in gate fixed in 1.0.12.
A departed player keeps their slot, and a rejoining one reclaims it, so that check
named someone who might not be playing at all and the peer really running the game
had its restart refused with `not_host`. Captured in a log as exactly that.

While a run is in progress the run host drives restarts; outside one, the lobby
host does, as before.

---

## 1.0.14

Server build **1.0.8** — copy `server/server.py` and **restart the server
process**.

### Rejoining no longer hands your kit back
A departed player's spelunker is stood still rather than removed, so the host's
snapshot of it still held the full kit they walked away with — and folding them
back in handed it straight back, which let a player bank consumables by leaving
and rejoining. A rejoiner now comes in with **no bombs and no ropes**, keeping the
health they left with (the idle body already holds it).

The server names the folded-in slots in the `run_start`, and the edit is applied
to that snapshot before it is written, so every machine makes the identical change
to the identical payload. It cannot be decided locally: the returning player's own
machine cleared its departed-player state when its run ended, so it no longer
knows it was the one who left.

Covered by `tests/test_rejoin_kit.py`.

---

## 1.0.13

Server build **1.0.7** — copy `server/server.py` and **restart the server
process**.

### Leaving the run is not leaving the room
1.0.12 handed the run host on when a player was dropped from the ROOM, but the
path a player actually takes when they "leave the game" is *End Adventure*: it
leaves the RUN and stays in the ROOM, so the drop never happens and the promotion
never fired. The room went on naming a run host that had stopped playing, so the
peer still simulating had its fold-in request rejected for not being the run host,
and the rejoining player stayed in the lobby — the same symptom, one layer down.

Ending your adventure now hands the role on, and "in the run" excludes anyone who
has left it, not just a late-joiner. Readying up to rejoin no longer makes you the
run host either: the peer driving the run keeps the role until the fold-in
actually happens.

### The header counted players who had left
`MODDED ONLINE  room XXXX  2 players` still said 2 after one player left. A
departed player keeps their slot in the roster on purpose — their spelunker is
stood still rather than removed, which is what keeps the simulation
deterministic — but the header was counting the roster instead of who is actually
playing. It now counts the latter.

Their spelunker and its loot row still appear on the transition screen. That is
the same deliberate design: removing a player mid-run would fork the simulation.

Covered by `tests/test_run_host_tracking.py`.

---

## 1.0.12

Server build **1.0.6** — you must copy the new `server/server.py` and **restart
the server process**; this release's fix is server-side.

### A host could leave but never rejoin
Folding a returning player in is driven by the run host, and the server decided
who that was with `room.host()` — "lowest occupied slot". Those are not the same
thing, and the gap is the whole bug:

1. player 1 (slot 1) leaves; player 2 carries the run on
2. player 1 comes back and is handed slot 1 again, because it is free
3. `room.host()` is therefore player 1 — the player still *waiting* to be folded in
4. player 2, which really is driving the run, sends its `joinfloor` request
5. the server sees `client is not room.host()` and drops it, silently
6. player 2 goes through the door alone, and player 1 stays in the lobby for good

It only ever bit the host, because only the host's slot is low enough to reclaim
the role on the way back in — which is why a peer leaving and rejoining always
worked.

The room now tracks `run_host_slot` separately from the lobby host, promotes it to
the lowest slot still *playing* when its holder leaves, and refuses to count a
late-joiner as the run host however low its slot. That mirrors the client's
`Network.runHostSlot` exactly, so the two halves finally agree on who is driving.
The server logs the handoff and logs any `joinfloor` it ignores, rather than
discarding it without a word.

Covered by `tests/test_run_host_tracking.py`.

---

## 1.0.11

### Rejoining mid-run never put you back in the game
A returning player is folded in by the world host, but only after the server has
been told they are **ready** — and that announcement could never happen for them.

It ran in one place only: the screen-change handler, behind
`phase == LOBBY and screen == CAMP`. A player leaving mid-run satisfies those in
the wrong order. `leaveRun` drops the phase to IDLE *first*, and the warp back to
the camp happens while it is still IDLE, so that screen change is skipped. By the
time they re-enter the room the phase becomes LOBBY while they are **already
standing in the camp**, and no further screen change ever comes. So readiness was
never announced, the server never emitted `join_pending`, the host was never told
to fold them in, and they sat in the camp indefinitely.

Announcing is now driven by a poll as well, so being in the camp and in a lobby is
enough on its own, whichever order those became true. The desync log records the
announcement, which previously left no trace at all.

Covered by `tests/test_lobby_ready.py`.

---

## 1.0.10

### The host could leave but never rejoin
A player who left and came back was folded into the run by the **world host** —
the one machine whose simulation is authoritative. That role is picked once, at
run start, as the lowest slot in the roster, and it was never moved again. So
when the player holding it left, every remaining machine went on pointing at a
slot that was no longer in the game and `isWorldHost()` was false *everywhere*.

Everything only the world host does then quietly stopped — publishing the
authoritative world and seed, and folding a late joiner in, which returns at its
first line for anyone who is not the world host. That is why the same rejoin
worked one way round and not the other: with a non-host gone the host was still
there to pull them back in, and with the host gone nobody was, so the returning
player sat in the lobby forever.

The role now passes to the lowest slot still playing, on the ordered
`player_left` event, so every machine agrees on the new host at the same point.
The desync log records the handoff.

Covered by `tests/test_world_host_handoff.py`.

---

## 1.0.9

### Rejoining left the whole party laggy
Not framerate — input lag, and it stayed for the rest of the run.

The lockstep input delay is sized from the two worst pings in the room, and sized
**once**, at run start. A rejoin is a run start. The catch is how a ping is
measured: the client stamps a request and times the reply in Lua, which only
means "network round trip" if our frame loop kept running throughout — and while
a level generates the game runs no script at all. A rejoin *is* a level load, so
the reply spanned it and the client reported a second or more of loading as its
ping. That pinned the room at the 20-frame ceiling (~333 ms), for everyone,
until the run ended.

The client now discards any sample whose window contains a stall, keeping the
previous value instead: reporting nothing new is better than telling the server a
link is a second slow when it isn't. The server deliberately still **caps** a
genuinely awful connection rather than ignoring it — under-sizing the delay for a
real 2 s link stalls the lockstep constantly, which is worse than input lag.

The desync-log header now records `inputdelay=`, which appeared nowhere before,
so "it went laggy after X" can be confirmed from a capture instead of inferred.

Covered by `tests/test_ping_sampling.py`.

---

## 1.0.8

### Rejoining after you leave
Leaving a run hides your spelunker rather than removing it — that is deliberate,
because deleting a player mid-run would fork the simulation. But the hiding was a
one-way door: `INVISIBLE`, `PASSES_THROUGH_EVERYTHING` and `NO_GRAVITY` were set
on the entity, and every path that could have cleared them bails the moment
nobody is marked as gone. So the flags outlived the departure. Coming back — to
the run in progress or to a fresh one — left you invisible, weightless and
falling through the floor, with nobody else able to see you either.

There is no `player_joined` event; a returning player always arrives on a
`run_start`, which clears the departed list wholesale, and that is precisely when
the last thing holding the undo information disappeared. The mod now remembers
which spelunkers it hid and gives them their bodies back once their slot is no
longer departed. It only ever clears the three flags it set itself, so a player
made invisible or weightless by another mod, or by an item, is left alone.

### Leftover HUD rows
A departed player's co-op HUD row was blanked by setting `opacity`, which the API
documents as controlling the row's *background* — not its contents. Their hearts,
bombs and ropes kept drawing over an empty slot. The row is now emptied properly,
and handed back intact when that player returns: the inventory slot is switched
off on departure and the engine never switches it back on by itself, so a
returning player previously had no inventory row at all.

Covered by `tests/test_player_return.py`.

---

## 1.0.7

Supersedes the previous public release, **1.0.46**.

**Everyone in a lobby must update together**, and if you run your own server you
must copy the new `server/server.py` **and restart the server process** — editing
the file does nothing to an already-running server. The mod now tells you in-game
if the server you're on is behind what it needs, and `py server/server_version.py`
reports any server's build from the command line.

The server build for this release is **1.0.5**; the mod tracks that separately
from its own version, so client-only releases no longer ask you to re-upload a
server that is already correct.

---

## Major fixes

### Mod settings are now synced from the host
Mod options feed level generation — the HD mod's own generator reads its settings
to pick room pools — so two players with the same mods and the same seed but
**different settings built different worlds**. A capture showed exactly that:
identical level seed on 1-2, but 427 vs 495 floor tiles, different ladders, an
altar on one machine and not the other, and a player who then fell out of a world
that only existed on one side. The seed distribution was flawless; the settings
weren't.

Everyone in a room now borrows the **host's** mod settings for as long as they're
in it, the same way the pet style already worked. You no longer have to hunt
through forty toggles to find the one that differs, and people who like different
settings can still play together.

**Your own settings and progress are never changed.** Modded Online does not
write any mod's save file at all — that file holds journal progress, unlocks and
tutorial flags as well as options, and nothing here touches it. Your values are
put back in memory *before* each mod saves, so a mod only ever writes its own
settings out, even mid-run; they're restored the moment you leave the room, and a
copy is written to `Mods/Packs/mo_options_backup.txt` before a single value is
changed. If that backup can't be written, nothing is overridden at all.

Settings that can't affect the world — window positions, the dev panel, overlay
toggles — are left alone on both sides.

### Jungle floors desynced from the engine's multithreaded water
Spelunky 2 simulates liquid across worker threads, so two machines two frames
into a level do **not** agree on the exact tiles at a waterline. That would be
harmless if mods only drew water — but the HD mod makes *spawn decisions* from
it, at `ON.LEVEL`, in the form:

```lua
if validlib.is_valid_lillypad_spawn(x, y, l) and prng:random_chance(7, LEVEL_DECO) then
```

Lua's `and` short-circuits, so the roll only happens when the liquid test passes.
**One tile of disagreement anywhere along a shoreline changes how many times the
shared PRNG is drawn**, and every draw after it lands somewhere else — for the
rest of the floor, and into the next one.

A capture showed it exactly: identical seed, identical options, all ten PRNG
streams identical at both `gen[pre]` *and* `gen[post]`, and then 16 vs 9
anchovies, 39 vs 38 lilypads and 2 vs 3 frogs at `ON.LEVEL` — after which every
later Jungle floor differed, while every Dwelling and Ice Caves floor matched
byte for byte. That pass returns immediately unless the theme is Jungle, which is
why only 2-x broke.

The determinism shim (now **v21**) answers `is_liquid_at` during a mod's
`ON.LEVEL` callbacks from a snapshot taken at `POST_LEVEL_GENERATION`, where zero
physics updates have run and the water is a pure function of the shared seed and
layout. Gameplay liquid checks — piranhas, drowning, bomb-displaced water — go
straight through to the engine as before, dry levels keep the engine's answer
untouched, and only mods that generate their own levels are affected, so Spelunky
2.5 is unchanged.

### Online runs are now marked as SEEDED, which they are
The server hands out the adventure seed and every machine generates from it — but
the engine was never told, so `state.quest_flags` still said "adventure run" and
mods took the branch meant for a solo player building up their own save file.

The HD mod does exactly that, in the one place it reads the flag. On an unseeded
run it picks a **character unlock** for the floor, and that choice reads how many
HD characters *this* player has unlocked, then draws from the level-generation
PRNG to pick one. Two players with different unlocks therefore took different
branches **and consumed a different number of generation draws**, so everything
drawn afterwards landed somewhere else: same seed, same mods, same settings, same
PRNG going in — completely different level. It's gated on `world == unlocked + 1`
plus a per-world theme, which makes the *first eligible floor of each world* the
one that breaks. Two separate captures desynced on exactly those floors: **1-2**
in Dwelling and **2-1** in Jungle.

Setting the flag costs nothing — no save file is read or written, in memory or on
disk, so nobody's progress can move. It also stops a networked run from
*recording* progress, which keeps two players' saves from drifting further apart
the longer they play together, and any other mod that respects the flag
(Randomizer 2.0 anchors itself on it) becomes deterministic for free. The flag is
set at the two lockstep-identical points every machine passes before a floor is
built, and handed back the moment the run ends, so solo play is unchanged.

The desync log now records `seeded=` beside the other generation inputs.

### The HD mod generated different worlds from the same seed
Two players with identical mods, identical settings, identical seeds and
identical PRNG state going into 2-1 still got completely different Jungle
floors — different rooms, different enemies, different shop, different spawn
points. Everything Modded Online controls matched; the divergence was inside the
HD mod's own Lua generator, which branched on state of its own. Two causes, both
fixed in the injected determinism shim (now **v20**):

- **Deterministic table iteration for mods that generate their own levels.** Lua
  seeds its string hash per process, so `pairs` over string keys walks a
  different order on every machine and every launch — a coin flip, every floor,
  that no amount of seed agreement can fix. Ordered iteration existed already but
  was welded to the same switch as the PRNG anchors, and those anchors are what
  once broke Spelunky 2.5's 1-4, so the whole package stayed off for every mod
  without a `level_order` global. The two are separate switches now: the HD mod
  gets ordered iteration, Spelunky 2.5 is left on precisely the behaviour it has
  been playing on.

- **The HD mod's run plan survived an instant restart on everyone but the
  presser.** It keeps its own plan of the run — which level each *feeling* loads
  on (tiki village, hive, restless, rushing water, the vault, the black market
  entrance), whether the worm has been visited — and only rebuilds it on
  `ON.RESET`, which the machine that pressed instant restart receives and a peer
  warped by the synchronised restart does not. Peers carried the dead run's plan
  into the new one. It's now cleared on the new-run signal every machine agrees
  on, exactly as a randomizer's `level_order` already was.

The desync log also samples **all ten PRNG streams** at each floor's generation
instead of three. The three it sampled were not the one the HD mod names when it
draws, so a capture could show "inputs matched" while the stream that mattered
had already diverged.

### "Mods don't match the room" now says what doesn't match
The rejection used to print one opaque digest — *"host runs: 1 scripts/199
files/19f26e1d"* — which told you only that something differed. Two players with
the same mod and the same 199 files had no way to find out which of the four
inputs to that digest had moved, and neither did the log.

The fingerprint is per-pack now (`name:files:hash:shim`), so a rejection is a
real diff and names the fix:

- *"'fyi.hdmod' is the same mod as the room's 'HDmod-1.3.1', just a differently
  named folder — rename your Mods/Packs folder…"*
- *"'fyi.hdmod' is a different VERSION: yours has 199 .lua files, the room's has
  204."*
- *"'fyi.hdmod' has the same 199 files but they are not the same files — one of
  you has an edited or differently packaged build."*
- *"'fyi.hdmod' is patched differently: yours is v19, the room's is v19+optv1.
  …whoever is behind should start the game once more and rejoin."*
- *"You have 'X' enabled and the room does not"* / *"The room has 'X' enabled and
  you do not"*

The full breakdown goes to the in-game log and the whole signature is now in the
desync-log header as `mods=`, so two captures side by side answer it as well. A
mod's folder name is no longer baked into its file hash, which is what makes the
rename case detectable at all.

### Doors on transition screens could be swallowed
The layer-door interception used the door list from the level you had just left
(nothing rescans it off-level), and entity ids get recycled between screens. If a
recycled id landed next to a player on a transition screen — likely, since players
stand right beside the exit door there — the door press was eaten and the
transition couldn't be taken. Most visible on transitions that offer a **shortcut**,
where more doors are clustered around the players. The interception is now
restricted to actual levels.

### Back layers were unreachable
Layer doors did nothing — a press was swallowed and no travel happened. The cause
was a callback-id mix-up: the mod released an engine hook with `clear_callback`,
which addresses a completely different registry, so instead of removing the hook
it deleted **one of the mod's own callbacks at random, once per floor**. Silently,
with no error. By 1-4 the callback that performs layer travel was simply gone.
Back-layer lights, money tracking and several other per-frame systems were being
deleted the same way.

### Players dropped mid-run for loading a level
While a level generates, the game runs no script code at all, so it sends nothing
— which the server could not tell apart from a crash. Walking into an exit door on
a heavy floor, or using instant restart, got you evicted from your own run. If you
were the host, that closed the room, and everyone sat on **WAITING FOR PLAYERS**
until the session timed out. Clients now announce a load *before* they block, and
the server grants a much longer grace while one is in progress.

### Reliable events could be lost or stop entirely
Two independent faults in the ordered event channel — the one that carries
restarts, kills, purchases and every other world-affecting interaction:

- The server acknowledged events **before** checking they could be applied, so an
  event arriving out of order was confirmed to the sender and then discarded. The
  sender never re-sent it. Gone for good.
- The server gave up re-sending after ~10 seconds. Because clients apply this
  channel strictly in order, one missed event meant every later one piled up
  unapplied — a client's event channel could die for the rest of the run while the
  game carried on looking completely normal.

Symptoms ranged from instant restart doing nothing to another player's actions
silently ceasing to register.

### Long boss fights ended in a crash
Spelunky 2.5 disposes of transient entities (lair-boss claws, rubble, replaced
pickups) by parking them far outside the level and scheduling a delete for their
next update — which never arrives, because entities out there are never updated.
They accumulate forever. A long lair-boss fight degraded from 60 to ~45 simulated
FPS and then took the process down. The mod now clears them up safely.

### Instant restart
Fixed several separate faults: restarting from any floor other than 1-1, restarts
that only worked every other time, and votes that could be swallowed entirely.

---

## New features

### Test players
Set **TEST PLAYERS** in the menu to 1–3 and every room you open gets that many
stand-in players, so the multiplayer paths can be exercised with nobody else
online. Each is a real client with a real slot on the real server — the roster
grows, extra spelunkers spawn, the co-op HUD gains rows. They vote yes on instant
restart, so restarting works on your own. Off by default.

### Seed pinning
**TEST SEED** pins the adventure seed for runs you host, written as the game
prints it (`057AF45C-68CB3C2B`). Instant restart replays the same run instead of
rolling a new one, which makes a floor that misbehaved reproducible on demand.

### Python is required, and now says so
The server, bridge and test players are Python scripts. Without Python the mod
used to produce a bare Windows error from a console you never asked for. It now
detects Python properly, explains what's needed, and opens the download page.
`py`, `python` and `python3` are all accepted, and Windows' Microsoft-Store
placeholder for `python.exe` is correctly not mistaken for an install.

### Server version handshake
The server reports its build on connect; the mod warns in-game and in the log if
it differs from yours. Because the server is a separate process, it is easy for it
to silently sit on old code while every client-side fix looks applied.

---

## Minor changes

- **Chat now opens with `T`** instead of Enter. Enter still sends, Esc cancels.
- Your other script mods now carry **two** clearly marked Modded Online blocks at
  the top of their `main.lua` — the determinism shim (`[ModdedOnline-Determinism
  Shim-v20]`) and the settings sync (`[ModdedOnline-OptionSync-v1]`). Both are
  added automatically, both are safe to delete, and `autoShim: false` in
  `config.json` stops either from being added. As always, a newly added or
  upgraded block only takes effect on the **next** launch.
- Fixed a crash when the engine returned a malformed player object — previously
  took down the camera and back-layer lighting.
- Liveness heartbeat is far more frequent, so a brief hitch can't be mistaken for
  a disconnect.
- A locally hosted server now **replaces** an older instance still running, rather
  than deferring to it. Previously an update could appear to have no effect.
- Reliable events are sent in order rather than arbitrary order, so the common
  case needs no recovery at all.
- The desync log records which server the session used and its build (`server=`),
  whether leaked-entity cleanup was active (`leaksweep=`), why a restart press was
  or wasn't accepted, and when the inbound event channel stalls.
- Test players write their own log next to the desync log.

---

## For server operators

- `RUN_TIMEOUT_S` 2 s → 8 s, plus a 60 s grace for a client that has announced a
  load. **Do not lower these**: they are sized for the slowest plausible level
  generation, and going under it evicts healthy players mid-run.
- Reliable events are now re-sent until acknowledged, with no give-up, for as long
  as the client is in the room. A genuinely dead client is removed by the timeout
  sweep instead.
- A host may pin an adventure seed for a room; instant restart replays it.
- New tools in `server/`: `server_version.py` (report any server's build),
  `fake_player.py` (stand-in player), `test_fake_player.py` (end-to-end tests).
  `test_server.py` has grown coverage for the event-channel and timeout fixes.
