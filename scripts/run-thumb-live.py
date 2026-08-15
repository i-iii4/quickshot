#!/usr/bin/env python3
"""Извлекает из test.sh блок сборки ThumbnailWindowLiveClickTests и запускает его."""
import os, re, subprocess, sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
os.chdir(root)
text = open('scripts/test.sh').read()
blocks = text.split('xcrun swiftc')
block = next(b for b in blocks if 'ThumbnailWindowLiveClickTests' in b)
block = block.split('-o "$THUMBNAIL_LIVE_OUT"')[0]
files = re.findall(r'(Sources/\S+\.swift|Tests/\S+\.swift)', block)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
arch = os.uname().machine
out = '/tmp/quickshot-thumb-live-test'
lib = os.path.join(root, 'NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a')
cmd = ['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{arch}-apple-macos26.0',
       '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
       '-D', 'TESTING', '-framework', 'AppKit', '-framework', 'CoreGraphics',
       '-framework', 'QuartzCore', '-framework', 'ImageIO',
       '-framework', 'Vision', '-framework', 'UniformTypeIdentifiers',
       *files, lib, '-o', out]
r = subprocess.run(cmd)
if r.returncode:
    sys.exit(r.returncode)
sys.exit(subprocess.run([out]).returncode)
