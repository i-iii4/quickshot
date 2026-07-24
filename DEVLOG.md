# DEVLOG — QuickShot

Инженерный журнал. Новые записи сверху.

---

## 24.07.2026 — план стабилизации реализован

Полностью реализованы фазы 1-5 из `CAPTURE_ARCHITECTURE.md` и автоматическая
часть фазы 6.

Capture lifecycle больше не восстанавливается по текущему состоянию кнопки мыши:
`CaptureGestureBuffer` хранит полный ранний down/drag/up, а session-scoped
Carbon Escape остаётся зарегистрированным от принятия hotkey до idempotent
teardown. Snapshot provider вынесен за `ScreenSnapshotProviding`; production
по-прежнему получает свежие session-owned пиксели прямым one-shot вызовом,
не делает pixel-producing prewarm и отбрасывает отменённые, неполные,
дублированные и превышающие `120ms` multi-display batch.

Доставка получила монотонный `CaptureSequence`. Старый crop/encode больше не
может перезаписать новый clipboard или изменить порядок карточек.
`CaptureArtifactStore` создаёт один preview, один encode и не более одного PNG
на скриншот, переиспользует их для copy/Copy All/drag/pin/save, владеет
pasteboard/card/drag/pin leases, удаляет crash leftovers и ограничивает сессию
100 карточками или 1 GiB.

Tray order и viewport вынесены в `ThumbnailCollectionModel`. Width clamp
считается для текущего экрана, overflow следует к newest детерминированно, а
pointer routing обновляется после каждого layout/state/animation commit, чтобы
невидимая часть host-окна не удерживала рабочий стол.

Production и все тестовые бинарники переведены на Swift 6,
`-strict-concurrency=complete` и `-warnings-as-errors`. AppKit-владельцы
помечены `@MainActor`, а передаваемые между executor пиксели имеют явную
immutable Sendable-границу.

Native UI Design System опубликована как отдельный приватный репозиторий
`i-iii4/native-ui-design-system`. QuickShot фиксирует ревизию
`b2e7cb0ad13a05d39dfc8e6ded91ab86817b9869` и SDK `0.4.0` в
`NativeUIDependencies.lock`; build/test принимают один разрешённый путь и больше
не зависят от неявного sibling `node_modules`. GitHub Actions получает только
read-only deploy key.

`build.sh` теперь компилирует, подписывает и проверяет staging bundle. Только
после этого `renameatx_np(RENAME_SWAP)` атомарно заменяет приложение. Отдельные
прогоны с принудительным compiler, codesign и pre-install failure подтвердили,
что предыдущий валидный `QuickShot.app` остаётся байт-в-байт неизменным.

Первый чистый CI-run выявил toolchain-разницу, которую локальный linker не
показывал: Zig 0.16 создавал archive member без требуемого Apple linker
8-byte alignment. После каждого Zig build архив теперь канонически
пересобирается системным `libtool`; локальный и CI link используют одинаковую
Mach-O упаковку вместо зависимости от терпимости конкретной версии linker.

Runner также запускает AppKit с Reduce Motion. Интеграционный odometer-тест
раньше безусловно требовал вертикальный roll и поэтому противоречил самому
accessibility-контракту. Теперь он проверяет stationary crossfade при Reduce
Motion, а направление обычного roll независимо закреплено чистым
`odometerMotionState`-тестом.

Локально прошли:

- полный headless `scripts/test.sh`;
- 100 случайных порядков crop/encode completion;
- 100 fake-backend lifecycle;
- 100-artifact resource/cleanup stress;
- Native SDK contract и ReleaseFast render/dispatch gates;
- production Swift 6 build и `codesign --verify --deep --strict`;
- atomic replacement и три failure-preservation сценария.

Ручные проверки cursor appearance, fullscreen Spaces, реальных конфигураций
дисплеев и p50/p95 latency намеренно не запускались автоматически: они
перехватывают ввод и показывают capture UI на активном экране. Они остаются
последним release-gate для точной финальной сборки.

---

## 24.07.2026 — архитектурный аудит и полный план стабилизации

Проведён полный read-only аудит baseline `d54b267`: capture lifecycle,
ранний ввод, cursor/focus ownership, window protection, параллельная доставка,
clipboard/artifact lifecycle, tray overflow и pointer routing, concurrency,
тестовая стратегия, Native SDK dependency и production build.

Текущий `scripts/test.sh`, production-сборка и проверка подписи проходят, но это
не является release-доказательством. Аудит обнаружил три блокирующих дефекта:

- завершённый до готовности backdrop жест теряется;
- карточка и автоматический clipboard независимо кодируют один снимок, а
  временные PNG не имеют владельца и cleanup lifecycle;
- параллельные finishing sessions не имеют общего sequence contract, поэтому
  старый результат может завершиться после нового и перезаписать порядок или
  clipboard.

Дополнительно подтверждены ненадёжный ранний `Esc`, конкуренция pixel-producing
prewarm с пользовательским capture, fail-open окно в protection audit,
неразрешённая атомарность multi-display batch, конфликт абсолютного append-only
контракта с конечным viewport, отсутствие screen-width clamp, потенциально
устаревающий pointer routing, 538 strict-concurrency warnings, source-scanning
вместо lifecycle-тестов, неприкреплённая sibling-зависимость Native UI и
неатомарная сборка.

`CAPTURE_ARCHITECTURE.md` переведён из статуса «реализация принята» в честный
remediation status. Зафиксирован поэтапный план:

1. сначала воспроизвести P0-дефекты детерминированными headless-тестами;
2. ввести полноценный gesture buffer и ранний session-scoped Carbon Escape;
3. добавить монотонный capture sequence, delivery coordinator и единый
   artifact store с cleanup и ресурсным бюджетом;
4. убрать pixel-producing prewarm, сделать protection fail-closed и закрыть
   multi-display decision gate;
5. вынести tray order/viewport в чистую модель и закрепить pointer pass-through;
6. перейти на Swift 6 strict concurrency, pin Native UI revision, сделать
   атомарную сборку и CI;
7. пройти полный headless stress и отдельный ручной runtime/latency gate.

`PRODUCT_CONTRACT.md` уточняет поведение заполненного viewport: существующие
карточки не двигаются, пока есть свободный слот; после заполнения viewport
детерминированно следует к новому снимку, сохраняя старые элементы доступными
прокруткой. Также добавлены обязательные regression gates для раннего жеста,
порядка delivery, cleanup, resource bounds, strict concurrency и воспроизводимой
сборки.

Production-код в рамках аудита и документирования не изменялся.

---

## 23.07.2026 — foreground selector и pointer routing приняты

После ручной проверки актуальной сборки приняты два блокирующих исправления
из предыдущей записи: в режиме выделения отображается один кастомный crosshair,
а после завершения снимка полноэкранный tray-host сразу возвращает ввод рабочему
столу. Удаление всех карточек больше не требуется для освобождения экрана.

Контракт закреплён автоматическими проверками
`SelectionPresentationCoordinatorTests`, `CursorLeaseTests` и
`TrayPointerRoutingTests`: presentation раскрывается только после foreground
ownership, курсор имеет одного сбалансированного владельца, а прозрачная часть
tray-host остаётся mouse-transparent. Видимые проверки fullscreen Spaces,
необычных multi-display-конфигураций и временных порогов остаются отдельными
release-gates.

---

## 22.07.2026 — отклонён nonactivating selector, устранён screen lock

Ручная проверка опровергла nonactivating-архитектуру из предыдущей
записи. Логи показывали `overlay cursor lease acquired`, но визуально
системная стрелка оставалась рядом с кастомным crosshair. Официальная
документация Apple уточняет, что display-аргумент `CGDisplayHideCursor`
не имеет эффекта, а background-процессу в общем случае не гарантировано
право менять cursor visibility. Успешный return code не являлся
доказательством видимого результата.

Второй регресс блокировал рабочий стол после снимка. Frozen overlay при
этом закрывался нормально; блокировку создавал полноэкранный
tray-host. После добавления карточки `showHost()` делал его key, и пустая
прозрачная область оставалась mouse target до `Delete All`, когда всё окно
скрывалось.

Теперь frozen pixels по-прежнему создаются до смены focus, но presentation
раскрывается только после подтверждённого foreground ownership и одного
AppKit `CursorLease`. Activation rejection, loss или timeout за `500ms` закрывают
сессию до reveal; teardown сначала скрывает presentation, затем возвращает
курсор и фокус исходному приложению.

Tray-host больше не становится key при обычном показе. Пара global/local
mouse monitors переключает `ignoresMouseEvents`: окно интерактивно только
над реальным hub/card content, а во всех остальных точках и во время capture
полностью пропускает ввод. Добавлены state-machine и pointer-routing тесты;
итог ручной runtime-проверки зафиксирован в записи 23.07.2026 выше.

---

## 21.07.2026 — nonactivating selector, защищённый трей и overflow viewport

> История отклонённой попытки; актуальный вывод и замена описаны в записи 22.07.2026 выше.

Повторная проверка в долгоживущем процессе QuickShot опровергла прежнее
краткое runtime-acceptance. За четыре сессии direct snapshot занял `807ms`,
`240ms`, `2079ms` и `33ms`, а ожидание `NSApp.activate()` после готовности кадра
добавляло `1565ms`, `7ms`, `901ms` и `5705ms`. В этом окне selector
оставался невидимым, ранний drag терялся, а `NSCursor.hide()` не гарантировал
скрытие указателя активного исходного приложения. Отсюда первая
задержка и двойной курсор.

Активация удалена из selector path полностью. `OverlayWindow` теперь
`.nonactivatingPanel`, не может стать key/main и не меняет active application.
`SelectionPresentationCoordinator` владеет ровно одним `CursorLease`, а тот
вызывает единственную пару `CGDisplayHideCursor` / `CGDisplayShowCursor`.
После успешного acquire в одной транзакции включаются pointer input и frozen
presentation. `Esc` принимает session-scoped Carbon hotkey, поэтому key-window
для отмены не нужно.

Frozen backdrop и selection chrome разнесены по двум окнам. Между ними
находится исключённый из capture трей QuickShot: он остаётся видимым, но
верхний chrome получает весь pointer input. При teardown сначала исчезают
оба overlay-слоя и crosshair, затем возвращается system pointer.

Отдельно устранён overflow-дефект трея. Layout скрывал карточки после
первого не вместившегося слота, но `finishTrayMotion()` затем вызывал
`finishTrayTransition` для всех items. Скрытые окна возвращались со старыми
или default-координатами, часто около левого верхнего угла. Теперь трей
имеет конечный viewport: новый снимок всегда видим, старые снимки доступны
прокруткой, а animation completion завершает только текущие visible items.

Два параллельных
`CGWindowListCreateImage` конкурировали внутри одного WindowServer compositor.
Теперь дисплеи снимаются последовательно с autorelease boundary на каждый
full-resolution image. Один union-snapshot не используется: на mixed-DPI
desktop он теряет Retina-разрешение. Startup preparation теперь вызывает
тот же direct backend и ту же общую lane, но не сохраняет полученные пиксели.

Исследование кандидатов не дало честного способа убрать OS-owned latency tail.
Современный `SCScreenshotManager.captureImage(in:)` на этой машине показал
`p95 970ms`, `max 1238ms`. Свежий helper-process добавил отдельный TCC/startup
risk и один раз ждал около минуты. `CGDisplayCreateImage` и cold
`CGDisplayStream` также дали выбросы. Сериализованный production provider в
300-run burst показал `p95 50.24ms`, но один `max 7183ms`; paced probe тоже
ловил системные выбросы. Поэтому `120ms p95` остаётся runtime release-gate
и не объявляется выполненным по короткой удачной серии. Автоматические
проверки закрывают cursor ownership, nonactivation, z-order, startup preparation,
viewport geometry и скрытые terminal states; видимая runtime-проверка остаётся
ручным release-gate и на момент этой записи ещё не принята.

---

## 21.07.2026 — устранён недетерминированный двойной курсор

После перехода на frozen overlay курсором одновременно управляли три
независимых механизма: два `CGDisplayHideCursor` с отложенным вторым
вызовом, прозрачный AppKit cursor rect и кастомный `CALayer`. Активация
приложения была асинхронной, а системный курсор возвращался до
скрытия overlay-окон. Это давало три гоночных исхода: чистый крестик,
зафиксированный старый курсор или двойной курсор.

Теперь единственный session-owned `CursorLease` вызывает ровно один
`NSCursor.hide()` и один парный `unhide()`. Frozen-окна пререндерятся
прозрачными, cursor lease берётся до их показа, а сами окна атомарно
раскрываются только после `NSApplication.didBecomeActiveNotification`. При
завершении кастомный крестик и все окна сначала исчезают, и только
потом возвращается системный курсор. Все `SelectionView` дополнительно
делят одного владельца видимого крестика, поэтому крестик с предыдущего
дисплея не может остаться на frozen backdrop.

Добавлены `CursorLeaseTests` и static gates на единственного владельца,
баланс, порядок reveal/dismiss и запрет возврата CoreGraphics/transparent-
cursor механизмов. Полный `scripts/test.sh` проходит.
Краткая первичная проверка выглядела успешной, но повторная runtime-
серия выявила activation race; актуальное продолжение зафиксировано
в записи выше.

---

## 20.07.2026 — реализован direct freeze-first capture

Production capture переведён на `DirectScreenSnapshotProvider`. Провайдер через
изолированный runtime ABI вызывает `CGWindowListCreateImage`, параллельно снимает
активные дисплеи до показа окон QuickShot и возвращает immutable batch с ID
конкретной сессии. Кэша, прогретого stream, системного subprocess, временного PNG
и второго снимка после mouse-up больше нет.

`CaptureSession` теперь использует явный lifecycle
`snapshotting -> selecting -> delivering -> finished`. Перед показом overlay
проверяются session ID и полный набор дисплеев. Старый `SelectionView` сохранён:
статический frozen backdrop лежит отдельным слоем, а курсор, внутренняя заливка и
рамка отрисовываются лёгким chrome поверх него. На mouse-up выполняется только
crop session-owned изображения по его фактическому pixel size.

QuickShot активируется только после готовности frozen pixels, поэтому исходный
hover уже сохранён в изображении, а приложение может владеть вводом и скрыть
системный курсор. Все terminal paths балансируют cursor state, закрывают окна,
останавливают snapshot/crop tasks и кооперативно возвращают активацию исходному
приложению. Окна QuickShot не скрываются: перед capture централизованно
переприменяется `sharingType = .none` и выполняется fail-closed audit.

Добавлены `DirectScreenSnapshotProviderTests`, новые frozen lifecycle gates и
обновлённые opt-in runtime-проверки. `scripts/test.sh` и production build проходят.
Headless runtime probe на двух дисплеях (`3456x2234` и `5120x2880`) за десять
последовательных запусков показал `min 21.07ms`, `p95 50.97ms`, `max 50.97ms`.
Видимый cursor/fullscreen smoke намеренно оставлен ручным, поскольку его нельзя
честно доказать headless-тестом без перехвата пользовательского экрана.

---

## 20.07.2026 — системный selector откачен, восстановлен custom-selection baseline

Системный путь через `/usr/sbin/screencapture` снят с production-направления.
Даже с `-T0` его завершение зависело от внутреннего capture-стека macOS и в
реальном использовании оставалось непредсказуемым. Записи ниже сохранены как
история эксперимента, но больше не описывают целевую архитектуру.

Без полного отката репозитория из `931807b` восстановлены `Overlay.swift`,
`CaptureTypes.swift`, `CoordinateMath.swift`, `FreshRegionCapture.swift`,
selection-тесты и capture-скрипты. Поэтому готовые курсор, рамка, внутренний
overlay и их геометрические проверки не будут рисоваться заново. Последние
изменения трея, Native SDK UI, хоткея и централизованной защиты окон сохранены.

Восстановленные `CaptureController` и `FreshRegionCapture` являются только
компилируемым baseline. Следующий production-путь: свежий прямой CoreGraphics
snapshot в момент хоткея, статическая frozen-подложка, существующий custom
selector и crop того же изображения на mouse-up. Stream cache, системный PNG и
второй capture после выделения в целевой архитектуре отсутствуют.

План и Definition of Done зафиксированы в `CAPTURE_ARCHITECTURE.md`; продуктовый
контракт обновлён в `PRODUCT_CONTRACT.md`. До реализации direct snapshot provider
и прохождения runtime-gates capture не считается release-ready.

---

## 20.07.2026 — устранена системная задержка после выделения

`screencapture` без параметра `-T` использует стандартную задержку 5 секунд.
Из-за этого после mouse-up системный процесс ждал примерно пять секунд, хотя
декодирование PNG и добавление карточки занимали миллисекунды. Команда запуска
теперь явно содержит `-T0`; это закреплено unit- и static-проверками.

```text
/usr/sbin/screencapture -i -s -x -T0 <UUID.png>
```

Продуктовой задержки после выделения больше нет.

---

## 19.07.2026 — переход на системное выделение macOS

После инцидента с двойным курсором кастомный selection-flow удален из
production. Требования к собственному крестику, рамке и внутреннему
overlay отменены. Визуалом и вводом владеет macOS.

Единый `SystemCaptureSession` запускает без shell:

```text
/usr/sbin/screencapture -i -s -x -T0 <UUID.png>
```

Отсутствующий файл означает cancel; пустой или битый файл — failure. PNG
декодируется ImageIO вне main thread и является единственным источником
пикселей. Повторного ScreenCaptureKit-снимка, прогрева и кэша нет.
Xattr `com.apple.metadata:kMDItemScreenCaptureGlobalRect` структурно читается через
`getxattr` и `PropertyListSerialization` для выбора экрана.

Удалены `SelectionPanelPool`, `SelectionInputTap`, `OverlayController`,
`CursorLease`, `SessionEscapeHotKey`, `FreshRegionCapture`, кастомные selection-
тесты и скрипты с синтетическим вводом. Accessibility больше не требуется
для выделения.

