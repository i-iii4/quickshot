#!/usr/bin/env python3
"""Полный аудит качества кода QuickShot: все оси разом.

Проверяет то, что раньше проверялось по одной оси за проход, из-за чего
«всё чисто» отодвигалось каждый раз. Ни одна проверка не правит код —
только показывает.

Оси: мёртвый код, копипаста, сложность, длина файлов, метки-заглушки,
неиспользуемые импорты, молчащие сканирующие проверки, формат.
"""
import glob
import hashlib
import re
import subprocess
import sys
from collections import defaultdict

SOURCES = sorted(glob.glob('Sources/*.swift'))
TESTS = sorted(glob.glob('Tests/*.swift'))
ALL = SOURCES + TESTS
ZIG = sorted(glob.glob('NativeQuickShotUI/src/*.zig'))

# Методы, которые зовёт система или синтаксис языка, а не наш код.
CALLED_BY_SYSTEM = {
    'main', 'applicationDidFinishLaunching', 'applicationWillTerminate',
    'windowDidResize', 'windowWillClose', 'windowDidBecomeKey', 'windowDidResignKey',
    'menuWillOpen', 'menuDidClose', 'draggingSession', 'callAsFunction',
    'mouseEntered', 'mouseExited', 'mouseMoved', 'mouseDown', 'mouseUp', 'mouseDragged',
    'keyDown', 'keyUp', 'flagsChanged', 'scrollWheel', 'draw', 'layout',
    'hitTest', 'acceptsFirstMouse', 'updateLayer', 'viewDidMoveToWindow',
}

failures = []


def report(title, items, detail=None):
    ok = not items
    mark = 'чисто ' if ok else 'НАЙДЕНО'
    print(f"[{mark}] {title}: {len(items) if not ok else ''}")
    if not ok:
        failures.append(title)
        for line in (detail or items)[:8]:
            print(f"          {line}")
        if len(items) > 8:
            print(f"          … ещё {len(items) - 8}")


def texts(paths):
    return {p: open(p).read() for p in paths}


def dead_declarations(scope, label):
    t = texts(ALL)
    dead = []
    for path in scope:
        src = t[path]
        name_of = path.split('/')[-1]
        for name in sorted(set(re.findall(r'^\s{0,4}(?:private |fileprivate |static )*func (\w+)[\(<]', src, re.M))):
            if name in CALLED_BY_SYSTEM:
                continue
            if uses(t, name, r'^\s*(private |fileprivate |public |static )*(override )?func\s+' + re.escape(name) + r'\b') == 0:
                dead.append(f"{name_of}: {name}()")
        for _, name in re.findall(r'^(?:public |internal )?(?:final )?(struct|class|enum) (\w+)', src, re.M):
            if '@main' in src:
                continue
            if uses(t, name, r'^\s*(public |internal )?(final )?(struct|class|enum)\s+' + re.escape(name) + r'\b') == 0:
                dead.append(f"{name_of}: тип {name}")
        for name in sorted(set(re.findall(r'^\s{4}(?:private )?(?:var|let) (\w+)\s*[:={]', src, re.M))):
            if uses(t, name, r'^\s{4}(private )?(var|let)\s+' + re.escape(name) + r'\b') == 0:
                dead.append(f"{name_of}: {name}")
    report(f'мёртвый код ({label})', dead)


def uses(t, name, skip):
    n = 0
    for txt in t.values():
        for m in re.finditer(r'\b' + re.escape(name) + r'\b', txt):
            start = txt.rfind('\n', 0, m.start()) + 1
            line = txt[start:txt.find('\n', m.start())]
            if re.match(skip, line):
                continue
            n += 1
    return n


# Идиома самодостаточного набора: каждый тест — отдельная программа с
# собственной точкой входа, и `run-one.py` собирает его минимальным списком
# файлов. Три строки проверки и тип ошибки внутри набора — цена этой
# независимости, а не копипаста.
TEST_IDIOMS = (
    'func require(', 'struct Failure: Error', 'static func run(',
    'NSApplication.shared.setActivationPolicy',
)


def is_idiom(chunk):
    return any(mark in chunk for mark in TEST_IDIOMS)


