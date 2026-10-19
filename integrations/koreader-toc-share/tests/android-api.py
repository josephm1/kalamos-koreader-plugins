#!/usr/bin/env python3
"""Check sender JNI descriptors against an official SDK/JDK javap -s listing.

Generate the listing with:
javap -s -classpath "$ANDROID_HOME/platforms/android-36/android.jar" \
  android.content.Intent android.content.ClipData 'android.content.ClipData$Item' android.content.Context \
  java.lang.ClassLoader java.io.File > android-signatures.txt
"""
import argparse
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('listing', type=Path)
parser.add_argument('--plugin', type=Path, default=root / 'tocshare.koplugin' if (root / 'tocshare.koplugin').is_dir() else root)
args = parser.parse_args()
methods = {}
method = None
for line in args.listing.read_text().splitlines():
    declaration = re.search(r'\b([\w.$]+)\([^;]*\)', line)
    if declaration:
        method = declaration.group(1)
    descriptor = re.search(r'descriptor: (\S+)', line)
    if descriptor and method:
        methods.setdefault(method, set()).add(descriptor.group(1))

source = (args.plugin / 'tocshare_android.lua').read_text()
checks = re.findall(r'"([A-Za-z][A-Za-z0-9_]*)",\s*"(\([^"\n]*\)[^"\n]*)"', source)
checked = 0
for name, signature in checks:
    if name == 'getUriForFile':  # AndroidX method, outside the platform android.jar.
        continue
    assert signature in methods.get(name, set()), f'{name}: {signature} does not match the SDK/JDK'
    checked += 1
for name, signature in [('android.content.Intent', '(Ljava/lang/String;)V'),
                        ('java.io.File', '(Ljava/lang/String;)V'),
                        ('android.content.ClipData$Item', '(Landroid/net/Uri;)V')]:
    assert signature in methods.get(name, set()), f'{name} constructor does not match the SDK/JDK'
    assert '"' + signature + '"' in source
    checked += 1
assert checked >= 17, 'Incomplete sender/API listing coverage'
print(f'Passed {checked} Android framework/JDK JNI descriptor checks')