Все окна QuickShot получают `sharingType = .none`; перед каждым запуском
защита централизованно переприменяется к `NSApp.windows`. Механизм помечен
Apple как legacy, поэтому добавлен отдельный opt-in A/B release gate. Его отказ
блокирует релиз и не включает скрытие трея или второй capture-path.
Обычный `scripts/test.sh` не запускает выделение и не перехватывает экран.

После первого запуска найден и исправлен fail-closed регресс: AppKit-объект окна
`NSStatusItem` хостится `MenuBarAgent` и не принимает `.sharingType = .none` как
окно QuickShot. Из-за его системный selector не запускался. Теперь protection
применяется к нему best-effort, а блокирующая проверка читает фактические
экранные surfaces WindowServer для PID QuickShot. Скрытые AppKit-объекты без
WindowServer surface больше не блокируют системный selector.

Второй runtime-дефект проявлялся как пустая карточка с одной тенью. ImageIO
возвращал ленивый `CGImage`, а session удалял исходный PNG до первой отрисовки.
Размеры были уже доступны, поэтому delivery ошибочно логировался как completed. Теперь
пиксели принудительно копируются в независимый bitmap до cleanup. Тест удаляет source PNG
перед чтением пикселя и проверяет, что снимок остался живым.

---

## 19.07.2026 — инцидент: не выполнен контракт живого hover и единственного курсора

### Проверяемый продуктовый контракт

Режим выделения должен одновременно выполнять все требования:

- мгновенно появляться поверх обычных и полноэкранных приложений;
- сохранять видимый hover и активное состояние исходного приложения;
- оставлять исходный экран живым до завершения выделения;
- показывать ровно один специально спроектированный курсор выделения;
- не передавать жест выделения исходному приложению и не изменять его состояние;
- получать свежие пиксели произвольной прямоугольной области;
- использовать только документированные публичные API, пригодные для долгосрочной поддержки.

Текущая ветка этот контракт не выполняет. Headless-тесты и подписанная сборка
проходят. В последней проверенной реализации event tap сохраняет hover,
блокирует передачу жеста исходному приложению и показывает overlay поверх
полноэкранного Space. Однако системная стрелка остается видимой под векторным
крестиком QuickShot. Двойной курсор является блокирующим дефектом.

### Хронология попыток и фактические результаты

1. **Выделение поверх зафиксированного изображения.** Ранние варианты
   ScreenCaptureKit сначала получали кадр или держали поток, а затем выполняли
   выделение поверх изображения. QuickShot надежно владел вводом и курсором, но
   появлялись непредсказуемая задержка, старые кадры из прогретого потока,
   системный индикатор захвата, дополнительная нагрузка и замороженный вместо
   живого исходный экран. Эту архитектуру заменили свежим снимком на mouse-up.

2. **Интерактивные неактивирующие полноэкранные панели.** Панели не вызывали
   `NSApp.activate`, однако становились целью указателя и меняли hit testing.
   Hover исходного приложения сбрасывался. Первоначально панели также
   ненадежно появлялись поверх полноэкранного Space другого приложения.
   Сохранение frontmost-приложения оказалось не равнозначно сохранению его
   hover и key-window appearance.

3. **Постоянно non-key и mouse-transparent панели с пассивным мониторингом.**
   Этот вариант сохранял владельца окна, но мог только наблюдать события.
   Глобальный `NSEvent` monitor не способен остановить жест до его доставки
   исходному приложению, поэтому требование отсутствия побочных кликов не
   выполнялось.

4. **Активный `CGEventTap`.** После разрешения Accessibility был добавлен
   заранее созданный tap. В состоянии покоя он пропускает события без изменений,
   а во время выделения блокирует движения, нажатия и drag до их доставки
   исходному приложению. Это устранило изменение исходного интерфейса и в
   проведенной live-проверке сохранило hover и работу поверх full-screen Space.

   Первая версия tap отключала его после каждой сессии. Отложенное уведомление
   об отключении могло прийти уже после запуска следующей сессии, поэтому
   overlay мигал или терял ввод. Tap переведен на жизненный цикл приложения:
   системное отключение по timeout или user input логируется и немедленно
   восстанавливается. Эта правка была необходима, но не решила владение видимым
   системным курсором.

5. **Скрытие курсора через Core Graphics.** Session-owned `CursorLease`
   симметрично вызывал `CGDisplayHideCursor` и `CGDisplayShowCursor`, повторно
   применяя скрытие после восстановления event tap. Live-проверка по-прежнему
   показывала системную стрелку. Apple документирует, что в большинстве случаев
   `CGDisplayHideCursor` влияет на видимый курсор только из foreground-
   приложения. QuickShot намеренно остается неактивным, поэтому успешный код
   возврата был ошибочно принят за доказательство реального скрытия курсора.

6. **Прозрачный AppKit-курсор из key non-activating panel.** Вызовы Core
   Graphics были удалены. Mouse-transparent `.nonactivatingPanel` становилась
   key без активации QuickShot, устанавливала прозрачный `NSCursor` и повторяла
   `set()` на отфильтрованных pointer events. Векторный крестик продолжал
   рисоваться отдельно. Две последовательные live-проверки снова показали два
   курсора: стрелку исходного приложения и крестик QuickShot. Локальный cursor
   stack не заменил курсор, фактически отображаемый для активного исходного
   приложения.

7. **Системный курсор и индикаторы по краям как fallback.** Эти варианты
   обсуждались, но не реализовывались. Они отклонены: стрелка, рука или I-beam
   не сообщают о режиме выделения области, а дополнительные индикаторы не
   исправляют курсор. Это нарушает уже согласованный UX-контракт.

### Почему проверки не предотвратили регресс

Статические тесты проверяли структуру исходного кода, балансировку cursor lease,
порядок запуска event tap и формальную геометрию крестика. Они не могли доказать:

- какой курсор WindowServer фактически показывает поверх другого приложения;
- сохраняется ли hover в реальном приложении;
- работает ли overlay в чужом full-screen Space;
- не получает ли исходное приложение события выделения;
- корректно ли восстанавливаются курсор и ввод после cancel или следующей сессии.

Зеленые headless-тесты и успешная сборка были ошибочно представлены как
достаточное подтверждение пользовательского поведения. Для этого дефекта
единственным доказательством является отдельная runtime-проверка полного
контракта.

### Подтвержденные границы публичных API

Проверка заголовков актуального macOS 26.1 SDK и документации Apple показала:

- `NSCursor.current` описывает курсор вызывающего приложения и может не
  совпадать с курсором, который отображается, пока активно другое приложение;
- `CGDisplayHideCursor` является публичным API, но в большинстве случаев
  требует foreground-приложение для изменения видимого курсора;
- `NSTrackingArea.Options.activeAlways` не доставляет `cursorUpdate`;
- `.nonactivatingPanel` гарантирует только отсутствие активации своего
  приложения, но не сохранение hover другого приложения и не передачу
  глобального владения курсором;
- `SCContentSharingPicker` выбирает приложения, окна и дисплеи, но не
  произвольную прямоугольную область.

Следовательно, сейчас не подтверждена ни одна документированная комбинация API,
которая одновременно оставляет исходное приложение живым и визуально hovered,
сохраняет QuickShot неактивным, блокирует доставку исходного ввода и глобально
заменяет курсор исходного приложения одним крестиком QuickShot.

### Исправление последнего анализа

После этих результатов интерактивная cursor-owning `.nonactivatingPanel` была
предложена как основной публичный вариант до изолированной проверки. Это было
необоснованно. Предыдущая live-проверка уже показала, что интерактивная панель
может сбросить hover, а документация Apple не гарантирует обратное. Этот вариант
нельзя называть решением без отдельного runtime proof на всех поддерживаемых
версиях macOS.

Capture-first поверхность с зафиксированным кадром остается технически
детерминированным публичным способом получить единственный курсор, но меняет
требуемый живой пользовательский опыт и поэтому не является решением без
компромиссов. Приватные WindowServer или SkyLight API и устаревшие capture API
не соответствуют ограничениям продукта и не должны предлагаться.

### Текущий статус и правило дальнейшей работы

Дальнейшую production-переделку нельзя начинать только на основании того, что
API выглядит подходящим. Новый кандидат сначала должен пройти изолированную
runtime-проверку:

- hover и active/key appearance исходного приложения сохранены;
- виден ровно один курсор;
- overlay работает поверх full-screen Spaces;
- жест выделения не изменяет исходное приложение;
- capture получает свежую выбранную область;
- cancel, повторная сессия и teardown полностью восстанавливают ввод и курсор.

До появления такого доказательства честный статус следующий: **требуемое
поведение не продемонстрировано на публичных долгосрочных API без компромисса
UX.**

---

## 17.07.2026 — попытка живого захвата без активации приложения

Первая попытка устранить регресс hover: selection path больше не вызывает
`NSApp.activate` и не создаёт полноэкранные окна при каждом hotkey. На старте
приложения `SelectionPanelPool` подготавливает по одной
`.borderless + .nonactivatingPanel` на дисплей; сессия только подключает свежий
`SelectionView`, показывает панели и возвращает их в пул.

Первый вариант всё ещё вызывал `makeKey()` после показа панели. Это сохраняло
frontmost application, но отнимало key-window status у исходного окна и поэтому
не гарантировало сохранение hover. Selection-панели теперь постоянно возвращают
`canBecomeKey == false`; вызовы `makeKey`/`makeFirstResponder` удалены из всего
overlay path. `Esc` обрабатывается отдельным session-scoped
`RegisterEventHotKey(kVK_Escape, 0)`, который не требует Accessibility или Input
Monitoring и снимается при teardown.

Повторный отложенный `CGDisplayHideCursor` заменён session-owned
`CursorLease`: каждый успешный hide симметрично закрывается одним show при
completion, cancel, shutdown или deinit. Headless-тесты проверяют повторный
release и аварийное освобождение lease без изменения реального курсора.

`SCShareableContent` теперь готовится параллельно пользовательскому выделению и
содержит только дескрипторы, не пиксели или stream frames. На mouse-up
`SCScreenshotManager` получает fresh region request. Фильтр обязательно
исключает всё приложение QuickShot; пустой exclusion fallback удалён, поэтому
невозможность исключения завершает попытку fail-closed.

Проверено: полный `./scripts/test.sh`, production `./build.sh`, подпись текущего
`QuickShot.app`. Live overlay smoke не запускался, чтобы не перехватывать
активный экран без явного запроса пользователя.

---

## 17.07.2026 — единая hover-сессия и interruptible motion трея

Ручное состояние `collapsed` отделено от временного представления. Hover на
хабе теперь раскрывает карточки, не меняя смысл следующего клика. Хаб, его ряд
команд и полные контейнеры карточек образуют одну hover-сессию: перевод курсора
на снимок больше не закрывает нижнее меню. Уход из всей области запускает общий
grace `180ms`; возврат отменяет именно актуальный таймер через generation guard.

Новый снимок в свёрнутом трее больше не раскрывает его постоянно. Карточка
появляется за `150ms`, остаётся полностью видимой `1.2s` и исчезает за `130ms`.
Hover удерживает её без лимита, а после ухода использует тот же grace. Tracking
перенесён на полный card container, включая resize band, поэтому между хабом и
карточкой нет мёртвой зоны.

Сворачивание карточек и шеврон используют один retargetable
`TrayProgressAnimator` с сохранением presentation velocity. Полёт полноразмерных
карточек заменён коротким axis-locked dissolve; opacity и shadow вычисляются из
абсолютного progress. Добавление, удаление и reflow выполняются одним
collection clock без stagger, а счётчик меняется вертикальным clipped-одометром
без скачков ширины.

Headless suite дополнен perceptual motion, collection terminal-state, odometer,
hover ownership и static architecture gates. Production и тесты используют
Native SDK `ReleaseFast`; live-window проверки остаются явным opt-in.

---

## 17.07.2026 — следующий capture не ждёт delivery предыдущего

После mouse-up selection admission освобождается до асинхронной доставки
изображения. Активная `selectionSession` отделена от `finishingSessions`, поэтому
следующий hotkey может сразу открыть новый overlay, пока предыдущий снимок
завершает fresh capture, clipboard preparation и thumbnail handoff. Каждая
finishing session сохраняется до собственного terminal outcome и затем
гарантированно закрывается.

Static capture gates проверяют разделение selection/delivery lifecycle и не
допускают возврата к одному глобальному session lock.

---

## 10.07.2026 — новые скриншоты занимают свободные слоты без reflow

Раскладка карточек больше не проходит `items.reversed()`. Порядок массива и
геометрии теперь совпадает: существующие карточки сохраняют свои координаты, а
новый снимок занимает следующий свободный слот по направлению от хаба. Для
текущего вертикального трея с нижним якорем это верхний слот; при зеркальном
якоре направление естественно станет нижним. Если места нет, новый индекс
попадает в overflow и скрывается, не вытесняя уже видимые карточки.

Расчет вынесен в чистый `ThumbnailLayout.swift`; headless-тесты проверяют все
четыре положения, неизменность прежних координат, направление роста и overflow.
Анимация добавления теперь применяется к `items.last`, а не к первому элементу
перевернутой раскладки.

---

## 10.07.2026 — переход интерфейса на House Dark

Все Native SDK surfaces переведены с Geist на фиксированный House Dark token
pack. Метрики хаба и карточек теперь читаются из House: small controls `28pt`,
радиус `8pt`, fast motion `120ms`; независимые команды сохраняют token spacing
`8pt`. Системные High Contrast и Reduce Motion продолжают проецироваться в
model-derived tokens, а системный Light/Dark больше не меняет выбранную темную
схему. Прозрачный canvas для плавающих surfaces сохранен.

Нейтральные команды используют темный House `secondary`, а не светлый
dark-theme `primary`. Hover bubble вынесен в отдельный Native SDK `panel` и
плавно проявляется под прозрачным bitmap кнопок; в покое его нет. House `xl`
radius `14pt` и inset `6pt` концентричны внутреннему control radius `8pt`.
Порядок действий зафиксирован слева направо (`Delete`, `Save As`, `Copy All`).

Устранена фундаментальная причина вялого reveal: каждый `mouseMoved` раньше
отменял текущий `CADisplayLink` и запускал полный цикл заново. Теперь один
целевой expansion state создает ровно один animation run; повторные события
игнорируются, а смена направления продолжает движение с длительностью,
пропорциональной оставшемуся пути.

Устранено залипание bubble после ухода курсора. Причиной была проверка
`mouseExited` по будущему expanded footprint: событие могло быть проигнорировано,
после чего изменившийся NSView уже не получал следующего движения. На время
hover-сессии устанавливаются local/global mouse monitors, которые проверяют
курсор относительно стабильного полного footprint независимо от текущей ширины
анимации. При выходе target всегда переключается на `0`; monitors снимаются при
закрытии, скрытии хаба и deinit.

---

## 09.07.2026 - production UI переведен на полный Native SDK interaction path

Проведен полный аудит hub, thumbnail, pinned, settings и status-menu surface-ов.
Все видимые command controls подтверждены как реальные Native SDK primitives;
AppKit оставлен только хостом окон, системного status item, изображений и
resize/drag интеграций.

Отдельно исправлена ошибка композиции: Geist `button-group` является
exclusive-choice register и намеренно заменяет child variants своим chrome.
Поэтому независимые hub/thumbnail commands переведены в обычные `row`, а
`button-group` оставлен только для model-owned выбора позиции в settings.
Правило добавлено в общий внешний contract, чтобы ошибка не повторялась в
других проектах.

Swift больше не маршрутизирует действия по тексту кнопки. `pointer_move`,
`pointer_down` и `pointer_up` передаются в Native SDK runtime, который владеет
hover, pressed, hit testing и typed dispatch. Метрики контролов и motion
читаются из pinned Geist tokens, а размеры thumbnail/pinned/settings/menu - из
фактических runtime semantics. Убраны лишние `+20pt`, исправлены 40pt icon
buttons внутри 32pt ряда и overflow settings/status menu.

Hover reveal сохраняет Geist fast motion `150ms`, не заканчивает изменение
ширины на 88% и раскрывает действия в одном порядке от core: `Delete`, `Save
As`, `Copy All`. Полный Native bitmap теперь строится один раз при переходе в
expanded state; display-link кадры двигают только frame/clip. Production build
линкует `ReleaseFast`, а Reduce Motion переключает длительность на ноль.

Добавлена проекция системных Light/Dark, High Contrast и Reduce Motion в
embedded runtime с pixel-тестом полного light -> dark -> light repaint.
`NativeSurfaceBehaviorTests` проверяет bounds, overlap, semantics, hover и клики
всех surface-ов без вывода окон. Live-window тесты стали явным opt-in через
`QUICKSHOT_RUN_LIVE_UI_TESTS=1`.

Проверено: внешний Native UI contract, `./scripts/test.sh`, first expanded
render <= 16.7ms, end-to-end first reveal frame <= 33.3ms, `./build.sh`
(`ReleaseFast`), production restart и системный лог без layout recursion,
Native UI errors или overflow.

---

## 09.07.2026 — документация сведена к рабочему контракту

Удалены два временных документа из активной документации. Отдельный файл про
interface model был лишним артефактом без статуса продукта, а capture redesign
plan дублировал уже реализованный UX-контракт.

`README.md` оставлен как короткая рабочая инструкция, `PRODUCT_CONTRACT.md` —
как источник требований и regression gates, `DEVLOG.md` — как журнал решений.
Требования к будущей UI-архитектуре оставлены только в контракте: новый shell
или framework не может ослабить capture UX, кликабельность controls, cursor
ownership, capture exclusion и свежесть финальных пикселей.

Production code в этой записи не менялся.

---

## 07.07.2026 — tray больше не скрывается перед fresh capture

