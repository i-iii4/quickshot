#!/bin/bash
# Отключает системный ⌘⇧4 (символьный хоткей id 30 — «Снимок выбранной области в файл»),
# чтобы комбинацию перехватывал QuickShot. Полностью обратимо: enable-system-shortcut.sh.
#
# parameters = ( keychar=52 '4', keycode=21, modifiers=1179648 = cmd+shift ).
set -euo pipefail

defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 30 \
  '{ enabled = 0; value = { parameters = ( 52, 21, 1179648 ); type = standard; }; }'

/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

echo "Системный ⌘⇧4 отключён."
echo "Если системный скриншот всё ещё перехватывает комбинацию — выйдите из сессии пользователя и зайдите снова."
