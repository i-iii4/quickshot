#!/usr/bin/env python3
"""Собрать и запустить один тестовый набор из test.sh по имени файла.

Нужен для быстрого цикла «упал — починил — прошёл» без полного прогона.
Список исходников берётся из соответствующего блока scripts/test.sh, поэтому
расхождения между быстрым прогоном и полным исключены.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))


def sources_for(test_file: str, extra: list[str]) -> list[str]:
    text = open(os.path.join(ROOT, 'scripts', 'test.sh')).read()
    blocks = [b for b in text.split('xcrun swiftc') if test_file in b]
    if not blocks:
        return extra
    block = blocks[0].split(' -o "')[0]
    return re.findall(r'(Sources/\S+\.swift|Tests/\S+\.swift)', block)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: run-one.py <TestFile.swift> [extra sources...]", file=sys.stderr)
        return 2
    os.chdir(ROOT)
    test_file = sys.argv[1]
    files = sources_for(test_file, sys.argv[1:])
    if not files:
        print(f"no build recipe for {test_file}", file=sys.stderr)
        return 2

    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
    arch = os.uname().machine
    out = f"/tmp/quickshot-one-{os.path.splitext(test_file)[0]}"
    lib = os.path.join(ROOT, 'NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a')
    cmd = ['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{arch}-apple-macos26.0',
           '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
           '-D', 'TESTING',
           '-framework', 'AppKit', '-framework', 'CoreGraphics', '-framework', 'QuartzCore',
           '-framework', 'ImageIO', '-framework', 'Vision',
           '-framework', 'UniformTypeIdentifiers', '-framework', 'Carbon',
           *files, lib, '-o', out]
    built = subprocess.run(cmd)
    if built.returncode:
        return built.returncode
    return subprocess.run([out]).returncode


if __name__ == '__main__':
    sys.exit(main())