Убран визуальный `orderOut`/restore для tray/hub перед созданием финального
снимка. Панель больше не должна мигать в момент capture completion.

`FreshRegionCapture` теперь строит `SCContentFilter` с исключением текущего
QuickShot application через `excludingApplications:exceptingWindows:`. Если
ScreenCaptureKit не отдаст current application, остаётся fallback по окнам
того же process ID; `window.sharingType = .none` остаётся дополнительной
защитой.

Regression gates обновлены: возврат `HiddenAppWindows`/`orderOut` в fresh
capture path считается регрессом, а app-exclusion filter стал обязательным.

Проверено: `./scripts/test.sh`, `git diff --check`, `./build.sh`.

---

## 07.07.2026 — live selection и fresh region capture после mouse-up

Capture hot path переписан под UX-контракт: hotkey теперь сразу создаёт live
selection overlay, без ожидания frozen кадра и без внешнего затемнения. До
начала drag визуально остаётся только кастомный курсор; лёгкий overlay рисуется
внутри выбранной области.

`ScreenFreezePipeline` удалён из product source set. Финальные пиксели теперь
получает `FreshRegionCapture`: после mouse-up overlay закрывается, затем
ScreenCaptureKit делает fresh capture выбранного прямоугольника. Старые
cached/stream frames больше не являются fallback-источником результата.

Regression gates инвертированы под новый контракт: тесты требуют
`beginLiveSelection`, `FreshRegionCapture.capture`, внутренний overlay без
full-screen dim, отсутствие frozen/stream path в активном коде, кликабельность
hub/thumbnail controls и fresh-region observability.

Проверено: `./scripts/test.sh`, `git diff --check`, `./build.sh`. Runtime
overlay/hotkey проверка не запускалась, чтобы не перехватывать активный экран.

---

## 06.07.2026 — документация сведена к UX-контракту capture

Документация очищена от описания внутренней capture-архитектуры как продукта.
Актуальный контракт теперь описывает только пользовательский опыт: hotkey
мгновенно вводит в selection mode, до drag экран визуально не меняется, а
overlay появляется только после начала выделения.

Зафиксирована новая инверсия overlay: больше нет внешнего затемнения вокруг
выделения как целевой модели. Лёгкий overlay должен жить внутри выбранного
прямоугольника, оставляя внешний экран визуально нетронутым.

UX-first план был временным рабочим артефактом; позже он свёрнут обратно в
основной контракт. Production code в этой записи не менялся.

---

## 06.07.2026 — третий capture после двух thumbnails не должен мигать tray

Live-log показал, что при двух снимках в tray третий hotkey не терялся:
`hotkey event received`, `capture trigger accepted`, `capture freeze pending`.
Срыв происходил в freezer: `capture stream fresh frame missed displays=3:stale`
примерно через `150 ms`. Tray мигал потому, что `CaptureSession.start` успевал
скрыть окна QuickShot перед freeze, затем ошибка восстанавливала hidden windows
без overlay.

Причина не в кликабельности tray и не в GlobalHotKey. Display stream может не
прислать post-hide `SCFrameStatus.idle` в коротком бюджете, особенно когда
видимое изменение состоит только из окон QuickShot, уже исключённых из capture
через `NSWindow.sharingType = .none`.

`ScreenFreezePipeline` теперь сохраняет строгий первый путь: post-hide complete
или post-hide idle heartbeat. Если heartbeat не пришёл вовремя, freezer делает
fresh `SCScreenshotManager.captureImage` fallback. Старый stream buffer больше
не принимается без post-hide подтверждения.

Regression gates обновлены, чтобы требовать fresh one-shot fallback и запрещать
`latest-active-stream` acceptance. Первичные попытки с `2.5 s` age-limit и затем
unbounded latest-active stream были неверными: первая снова падала на
`display=1:stale`, вторая реально отдала кадр с `maxAgeMs=132024`.

---

## 06.07.2026 — hotkey не должен срываться на static display idle

Live-log по жалобе "hotkey только мигает" показал, что Carbon hotkey приходит
сразу: `hotkey event received`, затем `capture trigger accepted`. Срыв был ниже
по стеку: `capture stream fresh frame missed displays=1:stale`, после чего
`CaptureController` показывал `requestUserAttention`, визуально похожий на
мигание приложения.

Причина: stream freezer принимал только `SCFrameStatus.complete`. На статичном
дисплее ScreenCaptureKit может прислать `SCFrameStatus.idle`: по SDK это значит,
что новый frame не создан, потому что display не изменился. Игнорировать такой
статус нельзя: complete pixel buffer может быть старше trigger, но post-hide
idle heartbeat доказывает, что эти pixels всё ещё актуальны.

`ScreenFreezePipeline` теперь хранит `latestIdleHeartbeats` отдельно от
complete `CVPixelBuffer`. Freshness gate принимает complete frame с
`receivedAt >= acceptedAfter` или старший complete buffer, подтверждённый
`idleAt >= acceptedAfter`. Старый stale-cache путь не возвращался: без post-hide
complete/idle подтверждения capture по-прежнему быстро падает и запускает
background maintenance.

Обновлены static gates в `CaptureHotPathStaticTests` и
`ScreenFreezePipelineBehaviorTests`: они теперь требуют обработку
`SCFrameStatus.idle`, раздельный idle heartbeat state и observability поля
`freshness`/`pixelAgeMs`.

Проверено: `./scripts/test.sh`, `./build.sh`, `git diff --check`. Актуальный
`QuickShot.app` перезапущен; startup log подтвердил hotkey registration,
persistent stream prewarm и first idle heartbeat для обоих displays.

---

## 05.07.2026 — stream freezer переделан без полумер

Предыдущая stream-backed попытка была признана неудачной: hot path всё ещё мог
вызвать `SCShareableContent.current`, затем упасть в one-shot fallback и дать
`capture overlay ready` около 10 секунд. Это противоречило самой цели горячего
stream UX.

`ScreenFreezePipeline` переписан как persistent stream freezer. `SCStream`
держится активным всё время работы QuickShot; idle stop удалён. Hot capture path
теперь только проверяет, что stream уже warm, ждёт complete frame с
`receivedAt >= acceptedAfter`, конвертирует его в frozen `CGImage` и возвращает
backdrop. `SCShareableContent.current` остался только в startup/background
stream refresh. `SCScreenshotManager.captureImage` полностью удалён из
активного freezer.

Если fresh frame не пришёл за `150 ms`, capture быстро завершается ошибкой и
планирует background maintenance; foreground one-shot fallback больше не
допускается. Цена решения - постоянный macOS screen-capture indicator, пока
QuickShot запущен.

Regression gates обновлены: hot path теперь явно запрещает
`SCShareableContent.current`, `SCScreenshotManager.captureImage`, `source=one-shot`,
idle-stop поля и старые stale-cache маркеры.

---

## 05.07.2026 — capture переведён на short-lived stream-backed freezer

После исследования задержки one-shot `SCScreenshotManager.captureImage` стало
понятно, что он сам даёт 0.6-3s на full-display capture и даже tiny capture
может занимать больше секунды. При этом уже запущенный `SCStream` отдаёт frames
примерно каждые 15-22 ms. Поэтому freeze path переведён с буквального
Mio-style one-shot на stream-backed fresh-frame-first архитектуру.

`ScreenFreezePipeline` теперь держит коротко прогретый `SCStream` per display,
принимает только `SCFrameStatus.complete`, хранит последний `CVPixelBuffer` и
на hotkey принимает только frame с `receivedAt >= acceptedAfter`, где
`acceptedAfter` идёт после trigger и после скрытия окон QuickShot. Если свежий
stream frame не пришёл за `120 ms`, pipeline не принимает старую картинку, а
падает обратно на one-shot `SCScreenshotManager.captureImage` с batch cap `3`.

Чтобы не получить вечный системный screen-capture indicator, warm streams
останавливаются после `30 s` idle window. Это даёт быстрый UX для запуска и
серии снимков, но не превращает приложение в постоянную запись экрана.

Обновлены `CaptureHotPathStaticTests`, `ScreenFreezePipelineBehaviorTests` и
`scripts/test.sh`: stream и `CVPixelBuffer` теперь разрешены только вместе с
freshness gate, complete-frame проверкой, idle stop и one-shot fallback; старые
unsafe stale-cache маркеры по-прежнему запрещены.

Проверено: `./scripts/test.sh` и `./build.sh`.

---

## 05.07.2026 — задокументирован latency baseline Mio-style freeze-first

После перезапуска актуального билда и log-only проверки зафиксирован текущий
performance baseline без синтетического управления экраном. Freeze-first путь
больше не показывает старый кадр и больше не даёт 2-3s ожидание в обычном
warm-path, но до целевого бюджета ещё далеко.

Замер текущих логов: `capture overlay ready` стабильно держится примерно в
диапазоне 590-660 ms, последний замер 630 ms, стабильное среднее после первых
трёх попыток около 644 ms. `capture display ready` даёт стабильное среднее
около 551 ms, `capture frozen ready` около 599 ms, а `capture overlay
constructed` около 45 ms. Ранние выбросы были около 1.24s и 1.75s.

Вывод: главный оставшийся тормоз находится в ScreenCaptureKit one-shot path,
скорее всего внутри `SCScreenshotManager.captureImage`, а не в AppKit overlay.
Следующий speed work должен сначала проверить и усилить prewarm, затем разнести
логами `SCShareableContent.current` и сам `SCScreenshotManager.captureImage`.
Если после этого one-shot capture остаётся около 500-600 ms, sub-200 ms UX
потребует отдельного решения с persistent stream/cache, а не косметической
полировки overlay.

---

## 05.07.2026 — production path снова приведён к Mio freeze-first architecture

После уточнения требования убран гибридный visible-start путь. Production capture теперь снова следует
Mio-порядку: `CaptureSession.start` скрывает окна QuickShot, запускает fresh full-display freeze и
создаёт selection overlay только после `capture frozen ready`, передавая готовые backdrops в
`beginFrozenSelection`.

`ScreenFreezePipeline` также приближен к исходной Mio-структуре: full-display freeze использует
`SCShareableContent.current` и прямой `SCScreenshotManager.captureImage`, prewarm делает тот же 2x2
dummy capture без искусственного timeout-race, display batch cap остаётся `3`. Удалены production
hooks для `beginLiveSelection`, `installFrozenBackdrops`, `PendingSelection`, `CaptureImageRace` и
активных freeze timeouts.

Regression gates теперь запрещают hybrid live-overlay-before-freeze path и проверяют, что overlay
создаётся только после готовых frozen screenshots. Предыдущие записи от 05.07 про visible-start и
background freeze timeout считаются superseded этой записью.

Проверено: `./scripts/test.sh` и `./build.sh`.

---

## 05.07.2026 — hotkey/menu больше не блокируются ожиданием fresh freeze

После перехода на Mio-style `SCScreenshotManager.captureImage` обнаружился жёсткий UX-регресс:
если full-display screenshot не успевал в bounded timeout, hotkey и menu command выглядели как
полностью нерабочие. Live-log показывал `capture freeze failed ... ScreenCaptureKit screenshot timed
out`, но пользователь не видел даже selection overlay, потому что previous implementation снова
сделала путь freeze-first-only.

State machine возвращён к visible-start контракту без возврата старого stale-cache риска: capture
сразу скрывает окна QuickShot, показывает `beginLiveSelection`, затем запускает `ScreenFreezePipeline`
и устанавливает fresh frozen backdrops через `installFrozenBackdrops`. Если пользователь завершил
selection раньше готовности fresh frame, selection сохраняется как `PendingSelection`, fullscreen
overlay сразу dismiss'ится, а crop/delivery продолжаются только после `capture frozen ready`.

`CaptureHotPathStaticTests`, `scripts/test.sh`, `README.md` и `PRODUCT_CONTRACT.md` обновлены, чтобы
будущий regression gate требовал порядок visible-start -> fresh freeze, а не закреплял молчаливое
ожидание ScreenCaptureKit.

Проверено: `./scripts/test.sh` и `./build.sh`.

---

## 05.07.2026 — background freeze timeout больше не сносит активный overlay

Ручная проверка показала следующий дефект: overlay появлялся, через секунду исчезал, и дальше ничего
не происходило. Live-log подтвердил `capture freeze failed ... ScreenCaptureKit screenshot timed out`
примерно через 0.9-1.9s. Причина была в том, что active full-display freeze использовал тот же
direct-manipulation timeout, что и видимый старт, хотя после `beginLiveSelection` это уже фоновая
работа.

Active freeze timeout увеличен до 6s как background failure ceiling; tiny prewarm остаётся 500ms.
`freezeFailed` больше не dismiss'ит overlay во время активного выбора: ошибка сохраняется как
`freezeFailure` и применяется только если selection уже завершён и ждёт fresh frame. Так медленный
ScreenCaptureKit больше не превращает hotkey/menu capture в “overlay мигнул и исчез”.

Regression gates обновлены: `ScreenFreezePipelineBehaviorTests` теперь требует длинный bounded
active-freeze budget, а `CaptureHotPathStaticTests` запрещает dismiss overlay внутри `freezeFailed`.

Проверено: `./scripts/test.sh` и `./build.sh`.

---

## 05.07.2026 — capture-flow переведен на Mio-style fresh freeze

После исследования Mio и macshot старый live-frame cache путь заменен на более простой
freeze-first contract: QuickShot скрывает свои окна, делает fresh full-display snapshots через
`SCScreenshotManager.captureImage`, затем показывает overlay уже поверх immutable frozen pixels.
Это сознательно убирает класс регрессов, где повторный снимок мог получить старую картинку из
кеша. Новый владелец нижнего слоя - `ScreenFreezePipeline`; старый `ScreenFrameCache` удален.

Архитектура сохраняет наши UI-контракты поверх Mio-подхода: overlay по-прежнему использует точные
`NSScreen.frame`, не учитывает Dock/menu bar, остается Space-scoped, скрывает системный курсор и
рисует собственную cursor/frame систему с clean separator. Для быстрого hotkey+drag до появления
overlay сессия временно трекает pre-overlay mouse-down и передает seed point в selection tool.

Regression gates обновлены под новую реальность: `ScreenFreezePipelineBehaviorTests` фиксирует tiny
2x2 prewarm, display batch cap `3` и bounded capture timeout; `CaptureHotPathStaticTests` теперь
требует freeze-before-overlay ordering, `SCScreenshotManager.captureImage`, `showsCursor = false`,
удаление старой cache-лексики из активных контрактов и сохранение off-main crop / prepared clipboard
handoff. `README.md`, `PRODUCT_CONTRACT.md` и log-only `verify-capture-observed.sh` тоже переведены
на fresh-freeze terminology.

Проверено: `./scripts/test.sh` и `./build.sh`.

---

## 04.07.2026 — active capture больше не принимает pre-request pixels

Закрыт путь, где повторный снимок мог получить старое состояние экрана: `ScreenFrameCache` принимал
cached frame как `responsive` или `validated`, даже если pixel buffer был создан до нового capture
request. Это было быстрым компромиссом для статичного desktop, но нарушало главный UX-контракт:
пользователь просит снимок текущего состояния, а не ближайшего старого кадра.

Теперь active capture принимает live stream frame только при `updatedAt >= requestedAt`, а prepared
frozen image тоже может быть использован только если создан после текущего request. `validatedAt`
остаётся только сигналом maintenance/stream-health; он больше не является основанием показывать
pre-request pixels. Логи accepted frame теперь допускают только `source=post-request`, а shell
verifier'ы падают при `source=responsive` или `source=validated`.

`ScreenFrameCacheBehaviorTests`, `CaptureHotPathStaticTests` и `scripts/test.sh` обновлены под новый
инвариант: даже кадр на миллисекунды старше request должен быть отвергнут и отправлен в fresh
stream/snapshot recovery, а не стать frozen backdrop.

---

## 04.07.2026 — crop ушёл с main mouse-up path

Повторный снимок после completed capture мог визуально задерживать выделенную рамку после `mouseUp`:
`completeSelection` уже вызывал `overlay.dismiss()` до delivery, но затем сразу же делал
`FrozenScreen.crop(globalSelection:)` на MainActor в том же mouse-up turn. Если `CGImage.cropping`
занимал заметное время, WindowServer не получал шанс убрать overlay до возврата run loop, и для
пользователя это выглядело как задержка завершения выделения.

Теперь `completeSelection` только валидирует selection, dismiss'ит overlay, восстанавливает окна,
логирует `capture end outcome=completed` и планирует `scheduleCropAndDelivery`. Сам crop выполняется
на background `DispatchQueue.global(qos: .userInitiated)`, а на main queue возвращаются только лог
`capture crop complete` и handoff в thumbnail/clipboard path. Через background boundary передаётся
display id, а не `NSScreen`, чтобы не тащить non-Sendable AppKit объект в background closure.

`CaptureHotPathStaticTests` и `scripts/test.sh` теперь запрещают `.crop(globalSelection:)` внутри
`completeSelection`, требуют background crop queue, лог `capture crop failed` для async-ошибки и
повторное разрешение target screen на main queue перед delivery.

Дополнительно выровнен реальный task priority с логическим `RefreshPriority`: active capture
recovery остаётся `.userInitiated`, а maintenance и post-capture `idle` refresh запускаются как
`.utility`. До этого `allowsStreamRestart: false` защищал от destructive stream restart, но сама
idle-задача всё равно стартовала с userInitiated priority и могла конкурировать с background crop
или доставкой только что сделанного снимка.

---

## 04.07.2026 — rect snapshot recovery получил hot-path budget и cooldown

Probe нижнего слоя показал системный отказ: `CGPreflightScreenCaptureAccess()` возвращал `true`, но
все варианты `SCShareableContent` отдавали пустой `displays`, `SCScreenshotManager` падал
`SCStreamErrorDomain -3811`, а `/usr/sbin/screencapture -x -R ...` тоже не мог создать rect image.
При такой внешней поломке QuickShot не должен на каждом повторном capture платить старый
2-секундный `rectSnapshotTimeoutNanoseconds` после `mouseUp`.

