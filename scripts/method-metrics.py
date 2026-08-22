#!/usr/bin/env python3
"""Метрики методов Swift-файла: строк кода и ветвлений.

Строки кода — без пустых и без строк-комментариев. Ветвления — `if`, `guard`,
`else`, `while`, `for`, `case` внутри `switch`. Нужен как приёмка разбора:
монолит, переехавший в приватный метод, виден здесь так же, как и в исходном.
"""
import re
import sys

DECL = re.compile(r'^(\s*)(?:@\w+\s+)*(?:public |private |internal |fileprivate |static |mutating |final )*func\s+(\w+)')
BRANCH = re.compile(r'(?:^|\s)(if|guard|else|while|for|case)(?:\s|\()')


def metrics(path):
    lines = open(path).read().split('\n')
    rows = []
    i = 0
    while i < len(lines):
        m = DECL.match(lines[i])
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
            rows.append((name, 0, 0))
            i += 1
            continue
        code = branches = 0
        j = head + 1
        depth = lines[head].count('{') - lines[head].count('}')
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
            depth += line.count('{') - line.count('}')
            j += 1
        rows.append((name, code, branches))
        i = j
    return rows


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'Sources/TrayGestureCore.swift'
    rows = sorted(metrics(path), key=lambda r: (-r[1], -r[2]))
    print(f"{'метод':<34}{'строк':>7}{'ветвлений':>12}")
    print('-' * 53)
    for name, code, branches in rows:
        print(f"{name:<34}{code:>7}{branches:>12}")
    print('-' * 53)
    print(f"{'максимум':<34}{max(r[1] for r in rows):>7}{max(r[2] for r in rows):>12}")


if __name__ == '__main__':
    main()
