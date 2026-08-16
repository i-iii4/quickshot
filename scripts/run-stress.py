#!/usr/bin/env python3
"""Собрать и запустить CaptureStressTool: числа по серии снимков подряд."""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
os.chdir(ROOT)

text = open('scripts/test.sh').read()
block = [b for b in text.split('xcrun swiftc') if 'Tests/ThumbnailWindowLiveClickTests.swift' in b][0]
files = re.findall(r'(Sources/\S+\.swift)', block.split(' -o "')[0])
extra = ['Sources/CaptureTypes.swift', 'Sources/DirectScreenSnapshotProvider.swift',
         'Sources/CoordinateMath.swift']
for name in extra:
    if name not in files and os.path.exists(name):
        files.append(name)
files.append('Tests/CaptureStressTool.swift')

sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
out = '/tmp/quickshot-stress'
cmd = ['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{os.uname().machine}-apple-macos26.0',
       '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
       '-D', 'TESTING', '-O',
       '-framework', 'AppKit', '-framework', 'CoreGraphics', '-framework', 'QuartzCore',
       '-framework', 'ImageIO', '-framework', 'Vision', '-framework', 'UniformTypeIdentifiers',
       *files, os.path.join(ROOT, 'NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a'),
       '-o', out]
built = subprocess.run(cmd)
if built.returncode:
    sys.exit(built.returncode)
sys.exit(subprocess.run([out, *sys.argv[1:]]).returncode)
