# QuickShot

Меню-бар утилита для macOS: быстрый скриншот выбранной области по глобальному хоткею,
сразу в буфер обмена. Без иконки в Dock — живёт значком в строке меню.

## Как это работает

1. Нажимаешь `⌘⇧4`.
2. QuickShot скрывает свои окна и сразу показывает интерактивный overlay.
3. Свежий frozen backdrop приходит отдельным шагом из прогретого ScreenCaptureKit stream cache.
   Если пользователь уже тянет область, рамка работает сразу, а итоговый регион кадрируется только
   после появления fresh frozen-кадра.
4. У угла экрана появляется миниатюра снимка (влетает scale+fade). Снимков может быть
   несколько — они выкладываются треем.
5. Наводишь на карточку — появляются кнопки **«Копировать»** и **«Закрыть»**. «Копировать»
   кладёт изображение в буфер обмена (галочка «Скопировано»), «Закрыть» отбрасывает снимок.
6. Двойной клик по карточке — полный кадр в отдельном окне (там `⌘C` копирует, `Esc` закрывает).

`Esc` во время выделения — отмена.

## Оверлей выделения

Оверлей устроен как **immediate selection chrome + fresh frozen backdrop**. ScreenCaptureKit stream cache
запускается после старта приложения, прогревает дисплеи параллельно и держит последний кадр каждого
дисплея в памяти, исключая окна QuickShot через
`SCContentFilter(display:excludingApplications:exceptingWindows:)`. По hotkey мы сначала показываем
рамку, затемнение и курсор, затем скрываем видимые окна QuickShot перед frozen-frame работой, а
frozen backdrop устанавливаем, когда stream-cache отдаёт свежий frame. Получение и конвертация
frozen image идут off-main, поэтому созданный overlay не застревает невидимым за тяжёлым
`CVPixelBuffer` -> `CGImage` шагом или скрытием окон. Hotkey path не строит новый `SCShareableContent`
и не вызывает one-shot screenshot из `CaptureController`; stream-owned snapshot допустим только как
фоновый способ получить fresh frame через уже подготовленный `SCContentFilter`.
До overlay QuickShot берёт только одноразовый snapshot позиции/состояния мыши; global mouse monitor
регистрируется уже внутри overlay, когда окно выведено.

Overlay window тоже не делает forced full-screen `displayIfNeeded()` перед показом: hot path создаёт
лёгкие view/layer-структуры и сразу order-front'ит окно, а AppKit рисует chrome естественным paint.
Это важно на больших дисплеях, где синхронный pre-render сам может стать видимой задержкой.
Активация приложения и key-window assignment отложены на следующий main-loop turn: они нужны для
Esc/key handling, но не должны блокировать первый видимый overlay.

