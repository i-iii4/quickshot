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
ZIG_BIN="${QUICKSHOT_ZIG:-$(command -v zig || true)}"
if [ -z "$ZIG_BIN" ] && [ -x "$HOME/.native/toolchains/zig-0.16.0/zig" ]; then
  ZIG_BIN="$HOME/.native/toolchains/zig-0.16.0/zig"
fi
if [ -z "$ZIG_BIN" ]; then
  echo "error: zig is required to build NativeQuickShotUI; set QUICKSHOT_ZIG or install Zig 0.16" >&2
  exit 1
fi

echo "==> Проверка Native UI contract"
NATIVE_DESIGN_SYSTEM_DIR="${NATIVE_DESIGN_SYSTEM_DIR:-$PWD/../native-ui-design-system}"
if [ ! -x "$NATIVE_DESIGN_SYSTEM_DIR/scripts/check.sh" ]; then
  echo "error: Native UI Design System not found at $NATIVE_DESIGN_SYSTEM_DIR" >&2
  exit 1
fi
NATIVE_DESIGN_SYSTEM_ZIG="$ZIG_BIN" \
  "$NATIVE_DESIGN_SYSTEM_DIR/scripts/check.sh" "$PWD/NativeQuickShotUI/src/hub.native"

NATIVE_UI_LIB="$PWD/NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a"

echo "==> Сборка ${BUNDLE} (${ARCH}, deployment macOS ${DEPLOY})"
echo "==> Сборка NativeQuickShotUI ($(basename "$ZIG_BIN"))"
(cd NativeQuickShotUI && PATH="$(dirname "$ZIG_BIN"):$PATH" "$ZIG_BIN" build lib -Doptimize=ReleaseFast)

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
  -framework Carbon \
  -framework CoreGraphics \
  -framework ImageIO \
  -o "$BUNDLE/Contents/MacOS/$APP" \
  "$NATIVE_UI_LIB" \
  Sources/*.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Подпись бандла. Стабильная личность (Apple Development / Developer ID) даёт
# неизменный designated requirement, поэтому TCC помнит доступ «Запись экрана» между
# сборками. Ad-hoc (-s -) меняет хеш кода каждую сборку и сбрасывает разрешение —
# используется только как fallback, если стабильной подписи нет.
SIGN_IDENTITY="${QUICKSHOT_SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null \
  | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"')}"
if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Подпись: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$BUNDLE"
else
  echo "==> Подпись: ad-hoc (стабильной личности не найдено — доступ будет слетать при пересборке)"
  codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true
fi

echo "==> Готово: ./$BUNDLE"
echo "    Запуск:  open ./$BUNDLE"
