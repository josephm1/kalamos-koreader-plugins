#!/usr/bin/env python3
"""Run plugin Lua tests using LuaJIT/Lua or the host Lua 5.4 shared library."""
import ctypes
import ctypes.util
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
plugin = root / 'tocshare.koplugin' if (root / 'tocshare.koplugin').is_dir() else root
test = root / 'tests' / (sys.argv[1] if len(sys.argv) > 1 else 'unit.lua')
interpreter = next((shutil.which(name) for name in ('luajit', 'lua5.4', 'lua') if shutil.which(name)), None)
if interpreter:
    subprocess.run([interpreter, str(test), str(plugin)], check=True)
else:
    library = ctypes.util.find_library('lua-5.4') or ctypes.util.find_library('lua5.4')
    if not library:
        raise SystemExit('Install LuaJIT or Lua 5.4 to run tests.')
    lua = ctypes.CDLL(library)
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_void_p]
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lua.lua_tolstring.restype = ctypes.c_char_p
    lua.lua_close.argtypes = [ctypes.c_void_p]
    # Lua long strings preserve paths without shell interpolation.
    source = f'arg={{[1]=[==[{plugin}]==]}}; dofile([==[{test}]==])'.encode()
    state = lua.luaL_newstate()
    lua.luaL_openlibs(state)
    try:
        status = lua.luaL_loadstring(state, source)
        if status == 0:
            status = lua.lua_pcallk(state, 0, -1, 0, 0, None)
        if status:
            raise SystemExit(lua.lua_tolstring(state, -1, None).decode())
    finally:
        lua.lua_close(state)
