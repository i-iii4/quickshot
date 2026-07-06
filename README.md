# QuickShot

Меню-бар утилита для macOS: быстрый скриншот выбранной области по глобальному
хоткею, сразу в буфер обмена. Без иконки в Dock - живёт значком в строке меню.

## Как Это Работает

1. Нажимаешь `Command-Shift-4`.
2. QuickShot скрывает свои окна.
3. `ScreenFreezePipeline` ждёт свежий сигнал из постоянно прогретого
   ScreenCaptureKit stream: новый complete frame или idle heartbeat строго после
   скрытия окон QuickShot.
4. Overlay появляется уже поверх готовых frozen backdrops.
5. Ты выделяешь область; итоговый crop берётся только из свежего frozen кадра.
6. У угла экрана появляется миниатюра, снимок копируется в буфер обмена.

`Esc` во время выделения отменяет capture.

## Capture Architecture

Текущий capture-flow - **persistent stream fresh-frame first**. Мы больше не
ждём `SCScreenshotManager.captureImage` на обычном hotkey path: он слишком
часто даёт 0.6-3s задержки на этой машине. Вместо этого
`ScreenFreezePipeline` постоянно держит тёплый `SCStream` per display. Frozen
backdrop строится из последнего complete `CVPixelBuffer`, но freshness
подтверждается строго после trigger и после скрытия окон QuickShot: либо новым
`SCFrameStatus.complete`, либо `SCFrameStatus.idle`, который по ScreenCaptureKit
значит, что новый кадр не был создан, потому что дисплей не изменился.
Если ScreenCaptureKit не присылает post-hide idle heartbeat для статичного
дисплея в коротком бюджете, допускается latest complete frame из активного
matching stream с отдельным логом `freshness=latest-active-stream`.

Старый stale-frame класс багов закрывается freshness gate: pre-hide pixels не
могут стать frozen backdrop сами по себе. Если complete frame старше
`acceptedAfter`, он допускается только при наличии post-hide idle heartbeat или
как latest frame из живого matching stream. Frames очищаются при остановке
stream или изменении display, поэтому detached stale buffers не принимаются.
`acceptedAfter` считается от момента, когда QuickShot уже спрятал свои окна,
плюс маленький settle-интервал на следующий display frame.

Stream path ждёт свежий frame только короткий direct-manipulation budget
(`150 ms`). Если stream не успел, capture быстро завершается ошибкой и
запускает background maintenance; hot path не уходит в one-shot fallback, потому
что такой fallback и создавал 3-10 секундные провалы.

Цена этой архитектуры - постоянный macOS screen-capture indicator, пока
QuickShot запущен. Это сознательный выбор в пользу скорости и предсказуемого
hot UX.

### Current Timing Baseline

До stream-backed изменения one-shot freeze-first baseline был около
590-660 ms до `capture overlay ready` на тёплом пути, с выбросами 1.24s и
1.75s; отдельные probes показывали `SCScreenshotManager.captureImage` в
диапазоне 0.6-3s. Stream probe показал другую картину: уже запущенный
`SCStream` отдаёт новые frames или idle heartbeats в коротком бюджете, поэтому
новый целевой путь - подтвердить post-hide freshness в пределах `150 ms`. Если
idle callback запаздывает на статичном дисплее, latest-active-stream fallback
сохраняет UX быстрым без возврата к 0.6-3s one-shot path.

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
- `ScreenFreezePipeline` persistent stream freshness и запрет one-shot fallback;
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
  ScreenFreezePipeline.swift stream-backed ScreenCaptureKit freezer
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