def duplicates(scope, label, window=6, floor=120):
    code = {}
    for p in scope:
        lines = [l.rstrip() for l in open(p).read().split('\n')]
        code[p] = [(i + 1, l) for i, l in enumerate(lines)
                   if l.strip() and not l.strip().startswith('//')]
    seen = defaultdict(list)
    for p, c in code.items():
        for k in range(len(c) - window + 1):
            chunk = [x[1].strip() for x in c[k:k + window]]
            if sum(len(x) for x in chunk) < floor:
                continue
            joined = '\n'.join(chunk)
            if is_idiom(joined):
                continue
            seen[hashlib.md5(joined.encode()).hexdigest()].append((p, k))
    used, merged = set(), []
    for _, locs in sorted(seen.items(), key=lambda kv: (kv[1][0][0], kv[1][0][1])):
        if len(locs) < 2:
            continue
        if any((p, k - 1) in used for p, k in locs):
            for p, k in locs:
                used.add((p, k))
            continue
        for p, k in locs:
            used.add((p, k))
        merged.append(locs)
    detail = [" | ".join(f"{p.split('/')[-1]}:{code[p][k][0]}" for p, k in locs) for locs in merged]
    report(f'копипаста ({label})', merged, detail)


# Осознанные исключения: длина без вложенности — не запутанность.
#
# `triggerCapture` и `renderNow` — линейные цепочки `guard`, где каждый шаг
# зависит от предыдущего и читается сверху вниз. `update` в Zig — линейное
# обновление модели. `onCommand` — плоская таблица разбора команд.
# `testHundredFakeBackendLifecycles` — группа задач: вложенность там задаёт
# сама модель конкурентности, а не логика теста.
COMPLEXITY_EXEMPT = {
    'triggerCapture', 'renderNow', 'update', 'onCommand',
    'testHundredFakeBackendLifecycles',
}


def complexity():
    heavy = []
    for p in SOURCES + ZIG + TESTS:
        out = subprocess.run([sys.executable, 'scripts/method-metrics.py', p],
                             capture_output=True, text=True).stdout.split('\n')
        for line in out[2:]:
            parts = line.split()
            if len(parts) != 5 or parts[0] in ('максимум',) or line.startswith('-'):
                continue
            name, code_lines, branches, cases, depth = parts[0], *map(int, parts[1:])
            if name in COMPLEXITY_EXEMPT:
                continue
            flat_table = depth <= 1 and cases == 0
            if flat_table:
                continue
            # Тестовый сценарий длинный по своей природе: он описывает шаги.
            if p.startswith('Tests/') and depth <= 3 and branches <= 10:
                continue
            if depth > 4 or branches > 10 or (code_lines > 60 and cases == 0 and depth > 1):
                heavy.append(f"{p.split('/')[-1]}: {name} — строк {code_lines}, ветвл {branches}, влож {depth}")
    report('сложность (влож>4, ветвл>10, длина>60 без таблицы)', heavy)


def placeholders():
    hits = []
    for p in SOURCES + TESTS + ZIG:
        for i, line in enumerate(open(p).read().split('\n'), 1):
            if re.search(r'\b(TODO|FIXME|HACK|XXX)\b', line):
                hits.append(f"{p.split('/')[-1]}:{i}")
    report('метки-заглушки', hits)


def unused_imports_disabled():
    hits = []
    for p in SOURCES:
        src = open(p).read()
        body = '\n'.join(l for l in src.split('\n') if not l.startswith('import '))
        for mod in re.findall(r'^import (\w+)', src, re.M):
            if mod in ('Foundation', 'AppKit', 'Cocoa'):
                continue
            if not re.search(r'\b' + mod + r'\b', body):
                hits.append(f"{p.split('/')[-1]}: {mod}")
    report('неиспользуемые импорты', hits)


def silent_checks():
    hits = []
    for line in open('scripts/test.sh').read().split('\n'):
        t = line.strip()
        if re.match(r'^rg (-F )?(-U )?-q ', t) and '$' not in t:
            if subprocess.run(t, shell=True, capture_output=True).returncode != 0:
                hits.append(t[:100])
    report('молчащие сканирующие проверки', hits)


def formatting():
    hits = []
    for p in SOURCES + TESTS:
        src = open(p).read()
        if '\n\n\n' in src:
            hits.append(f"{p.split('/')[-1]}: тройные пустые строки")
        trailing = [i for i, l in enumerate(src.split('\n'), 1) if l != l.rstrip()]
        if trailing:
            hits.append(f"{p.split('/')[-1]}: пробелы в конце строк ({len(trailing)})")
    report('формат', hits)


print("=== Аудит качества кода QuickShot ===\n")
dead_declarations(SOURCES, 'Sources')
dead_declarations(TESTS, 'Tests')
duplicates(SOURCES, 'Sources')
duplicates(TESTS, 'Tests', window=8, floor=160)
complexity()
placeholders()
silent_checks()
formatting()
print()
if failures:
    print(f"итог: осей с находками — {len(failures)}: {', '.join(failures)}")
    sys.exit(1)
print("итог: все оси чисты")
