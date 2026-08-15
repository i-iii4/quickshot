#!/usr/bin/env python3
"""Собрать и запустить CanvasSnapshotTool: рендер холста в PNG для глаз."""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
os.chdir(ROOT)

text = open('scripts/test.sh').read()
block = [b for b in text.split('xcrun swiftc') if 'Tests/EditorDrawingTests.swift' in b][0].split(' -o "')[0]
files = [f for f in re.findall(r'(Sources/\S+\.swift|Tests/\S+\.swift)', block)
         if 'EditorDrawingTests' not in f]
files.append('Tests/CanvasSnapshotTool.swift')

sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
out = '/tmp/quickshot-canvas-snapshot'
cmd = ['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{os.uname().machine}-apple-macos26.0',
       '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
       '-D', 'TESTING',
       '-framework', 'AppKit', '-framework', 'CoreGraphics', '-framework', 'ImageIO',
       '-framework', 'UniformTypeIdentifiers', '-framework', 'QuartzCore',
       *files, os.path.join(ROOT, 'NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a'),
       '-o', out]
built = subprocess.run(cmd)
if built.returncode:
    sys.exit(built.returncode)
target = sys.argv[1] if len(sys.argv) > 1 else '/tmp'
sys.exit(subprocess.run([out, target]).returncode)
