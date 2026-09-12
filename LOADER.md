# Modded Online — loader build

**Read this first. It is the whole brief.** This folder is a development copy of
`fyi.modded-online`, forked at mod version 1.0.22 / determinism shim v28, to build one
change: *stop injecting code into other people's mods.*

The shipping mod is untouched and still works. This copy is listed in
`Mods/Packs/load_order.txt` as `--fyi.modded-online-loader`, i.e. **disabled** — two
enabled copies would both bind the UDP port, both register every callback, and
`util.PackDir()` would resolve to whichever the load order hit first.

---

## The problem being solved

Modded Online makes Spelunky 2 content mods playable in networked co-op by running a
full lockstep simulation: the world is generated locally on every machine from a
shared adventure seed, and only inputs travel. That only works if every machine's Lua
behaves identically, and content mods are full of things that do not — `math.random`
drift, wall-clock timers, `pairs()` iteration order, per-run state that leaks across
runs.

The fix at the time of this fork was `src/shimInjector.lua`: **8,758 lines** (9,636
by the end) that prepend a ~870-line
payload into each content mod's `main.lua` on disk, with 27 archived payload versions
kept verbatim so an old block can be stripped by exact text on upgrade.

It works. It is also the thing to remove. Editing someone else's mod on disk is the
design flaw, and it drags along a marker/archive/strip protocol, a version treadmill,
and an entire class of bug that comes from being a guest inside another chunk — v25
shipped a callback registered above its own `local function`, which handed Playlunky a
`nil` and produced a boot-time Lua error plus a silently disabled fix.

## The approach

**Stop being a mod that patches other mods. Become the thing that runs them.**

Modded Online reads a content mod's Lua off disk and executes it inside *its own* Lua
state, against an `_ENV` it constructs — deterministic `math.random`, ordered `pairs`,
a simulation-derived clock. The mod never sees the real primitives, and no file on
disk is ever modified. This is the Forge/Fabric + Mixin arrangement: transform at
load, never touch the artifact.

The determinism logic survives — it is still needed, and the shim's version of it is
correct and field-proven. What dies is the *injection*.

## Verified facts this rests on

Each was checked against this install, not assumed:

1. **Playlunky gives every pack its own Lua state, with no channel between them.** No
   `package` table at all. Proven by a probe shipped in shim v23, which printed
   `package=false loaded=nil modules=0 keys=[] Sp25GameClass=true GameLib=true`.
   Non-`unsafe` mods have no `io` either, and `user_data` belongs to the script that
   wrote it. This is *why* injection was the only way in.
2. **Modded Online is `unsafe = true`** (`main.lua`), so it has real `io` and can read
   another pack's source.
3. **Asset-only packs work.** Five *enabled* packs — `Ralsei`, `HDGrass`, `Mooch`,
   `Better Neko Arc`, `fyi.awful-olmectm` — have no `main.lua` at all, just `Data/`.
4. **Playlunky mounts assets only for enabled packs.** `spelunky.log` shows mounts for
   exactly the nine enabled entries and none of the commented-out ones. This is the
   one real blocker: disabling a mod to stop its Lua also unmounts its assets.
5. **Spelunky 2.5 splits cleanly along that line:**
   - assets — `Data/`, `res/`, `soundbank/`, `shaders_mod.hlsl`
   - code — `main.lua`, `sp25debug1.lua`, `src/`
   - state — `save.dat`
6. **Playlunky does not serve a pack's PNGs to the game.** It converts them to `.DDS`
   into `Mods/Packs/.db/Mods/<pack>/` and mounts that *alongside* the pack — `.db\Mods\X`
   first, then `Mods/Packs\X`. For 2.5 that processed tree is **170 MB of `Data` and
   2.1 GB of `res`**, and `Data/Textures/border_main.png` reaches the game only as
   `.db/.../Data/Textures/border_main.DDS`.

   This is why Spike 2's first run changed world generation but no textures: `.lvl`
   files need no conversion and worked immediately, while the raw PNGs we junctioned in
   were catalogued (a 45 KB `mod.db` appeared for us) but never converted — and 2.5's
   own `.db`, where every converted texture already sits, is not mounted while 2.5 is
   disabled. **A hosted mod needs both trees linked, source and converted.**
7. **2.5 imports through `SafeImport({ path = "src.game" })`** (defined in
   `src/helpers.lua`), including root-level modules like `"sp25debug1"`. Emulating
   that one function is most of the module loader.

## Plan

