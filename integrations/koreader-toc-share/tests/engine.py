#!/usr/bin/env python3
"""Run original EPUB fixtures through an existing official KOReader Linux runtime."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('runtime', type=Path, help='directory containing KOReader luajit, setupkoenv.lua, fonts and libs')
parser.add_argument('--plugin', type=Path, default=root / 'tocshare.koplugin' if (root / 'tocshare.koplugin').is_dir() else root)
args = parser.parse_args()
runtime = args.runtime.resolve()
if not (runtime / 'setupkoenv.lua').is_file() or not (runtime / 'luajit').is_file():
    parser.error('Expected an extracted KOReader Linux runtime directory.')
with tempfile.TemporaryDirectory(prefix='tocshare-fixtures-') as directory:
    subprocess.run([sys.executable, str(root / 'tests/make-fixtures.py'), directory], check=True)
    subprocess.run([str(runtime / 'luajit'), str(root / 'tests/engine.lua'),
                    str(args.plugin.resolve()), directory], cwd=runtime, env={**os.environ, "KO_HOME": str(Path(directory) / "settings")}, check=True)