Active capture принимает только пиксели, созданные после текущего capture request. Для live stream
это означает `updatedAt >= requestedAt`; для prepared frozen image действует то же правило. Даже
очень свежий кадр, который появился до запроса, считается старым для нового снимка и не может стать
frozen backdrop или final crop. `validatedAt` остаётся maintenance-сигналом: он помогает понять,
когда живой stream давно не подтверждался и его нужно мягко освежить или перезапустить, но validation
не даёт права показывать пользователю pre-request pixels. Если cached frame старше запроса,
`ScreenFrameCache` просит у текущего stream fresh frame, а overlay уже остаётся активным и принимает
выделение. Дедлайн ожидания fresh frame может быть длиннее cold-start прогрева ScreenCaptureKit, но
это фоновый дедлайн: он не должен сдвигать момент появления overlay. Accepted stream frame всегда
логирует единственный допустимый источник acceptance: `source=post-request`; log-only verifier
падает при `source=responsive` или `source=validated`.
Если ScreenCaptureKit не отдаёт ни одного display даже после recovery-chain, `ScreenFrameCache`
использует cache-owned rect snapshot recovery (`SCScreenshotManager.captureScreenshot(rect:)`), а не
проталкивает screenshot API в `CaptureController`. Все окна QuickShot выставляют
`NSWindow.sharingType = .none`, поэтому emergency rect snapshot не должен запекать overlay, hub,
карточки или settings. Этот fallback остаётся active-path recovery, поэтому у него короткий timeout
и recent-failure cooldown: если системный screenshot stack уже отказал, следующий repeated capture
не должен снова тратить секунды после `mouseUp`. Пустой `SCShareableContent.displays` также
записывается в `recentShareableDisplayFailure`: пока действует `shareableDisplayFailureCooldown`,
active capture не прогоняет заново весь shareable-content recovery-chain и сразу получает typed
unavailable reason. Когда prewarm видит пустой `displays`, cache фоном запускает tiny rect-snapshot
probe и заранее выставляет cooldown, если весь screenshot stack сейчас unhealthy. Если active capture
приходит, пока probe ещё выполняется, он ждёт только короткий `rectSnapshotProbeJoinNanoseconds` и не
запускает второй `SCScreenshotManager` fallback параллельно.
`ScreenFrameCache.start` возвращает `StartResult`, а не `Bool`: reason недоступности cache остаётся
в cache layer и передаётся в rect snapshot recovery / `captureStackUnavailable`. Если rect snapshot
тоже недоступен, capture завершается сразу с явным `captureStackUnavailable`, а не маскирует
системный отказ как `noDisplay` и не ждёт полный frozen-frame timeout. Обработчик ошибки логирует
`capture stack unavailable` и показывает одно немодальное attention-событие вместо повторяющегося
modal alert. Такая же typed-граница применяется, если stream cache формально стартовал, но fresh
frozen frame не появился до bounded wait.

После завершения снимка QuickShot готовит следующий снимок на idle-path: только мягко просит fresh
frame у live stream и валидирует статичный desktop, если новый sample не пришёл. Post-capture prepare
не запускает `SCScreenshotManager` и не создаёт joinable prepared task: speculative one-shot work не
должен конкурировать со следующим active capture. Если пользователь успел отпустить мышь раньше,
чем frozen frame готов, overlay закрывается сразу после сохранения координат selection; QuickShot
держит свои окна скрытыми до завершения crop, но не оставляет выделенный прямоугольник висеть под
курсором. Если frozen frame уже готов к моменту `mouseUp`, overlay и session всё равно завершаются
до crop: `CGImage.cropping` выполняется на background queue, а на main queue возвращаются только
лог результата и handoff в thumbnail/clipboard path. Capture-time snapshot fallback остаётся
последним recovery-механизмом, но стартует только после короткого stream refresh grace, чтобы обычный
`SCStream` успел отдать fresh frame без дорогого screenshot API, и сам stream-owned fallback имеет
отдельный timeout. Stream startup/restart
коалесится по display, так что recovery одного
монитора не блокирует запуск другого. При этом `startingDisplays` и просто зарегистрированный
`streams[id]` не считаются готовым cache: usable source появляется только после real frame,
prepared image или успешного `startCapture()` в `startedDisplays`. Если active capture попадает ровно
в pending startup, он ждёт только короткое bounded окно готовности stream, а затем идёт в
recovery/failure вместо ожидания полного frozen-frame deadline на чужом startup. Refresh коалесится с owner id и priority: active capture
recovery может supersede idle post-capture refresh, а старый idle task не может снять флаг нового
refresh.

Age maintenance тоже двухступенчатый: сначала он мягко просит fresh frame у живого stream
(`allowsStreamRestart: false`), а destructive restart остаётся только для сильно устаревшего suspect
stream. Это переносит восстановление свежести в idle-path и не возвращает 2-3-секундную паузу в
следующий `mouseUp`. Реальный `TaskPriority` следует тому же контракту:
capture recovery запускается как user-initiated, а maintenance и post-capture idle refresh работают
как utility-задачи, чтобы не конкурировать с crop/delivery пользовательского снимка.

Завершение приложения тоже считается частью capture lifecycle. `applicationWillTerminate` явно
закрывает активную capture-сессию, dismiss'ит overlay, отменяет freeze/refresh work и переводит
`ScreenFrameCache` в terminal shutdown state. После этого поздно вернувшиеся async-задачи не имеют
права заново создавать stream или запускать post-capture prewarm. Startup prewarm тоже owned:
`CaptureController` хранит task, отменяет предыдущий prewarm перед новым и инвалидирует stale
completion при shutdown.

