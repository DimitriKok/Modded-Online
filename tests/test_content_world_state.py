"""Tests the read-only handle on Spelunky 2.5's own world state.

2.5 advances its world only when a door is taken and resets it to Dwelling in
`resetGame()`, and it carries state across runs within a game launch (the known
"textures are wrong after exiting to the title and starting another run" bug). So
two machines whose 2.5 history differs generate different worlds from the same
seed — a rejoiner is one case of that, and a player who played singleplayer before
joining is another. None of it is visible from outside 2.5's Lua state.

Getting at it took three attempts, and the first two were built on a premise that
does not hold in Playlunky:

  * v22 read one hard-coded `package.loaded` key, found nothing, and said nothing
  * v23 searched `package.loaded` by shape — and reported, out loud, that there is
    no `package` table at all (`package=false loaded=nil modules=0`)
  * v24 uses what that probe DID confirm: `Sp25GameClass` is a global, every
    instance shares it as `__index`, so wrapping a per-floor method on the class
    yields `self` — the live instance — without editing the mod
  * v25 acts on it: on the new-run signal every machine agrees on, it calls 2.5's
    OWN resetGame(), because 2.5 builds one game object per launch and nothing
    resets it for a machine that Modded Online warps into a run

Run:  python -m pytest tests/test_content_world_state.py -q
"""

from __future__ import annotations

import pathlib

import lupa

PACK = pathlib.Path(__file__).resolve().parent.parent
INJECTOR = (PACK / "src" / "shimInjector.lua").read_text(encoding="utf-8")

NL = chr(10)


def accessor() -> str:
    """The shipped capture/report block, verbatim, with its locals exposed."""
    start = 'local SHIM = "-- " .. MARKER .. [[ auto-added by Modded Online; safe to delete this block.\n'
    i = INJECTOR.index(start)
    j = INJECTOR.index("\n]]\n", i)
    body = INJECTOR[i + len(start):j]
    a = body.index("    local moWorldObj = nil")
    b = body.index("    MO_CONTENT_WORLD = moContentWorldState")
    return body[a:b] + NL.join([
        "", "hook = moHookWorldCapture", "probe = moContentWorldState",
        "reportMiss = moReportWorldSearch", "resetWorld = moResetContentWorld", "",
    ])


def lua(with_class: bool = True):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("_G = _G or {}; printed = {}; function print(s) printed[#printed+1] = s end")
    rt.execute(accessor())
    if with_class:
        # mirror 2.5: a global class, instances sharing it as __index
        rt.execute("""
Sp25GameClass = { sp25World = 0, spelunky2World = 0 }
Sp25GameClass.__index = Sp25GameClass
newLevelHooksRan, unhooked, entityDbRestored = 0, 0, 0
DWELLING = 1
function Sp25GameClass:newLevelHooks() newLevelHooksRan = newLevelHooksRan + 1 end
function Sp25GameClass:onSp25WorldTransition(w)
    if self.sp25World ~= w then self.spelunky2World = self.spelunky2World + 1 end
    self.sp25World = w
end
-- the shape of 2.5's own reset: drop every hook, put the entity db back, world one
function Sp25GameClass:resetGame()
    unhooked = unhooked + 1
    entityDbRestored = entityDbRestored + 1
    self.sp25World, self.spelunky2World = 0, 0
    self.transitionFromSp25World, self.transitionToSp25World = nil, nil
    self:onSp25WorldTransition(DWELLING)
end
function construct(sp25, s2)
    local i = setmetatable({}, Sp25GameClass)
    i.sp25World, i.spelunky2World = sp25, s2
    return i
end
""")
    return rt


def test_nothing_is_known_before_a_floor_generates():
    rt = lua()
    rt.eval("hook")()
    assert rt.eval("probe()") is None


def test_wrapping_the_class_captures_the_live_instance():
    rt = lua()
    rt.eval("hook")()
    rt.execute("game = construct(4, 3); game:newLevelHooks()")
    snap = rt.eval("probe()")
    assert snap is not None, "the instance was not captured from the class method"
    assert int(snap["sp25"]) == 4 and int(snap["s2"]) == 3
    assert "newLevelHooks" in str(snap["where"])


def test_the_wrapped_method_still_runs():
    """Capturing must not swallow the mod's own per-floor work."""
    rt = lua()
    rt.eval("hook")()
    rt.execute("game = construct(1, 1); game:newLevelHooks(); game:newLevelHooks()")
    assert int(rt.eval("newLevelHooksRan")) == 2


def test_hooking_twice_does_not_stack_wrappers():
    rt = lua()
    for _ in range(4):
        rt.eval("hook")()
    rt.execute("game = construct(2, 2); game:newLevelHooks()")
    assert int(rt.eval("newLevelHooksRan")) == 1
    assert int(rt.eval("probe()")["sp25"]) == 2


def test_it_tracks_the_instance_as_the_run_progresses():
    rt = lua()
    rt.eval("hook")()
    rt.execute("game = construct(1, 0); game:newLevelHooks()")
    assert int(rt.eval("probe()")["s2"]) == 0
    rt.execute("game.sp25World = 4; game.spelunky2World = 3; game:newLevelHooks()")
    snap = rt.eval("probe()")
    assert int(snap["sp25"]) == 4 and int(snap["s2"]) == 3


def test_the_divergence_it_exists_to_show():
    """A fresh machine and one carrying a previous run's state, on the same floor."""
    fresh, stale = lua(), lua()
    for rt, (sp25, s2) in ((fresh, (4, 3)), (stale, (1, 0))):
        rt.eval("hook")()
        rt.execute(f"game = construct({sp25}, {s2}); game:newLevelHooks()")
    assert int(fresh.eval("probe()")["sp25"]) != int(stale.eval("probe()")["sp25"])


