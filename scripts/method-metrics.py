#!/usr/bin/env python3
"""Метрики методов Swift-файла: строк кода, ветвлений, вложенности.

Строки кода — без пустых и без строк-комментариев.

Ветвления — `if`, `guard`, `while`, `for`. `case` СЧИТАЕТСЯ ОТДЕЛЬНО: плоская
таблица `switch` из полусотни строк-соответствий читается лучше именно как
таблица, и резать её на части — портить код ради числа.

Вложенность — максимальная глубина блоков внутри тела. Она и есть мера
запутанности: тридцать строк с глубиной 5 тяжелее ста линейных.

Нужен как приёмка разбора: монолит, переехавший в приватный метод, виден
здесь так же, как и в исходном.
"""
import re
import sys


def braces(line):
    """Скобки вне строковых литералов и комментариев.

    Без этого `case "{"` считался открытием блока, и метрика приписывала
    методу чужую глубину.
    """
    out = []
    in_string = False
    escaped = False
    i = 0
    while i < len(line):
        c = line[i]
        if in_string:
            if escaped:
                escaped = False
            elif c == '\\':
                escaped = True
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif line[i:i + 2] == '//':
            break
        elif c in '{}':
            out.append(c)
        i += 1
    return out.count('{'), out.count('}')

DECL = re.compile(r'^(\s*)(?:@\w+\s+)*(?:public |private |internal |fileprivate |static |mutating |final )*func\s+(\w+)')
# Zig: `fn name(`, возможно с `pub`, `export`, `inline`.
DECL_ZIG = re.compile(r'^(\s*)(?:pub\s+|export\s+|inline\s+|extern\s+)*fn\s+(\w+)')
BRANCH = re.compile(r'(?:^|\s)(if|guard|else|while|for)(?:\s|\()')
CASE = re.compile(r'^\s*case\s')


def metrics(path):
    lines = open(path).read().split('\n')
    decl = DECL_ZIG if path.endswith('.zig') else DECL
    rows = []
    i = 0
    while i < len(lines):
        m = decl.match(lines[i])
        if not m:
            i += 1
            continue
        indent, name = len(m.group(1)), m.group(2)
        # Сигнатура бывает многострочной: тело начинается там, где открылась
        # скобка, а не обязательно в строке `func`.
        head = i
        while head < len(lines) and '{' not in lines[head]:
            if lines[head].rstrip().endswith(('}', ')')) and head > i and 'func' not in lines[head]:
                break
            head += 1
        if head >= len(lines) or '{' not in lines[head]:
            rows.append((name, 0, 0, 0, 0))
            i += 1
            continue
        code = branches = cases = 0
        depth_max = 0
        j = head + 1
        depth = braces(lines[head])[0] - braces(lines[head])[1]
        while j < len(lines) and depth > 0:
            line = lines[j]
            stripped = line.strip()
            if stripped and not stripped.startswith('//'):
                code += 1
                found = BRANCH.findall(line)
                # `guard ... else` — одно решение, а не два: `else` у guard
                # обязателен и своей ветки не добавляет.
                if 'guard' in found and 'else' in found:
                    found.remove('else')
                branches += len(found)
                if CASE.match(line):
                    cases += 1
            opens, closes = braces(line)
            depth += opens - closes
            depth_max = max(depth_max, depth)
            j += 1
        rows.append((name, code, branches, cases, depth_max))
        i = j
    return rows


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'Sources/TrayGestureCore.swift'
    rows = sorted(metrics(path), key=lambda r: (-r[4], -r[2], -r[1]))
    print(f"{'метод':<32}{'строк':>7}{'ветвл':>7}{'case':>6}{'вложенность':>13}")
    print('-' * 65)
    for name, code, branches, cases, depth in rows:
        print(f"{name:<32}{code:>7}{branches:>7}{cases:>6}{depth:>13}")
    print('-' * 65)
    print(f"{'максимум':<32}{max(r[1] for r in rows):>7}{max(r[2] for r in rows):>7}"
          f"{max(r[3] for r in rows):>6}{max(r[4] for r in rows):>13}")


if __name__ == '__main__':
    main()