Доступ «Запись экрана» тоже не проверяется заново на нормальном hotkey path после уже
подтверждённого разрешения. QuickShot помнит последний granted state между запусками, а реальный
`CGPreflightScreenCaptureAccess()` обновляет это состояние в фоне во время prewarm. Если доступ
отозван, следующий unknown/denied путь снова покажет системный permission-flow вместо capture.

Курсор не системный: QuickShot прячет системную стрелку через CoreGraphics, ставит прозрачный
cursor rect как запасной слой защиты и рисует собственное перекрестье `CALayer`. Рамка выделения
рисуется тем же stroke-языком, что и перекрестье: чёрный halo + белое ядро, round caps, активный
угол рамки продолжает линии курсора через маленький разделитель. Никакой точки, ручки или изменения
размера курсора во время drag нет.

## Трей и хаб

Как только есть хотя бы один снимок, у угла появляется **хаб-счётчик** — тёмная «пуля» в стиле
дизайн-системы Vercel (Geist): чёрный фон, тонкая subtle-обводка, моноширинный счётчик. Клик по
ней растворяет карточки в хаб (сворачивание) и проявляет обратно (разворачивание). Новый снимок
авто-разворачивает трей.

Справа от цифры — **шеврон-индикатор** открытия/закрытия. Он показывает, куда раскроется трей, и
плавно доворачивается при клике. Направление зависит от положения кнопки: вертикальный трей
(справа/слева) раскрывается вверх (свёрнуто — стрелка вверх, развёрнуто — вниз), горизонтальный
(снизу/сверху) — влево (свёрнуто — влево, развёрнуто — вправо).

- Карточку можно тянуть за **левый/правый край**, меняя общую ширину всех карточек (сохраняется
  между запусками).
- Карточку можно **перетащить** как файл (drag-out) в Finder, Slack, редактор.
- Если карточек больше, чем влезает, лишние прячутся (видны после сворачивания счётчика).

