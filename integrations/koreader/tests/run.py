#!/usr/bin/env python3
"""Run handwriting persistence/lifecycle tests in fresh Lua states."""
import ctypes
import ctypes.util
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
plugin = root / 'kalamos.koplugin' if (root / 'kalamos.koplugin').is_dir() else root
tests = sorted((root / 'tests').glob('*.lua'))
interpreter = next((shutil.which(name) for name in ('luajit', 'lua5.4', 'lua') if shutil.which(name)), None)
if interpreter:
    for test in tests:
        subprocess.run([interpreter, '-e', f'package.path=[==[{plugin}/?.lua;]==] .. package.path; dofile([==[{test}]==])'], check=True)
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
    for test in tests:
        source = f'package.path=[==[{plugin}/?.lua;]==] .. package.path; dofile([==[{test}]==])'.encode()
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