`rectSnapshotTimeoutNanoseconds` ужат до короткого active-path бюджета, а `ScreenFrameCache` теперь
помнит recent rect-snapshot failure через `recentRectSnapshotFailure`. Пока действует
`rectSnapshotFailureCooldown`, повторный `rectSnapshotFrozenScreen` логирует
`capture cache rect snapshot skipped` и сразу возвращает `nil`, переводя сессию в typed
`captureStackUnavailable`, вместо повторного зависания на системном screenshot API. Успешный
shareable-content display listing или успешный rect snapshot очищает failure state.

Отдельно добавлен `recentShareableDisplayFailure`: пустой `SCShareableContent.displays` тоже
становится health-состоянием, а не просто строкой в логах. Пока действует
`shareableDisplayFailureCooldown`, active capture логирует `capture cache shareable content skipped`
и не прогоняет заново весь retry-chain `SCShareableContent` после уже доказанного no-displays state.
Успешный display listing очищает этот failure отдельно от rect-snapshot health.

Чтобы первый пользовательский жест не был первым местом, где мы обнаруживаем отказ fallback, пустой
`SCShareableContent.displays` теперь запускает background health probe: tiny 16x16
`captureScreenshot(rect:)` через `scheduleRectSnapshotProbe`. Probe owner-scoped через
`rectSnapshotProbeInFlight`, логирует `capture cache rect snapshot probe failed` и записывает тот же
cooldown state, который потом пропускает active-path rect snapshot.

Если active capture приходит пока health probe ещё выполняется, `rectSnapshotFrozenScreen` проходит
через async `shouldAttemptRectSnapshotRecovery`: он коротко joins probe (`rectSnapshotProbeJoinNanoseconds`),
но не запускает второй `SCScreenshotManager` fallback параллельно. Если probe не успел завершиться,
active path логирует `previousFailure=probe-in-flight` и уходит в typed failure вместо новой
многосекундной задержки.

В `CaptureSession` старый безымянный `6_000_000_000` заменён на named
`frozenFrameWaitNanoseconds`, чтобы frozen wait был явным direct-manipulation budget, а не скрытой
многосекундной парковкой.

Ещё одна граница стала typed: `ScreenFrameCache.start` больше не возвращает голый `Bool`.
`StartResult.unavailableReason` принадлежит cache layer и передаётся в rect snapshot recovery и
`CaptureError.captureStackUnavailable`. `CaptureSession` больше не собирает reason из догадки
`shareable content unavailable...`, когда cache уже знает точную причину.

Regression coverage:
`ScreenFrameCacheBehaviorTests` проверяет короткий rect-snapshot timeout и cooldown semantics.
`CaptureHotPathStaticTests` и `scripts/test.sh` запрещают возвращать старые multi-second constants
для active frozen wait / rect snapshot recovery, требуют `shouldAttemptRectSnapshotRecovery` и
background probe при пустом display listing, запрещают дублировать fallback, пока probe уже
in flight, требуют `StartResult` вместо bare `Bool` на cache startup boundary и защищают
`recentShareableDisplayFailure` как отдельный cooldown для repeated display-list failures.

---

## 04.07.2026 — pending/registered stream больше не считается usable cache

`ScreenFrameCache.start()` раньше возвращал success, если нужный display был в `startingDisplays`,
или если `CachedDisplayStream` уже лежал в `streams`, но `startCapture()` ещё не завершился. В узком
окне между началом prewarm/startup, регистрацией stream и реальной готовностью active capture мог
решить, что cache usable, а затем ждать fresh frozen frame до длинного frozen-frame deadline. Это
снова создавало риск задержки, только уже не в UI path, а в cache-ownership semantics.

Теперь `hasUsableCache` учитывает только real frame, prepared image или stream, явно отмеченный в
`startedDisplays` после успешного `startCapture()`. Pending startup отделён в `hasPendingStartup` и
`waitForUsableCacheOrFinishedStartup`: если другой startup уже идёт, active capture ждёт только
короткое bounded окно готовности stream. Если source за это окно не стал usable, путь возвращает
`false`, и `CaptureSession` переходит в cache-owned rect snapshot recovery / typed failure вместо
ожидания полного frozen-frame timeout на чужом startup.

Regression coverage:
`CaptureHotPathStaticTests` и `scripts/test.sh` запрещают считать `startingDisplays` или raw
`streams[id]` usable cache, требуют `startedDisplays`/`markStreamStarted` ownership gate и bounded
pending-startup wait plus log line
`capture cache pending startup did not become ready before short wait`.

---

## 04.07.2026 — startup prewarm стал owned lifecycle task

`CaptureController.prewarmCapturePipeline()` раньше запускал startup-prewarm как detached work без
явного owner'а. `ScreenFrameCache.shutdown()` уже защищал cache от позднего stream recreation через
`isShuttingDown`, но сам controller всё ещё мог получить поздний permission-state update от старого
prewarm после shutdown или после нового prewarm-запуска.

Теперь `CaptureController` хранит `prewarmTask` и `prewarmID`. Новый prewarm сначала отменяет старый,
shutdown отменяет owned prewarm, очищает task и инвалидирует id, а completion обновляет
`hasScreenCaptureAccess` только если id всё ещё актуален. Так startup prewarm стал частью того же
явного lifecycle, что active `CaptureSession` и `ScreenFrameCache`.

Regression coverage:
`CaptureHotPathStaticTests` и `scripts/test.sh` требуют owned `prewarmTask`, `prewarmID`,
cancel-before-new-prewarm, stale-completion guard и cancellation в `CaptureController.shutdown()`.

---

## 04.07.2026 — delivery после mouse-up вынесен из жеста

Новый вариант задержки проявился уже после готового выделения: на повторном снимке пользователь
отпускал мышь, мог двигать курсором, но выделенный rect визуально оставался ещё 2-3 секунды. Даже
если `overlay?.dismiss()` вызван в коде, AppKit не успевает реально убрать fullscreen window с
экрана, пока тот же main-thread turn занят синхронным PNG/TIFF-кодированием, записью временного
fileURL payload и раскладкой screenshot-card UI.

`CaptureSession.completeSelection` теперь после crop сразу завершает session: dismiss overlay,
restore hidden windows, `capture end outcome=completed`, post-capture prewarm. Image handoff
запускается только после `Task.yield()` на MainActor, чтобы compositor получил шанс убрать overlay.
`CaptureController.deliverCapturedImage` добавляет thumbnail отдельно, а clipboard payload готовит
через централизованный `Clipboard.prepareImage(... completion:)`: ImageIO-кодирование и запись
временного fileURL уходят на global queue, а на main возвращается только уже подготовленный
PNG/TIFF/fileURL payload для публикации в `NSPasteboard`.

Следом тот же payload contract распространён на остальные входы: thumbnail copy, `Copy all`,
pinned-window copy и drag-out. `Clipboard.PreparedImage` стал единой структурой для PNG/TIFF/fileURL,
`Clipboard.pasteboardItem(preparedImage:)` — единым builder'ом для drag/multi-copy, а карточки и
pinned windows заранее прогревают payload в background task. Production controls больше не вызывают
`NSBitmapImageRep(cgImage:)`, `tiffRepresentation` или `Clipboard.copy(cgImage:)` прямо из click/drag
handlers; fallback-подготовка, если cached payload ещё не готов, идёт через централизованный
`Clipboard.prepareImage(... completion:)`, который кодирует payload на global queue и возвращается на
main только для публикации в pasteboard/feedback.
Сами synchronous convenience API `Clipboard.copy(cgImage:)` и `Clipboard.copyAll(cgImages:)` удалены,
чтобы future call sites не могли снова обойти prepared-payload boundary.

Regression coverage:
`CaptureHotPathStaticTests` требует, чтобы completed capture dismiss'ил overlay и вызывал `end()` до
image handoff, запрещает синхронный `onImage(cropped, screen)` в `completeSelection`, и проверяет,
что capture delivery использует centralized async `Clipboard.prepareImage`, а `capture clipboard
copied` логируется только после `Clipboard.copy(preparedImage:)`. Дополнительно тест и
`scripts/test.sh` запрещают direct AppKit PNG/TIFF encoding и synchronous `Clipboard.copy(cgImage:)`
в thumbnail/pinned production paths, а также возвращение synchronous image-copy convenience API в
сам `Clipboard`.

---

## 04.07.2026 — legacy RegionCapturer удалён из production architecture

После переноса production capture на `ScreenFrameCache` в дереве оставался старый `RegionCapturer`
с отдельным `captureFull` через `SCScreenshotManager`. Он уже не вызывался, но сохранял второй
концептуальный capture path рядом с текущей архитектурой и мог вернуть будущий обход freshness,
typed-failure и timeout policies.

Общие типы вынесены в `CaptureTypes.swift`: `CaptureError` и `FrozenScreen.crop`. Legacy
`RegionCapturer.swift` удалён. `scripts/test.sh` и `CaptureHotPathStaticTests` теперь явно запрещают
возврат `RegionCapturer`/`captureFull` в `Sources`.

После удаления legacy path из `CaptureError` также убраны старые `exclusionUnavailable` и untyped
`failed(Error)`: они относились к `RegionCapturer`-era exclusion/screenshot wrapper и больше не
представляют текущую production architecture. Контракт post-capture preparation также уточнён:
idle prepare остаётся stream-only и не имеет права готовить snapshot/prepared-image work.

Ещё одна наружная failure boundary переведена с generic cache timeout на
`captureStackUnavailable`: если active stream wait истёк без fresh frozen frame, пользовательский
outcome теперь получает reason `fresh stream frame unavailable before timeout`. Внутри
`ScreenFrameCache` остались только private `RectSnapshotTimeout`/`SnapshotTimeout`, а общий
`CaptureError` больше не содержит internal cache timeout case.

Интерактивные verifier-скрипты теперь тоже защищены архитектурной границей: `verify-capture-runtime`,
`verify-capture-selection-output` и `verify-capture-cold-start` отказываются постить synthetic
hotkey/mouse events без `QUICKSHOT_ALLOW_SYNTHETIC_INPUT=1`. `verify-capture-observed` и
`probe-screen-capture-stack` остаются log/probe-only и `scripts/test.sh` запрещает добавлять в них
`CGEvent`/`cghidEventTap`.

---

## 04.07.2026 — mouse-up больше не держит overlay на повторном capture

Новый симптом был уже не в появлении overlay: первый снимок после запуска был мгновенным, но после
реально сделанного снимка следующий `mouseUp` оставлял выделенный прямоугольник висеть на экране ещё
2-3 секунды. По коду это происходило в `selectionCompleted`: если frozen frame ещё не готов,
selection сохранялся в `pendingSelection`, но overlay оставался видимым до `freezeCompleted`.

Поведение разделено на две части. Завершённый пользовательский жест теперь закрывает overlay сразу:
`selectionCompleted` записывает `pendingSelection`, логирует
`capture pending selection awaiting frozen frame` и dismiss'ит overlay. Сессия при этом не
заканчивается: QuickShot-окна остаются скрытыми, frozen frame догоняет в фоне, и crop выполняется
по тому же frozen image, когда он готов. Так требование freeze-screen сохраняется, но пользователь не
смотрит на застывший selection после отпускания мыши.

Вторая причина задержки была в post-capture архитектуре. После успешного снимка idle-path запускал
speculative `SCScreenshotManager.captureImage` через joinable prepared task. На следующем capture
эта работа могла конкурировать со stream recovery и превращаться в ровно ту 2-3-секундную паузу.
Post-capture prepare теперь stream-only: он только мягко просит/валидирует live `SCStream` frame
(`allowsStreamRestart: false`) и больше не создаёт `preparedFrozenScreenTask`. Capture-time snapshot
fallback остался как recovery, но стартует только после stream-validation grace
(`streamSnapshotDelayNanoseconds` > `refreshEscalationDelayNanoseconds`), чтобы обычный stream успел
закрыть статичный desktop без дорогого screenshot API.

Regression coverage:
`CaptureHotPathStaticTests` проверяет immediate dismiss pending selection, запрет joinable
post-capture snapshot tasks и stream-only prepare. `ScreenFrameCacheBehaviorTests` проверяет, что
snapshot fallback ждёт stream validation grace. Stream-owned `SCScreenshotManager.captureImage`
fallback также получил свой timeout, чтобы поздняя fallback-задача не оставалась подвешенной за
пределами active capture. `scripts/test.sh` дублирует эти gates.

---

## 04.07.2026 — system capture-stack failure больше не маскируется под noDisplay

Диагностический probe показал отдельный нижний отказ macOS: `CGPreflightScreenCaptureAccess()`
возвращал `true`, `SCShareableContent` отдавал windows/apps, но `displays` были пустыми; при этом
`SCScreenshotManager.captureScreenshot(rect:)` падал `SCStreamErrorDomain -3811`, а системный
`/usr/sbin/screencapture` тоже не мог создать rect image. Это не сценарий “нет монитора” и не
ошибка UI QuickShot.

Добавлен typed `CaptureError.captureStackUnavailable(String)`. Если shareable-content recovery не
даёт usable cache и cache-owned rect snapshot тоже не сработал, `CaptureSession` завершает путь через
`captureStackUnavailable` с cache-owned reason plus `rect snapshot failed`. `CaptureController`
логирует `capture stack unavailable` и показывает одно немодальное уведомление, защищённое
`didNotifyCaptureStackFailure`, через `NSApp.requestUserAttention(.informationalRequest)` вместо
молчаливого `NSLog` или повторяющегося modal alert.

Regression coverage:
`CaptureHotPathStaticTests` и `scripts/test.sh` требуют typed failure, explicit reason и nonmodal
one-shot notice для системного capture-stack отказа.

---

## 04.07.2026 — quick repeat capture больше не ждёт slow prepared task на mouse-up

По live unified log пользовательского сценария стало видно: первый capture после запуска завершался
быстро (`capture frozen ready` около 20ms), а следующие быстрые снимки входили в overlay за 2-10ms,
но после отпускания мыши висели в locked selection до `capture frozen ready`. Причина была не UI, а
freshness policy/cache wait:

- live `SCStream` frame возрастом 1.6-5.9s отвергался как `old frame rejected`, хотя stream был живой
  и мог не эмитить новый sample на статичном desktop;
- `waitForFrozenScreen` добавлял child-task с `await preparedTask.value`, поэтому даже если fresh
  stream frame приходил раньше, выход из `withTaskGroup` мог ждать медленный `SCScreenshotManager`.

Модель разделена. Live stream frame теперь хранит два времени: `updatedAt` для реального sample
buffer и `validatedAt` для успешного ответа stream на fresh-frame request после короткого
grace-window без нового sample. Capture может принять frame как `post-request`, `responsive` или
`validated`; это закрывает статичный desktop, где stream живой, но новый sample не приходит.
Но validation не может бесконечно продлевать один старый pixel buffer: `validatedFrameMaxPixelAge`
задаёт жёсткий ceiling для самих пикселей, после которого cache уходит в fresh/restart path. Suspect
frames за пределами validation/pixel-age window по-прежнему rejected/refresh. Prepared one-shot image
остаётся строгой: `immediatePreparedFrameAge = 0.20s`, так как у неё нет live-stream semantics.

Acceptance стал диагностируемым: `capture cache frame accepted` теперь пишет `source=post-request`,
`source=responsive` или `source=validated`, плюс `requestDeltaMs` и `validationDeltaMs`. Observed
verifier падает, если source исчез, если responsive frame вышел за свой max window или если validated
frame имеет слишком старую validation age или pixel age.

Чтобы этот responsive window не стал новой ловушкой, age maintenance теперь опережает его: примерно
перед истечением окна cache мягко просит fresh frame у live stream (`allowsStreamRestart: false`).
Destructive background restart отделён в `streamRestartAge` и применяется только к намного более
старому suspect stream. Так следующий capture не должен первым платить stale-stream recovery после
короткого idle, но QuickShot всё ещё не рестартит stream каждые несколько секунд.

Stream startup тоже стал наблюдаемым и bounded: перед `SCStream.startCapture()` логируется
`capture cache stream starting`, а сам start имеет deadline. Если ScreenCaptureKit зависнет между
`shareable content ready` и `stream started`, cache не остаётся молча в полуживом состоянии.
Ещё один live-log кейс: `SCShareableContent` может вернуть пустой `displays` при успешном permission
preflight. `loadShareableContent()` теперь предпочитает broad app listing для QuickShot exclusion, но
если displays пустой, явно ретраит on-screen listing, desktop-excluded listing и затем
`SCShareableContent.current`, логируя каждый fallback.
`ScreenFrameCache.start` теперь возвращает `Bool`: если после recovery-chain нет usable cache,
`CaptureSession` сначала пробует cache-owned rect snapshot recovery через
`SCScreenshotManager.captureScreenshot(rect:)`. Этот путь остаётся внутри `ScreenFrameCache`, а не
возвращается в `CaptureController`; все окна QuickShot получают `NSWindow.sharingType = .none`, чтобы
emergency snapshot не запекал overlay/hub/card UI. Если rect snapshot тоже не получился,
`CaptureSession` логирует `capture cache unavailable at start` и завершает сессию сразу, а не ждёт
полный frozen timeout.
Добавлен `scripts/probe-screen-capture-stack.sh`: он без overlay проверяет TCC preflight,
`SCShareableContent` variants, `SCScreenshotManager` rect APIs и системный `/usr/sbin/screencapture`.
Текущий probe показал: `preflight=true`, windows/apps есть, но `displays` пустой, rect screenshot
падает `SCStreamErrorDomain -3811`, а `screencapture` пишет `could not create image from rect`.