def test_a_mod_without_the_class_is_left_alone():
    rt = lua(with_class=False)
    rt.eval("hook")()
    assert rt.eval("probe()") is None


def test_a_miss_is_reported_out_loud_exactly_once():
    rt = lua(with_class=False)
    rt.eval("hook")()
    rt.eval("reportMiss")()
    rt.eval("reportMiss")()
    out = list(rt.eval("printed").values())
    assert len(out) == 1, "the miss must be reported once, not per floor"
    assert "NOT FOUND" in out[0]


def test_a_carried_over_world_is_reset_on_a_new_run():
    """The user's case: played singleplayer, went to the title, joined a room."""
    rt = lua()
    rt.eval("hook")()
    rt.execute("game = construct(1, 1); game:newLevelHooks()")          # a run happens
    rt.execute("game.sp25World = 4; game.spelunky2World = 3; game:newLevelHooks()")
    rt.eval("resetWorld")(0x1EAF9223)                                    # new run signal
    snap = rt.eval("probe()")
    assert int(snap["s2"]) == 1, "2.5 still thinks it is past world one"
    assert int(snap["sp25"]) == 1, "the route was not put back to Dwelling"
    assert int(rt.eval("unhooked")) == 1 and int(rt.eval("entityDbRestored")) == 1
    assert int(snap["resets"]) == 1


def test_it_equalises_two_machines_with_different_histories():
    """The property that matters: same state afterwards, whatever came before."""
    booted, played = lua(), lua()
    booted.eval("hook")()
    booted.execute("game = construct(1, 1); game:newLevelHooks()")
    played.eval("hook")()
    played.execute("game = construct(4, 3); game:newLevelHooks()")
    before = (int(booted.eval("probe()")["s2"]), int(played.eval("probe()")["s2"]))
    assert before[0] != before[1], "the fixture does not reproduce the divergence"
    for rt in (booted, played):
        rt.eval("resetWorld")(0x1EAF9223)                                # same signal
    a, b = booted.eval("probe()"), played.eval("probe()")
    assert (int(a["sp25"]), int(a["s2"])) == (int(b["sp25"]), int(b["s2"]))


def test_the_reset_is_reported_with_what_was_carried():
    rt = lua()
    rt.eval("hook")()
    rt.execute("game = construct(4, 3); game:newLevelHooks()")
    rt.eval("resetWorld")(0x1EAF9223)
    out = list(rt.eval("printed").values())
    assert len(out) == 1
    assert "1EAF9223" in out[0], "the run it fired for is not identifiable in the log"
    assert "resetGame" in out[0] and "carried s2world=3" in out[0]


def test_nothing_captured_means_nothing_touched():
    rt = lua(with_class=False)
    rt.eval("hook")()
    rt.eval("resetWorld")(1)
    assert int(rt.eval("unhooked or 0")) == 0   # no class fixture, no counters
    assert rt.eval("probe()") is None


def test_a_mod_without_the_reset_is_left_alone():
    rt = lua()
    rt.eval("hook")()
    rt.execute("Sp25GameClass.resetGame = nil; game = construct(4, 3); game:newLevelHooks()")
    rt.eval("resetWorld")(1)
    snap = rt.eval("probe()")
    assert int(snap["sp25"]) == 4 and int(snap["resets"]) == 0


def test_a_reset_that_raises_leaves_the_run_playable():
    rt = lua()
    rt.eval("hook")()
    rt.execute("""
Sp25GameClass.resetGame = function() error("boom") end
game = construct(4, 3); game:newLevelHooks()
""")
    rt.eval("resetWorld")(1)                       # must not propagate
    assert int(rt.eval("probe()")["resets"]) == 0
    out = list(rt.eval("printed").values())
    assert len(out) == 1 and "failed" in out[0], "a failed reset must say so"


def test_it_fires_on_the_signal_the_other_two_repairs_use():
    """Keyed to the adventure seed change, which every machine sees on one frame.

    level_order and POSTTILE_STARTBOOL are the same bug in two other mods, and that
    branch is the field-proven place for it — not a level_count or world_next test,
    which a leaked run does not reliably reset.
    """
    live = INJECTOR[INJECTOR.index('local SHIM = "-- " .. MARKER .. [['):]
    live = live[:live.index(NL + "]]" + NL)]
    i = live.index("if moLastRunSeed ~= nil and moLastRunSeed ~= first then")
    branch = live[i:live.index("moLastRunSeed = first", i)]
    assert "level_order = {}" in branch
    assert "POSTTILE_STARTBOOL = false" in branch
    assert "moResetContentWorld(first)" in branch


def test_the_route_is_only_ever_written_from_another_machines_value():
    """The rule that replaced "never write it".

    v22-v26 refused to touch 2.5's route at all, because picking an sp25 world for an
    engine world/theme is a guess -- its custom worlds do not map one-to-one. v27
    writes it, but only with the value the machine that walked through the door sent
    (see test_world_mailbox), and never by inventing a transition.
    """
    src = accessor()
    assert "g:onSp25WorldTransition(" not in src, "the shim invents a transition"

    # every write to the route sits inside the adopt branch, nowhere else
    i = src.index("if math.floor(m[1]) == MO_BOX_REQ then")
    branch = src[i:src.index("local idx = moWorldIdx[g.sp25World]", i)]
    for write in ("g.sp25World =", "g.spelunky2World ="):
        assert src.count(write) == 1, f"{write} appears outside the adopt branch"
        assert write in branch

    # and the reset path still goes through the mod's own method
    reset = src[src.index("local function moResetContentWorld"):
                src.index("-- ---------------------------------------------------------- world mailbox")]
    assert "g:resetGame()" in reset
    for write in ("g.sp25World =", "g.spelunky2World ="):
        assert write not in reset
