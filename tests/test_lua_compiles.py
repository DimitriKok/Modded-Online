"""Every Lua file must compile under a real Lua, not merely parse.

`luaparser` is more permissive than Lua itself. Twice in one session it accepted a
string literal containing a raw newline -- an escape that collapsed on its way through
a shell heredoc -- and the file only failed when lupa, or the game, tried to load it.
A parse check that a broken file can pass is not a check.

Run:  python -m pytest tests/test_lua_compiles.py -q
"""

from __future__ import annotations

import pathlib

import lupa
import pytest

PACK = pathlib.Path(__file__).resolve().parent.parent
LUA_FILES = sorted([PACK / "main.lua"] + list((PACK / "src").glob("*.lua")))

# `load` returns the chunk on success and nil + a message on failure, so the arity
# differs between the two. Normalising it in Lua keeps the assertion readable.
COMPILE = """
function compileError(src, name)
    local chunk, err = load(src, name)
    if chunk ~= nil then return "" end
    return tostring(err)
end
"""


@pytest.mark.parametrize("path", LUA_FILES, ids=lambda p: p.name)
def test_the_file_compiles(path):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(COMPILE)
    err = str(rt.eval("compileError")(path.read_text(encoding="utf-8"), "@" + path.name))
    assert err == "", f"{path.name} does not compile: {err}"