`waitForFrozenScreen` больше не ждёт `preparedTask.value`. Он polling'ом принимает fresh stream frame
или уже сохранённый prepared image, а если prepared task всё ещё slow после короткого grace window,
запускает `startSnapshotFallback` в detached task. Slow fallback может помочь, но не имеет права
удерживать mouse-up, если stream frame уже пришёл.

Regression coverage:
`ScreenFrameCacheBehaviorTests` проверяет responsive stream window отдельно от strict prepared window.
`CaptureHotPathStaticTests` и `scripts/test.sh` запрещают возвращать blocking
`await preparedTask.value` в frozen wait и требуют soft maintenance refresh до destructive restart.

---

## 04.07.2026 — cleanup refresh/prewarm переведён на guaranteed path

После сообщения о залипшем fullscreen screenshot проверили lifecycle overlay и cache-refresh путей.
`OverlayController.dismiss()` уже закрывает окна жёстко (`orderOut`, detach `contentView`, `close`) и
вызывается из `deinit`; старый PID при этом не имел capture-событий в unified log, только стартовый
prewarm.

Убрали другой источник хрупкости: `prepareForNextCapture`, `requestFreshFrame` и maintenance refresh
теперь чистят свои owner/task states через `defer`, а не через набор ручных `return`-веток. Это не даёт
post-capture подготовке или refresh owner остаться подвешенными после раннего завершения, supersede или
soft-refresh выхода.

Добавили explicit shutdown chain: `applicationWillTerminate` вызывает `CaptureController.shutdown()`,
активная `CaptureSession` dismiss'ит overlay и завершает `end(prepareNext: false)`, а
`ScreenFrameCache.shutdown()` отменяет prepared tasks, очищает streams/owners/startup flags и ставит
terminal `isShuttingDown` gate. Поздно вернувшийся async `start`/refresh теперь не может заново
создать stream после shutdown.

Regression coverage:
`CaptureHotPathStaticTests` и `scripts/test.sh` требуют guaranteed cleanup для post-capture prepared
task, refresh owner и explicit shutdown path.

---

## 04.07.2026 — post-capture prewarm больше не рестартит stream немедленно

По unified log ручного completed capture стало видно, что post-capture prewarm делал aggressive
`requestFreshFrame`: через 250ms без нового stream frame он начинал restart display stream, пока
stream-owned snapshot ещё готовил prepared image. Это создавало ненужный gap в cache прямо после
снимка: prepared image могла уже истечь, а новый stream ещё не успеть отдать first frame.

Политики разделены. Capture-time stale-frame recovery остаётся aggressive
(`allowsStreamRestart: true`), потому что overlay уже активен и нам нужно спасать свежий кадр.
Post-capture idle prewarm стал soft (`allowsStreamRestart: false`): он просит fresh frame, запускает
prepared snapshot bridge, но не разбирает текущий stream немедленным teardown/restart. Более тяжёлые
stream restarts остаются для активного recovery или дальнейшей maintenance, а не для первых
миллисекунд после завершения снимка.

Regression coverage:
`CaptureHotPathStaticTests` и `scripts/test.sh` проверяют, что `prepareForNextCapture` вызывает
soft refresh, а capture-time stale recovery всё ещё может эскалировать. Runtime/observed verifier
скрипты теперь отдельно падают, если в логах появляется
`capture cache fresh frame request escalating ... reason=post-capture prewarm`.

Дополнительно refresh коалесинг стал owner/prioritized. Раньше один `refreshInFlight` на display мог
заставить active capture recovery молча не стартовать, если idle post-capture refresh ещё держал
флаг. Теперь `RefreshPriority.capture` supersede'ит idle/maintenance owner, а `endRefresh` снимает
флаг только если task всё ещё владеет тем же `refreshID`. Это защищает быстрый повторный снимок от
случая, где idle prewarm сам становится причиной ожидания.

---

## 04.07.2026 — prepared image acceptance ужата до immediate window

Разделили два разных понятия, которые раньше были смешаны: retention prepared image в памяти и право
использовать её как источник нового screenshot. Prepared image может храниться дольше для cleanup и
join in-flight подготовки, но если она была сделана до нового capture request, она теперь принимается
только внутри того же very-short immediate-cache window, что и обычный stream frame. Если prepared
task завершилась до текущего запроса и уже вышла за этот window, `waitForFrozenScreen` логирует
`capture cache prepared task rejected` и идёт в sequential fresh fallback.

Это снижает риск повторить старый регресс со «старой картинкой»: post-capture prewarm остаётся
latency bridge, но не получает отдельный 1.25s stale allowance. Prepared image, произведённая после
текущего request, по-прежнему принимается сразу.

Regression coverage:
`ScreenFrameCacheBehaviorTests` теперь отдельно проверяет post-request prepared accept и rejection
pre-request prepared image вне immediate window. `CaptureHotPathStaticTests` проверяет, что
in-flight prepared task валидируется через `shouldServePreparedFrozenScreen(updatedAt:requestedAt:)`
перед accepted.

---

## 04.07.2026 — strict observed verification для completed capture

Усилена non-invasive проверка ручного снимка. Production path теперь логирует
`capture clipboard copied` сразу после `Clipboard.copy(cgImage:)`, без содержимого экрана и без
пиксельных данных. Это даёт log-only verifier-у доказуемый факт, что crop дошёл до буфера обмена.

`verify-capture-observed.sh` получил режим `REQUIRE_COMPLETED_SELECTION=1`: после ручного снимка он
ничего не нажимает и только читает unified log, но требует весь завершённый путь — `capture frozen
ready`, `capture crop complete`, `capture clipboard copied`, `overlay dismiss`, `overlay cursor
restored`, `capture end outcome=completed` и `capture cache post-capture prepare`.

`CaptureSession` теперь ведёт явный `endOutcome`: completed, cancelled, failed,
ignored-small-selection, missing-frozen-frame или crop-failed. Это важно для log-only verification:
cancel/no-op session больше не может выглядеть как успешный completed capture только потому, что
у неё был общий `capture end`.

Regression coverage:
`CaptureHotPathStaticTests` проверяет, что clipboard-copy лог стоит после `Clipboard.copy`, а
`scripts/test.sh` фиксирует presence строгого observed режима, explicit end outcome и summary
`completedSelection`.

---

## 04.07.2026 — display-scoped stream startup и expiry prepared image

Убрали ещё один источник случайных задержек: `ScreenFrameCache` больше не использует один глобальный
`startInFlight` для всех мониторов. Startup/restart stream теперь коалесится по display через
`startingDisplays`, поэтому recovery одного экрана не может молча заблокировать старт другого экрана
и оставить следующий capture ждать fallback.

Prepared frozen image также получила явный lifecycle: после post-capture подготовки она удаляется
после короткого bridge window. Это закрепляет продуктовый контракт: prepared image ускоряет быстрый
повторный снимок, но не становится ещё одним долгоживущим источником старого скриншота.

Regression coverage:
`CaptureHotPathStaticTests` запрещает возврат глобального `startInFlight` и проверяет display-scoped
startup gate. `ScreenFrameCacheBehaviorTests` проверяет expiry prepared image, а `scripts/test.sh`
дублирует эти инварианты shell-gates.

---

## 04.07.2026 — post-capture prewarm для следующего снимка

Разобрали оставшуюся задержку после реально сделанного скриншота: overlay входил за миллисекунды,
но следующий capture иногда платил 1-3 секунды за stale-frame recovery. Причина была в том, что
строгая защита от старого кадра (`old frame rejected`) запускала fresh-frame request и stream-owned
snapshot уже на следующем пользовательском жесте.

Архитектура изменена на idle-first: `CaptureSession.end()` теперь после освобождения сессии вызывает
`ScreenFrameCache.prepareForNextCapture(display:)`. Этот путь фоном просит свежий frame у существующего
`SCStream`, а если поток не отдаёт кадр быстро, заранее готовит `PreparedFrozenScreen` через уже
созданный stream/filter. Следующий capture может использовать prepared image только в коротком окне
свежести; он не становится новым долгоживущим fallback и не отменяет запрет на старые кадры.

Подготовка теперь tracked/joinable: если следующий capture приходит до завершения post-capture
snapshot, `waitForFrozenScreen` ждёт уже запущенную `preparedFrozenScreenTask`, а не создаёт
параллельный recovery. Это закрывает быстрый повторный сценарий сразу после сделанного скриншота,
где idle-подготовка ещё не успела записать готовый prepared image.

Два edge-case инварианта добавлены сразу: non-dropping stream restart (`dropFrame: false`) не отменяет
in-flight prepared task, а prepared snapshot не записывается, если `SCStream` уже успел отдать fresh
frame для того же post-capture request. Так prepared image остаётся latency bridge, а не гонкой с
более свежим stream frame.

Duplicate prepare также дедуплицируется до refresh work: `prepareForNextCapture` сначала регистрирует
joinable task, и только потом вызывает `requestFreshFrame`. Если подготовка уже идёт, новый вызов
логируется как `post-capture prepare already running` и не запускает второй stream refresh.

В `waitForFrozenScreen` join теперь настоящий: если есть `preparedFrozenScreenTask`, capture-time
snapshot fallback не добавляется параллельно. Следующий capture ждёт in-flight post-capture подготовку
и обычный stream polling, не создавая вторую дорогую `SCScreenshotManager` работу на том же display.
Если joined prepared task завершилась без кадра, `waitForFrozenScreen` запускает snapshot fallback
последовательно (`prepared task unavailable; starting sequential snapshot fallback`), а не ждёт до
общего timeout.

Regression coverage:
`ScreenFrameCacheBehaviorTests` проверяет, что recent prepared image может закрыть следующий capture,
а old prepared image истекает. `CaptureHotPathStaticTests` проверяет, что `prepareForNextCapture`
вызывается из `CaptureSession.end`, а не до overlay activation, и что frozen wait присоединяется
к in-flight post-capture preparation.

---

## 04.07.2026 — overlay activation отделён от frozen-frame conversion

Причина оставшейся визуальной задержки была не только в ожидании fresh frame. `CaptureSession`
создавал overlay, но затем мог сразу синхронно резолвить cached `CVPixelBuffer` в `CGImage` на
main actor до того, как AppKit успевал показать окно. В результате окно уже было сконструировано,
а пользователь всё равно видел паузу до первого paint.

Hotkey path теперь делает минимальные UI-шаги на main actor: одноразовый gesture snapshot, target screen,
`beginLiveSelection`, лог `capture overlay ready`. Скрытие окон QuickShot перенесено после overlay
activation, но до frozen-frame work: это сохраняет защиту от попадания UI в capture и не блокирует
первый видимый overlay. Вся работа с `ScreenFrameCache`, ожиданием fresh frame, `CVPixelBuffer` ->
`CGImage` и stream-owned snapshot уехала в `Task.detached`; на main actor возвращается только
готовый `FrozenScreen` для `installFrozenBackdrops`.

Вторая причина 3-секундных провалов — повторный `SCShareableContent` на capture-time fallback.
В логах текущего процесса такой вызов занимал `3737ms`, поэтому fallback больше не строит новый
content/filter во время capture. Если нужен быстрый snapshot, он берётся только через уже созданный
stream/filter; иначе overlay остаётся интерактивным, а fresh frame догружается off-main.

Freeze wait увеличен как фоновый deadline: если hotkey попал в момент медленного startup-prewarm,
overlay не должен исчезать через 1.5 секунды только потому, что ScreenCaptureKit ещё строит stream.
Это не меняет overlay budget: cold-start verifier теперь тоже требует `capture overlay ready` в
пределах 100ms, а не прежние 2500ms.

Ещё один hot-path источник вынесен из обычной дороги: `CGPreflightScreenCaptureAccess()` теперь
кэшируется и обновляется в фоне при prewarm. После подтверждённого доступа hotkey больше не делает
TCC/preflight IPC до overlay activation; remembered granted state переживает restart, поэтому даже
первый hotkey сразу после launch не обязан ждать prewarm. Повторная проверка на trigger остаётся
только для состояния unknown/denied.

Regression gate в `scripts/test.sh` теперь запрещает `frameCache.frozenScreen` и
`beginFrozenSelection` в `CaptureController`, чтобы future change не вернул synchronous freeze на
главный поток. Прямой public `ScreenFrameCache.frozenScreen(...)` удалён; наружу остаётся только
async `waitForFrozenScreen`, который вызывается из detached freeze task.

Добавлены фазовые логи main hot path: `tracker ready`, `windows hidden`, `target resolved`,
`overlay constructed`, затем итоговый `capture overlay ready`. Если ручной тест всё ещё увидит
паузу, `verify-capture-observed.sh` покажет, сидит ли она до overlay construction или уже вне
QuickShot-логики/первого paint.

После дополнительного аудита метрика стала end-to-end для глобального хоткея: `GlobalHotKey` ставит
timestamp сразу в Carbon callback (`hotkey event received`) и передаёт его в
`CaptureController.triggerCapture(startedAt:)`. Если callback уже пришёл на main thread, обработчик
вызывается синхронно, без лишнего `DispatchQueue.main.async` turn. Поэтому `capture overlay ready`
теперь включает задержку от системной доставки хоткея до интерактивного overlay.

Добавлен `CaptureHotPathStaticTests`: он парсит `CaptureController.swift` и проверяет, что
`CaptureSession.start` вызывает `beginOverlay` до `HiddenAppWindows.hideVisibleApplicationWindows()`
и до `startFreezeTask`, но скрытие окон всё ещё происходит до frozen-frame work. До overlay
activation нет `waitForFrozenScreen`, `frameCache.start`, `SCShareableContent`,
`SCScreenshotManager`, `createCGImage`, permission preflight, global monitor registration или
window-hide. Это более точный guard, чем одиночные `rg`.

Старый `CaptureGestureTracker` удалён: он регистрировал global mouse monitor до overlay, что было
нужно только при позднем overlay. Теперь до overlay сохраняется только `CaptureGestureSnapshot`
(позиция мыши и факт зажатой левой кнопки), а дальнейшее выделение ведёт сам `OverlayController`.

Из `OverlayController.begin` убран `w.displayIfNeeded()` до `orderFrontRegardless`. На больших
экранах forced synchronous full-screen render сам мог стать задержкой перед первым видимым overlay.
Теперь hot path только создаёт view/layer tree и сразу order-front'ит окна; AppKit рисует лёгкий
selection chrome естественным paint. `scripts/test.sh` запрещает возвращать `displayIfNeeded()` в
`Overlay.swift`.

`makeKeyAndOrderFront` и `NSApp.activate(ignoringOtherApps:)` также вынесены из первой overlay-дороги
в `DispatchQueue.main.async`. Окно сначала становится visible через `orderFrontRegardless`, а
activation/key assignment догоняют следующим main-loop turn для Esc/key handling. Static test
проверяет, что activation не происходит до `overlay begin`.

---

## 04.07.2026 — карточные controls переведены с Liquid Glass на command-buttons

Убрали нативные `.glass` кнопки с самих thumbnail-карточек. `ThumbnailView` теперь использует
`DesignSystemButtonGroup`: Vercel/Native Geist detached button-group — без общего контейнера,
без 1px seam, с 8pt gap между chips. Сегменты `DesignSystemButton` используют Geist small-control
метрики: 32pt height, 6pt control radius, 14pt label, 16pt icon и один hit target для icon+label.
Для QuickShot поверх произвольного экрана normal controls используют Geist primary fill (black under
white text), destructive — Geist filled red block, а не translucent wash, который теряется на светлом
рабочем столе.

`Copy` — icon+label segment, close — destructive icon segment. Feedback копирования (`Copied`)
пересчитывает layout карточки, чтобы текст не обрезался старой шириной. `GlassButton` оставлен для
отдельных нативных surface вроде full-size окна, но продуктовый контракт запрещает возвращать его в
per-thumbnail controls.

---

## 04.07.2026 — immediate overlay поверх fresh stream-cache

Убрана архитектурная причина 3-секундной задержки: `CaptureSession` больше не ждёт frozen frame до
показа overlay. Hotkey теперь сразу скрывает окна QuickShot и запускает `beginLiveSelection` на
целевом экране; `capture overlay ready` снова измеряет интерактивный слой, а не готовность картинки.

Свежий ScreenCaptureKit frame устанавливается вторым шагом через `installFrozenBackdrops`. Если
пользователь успел завершить выделение до готовности fresh frame, selection сохраняется как pending
и кадрируется только после `capture frozen ready`. Старый pre-request cached frame по-прежнему
отвергается и не может стать backdrop/final crop.

Regression gate в `scripts/test.sh` теперь требует `beginLiveSelection` и `installFrozenBackdrops`
в `CaptureController`; `cache pending` в runtime-verifiers больше не считается UX-регрессом, если
overlay уже active, зато `capture cache old frame accepted` остаётся hard failure.

---

## 04.07.2026 — hotkey path больше не блокируется TTL кадра

Эта запись описывала промежуточный компромисс и затем была superseded: old-frame fallback оказался
продуктовым регрессом, потому что запекал старое состояние экрана в новый screenshot. Текущий
контракт ниже: старый pre-request frame отвергается, а cache обязан дождаться frame после текущего
capture request.

Исправлен регресс скорости capture-flow: предыдущий stale-frame guard считал любой cached frame
старше `1s` непригодным, удалял stream и заставлял hotkey ждать новый ScreenCaptureKit frame.
На статичном рабочем столе это ошибочная модель: stream может не присылать новый sample buffer, хотя
последний кадр всё ещё визуально актуален. В unified log это проявлялось как `capture cache stale
frame` -> `capture cache pending` -> `capture overlay ready` через секунды.

Промежуточно wall-clock age перестал блокировать hotkey path: старый cached frame принимался как
fallback, логировался как `old frame accepted`, а stream обновлялся фоном. Это оказалось неверным
продуктово и заменено текущим pre-request rejection контрактом.

Regression gates теперь фиксируют, что старый кадр, полученный до текущего capture request, не
может стать screenshot source.

