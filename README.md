# Modded Online (client mod)

Self-hosted online play for scriptable Spelunky 2 mods (built for and tested
against Spelunky 2.5). This pack is standalone: it does not modify any other
mod — just enable it alongside your content mods.

- The server, client bridge and connectivity probe live in `server/` inside
  this pack. Full documentation: `Documents/Modded online/`.
- Requires unsafe mode (real UDP sockets): accept the Playlunky warning.
- **Requires Python** (the server, the connection bridge and the test players are
  Python scripts). If it is missing, the mod says so in-game and opens
  <https://www.python.org/downloads/> rather than letting Windows show a bare
  "not recognised" box from a console you never asked for — tick **Add python.exe
  to PATH** in the installer, then restart Spelunky 2. `py`, `python` and
  `python3` are all accepted; Windows' Microsoft-Store placeholders for
  `python.exe` are correctly *not* treated as an install. An install left off
  the PATH is found where the installer put it. **On Linux** it has to be the
  Windows Python, inside the game's Proton prefix: see "Playing on Linux
  (Proton)" below.
- Usage: the game's main menu → **MODDED ONLINE** (the game's Online row, renamed)
  → **HOST** or **JOIN**. A controller works as well as the keyboard. **VANILLA
  ONLINE**, at the bottom of that menu, opens the game's own Online menu. On a
  Playlunky build where the row can't be taken over, a `[O] MODDED ONLINE` hint shows
  on the main menu instead, and O opens it. The first time it starts, four popups
  come first:
  - how to set mods up;
  - a notice about the mod;
  - whether to switch on **AUTOMATICALLY SEND LOGS**;
  - whether to switch on **AUTOMATICALLY SYNC DATA**.

  Both switches can be changed later under **SETTINGS**.
- To play a mod online, tick it in Playlunky's options for Modded Online, then
  restart the game. A popup says so.
- **HOST** always opens a *private* (code-only) room — matchmaking never joins
  it; you share the room code with friends. Choose where it lives:
  - **Official server**: on the default server (`129.213.14.228`) — no need to
    run your own.
  - **Dedicated server**: on a server you run. Set **Server IP** to
    `127.0.0.1` (the bundled server auto-launches on this machine) or to
    another machine's address (start it there with
    `py server/server.py --dedicated` first). Remote addresses route through
    the client bridge automatically — no inbound port forward needed on the
    hosting PC, exactly like joining a friend.
- **JOIN** asks how:
  - **Friend**: join a specific hosted room by code — **Official server**
    (code only) or **Dedicated server** (their server IP + code).
  - **Matchmaking**: instantly finds an open *public* room with *your exact
    mod list* on the official server, or opens a fresh one if none are waiting.
    It only ever pairs you with other **Matchmaking** players — never someone's
    hosted room. No mod picker: the match is on your enabled scripts, since
    deterministic lockstep only works between identical setups.
- The default public server is `129.213.14.228` (change `PUBLIC_HOST` in
  `src/netCore.lua` to point elsewhere); run it with
  `py server/server.py --dedicated` so it stays up between sessions. For
  internet play its machine still needs its UDP port reachable — forward it on
  that router, or use an IPv6/public host.
- Everyone playing together needs the same mods, load order, and Modded Online
  version (the matchmaker and the lobby gate both enforce it).