Хаб — Vercel/Geist-подобная тёмная command-pill: compact-state состоит из одной заливки и одной
внешней обводки, без stacked rings/перемычек. По hover shell раскрывается в сторону от основной
кнопки и показывает короткие action pills: `Delete`, `Save`, `Copy`; полный смысл команд закреплён
в accessibility labels. Положение хаба и карточек считается от полного `screen.frame`, а не от
`visibleFrame`: Dock и menu bar не создают лишний отступ, при необходимости хаб осознанно
перекрывает системный chrome.
Трей живёт в полноэкранном прозрачном `TrayHostContentView`: он отдаёт события только реальным
сабвью (хабу, action pills, карточкам) и возвращает `nil` в пустоте. Это обязательная часть
кликабельности expanded hub, потому что проверка одного `HubWindow.hitTest` не доказывает, что клик
дойдёт через настоящее окно трея. Контейнер карточки и сама карточка тоже вручную маршрутизируют
hit-testing к своим controls, чтобы крестик, copy-кнопка и ресайз-ручка не отваливались
после правок прозрачного host-window.
Кнопки на карточке (**Копировать**/**Закрыть**) — собственные тёмные command-buttons QuickShot:
Vercel/Geist-подобные pill/circle controls с тонкой обводкой и явными hover/pressed состояниями,
без системного Liquid Glass. Окно «полный кадр» остаётся отдельным нативным surface.

Визуальные референсы для Vercel-подобного хаба лежат в
`reference/screenshots/vercel-hub/`.

## Настройки

Значок в строке меню → «Настройки…» → положение трея: слева / справа / снизу / сверху.
Новый снимок появляется у соответствующего угла.

## Сборка

```
./build.sh
```

Собирает `QuickShot.app` из `Sources/*.swift` одним вызовом `swiftc`. Нужен установленный
Xcode (toolchain Swift). Цель — `arm64-apple-macos26.0`.

## Тесты

```
./scripts/test.sh
```

Сейчас тестовый раннер покрывает интерактивный контракт хаба: основная кнопка должна оставаться
кликабельной в compact и hover-expanded состояниях, hover-расширение не должно сдвигать центр
основной кнопки, compact shell не должен собираться из stacked ring layers, видимые элементы не
должны выходить за shell на промежуточных кадрах раскрытия, action-labels не должны появляться в
обрезанном состоянии, радиусы/отступы/gaps должны оставаться математически согласованными, все
action-кнопки должны кликаться во время reveal и после него, а action-клик не должен случайно
сворачивать/разворачивать трей даже при mouse-exit между press и release. Отдельный live-level тест
создаёт настоящий `NSPanel` + `TrayHostContentView` и отправляет mouse events через window dispatch,
чтобы regression gate ловил случай, когда изолированный `HubWindow` кликается, а реальное окно нет.
Отдельный live-level тест проверяет клик по крестику отдельной карточки через тот же
window dispatch. Также проверяется `ScreenFrameCache`: старый cached frame, полученный до текущего
capture request, не должен попадать в frozen backdrop/final crop.

Для визуальной проверки хаба:

```
./scripts/render-hub-qa.sh /tmp/quickshot-hub-matrix-preview.png
```

Скрипт рендерит matrix PNG для позиций справа/слева/снизу/сверху, счётчиков `1`, `2`, `99+` и
промежуточных кадров раскрытия.

Для визуальной проверки selection tool:

```
./scripts/render-selection-qa.sh /tmp/quickshot-selection-tool-preview.png
```

Скрипт рендерит направления drag, маленькое выделение и wide/shallow state, используя debug-геометрию
`SelectionView`: курсор должен оставаться того же размера, а рамка должна продолжать его оси через
аккуратный разделитель.

Для runtime-проверки capture-flow:

```
./scripts/verify-capture-runtime.sh
```

Скрипт пересобирает и перезапускает `QuickShot.app`, ждёт первый stream frame или явный
`capture cache no stream candidates` для rect-snapshot recovery, синтетически отправляет серию
`Command-Shift-4`/`Esc`, затем проверяет unified log: overlay должен становиться ready быстро, без
controller-owned screenshot fallback, с подавлением/восстановлением системного курсора. `cache pending`
допустим, если overlay уже активен; stale `old frame accepted` недопустим. В summary `rectSnapshot=yes`
означает cache-owned emergency recovery через `ScreenFrameCache`, а не возврат старого one-shot пути
в `CaptureController`.

Для проверки твоего ручного теста без синтетических hotkey/overlay-событий:

```
./scripts/verify-capture-observed.sh
```

Скрипт ничего не нажимает и не показывает. Он читает unified log текущего `QuickShot.app` за
последнюю минуту и проверяет, что реальный ручной capture имел `capture overlay ready` в пределах
100ms, что overlay действительно начался, что hotkey path не делал `phase=trigger` permission
preflight при уже известном доступе, и что не было forbidden fallback/stale-frame признаков.
Если production path был вынужден использовать cache-owned rect snapshot recovery из-за пустого
`SCShareableContent.displays`, summary покажет `rectSnapshot=yes`.

Если нужно проверить сам системный capture-stack без overlay и без синтетического управления экраном:

```
./scripts/probe-screen-capture-stack.sh
```

Он не запускает QuickShot capture flow: только печатает `CGPreflightScreenCaptureAccess`, результаты
нескольких `SCShareableContent` loaders, маленький `SCScreenshotManager` rect probe и системный
`screencapture` baseline. Это диагностический probe для случаев, когда даже системный capture layer
возвращает пустые displays или `SCStreamErrorDomain`. Если probe показывает `preflight=true`, но
`displays` пустой и `/usr/sbin/screencapture` тоже не может создать rect image, QuickShot должен
идти в typed `captureStackUnavailable`, а не в обычный `noDisplay`.
После завершения capture в логах также должен появляться `capture cache post-capture prepare`:
это stream-only подготовка следующего снимка, которая переносит stale-stream recovery из следующего
пользовательского жеста в idle-период после текущей сессии. Она не должна запускать отдельный
post-capture screenshot/prepared task; следующий active capture имеет приоритет и сам решает, нужен
ли fallback после stream-validation grace.
Для проверки именно глобального хоткея используйте строгий режим:

```
REQUIRE_HOTKEY_EVENT=1 ./scripts/verify-capture-observed.sh
```

В этом режиме `capture overlay ready` считается от раннего Carbon-события `hotkey event received`.
Для проверки завершённого ручного снимка без синтетического управления экраном:

```
REQUIRE_HOTKEY_EVENT=1 REQUIRE_COMPLETED_SELECTION=1 WINDOW_SECONDS=1800 ./scripts/verify-capture-observed.sh
```

Этот режим читает только unified log и требует полный production path: `capture frozen ready`,
`capture crop complete`, `capture clipboard copied`, overlay dismiss, cursor restore, session end и
post-capture prepare. Завершение должно быть именно `capture end outcome=completed`, чтобы cancel
или маленькое проигнорированное выделение не считались успешным снимком. Также verifier запрещает
`capture cache fresh frame request escalating ... reason=post-capture prewarm`: idle-подготовка
следующего снимка должна оставаться soft и не разбирать активный stream сразу после capture.
После `mouseUp` overlay должен исчезать до доставки изображения: `capture end outcome=completed`
логируется до `capture image handoff started`. Crop самого frozen frame тоже не выполняется внутри
mouse-up handler: `completeSelection` планирует background crop, после чего main queue получает
только `capture crop complete` и delivery. `capture clipboard copied` теперь означает публикацию
уже подготовленного payload в `NSPasteboard`, а не синхронное PNG/TIFF-кодирование в обработчике
жеста. Тот же `Clipboard.PreparedImage` используется для кнопок карточек, `Copy all`, pinned-window
copy и drag-out.

Скрипты, которые сами постят hotkey/mouse events и могут открыть overlay
(`verify-capture-runtime.sh`, `verify-capture-selection-output.sh`, `verify-capture-cold-start.sh`),
по умолчанию отказываются запускаться. Для осознанного интерактивного прогона нужен явный флаг:

```
QUICKSHOT_ALLOW_SYNTHETIC_INPUT=1 ./scripts/verify-capture-runtime.sh
```

Для cold-start края:

```
./scripts/verify-capture-cold-start.sh
```

Скрипт перезапускает приложение и нажимает hotkey почти сразу после появления процесса. Этот путь
может ждать fresh frame после появления overlay, но не должен уходить в новый screenshot API fallback
или оставлять overlay без корректного восстановления курсора. Проверяются `overlay dismiss` и
`overlay cursor restored`; default budget для `capture overlay ready` такой же строгий, как в
warm runtime-проверке.

Для полного selection-output пути:

```
./scripts/verify-capture-selection-output.sh
```

Скрипт показывает однотонное тестовое окно, делает реальный hotkey+drag, ждёт PNG в clipboard и
проверяет, что crop завершился, курсор восстановлен, а итоговый PNG остался однотонным. Если в
snapshot попадёт overlay, рамка или кастомный курсор вместо тестового окна, пиксельная
uniformity-проверка провалится; `frameAge` остаётся диагностикой задержек и фонового refresh.

Продуктовый контракт capture-flow зафиксирован в `PRODUCT_CONTRACT.md`. Любая правка оверлея,
курсора, freeze или thumbnail hub должна сверяться с ним до merge.

## Запуск

```
open ./QuickShot.app
```

Важно запускать через `open` или Finder, а не голый бинарник
(`QuickShot.app/Contents/MacOS/QuickShot`) — иначе macOS неправильно привяжет доступ
«Запись экрана» к процессу, и на Tahoe приложение может не появиться в списке разрешений.

Чтобы приложение стартовало при входе в систему — добавь `QuickShot.app` в Системные
настройки → Основные → Объекты входа.

## Первый запуск: доступ «Запись экрана»

Любой инструмент захвата экрана на macOS требует разрешения «Запись экрана» — обойти
нельзя. При первом `⌘⇧4` появится системный запрос «QuickShot хочет записывать экран».

1. Нажми «Открыть Системные настройки».
2. Включи QuickShot в разделе Конфиденциальность и безопасность → Запись экрана.
3. Перезапусти QuickShot (ScreenCaptureKit нередко начинает работать только после
   перезапуска): значок в строке меню → «Выйти из QuickShot», затем снова `open ./QuickShot.app`.

После этого `⌘⇧4` работает сразу.

## Хоткей ⌘⇧4 заменяет системный

По умолчанию `⌘⇧4` в macOS — системный скриншот области в файл. QuickShot забирает эту
комбинацию себе. Системный хоткей отключается скриптом (обратимо):

```
./scripts/disable-system-shortcut.sh   # отключить системный ⌘⇧4 (отдать QuickShot)
./scripts/enable-system-shortcut.sh    # вернуть системный ⌘⇧4
```

Если системный скриншот всё ещё перехватывает `⌘⇧4` — выйди из сессии пользователя и
зайди снова (на части версий macOS изменение применяется после повторного входа).

Остальные системные комбинации не тронуты: `⌘⇧3` (весь экран), `⌘⌃⇧4` (область в буфер),
`⌘⇧5` (панель скриншотов) работают как раньше.

## Меню в строке меню

Значок «камера» → «Сделать снимок» / «Настройки…» / «Открыть доступ к записи экрана» /
«Выйти из QuickShot». Хоткей `⌘⇧4` в пункте меню не дублируется акселератором — его ловит
глобальный Carbon-хоткей.

## Что в буфере

Снимок кладётся в двух форматах в одной транзакции: PNG (для Slack и Chromium-приложений)
и TIFF (для Preview, Заметок) — вставляется корректно почти везде.

## Ограничения

- Выделение через границу двух мониторов клипуется до экрана, где начался drag.
- Хоткей зашит (`⌘⇧4`), без настройки из UI.
- Только буфер обмена, файл на диск не сохраняется.
- Курсор в снимок не попадает.
- Клавиатурное управление — только в окне «полный кадр» (`⌘C`/`Esc`); плавающая карточка
  управляется мышью (намеренно, чтобы не воровать фокус активного приложения).
- Подпись: `build.sh` сам подписывает Apple Development / Developer ID identity, если она есть —
  тогда доступ «Запись экрана» переживает пересборку. Без identity подпись ad-hoc, и macOS
  переспросит доступ при каждой пересборке.

## Структура

```
Sources/
  main.swift               точка входа (NSApplication, .accessory, run)
  AppDelegate.swift        строка меню + регистрация хоткея
  StatusItemController.swift  пункт меню (Снимок, Настройки, доступ, Выход)
  SettingsWindow.swift     окно настроек (положение трея), Auto Layout
  GlobalHotKey.swift       Carbon RegisterEventHotKey (без прав)
  Overlay.swift            окно-оверлей + вид выделения + контроллер оверлеев
  CaptureTypes.swift       CaptureError + FrozenScreen crop-модель
  ScreenFrameCache.swift   ScreenCaptureKit stream cache + recovery/fallback policy
  CoordinateMath.swift     AppKit → sourceRect (точки/пиксели, y-flip)
  CaptureController.swift   оркестрация одного цикла захвата
  ThumbnailManager.swift   трей миниатюр: раскладка, хаб, сворачивание/разворачивание
  ThumbnailWindow.swift    панель карточки + FrameAnimator (CADisplayLink)
  HubWindow.swift          хаб-счётчик: тёмная «пуля» (Vercel/Geist) + шеврон-индикатор
  PinnedWindow.swift       окно «полный кадр» (двойной клик по карточке)
  DSControls.swift         DesignSystemButton для карточек; GlassButton для отдельных нативных окон
  CardSizing.swift         геометрия карточки (ширина-анкер, потолок по экрану, cover-crop)
  Theme.swift              немногие токены (радиус карточки, шаг разметки)
  Clipboard.swift          ImageIO payload preparation + NSPasteboard publication
build.sh                   сборка .app-бандла + подпись (Apple Development / ad-hoc)
Info.plist                 метаданные бандла (LSUIElement и пр.)
scripts/                   вкл./выкл. системного ⌘⇧4
Tests/                     изолированные AppKit-тесты интерактивного поведения
DEVLOG.md                  инженерный журнал
```
