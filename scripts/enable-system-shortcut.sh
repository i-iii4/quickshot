#!/bin/bash
# Восстанавливает системный ⌘⇧4 (символьный хоткей id 30 — «Снимок выбранной области
# в файл»), отключённый ранее через disable-system-shortcut.sh.
set -euo pipefail

defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 30 \
  '{ enabled = 1; value = { parameters = ( 52, 21, 1179648 ); type = standard; }; }'

/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

echo "Системный ⌘⇧4 восстановлен."