- **The server is half of this mod, and it is a separate process.** Hosting on a
  REMOTE server (the official one, or a friend's) runs whatever code is deployed
  *there* — updating your pack does not update it, so every server-side fix is
  simply absent. The client now says so: it compares the server's build against
  its own on connect and warns in-game and in the log
  (`SERVER VERSION MISMATCH`), and the desync-log header records which server the
  session used (`server=`). To be sure you are on the fixed server, host with
  **Dedicated server** and Server IP `127.0.0.1` — that one is auto-launched from
  this pack, and any older instance still running is replaced first.
- **SETTINGS** (in the Modded Online menu) holds the rest:
  - **HIDE ROOM CODE** masks the room code for streaming.
  - **TEST PLAYERS** is described below.
  - **SYNC SAVE DATA** copies the progress you made under Modded Online into the
    mod itself.
  - **AUTOMATICALLY SEND LOGS** and **AUTOMATICALLY SYNC DATA** are below. Both
    are off by default.
  - **ENABLE DEBUG MESSAGES** shows the diagnostic lines at the top left of the
    screen, from Modded Online and from the mods it hosts. It's off by default.
- **Desync logs to Discord** (opt-in): switch on **AUTOMATICALLY SEND LOGS** and a
  run that desyncs sends its log to the server, which posts it to the Discord
  channel its operator set up. Server owners: see `server/DISCORD.md`.
- **AUTOMATICALLY SYNC DATA** does **SYNC SAVE DATA** for you every time the game's
  main menu comes up. If you also play the mod on its own, outside Modded Online,
  leave it off: it copies Modded Online's progress over the mod's every time.
- Settings persist in `config.json` next to this file.
- Console: set `MO_DEBUG = true` in the in-game console for verbose logs.

## Playing on Linux (Proton)

Spelunky 2 runs on Linux through Proton, as a Windows program inside a Wine prefix,
and so does everything Modded Online starts. The server, the bridge and the test
players need **the Windows version of Python, installed inside the game's Proton
prefix**. The Linux `python3` from your distribution is out of the game's sight, and
installing it does nothing for the mod.

1. Install protontricks (on Arch: `yay -S protontricks`; there is also a Flatpak,
   `com.github.Matoking.protontricks`).
2. Start Spelunky 2 once through Steam if you never have, so that its prefix exists.
3. From python.org, download Python 3.13's **Windows installer (64-bit)**,
   `python-3.13.x-amd64.exe` (the classic installer, not the Python install manager).
4. Run it inside Spelunky 2's prefix (Steam app id 418530):

   ```bash
   protontricks-launch --appid 418530 ~/Downloads/python-3.13.x-amd64.exe
   ```

5. On the installer's first page leave **Use admin privileges when installing py.exe**
   ticked (it puts `py.exe` in the prefix's `C:\windows`), tick **Add python.exe to
   PATH**, and choose **Install Now**.
6. Start the game and use MODDED ONLINE as on Windows.

Install the pack as one folder: `Mods/Packs/<folder>/main.lua`, not a folder inside a
folder. Unpacking a download straight into Mods/Packs can leave it one level deeper.
dev82 copes with that, but older builds lost their settings (the first-run popups on
every launch) and could not start the bridge.

Before dev80 the mod found Python only through Windows' `where` command, which Wine
implements from 10.0 on: with Proton 9 or older, Python installed this way still read
as missing. dev80 also looks where the installer puts it, so any Proton version works.

If the installer will not run, Python's **Windows embeddable package (64-bit)** works
too: unzip it to `drive_c/Python313` inside the prefix
(`steamapps/compatdata/418530/pfx/` in the Steam library that has the game), and the
mod finds `C:\Python313\python.exe` there.

The helpers run under Proton like the game, so after you quit, Steam can show
Spelunky 2 as running for up to a minute while the bridge closes itself.

If joining or hosting says **Could not reach the server**, the rest of the message
says how far the bridge got, from its log, `server/client_bridge.log` in this pack
(dev81 on): it did not start, the game's messages never reached it, the server did not
answer, or the server's reply never reached the game. Send that file along with the
report, and `modded_online_connect.log` from the Spelunky 2 folder (dev83 on), which
says which Python was used, the exact command each helper was started with, and
whatever Python printed (`server/client_bridge.out`).

## Testing on your own (TEST PLAYERS)

Set **TEST PLAYERS** (Modded Online menu → SETTINGS) to 1, 2 or 3 and every room you
open gets that many stand-in players (three is a full room, since you are the
fourth). Each is a real client (`server/fake_player.py`): its own process, its
own socket, a real slot on the real server. Your game sees normal extra players —
the roster grows, more spelunkers spawn, the co-op HUD gains rows, and every
multiplayer path (layer travel, transitions, restarts, someone leaving) runs for
real. They stand still and press nothing, and each gets its own character so you
can tell them apart.

They are started when you enter a lobby, so set the count before you host.

**Instant restart works on your own** with them in the party: the mod needs every
player to press restart, and each dummy votes yes once as soon as it sees your
vote (once per press — they do not answer each other).

What it cannot do is check that two machines *agree*: it runs no simulation, so
it sends no world digests or position checksums. Finding a real desync still
takes two real machines.

It commits its input about two seconds ahead of your game rather than answering
frame by frame, so your game never waits on it and the run stays smooth. (If you
still see stutter, check whether `mo_trace.on` is present in this folder — that
turns on per-frame crash tracing, which writes to disk on every callback of every
frame. Delete it unless you are actively capturing a crash. It now also switches
itself off when a run ends, so it can no longer keep writing on the main menu.)

The other diagnostic flag is `mo_dump.on`, and it is **off** by default. With it,
the log gains the full sorted entity list for every floor — the artifact you diff
between two machines to find where a world diverged — at about 190 KB and ~4000
lines per floor. Without it you still get the floor digest that *detects* a
divergence, the run state that gates generation, every player's kit, and the
per-type entity histogram. Create the file only when you are about to capture a
desync, and delete it afterwards.

Leave it at OFF for normal play — the count is persisted, and with it set you
would drop strangers into a friend's lobby (the game toasts a warning when it
does).

You can also run it by hand, which is how you give it buttons to hold:

```bash
py server/fake_player.py 127.0.0.1 26000 ABCD --name Tester --hold right+jump
```

Stop it with Ctrl-C in its window; the mod stops it for you when you leave.

`py server/test_fake_player.py` exercises it end-to-end against the real server.
The stand-in there models the real lockstep gate — it only advances a frame once
the dummy's input for it has actually arrived — so a dummy that stops feeding it
fails the test with the frame it died on, instead of quietly hanging.

## Session rules

- **Starting a run from the camp lobby** depends on the room type:
  - **Private** (friend / dedicated / official-host rooms): everyone is ready as
    soon as they reach the camp with a character picked, and the **host** walks
    into the camp's **main door** to start the run for the whole party. Everyone
    else's door won't open.
  - **Public** (Matchmaking rooms): each player readies up by walking through the
    camp's **main door** — it doesn't leave the camp, it just marks you ready
    (walk through again to un-ready). Once *every* player in the room is ready,
    the run begins for everyone automatically. It never starts with just one
    player, so readying up alone simply keeps you waiting in the lobby until
    someone else matchmakes in; they can keep joining and readying until it
    starts.
- **Match your mod settings with each other.** Mod options feed level
  generation -- the HD mod's generator picks room pools from its own settings --
  so players whose settings differ build different worlds from the same seed and
  desync. Earlier versions borrowed the host's settings automatically; that
  relied on a block injected into each mod's `main.lua`, and injection is gone.
  Set a mod's options the same way on both machines before you play.

  If a run desyncs for no visible reason, compare the `packopts=` line at the
  top of both `desync_log.txt` files: a difference there means the settings
  differ somewhere. It is not conclusive on its own -- the mod-picker
  checkboxes are options too, and those differ legitimately when two players
  have different mods installed.

- **Instant restart is a vote** while online: pressing it mid-run casts a vote
  (your spelunker keeps playing — the local restart is cancelled) and the run
  only restarts once EVERY present player has pressed instant restart, at which
  point the whole party restarts together on a fresh seed. An incomplete vote
  expires after 20 s, and a player leaving no longer blocks it. From the
  post-wipe death screen there is no vote — the host's restart just starts the
  next run.
- **End adventure** gives up the run by killing your party (that's what the
  button does), so it's an **individual leave that exits the room**: YOU leave
  the room entirely while the OTHERS keep playing. Your spelunker is *taken out
  of their world* (not left standing idle) the instant you go — every remaining
  machine drops your whole kit for them to grab (held item, backpack, and your
  bombs, ropes and powerups like climbing gloves or spike shoes — the bombs and
  ropes come in a player bag, the powerups as pickups), hides your spelunker,
  switches off its collision, and drops you from the party roster so you leave no
  HUD bar, off-screen cursor, ghost or transition-screen panel behind — all on
  the same simulated frame, so it can't be seen or bumped and it can't desync. If
  you
  hosted the room, the host role simply passes to the next player (a private
  room no longer closes when its host gives up mid-run). A genuine full party
  wipe is different: everyone died, so everyone returns to the camp lobby
  together to restart. (Modded Online tells the two apart by whether the room
  reopens for everyone or keeps running for the others.) There is no longer a
  client-side "floor rescue" on a lone party death.
- **Pausing / tabbing out never freezes the party**: the shared world can't
  stop for just one player under lockstep, so a menu pause or a window that
  loses focus no longer halts everyone — the world keeps running and that
  player's spelunker simply stands still until they return. (The pause menu
  therefore doesn't freeze the game while online; leave a run with instant
  restart → Return to Camp.)
