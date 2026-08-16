#!/usr/bin/env python3
"""Собрать и запустить TrayStackSnapshotTool: рендер стопок трея в PNG."""
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
os.chdir(ROOT)

files = ['Sources/TrayScrollModel.swift', 'Sources/ThumbnailLayout.swift',
         'Tests/TrayStackSnapshotTool.swift']
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
out = '/tmp/quickshot-tray-snapshot'
cmd = ['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{os.uname().machine}-apple-macos26.0',
       '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
       '-framework', 'AppKit', '-framework', 'CoreGraphics', '-framework', 'ImageIO',
       '-framework', 'UniformTypeIdentifiers',
       *files, '-o', out]
built = subprocess.run(cmd)
if built.returncode:
    sys.exit(built.returncode)
sys.exit(subprocess.run([out, *sys.argv[1:]]).returncode)