---

## 04.07.2026 — старые pre-request frames больше не попадают в screenshot

Исправлен регресс, где `ScreenFrameCache` принимал frame ageMs в секунды и десятки секунд как
`cache hit`, из-за чего overlay/final crop получали старое состояние экрана. `CaptureSession` теперь
передаёт timestamp текущего capture request в `ScreenFrameCache`; cached frame допустим только если
он пришёл после этого timestamp или попадает в очень короткое immediate-cache окно.

Если warm cache старее текущего запроса, `frozenScreen` возвращает `nil`, логирует
`capture cache old frame rejected` и запрашивает свежий frame у существующего `SCStream` через
`updateConfiguration`/`updateContentFilter`. Если новый frame не приходит быстро, refresh
эскалируется до stream restart. Старый frame при этом больше не может стать frozen backdrop.

`ScreenFrameCacheBehaviorTests` обновлён: очень свежий warm frame сохраняет fast path, old
pre-request frame rejected, frame after request accepted.

---

## 04.07.2026 — stale-frame guard и реальный host hit-testing для хаба

Capture-часть этой записи зафиксировала промежуточную гипотезу hard TTL. Текущий контракт заменён
записью выше: wall-clock age больше не блокирует hotkey path, а обслуживает фоновый refresh.

Пойман критичный capture-регресс: `ScreenFrameCache` записывал `CachedFrame.updatedAt`, но
`frozenScreen(for:)` не проверял возраст кадра. Если `SCStream` зависал или переставал обновляться,
15-минутный `CVPixelBuffer` всё равно считался `cache hit` и попадал в overlay/final crop.

В промежуточной версии cached frame получил hard TTL (`1s`), а старый по времени frame удалял stream
и запускал новый warm stream через обычный `cache pending/cache late hit` путь. Это оказалось
неверным для статичного desktop и заменено текущим фоновым refresh-контрактом. Полезная часть
осталась: старые stream callback больше не могут воскресить удалённый state, потому что каждый
`CachedDisplayStream` имеет `UUID`, а `storeFrame` принимает кадр только от актуального stream-id.

Параллельно найден реальный источник повторяющейся некликабельности hub action buttons. Старые тесты
кликали `HubWindow` напрямую, минуя родительское окно. В настоящем tray путь идёт через
fullscreen-прозрачный host content view; обычный `NSView` мог вернуть себя вместо расширившегося
`HubActionPill`. Добавлен `TrayHostContentView`, который вручную hit-test'ит интерактивные сабвью
сверху вниз и возвращает `nil` для пустого прозрачного пространства. Это сохраняет click-through
пустоты и пропускает реальные клики в expanded hub.

Regression gates усилены: текущий `ScreenFrameCacheBehaviorTests` фиксирует hot-path для старых
по времени кадров, а
`HubWindowLiveClickTests` создаёт настоящий `NSPanel` + `TrayHostContentView` и отправляет mouse
events через window dispatch. Теперь сценарий «изолированный hub кликается, а реальное окно трея нет»
падает в `./scripts/test.sh`.

Следом пойман побочный регресс этого же слоя: стеклянный `x` у отдельной карточки визуально был
показан, но click path останавливался на `ThumbnailView`, а не доходил до `GlassButton`.
`ThumbnailView` и `CardContainer` теперь явно маршрутизируют hit-testing к controls перед телом
карточки. Добавлен `ThumbnailWindowLiveClickTests`: настоящий `NSPanel`, `TrayHostContentView`,
реальная карточка и window-dispatch click по центру close button; тест падает, если карточка не
удаляется.

---

## 04.07.2026 — Vercel/Geist-подобный hover hub без кликовых регрессов

Хаб закреплён как набор Vercel/Native Geist detached command buttons, а не инженерная stretched-pill
оболочка: compact core — 32pt icon+label button (`N screenshots` + stack icon + trailing chevron) с
6pt radius; раскрытые actions — отдельные chips с 8pt gap, без shell border, shared seam и stacked
`CAShapeLayer` rings. В раскрытом состоянии visible labels используют явные command names:
`Delete`, `Save As`, `Copy All`; accessibility labels добавляют полное описание действия без
превращения chip в длинную строку.

Hover reveal следует Geist fast motion (`150ms`) и остаётся на `easeOutQuad`, чтобы последние
миллиметры раскрытия не растягивались. Текст action chip появляется только когда label уже полностью
в clip, но действие становится доступным до финального кадра раскрытия. При нажатой action chip shell больше не
схлопывается от `mouseExited` до `mouseUp`, поэтому клики по `Delete`/`Save As`/`Copy All` не теряются.

Тестовый контракт расширен: проверяется отсутствие shell stroke/decorative sublayers, 32pt height,
6pt radius, icon+label core, явный нейминг action labels, клики по chips в промежуточных reveal
frames, полный набор action-кликов для обоих направлений раскрытия и сценарий
`press -> shell mouse exit -> release`.
Visual QA обновляется через `./scripts/render-hub-qa.sh /tmp/quickshot-hub-matrix-preview.png`.

---

## 04.07.2026 — frozen-first capture через прогретый ScreenCaptureKit stream cache

Зафиксирован `PRODUCT_CONTRACT.md`: capture-flow считается корректным только если overlay появляется
уже поверх frozen backdrop, системный курсор не конкурирует с кастомным, QuickShot UI не попадает в
frozen/final кадр, а быстрый hotkey+drag не требует повторного клика.

Аудит показал, что предыдущая модель **live chrome → frozen backdrop later** архитектурно
провоцировала два симптома: видимый delayed переход с живого desktop на frozen image и редкое
попадание собственного курсора/рамки в снимок, если ScreenCaptureKit не успевал или не мог надёжно
исключить только что созданные overlay windows.

Проверены альтернативы:

- `CGDisplayCreateImage`, `CGWindowListCreateImage` и `CGDisplayStream` в текущем macOS SDK помечены
  `unavailable`/obsoleted: компилятор требует ScreenCaptureKit.
- `SCScreenshotManager.captureScreenshot(rect:configuration:)` и
  `captureImage(contentFilter:configuration:)` работают, но one-shot путь на 5K экране стабильно
  занимает около `950-970ms`; уменьшение output до `1280x720` не снимает эту задержку.
- Прогретый `SCStream` отдаёт первый кадр после старта приложения примерно за `80-550ms`, а после
  прогрева hotkey может брать frame из памяти. В серийной live-проверке после перезапуска:
  худший `cache hit 27.3ms`, худший `overlay ready 42.6ms`, без cache miss.

Историческая frozen-first архитектура: `ScreenFrameCache` стартует по одному `SCStream` на дисплей после запуска
приложения, создаёт stream-объекты для дисплеев и стартует их параллельно, используя
`SCContentFilter(display:excludingApplications:exceptingWindows:)`, чтобы весь QuickShot исключался
на уровне приложения. `CaptureSession` по hotkey скрывает видимые окна QuickShot, берёт cached
`CVPixelBuffer`, конвертирует его в `CGImage`, и только после этого показывает overlay на активном
экране через `beginFrozenSelection`. Если hotkey попал на границу прогрева, session ждёт
stream-cache и завершает путь через `cache late hit`; `SCScreenshotManager` больше не вызывается из
hotkey-path `CaptureController`.

Эта frozen-first часть superseded записью выше от 04.07.2026: overlay снова стартует сразу через
`beginLiveSelection`, а fresh backdrop ставится позже через `installFrozenBackdrops`.

Добавлен `scripts/verify-capture-runtime.sh`: он пересобирает и перезапускает app bundle,
дожидается первого stream-cache frame, синтетически отправляет серию `Command-Shift-4`/`Esc` и
валидирует unified log: обязательно immediate `cache hit` на каждый capture, запрещены `cache pending`
и любые fallback-маркеры, проверяется hide/restore системного курсора, худший `overlay ready` должен
быть быстрее `250ms`. Добавлен `scripts/verify-capture-cold-start.sh`: он нажимает hotkey почти
сразу после старта процесса и разрешает только stream-cache `late hit`, без screenshot API fallback,
а также проверяет dismiss/restore cursor lifecycle после `Esc`.

Добавлен `scripts/verify-capture-selection-output.sh`: он поднимает однотонное тестовое окно,
выполняет настоящий hotkey+drag, проверяет `capture crop complete`, `overlay cursor restored` и
читает PNG из clipboard. Пиксельная проверка требует почти полной uniformity итогового изображения;
это ловит попадание overlay, selection frame или кастомного курсора в финальный snapshot.

Для курсора/рамки добавлены `SelectionToolBehaviorTests` и `scripts/render-selection-qa.sh`.
Тесты фиксируют численный контракт: crosshair ровно из двух shape layers (halo/core), размер и
anchor не меняются во время drag, а frame gap равен `crosshairGap + crosshairArm + frameSeparator`
для всех четырёх drag-квадрантов. Renderer строит PNG-матрицу из debug-геометрии `SelectionView`,
чтобы можно было глазами сверить, что рамка естественно продолжает курсор, без точки/ручки/перемычки.

---

## 03.07.2026 — ускоренный reveal и кликабельность всех action pills

Хвост hover-раскрытия был слишком вязким: `easeOutCubic` замедлял последние миллиметры, из-за чего
левый/дальний action pill визуально приезжал с задержкой. Expansion переведён на более ровный
`easeOutQuad`, длительность снижена до `145ms`. Текст action pill теперь появляется и становится
кликабельным, когда его label-зона полностью находится внутри clip, а не когда декоративная капсула
целиком закончила въезд. Это сохраняет запрет на clipped text, но убирает лишнюю задержку.

Тесты расширены: теперь кликаются все три action pills (`Delete`, `Save As`, `Copy All Screenshots`)
в обоих направлениях раскрытия, а не только первая найденная кнопка.

---

## 03.07.2026 — воспроизводимый visual QA для хаба

Добавлен `scripts/render-hub-qa.sh`: он компилирует `HubWindow` с тестовым progress-hook и
рендерит matrix PNG для позиций справа/слева/снизу/сверху, счётчиков `1`, `2`, `99+` и нескольких
кадров раскрытия. Это превращает проверку «ничего не вылезает, core не приезжает, радиусы и
отступы держатся» в воспроизводимый артефакт, а не в одноразовый screenshot из `/tmp`.

Поверх визуального QA добавлены численные debug-снимки геометрии под `#if TESTING`: тесты проверяют
half-height радиусы core/action pills, общий action/core height, `3pt` shell inset, `7pt` group/action
gaps, интерактивность только полностью раскрытых action pills и инертность пустой части shell на
промежуточных кадрах.

---

## 03.07.2026 — полировка hover-action хаба и геометрические тесты

Первая версия hover-action хаба была функциональной, но визуально оставалась черновой: тяжёлая
двойная обводка, разный внутренний ритм core/action pills и риск не заметить вылезание элементов во
время reveal. Геометрия сведена к единому контракту: внешний shell имеет 3pt inset вокруг всех
внутренних pills, core и action-кнопки одной высоты, раскрытие держит центр core на месте, а action
pills проявляются через masked clip без scale-transform.

Тесты усилены: кроме кликов теперь проверяются все позиции трея, правильный anchored edge при
раскрытии, стабильность центра core, containment видимых элементов в промежуточных кадрах анимации
и запрет на видимый clipped text у action-labels. Текст команд появляется только после того, как
соответствующий pill помещается внутри shell целиком; до этого раскрывается только тёмное тело.

---

## 03.07.2026 — тестовый контракт для хаба

После редизайна hover-action хаба был пойман регресс: клик по основной кнопке мог перестать
сворачивать/разворачивать скриншоты. Добавлен `scripts/test.sh` — изолированный AppKit-раннер,
который компилирует `HubWindow` с тестовыми стабами `TrayPosition` и `FrameAnimator` и проверяет
самый важный контракт: compact-клик по core вызывает toggle, hover-expanded shell не двигает центр
core, клик по core после раскрытия всё ещё вызывает toggle, а action pill вызывает свой action и
не сворачивает трей случайно.

---

## 03.07.2026 — live overlay без задержки, единый курсор+рамка, хаб без отступа Dock

### Выделение можно начинать сразу

Старая архитектура ждала frozen screenshot перед полноценным выделением: визуально overlay уже
появлялся, но быстрый сценарий «нажал хоткей и сразу потянул мышью» мог не стартовать с первого
drag. Поток переделан в `CaptureSession`: сначала мгновенно показываем **live selection chrome**
(затемнение, рамка, кастомный курсор), параллельно снимаем full-screen кадры ScreenCaptureKit и
докладываем их позже через `installFrozenBackdrops`. Если пользователь успел закончить выделение
раньше готовности frozen-кадра, selection ждёт завершения freeze и только потом кадрируется.

Чтобы в итоговый снимок не попадал сам QuickShot, `RegionCapturer.captureFull` теперь принимает
`excludingBundleIdentifier` и строит `SCContentFilter` с исключением приложения QuickShot. Это
сохраняет обязательную модель «замороженный экран → crop», но убирает UX-задержку на старте.

### Курсор и рамка — одна дизайн-система

Отказались от системного crosshair окончательно: window server сбрасывал его в стрелку на движениях,
а простое `NSCursor.hide()` оказалось недостаточно жёстким в текущем overlay-потоке. Теперь
системный курсор подавляется через `CGDisplayHideCursor` с балансировкой hide/show count, а внутри
overlay дополнительно выставляется прозрачный cursor rect. Видимый курсор — только наш `CALayer`.

Промежуточная идея с точкой/ручкой у активного угла отклонена как неверная визуально. Текущая модель:
перекрестье не меняет размер и форму во время drag, а рамка выделения рисуется тем же stroke-языком:
чёрный halo 3.5pt + белое ядро 1.5pt, round caps. Активные стороны рамки лежат ровно на осях arm
курсора и начинаются после `crosshairGap + crosshairArm + frameSeparator`, поэтому рамка выглядит
как продолжение линий курсора через маленький разделитель, без точки, перемычки или отдельного
handle.

### Хаб и карточки больше не учитывают Dock/menu bar

Позиционирование хаба и карточек переведено с `screen.visibleFrame` на полный `screen.frame`.
Иначе после фикса положения хаба карточки продолжали учитывать Dock/menu bar, и между кнопкой и
раскрытыми скриншотами появлялась большая дыра. Теперь оба слоя живут в одной системе координат:
если системный chrome находится в выбранном углу, хаб осознанно может его перекрывать.

Хаб остаётся Vercel/Geist-подобной тёмной пилюлей: добавлены hover/pressed-состояния через
background/border transition, фиксированная высота 34pt, моноширинный счётчик и шеврон. Скриншоты-
референсы сохранены в `reference/screenshots/vercel-hub/`.

---

## 02.07.2026 — хаб: тёмная «пуля» Vercel/Geist с шевроном-индикатором

Ушли от Liquid Glass в хабе. Новый хаб — тёмная **пилюля в стиле дизайн-системы Vercel (Geist)**:
чёрный фон, тонкая subtle-обводка (белый 14%), белый моноширинный счётчик. Сплошная заливка —
приглушение вне key-окна снято по построению (та самая проблема всей саги с `.glass`), больше не
зависит от фокуса. Нативных Geist-компонентов для AppKit нет (Geist — веб), поэтому это осознанная
реимплементация стиля на `NSView` + `CAShapeLayer`, а не «те самые» компоненты.

Справа от цифры — **шеврон-индикатор** открытия/закрытия. Показывает, куда раскроется трей, и
плавно доворачивается при клике. Направление берётся из позиции кнопки через `isVertical`
(совпадает с реальной геометрией `cardLayout`): вертикальный трей раскрывается вверх (свёрнуто ↑,
развёрнуто ↓), горизонтальный — влево (свёрнуто ←, развёрнуто →).

Грабли: первая версия крутила `NSView.frameCenterRotation`, а `layout()` сбрасывал угол в 0 и
переставлял без анимации — при этом `resizeToFit` дёргал `layout()` прямо во время анимации, поворот
затирался («дёргается при нажатии»). Починка: поворот вынесен на отдельный `CAShapeLayer` (вектор,
чёткий; `anchorPoint 0.5` — вокруг центра), анимация — `CABasicAnimation` по `transform.rotation.z`.
`layout()` двигает только позицию слоя, поворот не трогает. Анимируем строго на настоящем
сворачивании/разворачивании (не на каждом `setState`). Внешний API `HubWindow` сохранён — менеджер
трея и позднейшие фиксы не тронуты.

---

## 25.06.2026 — хаб обратно на нативное Liquid Glass (по решению UX)

Пробовали редизайн хаба в панель-«шторку» (чёрная, как продолжение нотча, по-угловые скругления:
внутренние выпуклые, у кромки вогнутые) — отклонён, откатан целиком (был незакоммичен). Также
отклонён промежуточный `NSGlassEffectView`.

Итог по решению пользователя: хаб — снова **нативная `.glass`-кнопка** (`GlassButton`, круглая),
чтобы визуально совпадать с кнопками карточки. Меняли только внутренности `HubWindow` (материал
`NSVisualEffectView` → `.glass`-кнопка) при том же внешнем API, поэтому позднейшие фиксы остались:
видимость при count≥1, доталкивание на фуллскрины, следование за активным экраном. Сознательно
принят размен: нативное стекло гаснет вне key-окна и оживает на ховере/взаимодействии — публичного
обхода для фоновой панели нет.

---

## 25.06.2026 — трей на чужих фуллскринах (осознанный workaround)

### Проблема

Трей виден на обычных Spaces и на том фуллскрине, где сделан снимок, но на ДРУГИХ фуллскринах не
появлялся.

### Почему

