#!/usr/bin/env python3
"""Собрать и запустить CaseGeometrySnapshotTool: рендер шкатулки целиком в PNG.

Подложка, карточки и панель вместе: панель в изоляции не показывает
геометрию шкатулки. См. CLAUDE.md.
"""
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
os.chdir(ROOT)

text = open('scripts/test.sh').read()
block = [b for b in text.split('xcrun swiftc') if 'Tests/NativeSurfaceBehaviorTests.swift' in b][0].split(' -o "')[0]
files = [f for f in re.findall(r'(Sources/\S+\.swift|Tests/\S+\.swift)', block)
         if 'NativeSurfaceBehaviorTests' not in f]
# Геометрия шкатулки живёт в этих трёх файлах; менеджер тянуть незачем.
for extra in ['Sources/Theme.swift', 'Sources/TrayScrollModel.swift',
              'Sources/ThumbnailLayout.swift', 'Sources/TrayPosition.swift',
              'Sources/TrayCaseView.swift']:
    if extra not in files:
        files.append(extra)
files.append('Tests/CaseGeometrySnapshotTool.swift')

# Разметка живёт в Zig-библиотеке: без пересборки снимок показывает
# ПРОШЛУЮ вёрстку, и правка выглядит бесследной. Ловушка стоила прогона.
zig = os.environ.get('QUICKSHOT_ZIG') or shutil.which('zig') \
    or os.path.expanduser('~/.native/toolchains/zig-0.16.0/zig')
env = dict(os.environ, PATH=os.path.dirname(zig) + os.pathsep + os.environ['PATH'])
subprocess.run([zig, 'build', 'lib'], cwd='NativeQuickShotUI', env=env, check=True)

sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
out = '/tmp/quickshot-case-geometry-snapshot'
cmd = ['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{os.uname().machine}-apple-macos26.0',
       '-swift-version', '6', '-strict-concurrency=complete',
       '-D', 'TESTING', *files, 'NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a',
       '-o', out]
subprocess.run(cmd, check=True)
sys.exit(subprocess.run([out, *sys.argv[1:]]).returncode)
