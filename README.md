# QuickShot

Меню-бар утилита для macOS: быстрый скриншот выбранной области по глобальному
хоткею, сразу в буфер обмена. Без иконки в Dock - живёт значком в строке меню.

## Как Это Работает

1. Нажимаешь `Command-Shift-4`.
2. QuickShot скрывает свои окна.
3. `ScreenFreezePipeline` делает свежие full-display snapshots через
   ScreenCaptureKit, в стиле Mio.
4. Overlay появляется уже поверх готовых frozen backdrops.
5. Ты выделяешь область; итоговый crop берётся только из свежего frozen кадра.
6. У угла экрана появляется миниатюра, снимок копируется в буфер обмена.

`Esc` во время выделения отменяет capture.

## Capture Architecture

Текущий capture-flow - **Mio-style freeze first**. Мы больше не держим
последний кадр рабочего стола как источник истины для следующего снимка. Каждый
capture request получает свежий full-display screenshot после trigger, поэтому
старая картинка из предыдущего снимка не может попасть в backdrop или final
crop.

На старте приложение делает tiny prewarm: 2x2 `SCScreenshotManager.captureImage`.
Это прогревает ScreenCaptureKit путь, но не показывает UI и не блокирует работу.
На hotkey сессия скрывает видимые окна QuickShot, снимает дисплеи батчами с
cap `3`, затем показывает overlay с готовыми frozen backdrops.

Overlay появляется после `capture frozen ready`, как в Mio. Целевой warm-path
budget для `capture overlay ready` - до 200 ms, с ориентиром Mio на десятки
миллисекунд после prewarm. Задержка 2-3 секунды до overlay считается
performance-регрессом, который нужно устранять в freeze pipeline, а не обходить
пустым live overlay.

### Current Timing Baseline

Последний log-only замер текущей freeze-first версии после перезапуска:

- `capture overlay ready`: стабильный диапазон около 590-660 ms, последний
  замер 630 ms, стабильное среднее после первых трёх попыток около 644 ms;
- `capture display ready`: стабильное среднее после первых трёх попыток около
  551 ms;
- `capture frozen ready`: стабильное среднее после первых трёх попыток около
  599 ms;
- `capture overlay constructed`: стабильное среднее около 45 ms;
- холодные/ранние выбросы были около 1.24s и 1.75s.

Это лучше прежнего 2-3s поведения, но всё ещё выше продуктового бюджета.
Основная стоимость сейчас находится в `SCScreenshotManager.captureImage`, а не
в создании overlay. Следующий speed work должен сначала доказать эффективность
prewarm и разложить freeze timing на `SCShareableContent.current` отдельно от
самого `SCScreenshotManager.captureImage`. Если после корректного prewarm
one-shot ScreenCaptureKit всё равно остаётся около 500-600 ms, путь к
sub-200 ms UX потребует отдельного архитектурного решения с persistent
stream/cache, а не только полировки overlay.

Все окна QuickShot дополнительно выставляют `NSWindow.sharingType = .none`;
selection overlay, hub, thumbnails, settings и helper windows не должны
запекаться в frozen image.

## Selection Tool

Курсор не системный: QuickShot прячет системную стрелку через CoreGraphics,
ставит прозрачный cursor rect как запасной слой защиты и рисует собственное
перекрестье `CALayer`. Рамка выделения рисуется тем же stroke-языком, что и
перекрестье: чёрный halo + белое ядро, round caps, активный угол рамки
продолжает линии курсора через маленький разделитель. Никакой точки, ручки,
перемычки или изменения размера курсора во время drag нет.

## Трей И Хаб

Как только есть хотя бы один снимок, у угла появляется хаб-счётчик - тёмная
пуля в стиле Vercel/Geist. Клик по ней сворачивает карточки в хаб и раскрывает
их обратно. Новый снимок авто-разворачивает трей.

Хаб раскрывается на hover и показывает короткие action pills: `Delete`, `Save`,
`Copy`; полный смысл команд закреплён в accessibility labels. Положение хаба и
карточек считается от полного `screen.frame`, а не от `visibleFrame`: Dock и
menu bar не создают лишний отступ.

Кнопки на карточке (`Copy`/`Close`) - собственные тёмные command-buttons
QuickShot, без системного Liquid Glass.

Визуальные референсы лежат в `reference/screenshots/`.

## Сборка

```bash
./build.sh
```

Собирает `QuickShot.app` из `Sources/*.swift` одним вызовом `swiftc`. Нужен
установленный Xcode toolchain. Цель - `arm64-apple-macos26.0`.

## Тесты

```bash
./scripts/test.sh
```

Тестовый раннер покрывает:

- хаб и action pills, включая live window dispatch;
- кликабельность controls на отдельных карточках;
- `ScreenFreezePipeline` prewarm/batch параметры;
- selection cursor/frame geometry;
- static gates для Mio-style freeze-before-overlay порядка;
- off-main crop и prepared clipboard payload path.

Визуальная проверка хаба:

```bash
./scripts/render-hub-qa.sh /tmp/quickshot-hub-matrix-preview.png
```

Визуальная проверка selection tool:

```bash
./scripts/render-selection-qa.sh /tmp/quickshot-selection-tool-preview.png
```

Логовая проверка ручного capture без синтетического управления экраном:

```bash
./scripts/verify-capture-observed.sh
```

Скрипты, которые сами постят hotkey/mouse events и могут открыть overlay,
по умолчанию отказываются запускаться. Для осознанного интерактивного прогона
нужен явный флаг:

```bash
QUICKSHOT_ALLOW_SYNTHETIC_INPUT=1 ./scripts/verify-capture-runtime.sh
```

## Запуск

```bash
open ./QuickShot.app
```

Запускать нужно через `open` или Finder, не голый бинарник
`QuickShot.app/Contents/MacOS/QuickShot`, чтобы macOS правильно привязала
доступ «Запись экрана» к bundle.

## Первый Запуск

Любой инструмент захвата экрана на macOS требует разрешения «Запись экрана».
При первом `Command-Shift-4` появится системный запрос.

1. Нажми «Открыть Системные настройки».
2. Включи QuickShot в разделе Конфиденциальность и безопасность -> Запись экрана.
3. Перезапусти QuickShot.

## Хоткей

По умолчанию `Command-Shift-4` в macOS - системный скриншот области в файл.
QuickShot забирает эту комбинацию себе. Системный хоткей отключается скриптом:

```bash
./scripts/disable-system-shortcut.sh
./scripts/enable-system-shortcut.sh
```

## Структура

```text
Sources/
  AppDelegate.swift          строка меню + регистрация хоткея
  CaptureController.swift    оркестрация одного цикла захвата
  ScreenFreezePipeline.swift Mio-style ScreenCaptureKit freezer
  Overlay.swift              frozen overlay + selection tool
  CaptureTypes.swift         CaptureError + FrozenScreen crop model
  CoordinateMath.swift       AppKit points -> source pixels
  ThumbnailManager.swift     трей миниатюр
  ThumbnailWindow.swift      карточки снимков
  HubWindow.swift            Vercel/Geist-like hub
  Clipboard.swift            ImageIO payload preparation
Tests/                       AppKit/static regression gates
scripts/                     build, QA, capture verification helpers
PRODUCT_CONTRACT.md          продуктовый контракт
DEVLOG.md                    инженерный журнал
```