`.canJoinAllSpaces` распространяется на обычные (user) Spaces, но НЕ на фуллскрин-Spaces — каждый
фуллскрин это отдельный изолированный Space. Трей виден на фуллскрине съёмки, потому что там его
вывели вперёд (`orderFrontRegardless` в `add()`); в другие фуллскрины он ни разу не «заводился».
`.fullScreenAuxiliary` лишь РАЗРЕШАЕт показ поверх фуллскрина, но не заносит окно в каждый
фуллскрин-Space автоматически. Декларативного «будь на всех фуллскринах» в публичном API нет: вся
система Spaces реализована в Dock.app поверх приватного SkyLight (см. ресёрч по свайпу ниже).

### Решение и честная оговорка

На `activeSpaceDidChange` доталкиваем трей вперёд (`host.orderFrontRegardless()`), чтобы он заходил
в текущий Space, включая фуллскрин (через `.fullScreenAuxiliary`). Проверено экспериментом —
работает: трей теперь появляется на чужих фуллскринах.

Это **осознанный workaround, а не чистая архитектура** (зафиксировано по требованию UX): для обычных
Spaces правильный путь декларативный (`.canJoinAllSpaces`, ОС держит сама), а для фуллскринов
декларативного механизма нет, поэтому реактивно доталкиваем окно на каждую смену Space. Минус —
лёгкий z-order/мелькание и зависимость от капризного Dock-управления фуллскринами; гарантии на
каждый фуллскрин публичный API не даёт, но эмпирически держит.

### Попутно (не закоммичено)

Отдельно проверяли, можно ли заставить трей стоять НЕПОДВИЖНО, пока Spaces проезжают под ним (как
Dock). Ответ по источникам — нельзя публично: «висеть над» анимацией свайпа умеет только системный
хром через привилегированное соединение Dock.app с WindowServer (SkyLight); третьей стороне нужен
инжект в Dock + отключённый SIP. Эксперимент с высоким уровнем окна не помог (окно пряталось на
время свайпа) — откатан.

---

## 25.06.2026 — хаб-счётчик: стабильный вид, всегда виден, капсула

### Кнопка уходила в «disabled»

Хаб был системной `.glass`-кнопкой, чей активный вид следует за key/active-состоянием окна. Трей —
фоновая nonactivating-панель, почти всегда не key, поэтому при фокусе другого приложения / свайпе
Spaces стекло гасло в «disabled». Публичного способа форсировать активный вид системного контрола
в не-key окне нет (Apple DevForums). Re-key на ховере латал только моменты взаимодействия.

**Инженерно верное решение — отвязать вид от состояния окна.** Хаб переписан: фон —
`NSVisualEffectView` с `state = .active` (документированный пин «всегда активный вид материала», НЕ
гаснет вне key), пин тёмной темы (белая цифра читаема всегда, заодно ушла нестабильность цвета),
цифру и клик рисуем/обрабатываем сами (`acceptsFirstMouse` → клик работает в не-key окне). Размен:
это уже не системный Liquid-Glass-безель, а пин-активный материал — но стабильный по построению.

### Виден при count >= 1

Раньше хаб показывался от 2 снимков. Теперь — при любом count >= 1 (скрыт только на 0). Заодно
разрешили сворачивание одной карточки, иначе кнопка была бы видна, но клик ничего не делал бы.

### Рост в капсулу с потолком «99+»

Фиксированный круг обрезал 3+ цифры. Теперь форма — roundedRect с радиусом = высота/2: круг при
коротком числе, плавно капсула при широком (маска перерисовывается под размер, ширина =
`max(диаметр, ширина_текста + поля)`). Потолок «99+» держит ширину ограниченной. Высота фиксирована,
поэтому раскладку развели: вертикальный отступ карточек — по высоте хаба (карточки не двигаются при
росте ширины), горизонтальный — по ширине; размер обновляется перед позиционированием.

---

## 25.06.2026 — оверлей: своё перекрестье и сброс при свайпе Spaces

### Курсор-перекрестье срывался в стрелку — теперь рисуем сами

Системный курсор в оверлее упорно слетал в стрелку при движении, несмотря на cursorUpdate/
resetCursorRects/`set()` в mouseMoved. Диагностика логом дала корень: приложение в оверлее
**активно** (`appActive=true`), а курсор на КАЖДОЕ движение сбрасывает **window server** по
зарегистрированным cursor-rect'ам — без crosshair-ректа ставит стрелку, причём ПОСЛЕ нашего
`set()` в обработчике события. App-side `set()` принципиально не может победить пер-move сброс.

Решение, не зависящее от этих механизмов: **прячем системный курсор** (`NSCursor.hide()` —
приложение активно, поэтому работает) и **рисуем перекрестье сами** — векторный CALayer (белый «+»
с тёмным ореолом, чёткий на Retina), двигаем по `mouseMoved`/`mouseDragged` через `CATransaction`
без анимации. Скрытому курсору window server'у нечего сбрасывать — проблема исчезает по корню.
Защита от потери курсора: `unhide()` в dismiss, deinit и на всех путях выхода (Esc возвращает).

### Свайп между Spaces во время выделения — отменяем захват

Свайп на другой Space оставлял застрявший оверлей: `Esc` висит на ЛОКАЛЬНОМ мониторе клавиатуры,
а после свайпа оверлей теряет key, и события до монитора не доходят — выйти можно было только сняв
кадр. Плюс `.canJoinAllSpaces` таскал протухший замороженный кадр за пользователем. По модели
«заморозки» свайп на другой Space — уход от снятого момента, снимать там нечего. Поэтому: убрали
`.canJoinAllSpaces` у оверлея (привязан к своему Space) и на `activeSpaceDidChange` во время
выделения отменяем захват (dismiss + возврат курсора). Многомониторное выделение в одном Space не
задето — переход между мониторами этого события не шлёт (проверено логом).

---

## 24.06.2026 — трей следует за активным экраном

Трей был приколочен к экрану последнего снимка и не переезжал на другой монитор. Лог показал факт:
переход на другой монитор НЕ шлёт `activeSpaceDidChange`, а `NSScreen.main` отстаёт на событие —
зато экран под курсором на первом же клике точен. Поэтому ловим клики глобальным монитором (видит
чужие приложения, прав не требует) и переносим хост на экран под курсором, если трей не там.
Триггер по намеренному клику, не по каждому движению мыши — без дёрганья (модель «за активным
экраном», не «буквально за курсором»). Свайп Spaces в одном экране и так работал
(`.canJoinAllSpaces` у трея). Плюс защита: отключили монитор с треем — переезд на главный.

---

## 18.06.2026 — Cmd-V скопированного скриншота в терминал

### Симптом

Скопированный кнопкой скриншот при перетаскивании в терминал вставлялся как путь, а по Cmd-V в
терминал — «ломался». При этом в обычные приложения картинка по Cmd-V вставлялась нормально, и текст
в терминал тоже копировался нормально.

### Причина

`Clipboard.copy` клал в буфер только image-типы (PNG + TIFF), без файловой ссылки. Drag-out же
кладёт ещё `fileURL` (через временный файл). Терминал на Cmd-V читает `public.file-url` (как при
copy файла в Finder) — а его не было, только байты картинки, которые терминалу нечем вставить.

### Фикс

`Clipboard.copy` теперь тоже пишет временный PNG и добавляет `fileURL` рядом с PNG/TIFF (порядок:
image-типы первыми, fileURL последним). Терминал по Cmd-V берёт путь, приложения-картинки берут
PNG/TIFF и файловую ссылку игнорируют — их вставка не меняется. Та же модель, что у drag-out.

---

## 18.06.2026 — оверлей выделения: слой-заморозка + хром, и курсор

### Глитч появления

Оверлей при появлении «подёргивался», картинка доезжала в два шага, были видны края при влёте.
Корень: один `SelectionView` в `draw(_:)` перерисовывал ВСЁ сразу — полноэкранную заморозку +
затемнение + рамку, и `mouseDragged` дёргал `needsDisplay` на каждый сдвиг. Статика и динамика были
смешаны, тяжёлая картинка гонялась на каждый тик, плюс окно показывалось со штатной анимацией влёта.

### Разделили статику и динамику

- **Заморозка — статический слой** `BackdropView` (`layer.contents = cgImage`, `contentsGravity =
  .resize`), выставлен один раз. GPU композитит пиксель-в-пиксель, не перерисовывается, не «доезжает».
- **Затемнение + рамка — лёгкий хром** `SelectionView` поверх; перетаскивание рамки гоняет только
  дешёвый слой, который `.copy`-clear'ом пробивает прозрачную дыру над бэкдропом.
- **Атомарный показ:** `animationBehavior = .none` + `displayIfNeeded()` до `orderFront` — оверлей
  появляется разом, без влёта и видимых краёв. Бэкдроп передаём как `CGImage` прямо в слой.

### Курсор-перекрестье срывался в стрелку при движении

Для выделения нужен `NSCursor.crosshair` — его центр точно метит пиксель начала/конца рамки (стандарт
для region-выделения, как у встроенного macOS-скриншота). После выноса `SelectionView` в сабвью
`resetCursorRects` перестал держаться: на каждый mouse-moved система ставила стрелку. Перевели на
`cursorUpdate` через tracking-область (в оверлее приложение активно — механизм надёжен) + явный
`NSCursor.crosshair.set()` в `mouseDown`/`mouseDragged` (во время drag `cursorUpdate` не приходит).

---

## 18.06.2026 — захват по модели «заморозка → кадрирование»

### Проблема

Нажатие ⌘⇧4 сбрасывало ховеры/тултипы/активные состояния — нельзя было снять состояние по
наведению. Корень архитектурный: порядок был «оверлей → выделение → захват живого экрана». Показ
полноэкранного оверлея + `NSApp.activate` деактивировал окно под низом (оно сбрасывало hover) и
перекрывал курсор нашим оверлеем (элемент считал, что курсор ушёл). Захват шёл уже по сброшенному
экрану.

### Что выяснили по источникам

«Заморозка экрана на время выделения» — реальная модель (Windows Snipping Tool так делает), но НЕ
универсальная (macOS ⌘⇧4 не морозит). Для самих ховер/тултип-снимков индустриальный приём —
таймер-задержка, т.к. часто сам триггер гасит transient-элемент. У нас же ховер гасит не хоткей
(глобальный Carbon не двигает мышь и не меняет фокус), а наш оверлей+активация — поэтому достаточно
снять кадр в первый миг.

### Решение

Инвертировали поток: по хоткею СНАЧАЛА мгновенно снимаем полные экраны всех дисплеев в память
(`RegionCapturer.captureFull`, один fetch `SCShareableContent`), БЕЗ оверлея и активации — живой
экран не трогается, истинное состояние попадает в пиксели. Затем показываем эти снимки как подложку
выделения (`SelectionView.backdrop`: кадр + затемнение, в рамке кадр на полном контрасте), и в
конце кадрируем уже снятое изображение (`FrozenScreen.crop`), без повторного живого захвата.
Координатная математика (`CoordinateMath`) переиспользована для кропа CGImage. Экран на время
выделения визуально застывает — ожидаемый признак, что кадр снят. Задержку-countdown отложили как
отдельный опциональный режим.

---

## 16.06.2026 — ресайз карточки: краевая модель и почему убрали курсор

### Курсор ресайза убран намеренно (ограничение macOS, подтверждено Apple DTS)