- **Chat**: press **T** in the camp lobby or during a run to type a
  message, **Enter** to send (**Esc** cancels). Messages run over the reliable
  event channel and appear for everyone, and a "*name* is typing…" notice shows
  while others compose. Chat never touches the world simulation, and typing
  holds your spelunker still so `wasd` doesn't move it.
- **Public rooms** (Matchmaking / official host) stay open when the host
  leaves — the host role passes to the next player and the room only closes
  once everyone has left. Private (friend / dedicated-hosted) rooms close when
  their host backs out from the lobby — but *not* when the host gives up
  mid-run with End Adventure: that hands the host role on so the players still
  going aren't kicked.
- **Desync recovery**: if the machines' worlds hard-diverge (the old
  "Waiting for other players" freeze), the world host automatically warps
  everyone FORWARD to the floor past the desynced one, generated from its
  authoritative seed — always advancing, so a recovery can never loop. The
  warp carries the host's run state (level count, shopkeeper aggro, Kali)
  and every player's inventory (health, bombs, ropes, money, powerups, held
  item, mount), so all machines rebuild identical spelunkers. Players who
  are dead in the host's snapshot come back with 4 HP (after a desync the
  machines usually disagree about who died; vanilla co-op revives the dead
  every level anyway).
- **Party wipe**: a whole-party death is treated as that player leaving the run.
  A solo give-up (End Adventure) removes just that player — their spelunker is
  hidden and made non-colliding on every other machine, their whole kit drops
  for the others, and they exit the room while the rest play on. A real wipe
  (everyone dead) reopens the room, so everyone returns to the camp lobby to
  restart together. There is no client-side "floor rescue" anymore.
