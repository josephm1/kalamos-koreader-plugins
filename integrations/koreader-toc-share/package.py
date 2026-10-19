#!/usr/bin/env python3
"""Test and package only the independent plugin, with a reproducible ZIP and SHA-256."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
source = root / 'tocshare.koplugin' if (root / 'tocshare.koplugin').is_dir() else root
default_output = root.parents[1] / 'artifacts/koreader-toc-share-0.6.0.zip' if source != root else root / 'dist/koreader-toc-share-0.6.0.zip'
parser.add_argument('--output', type=Path, default=default_output)
parser.add_argument('--koreader-runtime', type=Path, help='also run real EPUB-engine fixtures')
parser.add_argument('--android-signatures', type=Path, help='official SDK/JDK javap -s listing for JNI contract checks')
args = parser.parse_args()
subprocess.run([sys.executable, str(root / 'tests/run.py')], check=True)
subprocess.run([sys.executable, str(root / 'tests/run.py'), 'metadata.lua'], check=True)
subprocess.run([sys.executable, str(root / 'tests/run.py'), 'book.lua'], check=True)
if args.android_signatures:
    subprocess.run([sys.executable, str(root / 'tests/android-api.py'), str(args.android_signatures), '--plugin', str(source)], check=True)
if args.koreader_runtime:
    subprocess.run([sys.executable, str(root / 'tests/engine.py'), str(args.koreader_runtime), '--plugin', str(source)], check=True)
output = args.output.resolve()
output.parent.mkdir(parents=True, exist_ok=True)
files = ('_meta.lua', 'main.lua', 'tocshare_range.lua', 'tocshare_book.lua', 'tocshare_metadata.lua', 'tocshare_android.lua', 'README.md', 'LICENSE', 'NOTICE.md')
temporary = output.with_suffix('.zip.tmp')
try:
    with ZipFile(temporary, 'w', compression=ZIP_DEFLATED) as archive:
        for name in sorted(files):
            item = ZipInfo('tocshare.koplugin/' + name, date_time=(2026, 10, 15, 0, 0, 0))
            item.compress_type = ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, (source / name).read_bytes())
    with ZipFile(temporary) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(files)
        for name in files:
            assert archive.read('tocshare.koplugin/' + name) == (source / name).read_bytes()
    temporary.replace(output)
finally:
    temporary.unlink(missing_ok=True)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix('.zip.sha256').write_text(f'{digest}  {output.name}\n')
print(f'Built {output} ({output.stat().st_size} bytes)\nSHA-256: {digest}')