Несколько итераций курсор у углов «мигал»/«не ловился». Перебрали `resetCursorRects`, `cursorUpdate`,
`NSCursor.push/pop` — все вели себя одинаково нестабильно. Причина не в механизме, а ниже:
[Apple Developer Forums](https://developer.apple.com/forums/thread/738051) — фоновому (неактивному)
приложению window server **не даёт менять курсор** над своим окном, перебивая стрелкой; инженер DTS
подтверждает, рабочего обхода в публичном API нет (только активировать приложение, ценой фокуса).
Трей — `nonactivatingPanel` фонового агента, ровно эта конфигурация. Поэтому курсор убрали совсем:
findability даёт не вид курсора, а крупная предсказуемая зона.

### Краевая модель ресайза

Тянем не угол, а одну ВНУТРЕННЮЮ сторону карточки (полоса `EdgeHandle` ±`resizeBand`, центрирована
на крае, чуть выходит наружу). Какая сторона — по позиции трея: трей справа → левый край, слева →
правый, сверху → нижний, снизу → верхний. Это само снимает конфликт направления: внешний край
приколочен раскладкой к краю экрана, поэтому внутренний (который тянем) идёт за курсором 1:1.
До этого пробовали 4 угловые ручки с диагональными курсорами — отказались: соседние угловые зоны
перекрывались (зона вылезает за край больше, чем зазор), курсоры с противоположными диагоналями
дёргались (диагноз снят логом фактических frame ручек). Контейнер карточки на `resizeBand` больше
карточки, поля пропускают клики сквозь (`CardContainer.hitTest`).

### Доводки заодно

- Тайминги анимаций ускорены и сделаны почти незаметными: движение ~160ms, fade кнопок 90ms,
  стаггер 15ms, везде ease-out без overshoot.
- Свайп между Spaces гасил стекло (не-key окно): `ThumbnailManager` на `activeSpaceDidChange`
  пере-key'ит хост, если курсор над треем; `PinnedWindow` берёт key на ховере.

---

## 15.06.2026 — фикс: захват на втором мониторе

### Симптом

На втором мониторе ⌘⇧4 не работал: затемнение не появлялось, выделение не начиналось —
«ничего не происходит». На главном экране всё ок.

### Причина (подтверждена логом фактических frame)

`OverlayController` создаёт по окну на каждый экран. Окно создавалось через
`NSWindow(contentRect:…:screen:)` с `contentRect = screen.frame` (глобальные координаты) И
параметром `screen:` того же экрана. Этот инициализатор трактует `contentRect` **относительно
origin переданного экрана**, поэтому на дисплее слева (origin x = -1728) смещение применялось
дважды: -1728 + -1728 = -3456. Окно улетало за пределы экранов, второй монитор оставался без
оверлея, клики там не попадали ни в одно окно. Главный экран (origin 0,0) не страдал — для него
относительные координаты равны глобальным.

### Фикс

Создавать окно **без** параметра `screen:` (тогда `contentRect` — глобальный), точную посадку
добивать явным `setFrame(screen.frame)`. Плюс `OverlayWindow.constrainFrameRect(_:to:)` возвращает
рамку без правок — иначе AppKit «подтягивает» borderless-окно так, чтобы титул остался на экране,
и снова уносит оверлей с дисплея, имеющего отрицательный origin. Также `SelectionView`
переопределяет `acceptsFirstMouse → true`: оверлеи экранов кроме главного не key, и без этого
первый клик тратился бы на активацию окна, а не на старт выделения.

Координатная часть захвата (`RegionCapturer` по `displayID`, `CoordinateMath` с y-flip по высоте
конкретного дисплея) была корректна — её не трогали.

### Процессный вывод

До находки было две впустую отгруженные «правдоподобные книжные» правки (`acceptsFirstMouse`,
затем `constrainFrameRect`) — каждая стоила полного круга через пользователя, а вторая ещё и
усугубила баг. Правду дал не очередной guess, а диагностическое логирование фактических `frame`
окон, добавленное только на третьей итерации. Урок: для дефекта «на A работает, на B нет» сначала
инструментировать разницу A/B, и лишь потом выдвигать причину. Логирование затем снято.

---

## 15.06.2026 — v2: доводка UX карточки и хаба

Поверх перехода на одно окно-хост — четыре правки по обратной связи.

1. **Кнопки карточки появляются/исчезают плавным fade**, а не скачком `isHidden`. Анимируем
   `alphaValue` (0.15s) через `NSAnimationContext`; кнопки стартуют с alpha 0, completion прячет
   `isHidden=true` только то, что реально догасло (мышь могла вернуться и заново зажечь).
2. **Зона ресайза переписана архитектурно.** Было: хрупкое определение бокового края в `mouseDown`
   тела через `edgeAt()` — тяжело нащупать. Стало: отдельные вью-ручки `ResizeHandle` по обоим
   боковым краям (во всю высоту, ширина `edgeBand`). У каждой своя tracking-область с `cursorUpdate`
   (надёжный курсор `.resizeLeftRight`, без капризов `resetCursorRects`) и свой захват drag. Ручки
   лежат поверх изображения, но под кнопками — в верхнем ряду побеждает кнопка. Тело карточки теперь
   отвечает только за drag-out и даблклик.
3. **Цифра хаба — нативный адаптивный цвет** (`controlTextColor`), а не форсированный белый. Белый
   был костылём против muted-бага, который ушёл вместе с переходом на одно key-окно; на светлом
   фоне/светлой кнопке он не читался. Теперь система сама даёт контраст под тему и под стекло.
4. **Убран тень-градиент у обрезанного края карточки.** Кроп изображения под высоту экрана
   остаётся (CardSizing), а визуальный индикатор «кадр продолжается» удалён как лишний шум.

### Что протестировано

- Сборка `build.sh`: чистая. Running app перезапущен (kill + `open`). Живой тест мышью — за
  пользователем; подтверждён прогресс по всем четырём пунктам.

---

## 15.06.2026 — v2: трей на одном окне-хосте (настоящий фикс 4 багов)

### Почему предыдущая попытка провалилась

Запись ниже («key-флаппинг») чинила симптомы и не сработала. Ключевая ошибка — `override var
isKeyWindow { true }`: это переопределение геттера, а система рисует стекло, сверяясь с
**реальным** состоянием key-окна через window server, а не вызывая наш геттер. То есть это был
no-op, кнопки так и оставались приглушёнными до клика. Подтверждено источником: на
[Apple Developer Forums](https://developer.apple.com/forums/thread/818901) ровно этот вопрос про
macOS 26 остался без ответа даже у DTS — **публичного API заставить не-key панель рисовать
активное стекло не существует**. Активный вид рисует только key-окно. При множестве плавающих
панелей key может быть лишь одна, поэтому мульти-панельная архитектура физически не может показать
активное стекло на всех контролах одновременно.

Отдельный процессный провал: «исправлено» объявлялось по чистой сборке, без перезапуска running
app — пользователь несколько итераций смотрел на старый бинарник.

### Решение — одна панель-хост

Вместо N плавающих панелей — ОДНА прозрачная nonactivating-панель `TrayHostPanel` на весь экран,
key. Карточки и хаб теперь её **сабвью**, а не отдельные окна. Это разом снимает все четыре
дефекта:

1. **Стекло приглушено до клика.** Одно key-окно, конкуренции за key нет → стекло активно сразу.
   Хост делается key при показе и на ховере карточки (`hostBecomeKey()`); флаппинга нет — окно одно.
2. **Клик по хабу не сворачивал.** В key-окне штатный `target/action` NSButton работает —
   ручной перехват `mouseDown` убран, хаб снова обычный `GlassButton`.
3. **Хаб «рос» и были видны края viewport.** Press-lift стекла больше не обрезается панелью
   размером в кнопку: вокруг хаба есть поле общего хоста (`NSView` не клипует сабвью по умолчанию).
4. **Нестабильность контролов и зоны перетаскивания.** Один маршрут событий в одном окне вместо
   гонок между панелями и ручных хаков.

Клики по пустым (прозрачным) областям хоста проходят в приложения под треем: borderless-окно с
прозрачным фоном пропускает мышь per-pixel ([NSWindow.ignoresMouseEvents — поведение по
умолчанию](https://developer.apple.com/documentation/appkit/nswindow/1419354-ignoresmouseevents)).
Тень карточки раньше давал `panel.hasShadow`; теперь — слой-контейнер `container` с
`shadowPath` (masksToBounds=false), а скругление/клип изображения остаётся внутри `ThumbnailView`.
Анимации (влёт, сворачивание-в-хаб, разворачивание) двигают frame/alpha сабвью, не окна.
Координаты карточек/хаба считаются глобально и конвертируются в систему хоста (`toLocal`).

### Неизбежный размен

Активное стекло требует key-окна, а key-окно у nonactivating-панели перетягивает на себя
клавиатуру и снимает фокус-вид с окна активного приложения, **пока трей в фокусе**. Полностью
пассивный трей в фоне всё равно будет глушиться — это ограничение системного `.glass`, обхода нет
(тот же тред Apple). Размен принят осознанно.

### Что протестировано

- Сборка `build.sh`: чистая. Running app перезапущен (kill старого PID + `open`) — проверяется
  именно новый бинарник.
- Автотестов в проекте нет; оконно-стеклянный слой юнит-тестами не покрывается. Живой тест мышью
  (ховер-reveal без клика, сворачивание хабом, press-lift, ресайз за край, проброс кликов сквозь
  пустоту) — за пользователем.

---

## 15.06.2026 — v2: чиним 4 бага трея и хаба (key-флаппинг)

### Корень

Все четыре дефекта свелись к одному источнику — `makeKey`-флаппингу между nonactivating-панелями.
Карточки делались key по ховеру, хаб — по показу; панели наперебой отбирали системное key-окно,
и в момент этого скачка ломался ховер-reveal, гасла цифра хаба и съедался клик по хабу
(clickthrough). Решение: нигде не звать `makeKey`, а активный вид стекла обеспечить самоотчётом
`isKeyWindow = true` у панели — это только отрисовка, системное key-окно активного приложения не
трогается. Подход заменяет механизм из записи 14.06.2026 (там карточки/хаб реально делались key).

### Что исправлено

1. **Ресайз карточки за край ловился в ~1px.** `ThumbStyle.edgeBand` 8→16 — крупнее зона хвата.
2. **Ховер по карточке не показывал кнопки «Копировать»/«Закрыть».** Убран `window?.makeKey()` из
   `ThumbnailView.mouseEntered` (он и ломал reveal); активный вид кнопок теперь даёт
   `ThumbnailPanel.isKeyWindow = true`.
3. **Цифра хаба то белая, то приглушённая.** Задаём её явным `attributedTitle` (белый цвет + шрифт
   + центрирование) вместо голого `title`, который система перекрашивала под состояние кнопки;
   плюс `HubPanel.isKeyWindow = true` держит стекло в активном виде.
4. **Клик по хабу не сворачивал трей.** В borderless nonactivating-панели модальный tracking-loop
   ячейки `NSButton` не доводил `target/action` до диспетчеризации. Подкласс `HubButton` ловит клик
   сам: подсветка (`isHighlighted`) на нажатии, `onClick` на отпускании внутри `bounds`,
   `super.mouseDown` не зовём (его цикл съел бы `mouseUp`). `target/action` обнулены — без двойного
   срабатывания. Для наследования с `GlassButton` снят `final`.

### Что протестировано

- Сборка `build.sh`: чистая, подпись Apple Development проходит.
- Живой тест мышью (ховер-reveal, цвет цифры, клик-сворачивание, ресайз за край) — за пользователем:
  синтетический клик/ховер на фоновой панели не воспроизводится без Accessibility у терминала.

---

## 14.06.2026 — v2: трей миниатюр и нативный Liquid Glass

### Что сделано

От одной миниатюры с кнопкой перешли к трею: несколько снимков выкладываются колонкой/рядом
у угла экрана, у самого угла — круглая нативная Liquid Glass кнопка-хаб со счётчиком. Клик по
хабу растворяет карточки в него (сворачивание) и проявляет обратно (разворачивание); новый
снимок авто-разворачивает трей и влетает scale+fade. На карточке по ховеру появляются кнопки
«Копировать» и «Закрыть» (нативные `.glass`), двойной клик открывает полный кадр в отдельном
ресайзибельном окне. Положение трея (слева/справа/снизу/сверху) настраивается.

Вся переделка прошла через сплошной аудит кода против macOS 26 / Apple HIG (мульти-агентный,
6 дименшенов, состязательная проверка каждой находки двумя линзами) — отсюда список принципов
ниже, а не «по памяти».

### Liquid Glass — нативные компоненты и системные метрики

1. **Кнопки — `NSButton` + `bezelStyle = .glass`** (macOS 26). Это и есть документированный путь
   Apple для кнопок, плавающих над контентом (WWDC25 session 310). Стекло, состояния
   rest/hover/pressed/focus и press-lift рисует система; форму задаёт `borderShape`
   (`.capsule` для иконка+текст, `.circle` для иконки/цифры), отдельного corner-radius нет.
2. **Ноль захардкоженных размеров хрома.** Размер символа — из `NSFont.systemFontSize(for: .large)`,
   а не магического `14`; диаметр круглых кнопок — из их `fittingSize`; диаметр хаба — из
   `fittingSize.height` large-контрола, а не `44`. Длительности анимаций — именованный `TrayAnim`.
   Удалён мёртвый токен радиуса кнопки. Окно настроек — Auto Layout, сайзится по контенту.
3. **`NSGlassEffectContainerView` НЕ применяли — проверено эмпирически.** Контейнер сливает
   `NSGlassEffectView`-поверхности, а на `.glass`-кнопки не влияет (одиночные и «в контейнере»
   рендерятся идентично). Оборачивать кнопки в него — карго-культ.

### Корневое: `.glass` в не-key окне рисуется приглушённо

Главный баг состояний: `.glass`-кнопка в окне, которое не является key, система рисует в
**неактивном (приглушённом) виде** — выглядит как disabled. Доказано прямым сравнением (key
vs не-key панель: серые кнопки против белых на полном контрасте).

- **Карточка делается key по ховеру** (`window.makeKey()`). Панель `.nonactivatingPanel` —
  это не активирует приложение и не отбирает фокус у переднего окна (фоновое окно не тускнеет),
  но кнопки сразу рисуются активными, а не после клика.
- **Хаб — отдельный key-capable подкласс панели** (`HubPanel.canBecomeKey = true`) и делается
  key при показе. Иначе клик по `NSButton` в borderless nonactivating-панели не диспатчился
  (хаб «не сворачивал»), а цифра рисовалась серой. Теперь клик срабатывает, цифра — белая.
- Передний план всегда на полном контрасте: reveal кнопок — через `isHidden` (чётко, без
  alpha-ramp), а не через альфу всего контрола; у хаба убран любой масштаб цифры. Снят
  фокус-ринг (`focusRingType = .none`) — в мышиных плавающих панелях он лишний.

### Моушн — нативный словарь, синхронно с дисплеем

- Покадровый `Timer 1/60` заменён на **`CADisplayLink`** (`FrameAnimator`): движение идёт по
  vsync, корректно на ProMotion 120 Гц. Кривые с оседанием (ease-out / лёгкий overshoot)
  вместо симметричного smoothstep.
- Новый снимок влетает scale (0.92→1) + fade; сворачивание — dissolve карточки в точку хаба;
  разворачивание — emerge из хаба с оседанием. Стаггер между карточками.
- Убран чужеродный белый flash при копировании (полноэкранный белый зарезервирован за моментом
  съёмки экрана). Единственный фидбэк копирования — галочка + согласованная подпись «Скопировано».

### Поведение и доступность

- Карточка: ресайз только за левый/правый край (курсор строго по оси ширины; высота производная),
  drag-out файла, двойной клик — полный кадр. Кнопки «Копировать»/«Закрыть» по ховеру.
- Окно «полный кадр» (`PinnedWindow`): системные «светофоры» + `Esc` — закрыть, `⌘C` — копировать,
  тултипы; дублирующий glass-крестик убран.
- VoiceOver хаба: число — `accessibilityValue`, состояние трея — label; a11y «Отбросить снимок»
  на деструктивной кнопке, тултипы. Двойной контур выделения в оверлее (читается на любом фоне).
- Пункт меню очищен от нерабочего акселератора `⌘⇧4` (его ловит глобальный Carbon-хоткей).

### Сборка/подпись

`build.sh` определяет Apple Development / Developer ID identity и подписывает им — тогда хеш кода
стабилен и доступ «Запись экрана» переживает пересборку. Ad-hoc остаётся фолбэком.

### Сознательные отступления

- **Клавиатуру на плавающей карточке не делали:** это потребовало бы делать панель key по ховеру
  и воровать фокус активного приложения — антинативно для пассивной миниатюры. Клавиатуру дали
  окну «полный кадр», которое и так key.
- Кнопка «развернуть» на карточке убрана — полный кадр открывается двойным кликом.

### Что протестировано

- Сборка: чистая. Рендер сцены (трей, ряд кнопок, хаб), полный цикл свернуть→развернуть и влёт
  новой карточки проверены на скриншотах через тестовый бинарник из реальных классов сцены.
- Корень состояний (key→активные кнопки, не-key→приглушённые) и активный вид кнопок/цифры после
  `makeKey` подтверждены захватом окон по ID.

### Не проверено автоматикой

- Реальные клик/ховер на фоновой панели синтетикой не воспроизводятся (постинг событий требует
  Accessibility у терминала) — проверялся механизм (key-состояние), а не имитация клика. Живой
  тест мышью — за пользователем.

---

## 14.06.2026 — v1: первый рабочий срез

### Что сделано

Меню-бар агент для macOS, делающий быстрый скриншот выбранной области по глобальному
хоткею и кладущий его в буфер обмена через миниатюру с кнопкой «Копировать».

Сценарий: `⌘⇧4` → затемнённый оверлей с перекрестьем → выделение рамкой → по отпусканию
мыши снимок региона делается сразу → миниатюра в правом нижнем углу с кнопкой
«Копировать» → клик кладёт изображение в буфер и закрывает миниатюру. `Esc` отменяет.

### Окружение

- Swift 6.2.1 (Xcode toolchain), `swiftc`, цель `arm64-apple-macos26.0`.
- macOS 26+ (Tahoe и новее).
- Компиляция одним вызовом `swiftc` всех `Sources/*.swift` в один модуль, без Xcode-проекта.
- Языковой режим `-swift-version 5` — обязателен (см. ниже).

### Ключевые технические решения

Решения зафиксированы по итогам исследования актуальных API (со ссылками на Apple
Developer Forums и SDK-диффы), а не «по памяти».

1. **Захват — ScreenCaptureKit `SCScreenshotManager.captureImage(contentFilter:configuration:)`.**
   `CGDisplayCreateImage` и `CGWindowListCreateImage` обероблены (obsoleted) в SDK 15.0+
   и не компилируются под актуальный SDK. SCScreenshotManager отдаёт `CGImage` прямо в
   памяти, с типизированными ошибками и точным контролем Retina-пикселей.

2. **Хоткей — Carbon `RegisterEventHotKey`.** Единственный механизм без запроса прав
   (ни Accessibility, ни Input Monitoring). `NSEvent.addGlobalMonitorForEvents(.keyDown)`
   молча требует Accessibility и без неё не срабатывает; `CGEventTap` — ещё тяжелее.
   Carbon формально deprecated, но работает и остаётся стандартом для одиночного хоткея.
   Ограничение macOS 15/26: комбинация обязана содержать Command или Control (иначе
   `RegisterEventHotKey` вернёт `-9868`). `⌘⇧4` это выполняет. Проверено: при запуске
   лог `RegisterEventHotKey вернул noErr`.

3. **Координаты — два разных y-flip, которые нельзя путать.**
   `SCStreamConfiguration.sourceRect` отсчитывается СВЕРХУ-СЛЕВА и ЛОКАЛЬНО для дисплея
   (не глобально по десктопу). Поэтому: вычитаем `frame.origin` дисплея (убираем смещение
   мульти-монитора), затем flip по высоте ИМЕННО ЭТОГО дисплея. Глобальный flip по высоте
   меню-бар-дисплея (для CGDisplayBounds) тут НЕ применяется. Размеры `width/height` —
   в ПИКСЕЛЯХ: точки × `pointPixelScale` (иначе на Retina снимок вдвое меньше и размытый).
   Логика выделена в `CoordinateMath` и не зависит от AppKit-типов (чистые `CGRect`).

4. **Буфер обмена — одна транзакция PNG + TIFF.** PNG надёжнее всего читают Slack и
   прочие Chromium-приложения, TIFF — родной для AppKit (Preview, Заметки). Нельзя в
   одной транзакции мешать `writeObjects([...])` и `setData(...)`.

5. **Сборка — `.app`-бандл со стабильным `CFBundleIdentifier`.** TCC («Запись экрана»)
   привязывается к бандлу; на Tahoe голый бинарник может вообще не появиться в списке
   разрешений. Запуск через `open`/Finder, не exec бинарника.

### Подводные камни и как обошли

- **Затемнение в кадре.** Перед захватом прячем оверлеи (`orderOut`) и даём компоновщику
  ~50 мс (`asyncAfter`), чтобы затемнение ушло из следующего кадра, и только потом
  вызываем `captureImage`.
- **Swift 6 strict concurrency** отвергает Carbon C-колбэк и глобальное состояние хоткея —
  поэтому `-swift-version 5`.
- **Захват `NSScreen` через границу `Task`** давал предупреждение Sendable. Рефакторинг:
  `RegionCapturer.capture` принимает Sendable-данные (`CGRect` + `CGDirectDisplayID`),
  а `NSScreen` для миниатюры заново ищется на главном потоке по `displayID`. Сборка без
  предупреждений.
- **Borderless-окно не получает клавиши.** `OverlayWindow` переопределяет
  `canBecomeKey/canBecomeMain → true`; плюс локальный монитор `Esc` в `OverlayController`
  на случай мульти-монитора (key-окно одно, а отменять надо отовсюду).
- **Удержание объектов.** `AppDelegate` держит `CaptureController` и `StatusItemController`;
  `OverlayController` держит массив окон; `GlobalHotKey` держит `EventHotKeyRef` и
  `EventHandlerRef`. Иначе хоткей перестаёт срабатывать, окна освобождаются на лету.

### Права (TCC)

- Хоткей `⌘⇧4` — НОЛЬ запросов прав.
- «Запись экрана» — один системный запрос при первой попытке захвата. Обойти нельзя:
  `screencapture` CLI требует ровно того же. Логика: `CGPreflightScreenCaptureAccess()`
  (тихая проверка) → при первом разе `CGRequestScreenCaptureAccess()` (системный диалог)
  → при повторных неудачах свой alert со ссылкой в Системные настройки.
- Caveat ad-hoc-подписи: `codesign -s -` меняет хеш кода при каждой сборке, поэтому TCC
  считает пересборку новым приложением и заново спрашивает доступ. Для стабильного доступа
  подписать фиксированным self-signed/Developer ID, не меняя `CFBundleIdentifier`.

### Системный ⌘⇧4

По решению заменяем системный `⌘⇧4` своим. `scripts/disable-system-shortcut.sh`
отключает символьный хоткей id 30 («Снимок выбранной области в файл»), сохраняя привязку
для обратимости; `scripts/enable-system-shortcut.sh` возвращает. Применено через
`activateSettings -u`. Проверено: `id 30 enabled = 0`. На части версий macOS изменение
символьных хоткеев полностью вступает в силу после повторного входа в сессию.

### Что протестировано

- Сборка: чистая, без предупреждений.
- Запуск: процесс стартует, не падает, регистрирует хоткей (`noErr`), создаёт пункт меню.
- Системный `⌘⇧4` отключён (подтверждено чтением plist).

### Что требует ручной проверки (нужен живой пользовательский ввод)

- Полный цикл захвата: выдать «Запись экрана» при первом `⌘⇧4`, затем выделить область и
  убедиться, что снимок корректен (Retina-резкость, цвет, точные границы), миниатюра
  появляется справа внизу, «Копировать» кладёт в буфер и закрывает.
- Поведение на втором/внешнем дисплее.

### Известные ограничения v1 / TODO

- Выделение, пересекающее границу двух экранов, клипуется до экрана, где начался drag
  (полноценного сшивания мульти-дисплея нет).
- Хоткей зашит (`⌘⇧4`), без UI-настройки.
- Только буфер обмена, без записи файла на диск (по требованию).
- Курсор в снимок не попадает (`showsCursor = false`).
- Подпись ad-hoc — при пересборке TCC переспросит доступ.
