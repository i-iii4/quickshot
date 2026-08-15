#!/usr/bin/env python3
"""Каждое требование уровней 1 и 2 обязано упоминаться в тестах.

Проверка нужна не ради формальности: без неё требование легко объявить
выполненным, не проверив. Ссылка на идентификатор в тесте — минимальное
доказательство того, что о требовании вообще подумали.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

SOURCES = [
    (ROOT / "SYSTEM_REQUIREMENTS.md", r"- \*\*([12])\*\* `((?:TR|ST|ED)-[0-9]+[a-z]?)`"),
    (ROOT / "ANNOTATION_REQUIREMENTS.md", r"- \*\*([12])\*\* `([A-Q]-[0-9]+)`"),
]


def required_ids() -> set[str]:
    ids: set[str] = set()
    for path, pattern in SOURCES:
        for line in path.read_text().split("\n"):
            match = re.match(pattern, line.strip())
            if match:
                ids.add(match.group(2))
    return ids


def referenced_text() -> str:
    text = "".join(p.read_text() for p in (ROOT / "Tests").glob("*.swift"))
    text += (ROOT / "scripts" / "test.sh").read_text()
    return text


def main() -> int:
    ids = required_ids()
    if not ids:
        print("requirement coverage: no requirements parsed", file=sys.stderr)
        return 1

    text = referenced_text()
    missing = sorted(i for i in ids if i not in text)
    if missing:
        print(f"requirement coverage: {len(missing)} of {len(ids)} not referenced by any test",
              file=sys.stderr)
        print(" ".join(missing), file=sys.stderr)
        return 1

    print(f"RequirementCoverage: passed ({len(ids)} requirements referenced)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
