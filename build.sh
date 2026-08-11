#!/bin/bash
# Собирает QuickShot.app из исходников Sources/*.swift одним вызовом swiftc.
# Bundle заменяется только после успешной компиляции, подписи и проверки подписи.
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
                                        # Без --sdk macosx xcrun отдаёт SDK из CommandLineTools,
                                        # который может быть новее Swift-компилятора Xcode.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
STAGING_ROOT="$(mktemp -d "$PWD/.QuickShot-build.XXXXXX")"
STAGING_BUNDLE="$STAGING_ROOT/$BUNDLE"
ATOMIC_REPLACE="$STAGING_ROOT/atomic-replace"
trap 'rm -rf "$STAGING_ROOT"' EXIT

ZIG_BIN="${QUICKSHOT_ZIG:-$(command -v zig || true)}"
if [ -z "$ZIG_BIN" ] && [ -x "$HOME/.native/toolchains/zig-0.16.0/zig" ]; then
  ZIG_BIN="$HOME/.native/toolchains/zig-0.16.0/zig"
fi
if [ -z "$ZIG_BIN" ]; then
  echo "error: zig is required to build NativeQuickShotUI; set QUICKSHOT_ZIG or install Zig 0.16" >&2
  exit 1
fi

echo "==> Проверка Native UI contract"
NATIVE_DESIGN_SYSTEM_DIR="$("$PWD/scripts/resolve-native-ui-dependency.sh")"
NATIVE_DESIGN_SYSTEM_ZIG="$ZIG_BIN" \
  "$NATIVE_DESIGN_SYSTEM_DIR/scripts/check.sh" "$PWD/NativeQuickShotUI/src/hub.native"

NATIVE_UI_LIB="$PWD/NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a"

echo "==> Сборка ${BUNDLE} (${ARCH}, deployment macOS ${DEPLOY})"
echo "==> Сборка NativeQuickShotUI ($(basename "$ZIG_BIN"))"
(cd NativeQuickShotUI && PATH="$(dirname "$ZIG_BIN"):$PATH" "$ZIG_BIN" build lib -Doptimize=ReleaseFast)
"$PWD/scripts/normalize-native-static-library.sh" "$NATIVE_UI_LIB"

mkdir -p "$STAGING_BUNDLE/Contents/MacOS"
mkdir -p "$STAGING_BUNDLE/Contents/Resources"

if [ "${QUICKSHOT_TEST_FAIL_BEFORE_COMPILE:-0}" = "1" ]; then
  echo "error: injected compiler failure" >&2
  exit 86
fi

# Swift 6 и complete strict concurrency являются release gate: AppKit живёт на
# MainActor, а Carbon callbacks входят в него через проверенную C-границу.
xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  -framework ImageIO \
  -o "$STAGING_BUNDLE/Contents/MacOS/$APP" \
  "$NATIVE_UI_LIB" \
  Sources/*.swift

cp Info.plist "$STAGING_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$STAGING_BUNDLE/Contents/PkgInfo"

if [ "${QUICKSHOT_TEST_FAIL_BEFORE_SIGN:-0}" = "1" ]; then
  echo "error: injected signing failure" >&2
  exit 87
fi

# Подпись бандла. Стабильная личность (Apple Development / Developer ID) даёт
# неизменный designated requirement, поэтому TCC помнит доступ «Запись экрана» между
# сборками. Ad-hoc (-s -) меняет хеш кода каждую сборку и сбрасывает разрешение —
# используется только как fallback, если стабильной подписи нет.
SIGN_IDENTITY="${QUICKSHOT_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' \
    | head -1 \
    | tr -d '"' \
    || true)"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Подпись: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGING_BUNDLE"
else
  echo "==> Подпись: ad-hoc (стабильной личности не найдено — доступ будет слетать при пересборке)"
  codesign --force --deep --sign - "$STAGING_BUNDLE"
fi

codesign --verify --deep --strict "$STAGING_BUNDLE"

if [ "${QUICKSHOT_TEST_FAIL_BEFORE_INSTALL:-0}" = "1" ]; then
  echo "error: injected installation failure" >&2
  exit 88
fi

xcrun clang -Wall -Wextra -Werror \
  "$PWD/scripts/atomic-replace.c" \
  -o "$ATOMIC_REPLACE"
"$ATOMIC_REPLACE" "$STAGING_BUNDLE" "$PWD/$BUNDLE"

echo "==> Готово: ./$BUNDLE"
echo "    Запуск:  open ./$BUNDLE"
