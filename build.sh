#!/bin/bash
# Собирает QuickShot.app из исходников Sources/*.swift одним вызовом swiftc и
# складывает их в .app-бандл (без Xcode-проекта), затем ad-hoc подписывает.
#
# Почему .app-бандл, а не голый бинарник: TCC («Запись экрана») привязывается к
# бандлу со стабильным CFBundleIdentifier; на Tahoe голый бинарник может вообще не
# появиться в списке разрешений. Запускать через `open` / Finder, а не exec бинарника.
set -euo pipefail
cd "$(dirname "$0")"

APP="QuickShot"
BUNDLE="${APP}.app"
ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"

echo "==> Сборка ${BUNDLE} (${ARCH}, deployment macOS ${DEPLOY})"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

# -swift-version 5 ОБЯЗАТЕЛЕН: в языковом режиме Swift 6 строгая проверка
# concurrency отвергает Carbon C-колбэк и глобальное изменяемое состояние хоткея.
xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework CoreGraphics \
  -o "$BUNDLE/Contents/MacOS/$APP" \
  Sources/*.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Ad-hoc подпись всего бандла. ВНИМАНИЕ: ad-hoc (-s -) меняет хеш кода при каждой
# сборке, поэтому TCC будет считать пересобранное приложение новым и заново спросит
# доступ «Запись экрана». Для стабильного доступа подпишите фиксированным
# self-signed/Developer ID удостоверением, оставив CFBundleIdentifier неизменным.
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo "==> Готово: ./$BUNDLE"
echo "    Запуск:  open ./$BUNDLE"