Strangler pattern. `src/shimInjector.lua` stayed until the loader could carry a real
run; it was deleted at the end, not the start. **Done** -- see CHANGELOG 2.0.0-dev42.

**Spike 1 — does the module graph even load?** *(in progress)*
Load 2.5's `main.lua` and every module it imports into a sandbox, with all
registration APIs stubbed so nothing reaches the engine. Report: modules loaded,
callbacks it wanted, globals it read that we did not provide, first error and where.
This flushes out the loader-emulation gap in one sitting. `src/modHost.lua` is this.

**Spike 2 — assets without the mod's Lua.** *(PASSED)*
`tools/spike2.py`. The brief originally called for a separate assets-only twin pack.
Reading the API definitions 2.5 bundles says that is the wrong shape:

    spel2-part1.lua:685   "List files in directory relative to the script root"
    spel2-part1.lua:1472  "Loads a sound from disk relative to this script"

and 2.5 loads its atlases by relative path — `textureDef.texture_path =
"res/ATLASES/textures1.png"` (`src/theming/textures.lua:45,100`). If Overlunky resolves
those against **the calling script's** root, a mod hosted inside Modded Online resolves
them against *our* root, not its own. So the assets belong **inside the loader pack**,
not beside it — one pack, which also gets them mounted for free.

Two consequences worth carrying:

* That rule is documented for `list_dir` and `create_sound`. Whether `define_texture`
  follows it is an inference; booting the game is what settles it, and it is the single
  most load-bearing unknown left in this design.
* If it holds, **one hosted content mod at a time.** Two mods' asset trees would
  collide inside our single pack root (both may ship `res/ATLASES/textures1.png`), and
  namespacing them means rewriting the paths in their code — which is the thing this
  whole build exists to stop doing.

Junctions rather than copies: `res/` alone is 277 MB, `mklink /J` needs no elevation
(verified), and a junction tracks the real folder so a 2.5 update is picked up instead
of going stale. `shaders_mod.hlsl` is a single file, so it is copied and will go stale.

*Result, from two boots with 2.5 disabled and the loader pack enabled:* the first
linked only the source assets and changed **world generation but no art**; the second
also linked the converted `.db` tree and 2.5's textures appeared on the main menu. Both
halves of a hosted mod's assets now serve from our pack with the mod itself disabled,
which is what Spike 2 set out to prove.

Custom entities do not spawn, correctly — they are defined and placed by 2.5's Lua.
What is on screen is 2.5's art plus its 35 vanilla-named `.lvl` replacements, which
need no code; its 52 `sp25-*.lvl` custom-world files stay dormant because only its Lua
selects them. That line — assets yes, behaviour no — is exactly the boundary this spike
was drawn to find.

**Spike 3 — reach 1-1.** *(PASSED)*
Registrations live, gated on the `mo_host.on` flag file. From the log of the boot
that worked:

```
Playlunky :: Mod fyi.spelunky-25-2 registered as a script mod ...   (0 occurrences)
[fyi.modded-online-loader]: [ModdedOnline] mod host: LOADED
    | 633 modules, 633 chunks, 214 registrations, 8 unknown globals
```

Playlunky never loaded 2.5. Modded Online did, inside its own Lua state, and the game
came up with 2.5's worlds, art and **custom entities**. 633 modules rather than the
headless spike's 56, because in the real game `game:init()` runs `Hooks.runHooks`,
which pulls in every per-world hook module.

That also settles Spike 2's open question: the custom entities arrived with their
sprites, so `texture_path = "res/ATLASES/..."` did resolve against *our* pack root.
The assets-inside-the-loader-pack shape is correct, and the one-mod-at-a-time
constraint that follows from it is real.

Three globals surfaced that the headless run had not, and all three are the same
read-then-default idiom as the original five — `newItems.lua:105` is literally
`if Sp25FireproofManager ~= nil then`. Nothing missing.

**The mechanism is proven. What is not yet built is everything that made the shim
worth having** — see below.

## Where this actually stands

The loader runs a total conversion with nothing injected. It does **not** yet make it
deterministic: the sandbox currently hands the mod the raw `math.random`, the raw
`pairs` and the engine's own `get_frame`/`get_ms`. A networked run today would desync
exactly as it did before any shim existed.

In order:

1. **Port the determinism guarantees into `newSandbox`.** *(core done — `src/determinism.lua`)*
   Universal parts apply to **every** hosted mod: ordered `pairs`, a private
   generator, the simulated clock, the ON.FRAME remap and the per-hook PRNG anchor.
   Per-mod behaviour is now an **adapter** that feature-detects rather than an inline
   `if` for a mod somebody happened to have tested — a mod matching no adapter still
   gets the whole core.

   Two things changed shape in the move. The mod gets its **own** xorshift64\*
   generator rather than Lua's: hosting puts it in our state, where `math.randomseed`
   would reach the generator `netCore.lua:183` seeds from the wall clock. And ordered
   `pairs` is now **on by default** — the payload enabled it only for mods it had
   already watched desync, which is no help to a mod nobody has tested.

   **Still to port, both mod-specific and both behind real desyncs:**
   - the **2.5 adapter** — `resetGame` as a new-run equaliser and the world-state
     capture. These fixed the last two desyncs before this fork, so a networked run
     without them regresses to those.

     The **world mailbox** is no longer the shape of the answer. It smuggled four
     bytes through `state.arena.player_lives` because Playlunky gives two packs no
     channel between them — and hosting removed that barrier entirely: the mod's
     world counter is a value in its own module table, in our state, readable
     directly. The loader-side half was removed in dev44 rather than left looking
     like a working feature; it could not fire, because the only thing that ever
     wrote the PUB tag was the injected block.
   - the **liquid snapshot**, which the payload gated to run-plan/HD mods.
2. **A two-machine run.** Same seed, identical floors, no desync. Until that passes
   the loader is unproven for the only purpose it has.
3. **`save.dat`.** `ON.SAVE`/`ON.LOAD` fire for our script now, so a hosted mod's
   progress writes into our pack and its existing save is orphaned. Route it back.
4. ~~**Only then delete `shimInjector.lua`.**~~ **Done** (2.0.0-dev42), along with
   `optionSync.lua` and the world mailbox in dev44: both were halves of mechanisms
   whose other half lived in the injected block.
5. **Packaging.** Today this needs hand-run junctions, a `load_order.txt` edit and a
   flag file. For anyone but us it has to become something the mod does from its own
   menu — and the two-states-only rule (`tools/spike2.py`) has to be enforced there
   too, because mixing them mounts every asset twice and crashes the game on boot.

## What must not regress

The shipping mod took a long time to get right and every mechanism in it has a desync
in the logs behind it. Carry these into the sandbox, do not reinvent them:

- `math.random` seeded per floor from the run seed, and re-anchored every simulated
  frame — a draw taken off the simulated path (a render callback, a frame during a
  lockstep stall) shifts that machine's stream for the rest of the floor.
- **Ordered `pairs`.** Not cosmetic: iteration order changes how many times the shared
  PRNG is drawn, which changes the world. This is what desynced Randomizer 2.0.
- `get_frame` / `get_ms` derived from `state.time_total`, carrying elapsed time forward
  across a restart rather than jumping. Both failure directions have been seen: the HD
  mod's music faded for minutes one way and overlapped the other.
- The per-hook PRNG save / anchor / restore around generation callbacks.
- Callback ordering. In the shim this was fragile because the payload was a guest.
  Inside our own state we own registration order outright — that whole hazard class
  goes away, and it should not be recreated.

## Open questions

- **`save.dat`.** `ON.SAVE`/`ON.LOAD` fire per script, so a hosted mod's save handler
  would write into *our* pack. Needs routing back plus a migration, and divergent mod
  saves are already a known desync source (`packsave=` in the log header).
- **`meta.unsafe`.** 2.5 declares itself safe; hosted inside us it inherits our unsafe
  privileges. A real security downgrade — say so plainly in the UI.
- **Options UI.** `register_option_*` is per-script; a hosted mod's settings would
  appear under Modded Online's entry.
- **Error attribution.** Use `load(src, "@fyi.spelunky-25-2/src/game.lua")` so
  tracebacks name the mod's file. Better than today, but only if it is done.
- **Which Playlunky per-pack APIs are we not emulating?** Spike 1 answers this. Every
  gap found is also the precise thing worth requesting upstream.

## The alternative that is still better, if it is available

The single highest-leverage fix is not in this repo: **patch Playlunky itself** to give
every script state a deterministic environment behind a `deterministic_mode=1` ini
flag. Same logic as the shim, ~200 lines of C++ at `sol::state` creation, and it fixes
this for every mod and every user, forever. Factorio and Roblox both put determinism
in the loader for exactly this reason. This build is what you do if that PR is not an
option — it needs nobody's permission.

## Working here

Same toolchain as the parent:

```bash
py -m pytest tests/ -q
```

`luaparser` for the Lua, `lupa` to execute it against stubs. The house rule is that
every mechanism has a test that would have caught the bug it exists for.