- **Quitting mid-run**: leaving no longer freezes the rest of the party.
  - *Quit to menu* (a pause option that returns to the main menu): you leave the
    room the instant the quit begins — the others are told right away and keep
    playing, while you ride out to the menu. Leaving hands the room off, so a
    public lobby carries on without you.
  - *Closing the game* (an "Exit Game" that shuts the app down): the app can't
    warn the server, so the others briefly wait — but a player who is silent for
    ~2 s mid-run is dropped automatically (they stream inputs constantly while
    alive), instead of stalling everyone for the full ~15 s connection timeout.
- **Back layers**: any player can take a layer door alone — each machine's
  camera follows its own spelunker's layer (vanilla forces the camera to the
  leader's layer, which made solo layer travel impossible in co-op). Players
  in the back layer carry their own light aura. Locked layer doors need the
  door already unlocked, a key in hand (consumed) or the skeleton key pickup;
  a still-locked door never opens from inside the back layer.
- **Mod matching**: lobbies compare enabled SCRIPT packs only, ignoring
  load order and data-only mods (skins, sprites, sounds), so those are free
  to differ between players.
- **Leaving**: the client bridge closes itself when the game leaves the
  session (or goes silent). A non-dedicated server exits once it holds no rooms;
  a `--dedicated` server (and public rooms) stay up. Backing out to the main
  menu from the lobby counts as leaving.
