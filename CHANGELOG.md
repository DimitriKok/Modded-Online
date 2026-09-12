# Changelog

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
