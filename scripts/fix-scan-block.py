#!/usr/bin/env python3
"""Пересобрать блок сборки EditorScanTests из списка исходников живого набора карточек."""
import pathlib
import re

p = pathlib.Path('scripts/test.sh')
s = p.read_text()

start = s.index('xcrun swiftc', s.index('  Tests/EditorScanTests.swift') - 4000)
end = s.index('-o "$SCAN_OUT"') + len('-o "$SCAN_OUT"\n')
s = s[:start] + s[end:]

source_block = [b for b in s.split('xcrun swiftc') if 'Tests/ThumbnailWindowLiveClickTests.swift' in b][0]
files = re.findall(r'(Sources/\S+\.swift)', source_block.split(' -o "')[0])
assert files, "не нашёл список исходников"
lines = "".join(f"  {f} \\\n" for f in files)

block = ("xcrun swiftc \\\n"
         '  -sdk "$SDK" \\\n'
         '  -target "${ARCH}-apple-macos${DEPLOY}" \\\n'
         "  -swift-version 6 \\\n"
         "  -strict-concurrency=complete \\\n"
         "  -warnings-as-errors \\\n"
         "  -D TESTING \\\n"
         "  -framework AppKit \\\n"
         "  -framework CoreGraphics \\\n"
         "  -framework QuartzCore \\\n"
         "  -framework ImageIO \\\n"
         "  -framework Vision \\\n"
         "  -framework UniformTypeIdentifiers \\\n"
         + lines +
         "  Tests/EditorScanTests.swift \\\n"
         '  "$NATIVE_UI_LIB" \\\n'
         '  -o "$SCAN_OUT"\n\n'
         '"$SCAN_OUT"\n')

marker = '"$STORAGE_LIFECYCLE_OUT"\n'
idx = s.index(marker, s.index('Tests/StorageLifecycleTests.swift')) + len(marker)
s = s[:idx] + "\n" + block + s[idx:]
p.write_text(s)
print("scan block rebuilt with", len(files), "sources")