- **Leaked entities**: Spelunky 2.5 disposes of transient entities (the Dwelling
  lair boss's claws, rubble, replaced pickups) with `Helpers2.sweepUnderTheRug`,
  which parks them at (-1000,-1000) and defers the destroy to the entity's next
  state-machine update — which an entity that far outside the level never gets, so
  every swept entity leaks. A long lair-boss fight piles up thousands, the sim
  rate decays (the "known 2.5 lag"), and the engine eventually dies inside its own
  update. Modded Online finishes the job once they pile up: while more than 1000
  are parked, entities parked at the sentinel X for 300+ simulated frames are
  destroyed on a fixed cadence in sorted uid order, so every machine destroys the
  identical set on the identical frame. Fewer are left where 2.5 put them, as when
  playing alone (since dev79: the few hundred 2.5 parks as a summit floor begins
  were the last thing hosting did differently before a crash leaving one). Players,
  mounts, active floors and engine furniture are never touched. Each floor's log
  says what was parked. Drop `mo_nosweep.on` in the pack folder to disable it; the
  desync-log header records which way it ran (`leaksweep=`).
- **Reliable events**: the ordered channel is applied strictly in sequence on the
  client, so a single event a client never receives holds back every later one.
  The server therefore re-sends until acked and **never gives up** while the
  client is still in the room (a client that is genuinely gone is removed by the
  timeout sweep instead), and it never acks an event it cannot yet apply. Both
  matter: the failure mode is invisible from inside the game, because the
  unreliable state channel keeps flowing and play continues perfectly while every
  world event is silently ignored.
- **Loading**: a client sends nothing at all while a level generates — its Lua
  callbacks don't run, so neither inputs nor heartbeats go out. Silence therefore
  cannot distinguish "loading" from "crashed", and on a heavy floor a single
  blocked frame can last tens of seconds. So the client **announces the load
  before it blocks** (`{"t":"loading"}`, sent from the GUI tick while a screen
  change is pending and again at `PRE_LOAD_SCREEN`), and the server grants it
  `LOADING_GRACE_S` instead of the in-run drop timer, ending that grace the moment
  an input datagram shows it is simulating again. Without this, walking into an
  exit door on a laggy floor gets the player evicted mid-run — and an evicted host
  closes a private room outright, leaving everyone on WAITING FOR PLAYERS.
  `RUN_TIMEOUT_S` still has to stay clear of ordinary hitches, and the client
  heartbeat (`HEARTBEAT_MS`) well under it.

## Module map

| File | Role |
|---|---|
| `main.lua` | meta + module loading |
| `src/util.lua` | logging, `SafeCall` |
| `src/json.lua` | wire-format JSON |
| `src/netCore.lua` | UDP session, reliable ordered event channel, config |
| `src/inputSync.lua` | lockstep input gate, desync detection, floor resync |
| `src/eventSync.lua` | run lifecycle, seed authority, instant-restart redirect |
| `src/menuProbe.lua` | diagnostic: what the game's menus look like from Lua (`mo_menuprobe.on`) |
| `src/menuInput.lua` | the game's own menu input (controllers) for our menu and popups |
| `src/mainMenuHook.lua` | MODDED ONLINE as the main menu's Online row; VANILLA ONLINE |
| `src/vanillaUI.lua` | the menu, popups and plaques in the game's own font and menu sprites |
| `src/campPuppets.lua` | the other players in the camp lobby, as puppets |
| `src/menuUI.lua` | MODDED ONLINE window + in-run status line |
| `src/chat.lua` | in-run text chat |
