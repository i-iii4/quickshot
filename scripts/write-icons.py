#!/usr/bin/env python3
"""Генерация набора SVG-иконок панели редактора (lucide-диалект, 24x24 stroke)."""
import os

BASE = os.path.join(os.path.dirname(__file__), '..', 'NativeQuickShotUI', 'src', 'icons')
HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
        'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">')
TAIL = '</svg>'

ICONS = {
    'tool-select': '<path d="m3 3 7.07 16.97 2.51-7.39 7.39-2.51L3 3z"/>',
    'tool-arrow': '<path d="M7 7h10v10"/><path d="M7 17 17 7"/>',
    'tool-box': '<rect x="4" y="5.5" width="16" height="13" rx="2"/>',
    'tool-oval': '<ellipse cx="12" cy="12" rx="8.5" ry="6"/>',
    'tool-line': '<line x1="5" y1="19" x2="19" y2="5"/>',
    'tool-pen': ('<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83'
                 'l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/>'
                 '<path d="m15 5 4 4"/>'),
    'tool-text': ('<polyline points="4 7 4 4 20 4 20 7"/>'
                  '<line x1="9" y1="20" x2="15" y2="20"/>'
                  '<line x1="12" y1="4" x2="12" y2="20"/>'),
    'tool-mark': ('<path d="m9 11-6 6v3h9l3-3"/>'
                  '<path d="m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4'
                  'a2 2 0 0 1 2.8 0l5.2 5.2a2 2 0 0 1 0 2.8Z"/>'),
    'tool-step': '<circle cx="12" cy="12" r="8.5"/><path d="m10.2 9.7 2.3-1.7V16"/>',
    'tool-hide': ('<rect x="3.5" y="8" width="17" height="8" rx="1.5"/>'
                  '<line x1="7" y1="16" x2="10.5" y2="8"/>'
                  '<line x1="12" y1="16" x2="15.5" y2="8"/>'),
    'tool-crop': '<path d="M6 2v14a2 2 0 0 0 2 2h14"/><path d="M18 22V8a2 2 0 0 0-2-2H2"/>',
    'weight-thin': '<line x1="4" y1="12" x2="20" y2="12" stroke-width="1.3"/>',
    'weight-medium': '<line x1="4" y1="12" x2="20" y2="12" stroke-width="2.8"/>',
    'weight-thick': '<line x1="4" y1="12" x2="20" y2="12" stroke-width="4.6"/>',
    'shape-fill': ('<rect x="4" y="4" width="16" height="16" rx="3"/>'
                   '<rect x="8.5" y="8.5" width="7" height="7" rx="1" fill="currentColor" stroke="none"/>'),
    'undo': ('<path d="M9 14 4 9l5-5"/>'
             '<path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"/>'),
    'redo': ('<path d="m15 14 5-5-5-5"/>'
             '<path d="M20 9H9.5A5.5 5.5 0 0 0 4 14.5A5.5 5.5 0 0 0 9.5 20H13"/>'),
    'scan': ('<path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/>'
             '<path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>'
             '<circle cx="12" cy="12" r="3"/>'),
}

# Образцы палитры: буквальные цвета — это содержимое рисования, а не хром темы.
# Hex-значения обязаны совпадать с AnnotationPalette в Sources/AnnotationRenderer.swift.
SWATCHES = {
    'swatch-red': '#EB3D47',
    'swatch-amber': '#FCB829',
    'swatch-green': '#33B86B',
    'swatch-blue': '#408CF5',
    'swatch-violet': '#995CEB',
}

os.makedirs(BASE, exist_ok=True)
for name, body in ICONS.items():
    with open(os.path.join(BASE, name + '.svg'), 'w') as f:
        f.write(HEAD + body + TAIL + '\n')
for name, colour in SWATCHES.items():
    with open(os.path.join(BASE, name + '.svg'), 'w') as f:
        f.write(HEAD + f'<circle cx="12" cy="12" r="7" fill="{colour}" stroke="none"/>' + TAIL + '\n')
with open(os.path.join(BASE, 'swatch-graphite.svg'), 'w') as f:
    f.write(HEAD + '<circle cx="12" cy="12" r="7" fill="#292B30" stroke="#71757D" stroke-width="1.5"/>' + TAIL + '\n')
print('icons written:', len(os.listdir(BASE)))
