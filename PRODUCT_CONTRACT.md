# QuickShot UX Contract

This document defines the user experience. Implementation details can change,
but any behavior that breaks this contract is a regression.

The direct freeze-first implementation follows this contract. Automated gates
cover structure, pixels, geometry, and lifecycle; cursor appearance and
fullscreen behavior remain explicit runtime release checks.

## Capture Start

1. `Command-Shift-4` starts exactly one selection session.
2. Repeated triggers during an active session are ignored.
3. Before QuickShot activates or presents a window, it captures one fresh,
   immutable in-memory snapshot of every active display.
4. The pixels correspond to the hotkey moment and preserve the visible hover,
   tooltip, menu, and active appearance of the source application.
5. Selection appears only after those pixels exist. It must not expose a dark
   waiting layer, spinner, progressive backdrop installation, or stale frame.
6. Hotkey-to-selector latency targets `120ms` at p95 on the development machine;
   multi-second ScreenCaptureKit or system-tool waits are release blockers.
7. QuickShot's own windows, hub, thumbnails, settings, and helper UI must not be
   visible inside the frozen pixels or final crop.
8. QuickShot must not hide, move, or fade the tray during capture. Window sharing
   protection must exclude it without visible flicker.

## Before Drag

1. The screen is frozen at the hotkey moment but remains visually unchanged.
2. The only visible selection affordance is the custom QuickShot cursor.
3. The system pointer is hidden; the user must not see two cursors.
4. No selection frame or overlay is drawn until the drag starts.
5. Cursor replacement is atomic: the frozen surface and custom crosshair cannot
   be visible in the same frame as the source application's pointer.

## Drag Selection

1. Mouse-down starts the selection immediately.
2. The selection frame follows the pointer without lag or jumps.
3. The overlay is inverted from the previous model: it appears inside the
   selected rectangle, not outside it.
4. The outside area remains undimmed and live-looking.
5. The inner overlay is light, restrained, and content-preserving. It must not
   obscure the user's ability to inspect what is being selected.
6. The overlay exists only while there is an active selection rectangle.
7. Tiny selections below the minimum useful size are ignored on release.

## Cursor And Frame

1. The visible cursor is QuickShot's vector crosshair.
2. The cursor does not change size, anchor, or shape during drag.
3. The frame and cursor are one design system: same stroke widths, same
   halo/core contrast, round caps, and a deliberate separator where they meet.
4. There is no dot, handle, bridge, duplicate pointer, or flicker.
5. The frame remains stable for all drag directions and small selections.

## Completion

1. Mouse-up finalizes the selected region.
2. The result is cropped from the immutable hotkey snapshot. Mouse-up must not
   start a second screen capture.
3. A successful selection creates exactly one new thumbnail and copies the image
   to the clipboard.
4. No stream, warmed frame, previous screenshot, temporary PNG, or asynchronous
   second capture may become the pixel source.
5. If the initial snapshot cannot be produced, selection does not start and the
   attempt fails cleanly.
6. `Esc`, failure, shutdown, and successful completion restore the system cursor,
   close every overlay, and return focus without leaking session state.
7. Mouse-up-to-card latency targets `100ms` at p95.
8. Teardown is atomic in reverse order: custom chrome and overlay windows vanish
   before the system pointer is restored.

## Tray And Hub

1. Hub click toggles thumbnail collapse/expand.
2. Manual collapse state and hover presentation are separate. Hovering the hub
   temporarily reveals a collapsed tray without changing what the next hub
   click means.
3. Hub and visible card containers form one hover session. Moving from the hub
   or its command row onto any card keeps both the command row and cards open.
4. The hover region is one continuous island: visible hub row, visible cards,
   and the gaps between them (bridged up to `20pt`) with an `8pt` shield and
   exit hysteresis. A slow pointer crossing a gap between controls or between
   the hub and a card must not lose the session or the host's mouse routing.
5. Leaving the complete island starts a `180ms` grace period. Re-entry cancels
   that exact pending close; superseded timers cannot close a newer session.
6. A new screenshot does not permanently expand a collapsed tray. Its
   acknowledgement uses `150ms` insertion, `1.2s` fully visible hold, and
   `130ms` exit. Hover holds it until pointer exit plus the normal grace period.
7. Hub action buttons are clickable and do not accidentally toggle collapse.
8. Per-thumbnail `Copy`, close, resize, and card interactions remain clickable.
9. While a free visible slot exists, thumbnail geometry is append-only: the new
   screenshot takes the next slot away from the hub and existing cards keep
   their origins. Once the finite viewport is full, it advances
   deterministically toward the newest screenshot; older cards remain ordered
   and scroll-reachable, and no card may appear at a stale/default coordinate.
10. The tray/hub position is based on full screen frames and may overlap Dock or
   menu bar.
11. The hub is a compact Vercel/Native-inspired icon+label command surface
   aligned to the House small-control register: 28pt height, 8pt radius, 14pt
   labels, 16pt icons, and 8pt gaps between independent command buttons.
12. Hover reveal exposes three visible actions: `Close`, `Save As`, and
   `Copy All`. `Close` uses the `x` glyph and clears the tray; it is a
   dismissal, not a destructive file operation. They render as icon-only House commands; the command name
   appears as a tooltip. QuickShot draws the tooltip itself (system help
   tags never fire for an inactive accessory app); its window is excluded
   from screen capture and ignores the pointer. The core `Hide`/`Show`
   button keeps its icon+label form.
13. Tooltip timing: a cold show waits `500ms`; while a tooltip is visible,
   moving to a neighbouring command retargets it instantly without a second
   delay. Leaving the commands, pressing, collapsing the row, or any row
   relayout dismisses it immediately.
14. The tooltip is typeset on the House small-control register: control
   height, control radius, button font size, and horizontal control inset
   all come from Native SDK tokens; fill and stroke are sampled from the
   rendered House bubble surface. The window shadow matches card elevation.
15. Per-thumbnail controls use independent House command buttons in a
   token-spaced row, not exclusive-choice `button-group` chrome or
   native Liquid Glass buttons.
16. Empty transparent tray space does not steal pointer events from controls.
17. The tray must not blink during capture completion.
18. The left-to-right action order is always `Close`, `Save As`, `Copy All`,
    regardless of the screen edge.
19. Hover reveal uses the House fast-motion token (`120ms`, or `0ms` under
    Reduce Motion), scales interrupted transitions by the remaining distance,
    changes width through the final frame, and does not rerender Native SDK
    pixels on every display-link tick.
20. At rest only the compact command button is visible. Hover fades in one
    token-owned House Dark bubble behind the complete command row; gaps inside
    the hub belong to that surface and pixels outside it remain transparent.
21. Bubble and button corners are concentric: House `xl` outer radius `14pt`,
    House control radius `8pt`, and their difference is the `6pt` inset.
22. Repeated `mouseMoved` events for an unchanged hover target never restart
    the active reveal animation.
23. While hover is active, cursor exit is evaluated against the stable fully
    expanded footprint independently of the resizing view. Leaving it always
    drives the bubble opacity back to zero, even if AppKit already stopped
    delivering events to the current view bounds.
24. Tray cards, chevron rotation, opacity, and shadows derive from one
    interruptible tray progress. Collection insertion/removal/reflow and the
    clipped vertical count odometer have explicit headless regression tests.

## Screenshot Storage

1. A capture is written to a user-visible folder at capture time, not at export
   time. The file exists independently of the tray.
2. The folder is configurable; it defaults to a QuickShot folder inside the
   user's Pictures.
3. Stored screenshots expire. The retention window is a day, a week, a month, or
   never, and defaults to a week.
4. Expired screenshots are deleted permanently, never moved to the Trash: the
   point of an expiry window is that the data is gone.
5. The sweep runs at launch, periodically while running, and whenever the
   retention setting changes. Shortening the window applies to already stored
   screenshots.
6. The sweep only deletes QuickShot's own files, identified by name, and never
   deletes the file currently open in an editor.
7. Autosave can be switched off entirely. With autosave off nothing is written
   to disk: the screenshot lives in the tray and on the clipboard only.
8. The stored file is not tied to delivery leases. Closing the tray and removing
   a card both leave the file untouched; only expiry or the user removes it.
9. A failure to write (missing folder, no permission, full disk) is reported
   explicitly and never silently drops the capture: the screenshot stays in the
   tray and on the clipboard.

## Annotation

1. Annotation opens for a finished screenshot: double-click a tray card or a
   pinned window. The capture overlay is never repurposed for drawing.
2. Annotations are objects, not baked pixels, for as long as the screenshot
   stays in the tray. Reopening a card returns text as editable text.
3. Undo and redo cover creation, deletion, movement, resizing, property
   changes and text edits, without a depth limit inside the session. A gesture
   occupies exactly one history step; a click without movement occupies none.
4. The canvas zooms between 10% and 800% keeping the point under the cursor
   fixed, never lets the image leave the viewport, never upscales an image
   smaller than the window, and keeps stroke width visually constant.
5. Every tool is reachable by a single letter key, and the full cycle — select,
   create, move, resize, restyle, delete, apply — works without a mouse.
6. Hiding sensitive data has exactly one tool: an opaque bar. Blur and
   pixelation are rejected (`X-8`) — a second, recoverable way to hide is not a
   choice worth offering. Applying the document bakes hiding objects
   irreversibly.
7. Detection of sensitive data uses on-device text recognition, reports what it
   found, and never hides anything silently.
8. Saving rewrites the file in the folder, marks the card `Edited`, and every
   later delivery — clipboard, drag, export — uses the edited version.
9. Closing the tray destroys editable state; the folder keeps the last saved
   version.

## Tray Scrolling

1. When cards do not fit, the tray scrolls continuously with momentum. Nothing
   is hidden because of a lack of space.
2. Cards past either edge collect into a stack with a shrinking step, fading
   and scaling instead of disappearing: the stack is the signal that more
   exists. Depth owns the draw order — a deeper layer is always behind — and
   the stack fits inside the viewport: the near edge tucks behind the hub, the
   far edge reserves a band, because there the screen edge would simply cut the
   layers into translucent stubs.
3. The default position shows the newest screenshots; a new capture returns to
   that position.
4. A continued pull past an edge collapses the tray. The threshold is measured
   in accumulated overshoot, not in touching the edge, and does not depend on
   how many screenshots there are.
5. A two-finger swipe over the hub button expands a collapsed tray and
   collapses an open one; clicking keeps working as before.
6. Scroll-strip geometry matches the static layout on every edge: cards sit at
   the same cross-axis position whether the tray overflows or not. Stack depth
   (opacity and scale) reaches the card views; deep cards give up clicks to
   the top card.
7. The rubber band is visible: past an edge the offset moves with resistance
   and, on release, returns with a short ease-out instead of an instant clamp.
   Phase-less mouse wheels get hard edges and no rubber band.
8. Content follows the fingers: the scroll delta is applied with its own sign.
   Mouse wheels report line units, so a notch is scaled to points - a notch
   that moves the strip by one point is a defect.
9. A scroll frame only moves cards. Card widths, hub position and resize modes
   belong to layout changes, not to every scroll event.
10. Exactly one card shows its hover buttons: the one under the pointer. Cards
   that leave the pointer during a scroll never receive `mouseExited`, so the
   hover owner is reassigned after every scroll frame.
11. Scrolling is owned by the tray window, not by the view under the pointer.
   Empty tray space and card resize bands deliberately pass clicks through and
   therefore hit-test to nothing, so gesture delivery cannot depend on them: a
   gesture must survive the gaps between cards, and momentum must keep the
   strip moving after the cards have left the pointer. Scrolling over the hub
   button stays the collapse swipe.

## Editor Interface

1. Every control in the editor toolbar and on a tray card dispatches its
   command: a control that does nothing when pressed is a defect of the same
   weight as a crash.
2. Controls are icon-first in the design-system register: tools and style as
   selectable icon groups, colour as literal swatches matching the drawing
   palette, commands as icon buttons. Every control carries an accessible name
   that explains the action and surfaces it as a hover tooltip. Visible one-
   and two-letter codes are prohibited: they require a legend the user does
   not have.
2a. Style properties are contextual: colour, stroke weight and fill appear only
   while something is selected, and transform commands only in their own mode.
   With nothing selected the toolbar shows at most 16 controls. A permanent row
   of thirty controls is a pile whether it is spelled in words or in icons.
3. The toolbar lays out without clipping or overlapping the canvas at every
   window width from the minimum to full screen, splitting into short grouped
   rows when the window is narrow rather than pushing controls past the edge.
4. Commands are grouped by purpose: tools, style, history and delivery.
5. Crop and rotate exist as first-class operations and change the size and
   orientation of the exported image.
6. Editor state persists across an application restart while the screenshot
   file is alive, as internal state with no compatibility guarantees: a
   mismatch discards it whole and leaves the screenshot as an image.
7. The canvas shows the screenshot upright: display orientation matches the
   capture, verified by a pixel test, and export orientation stays
   authoritative. Text and counter digits are drawn in the same orientation on
   screen and in the export, verified by measuring ink distribution rather than
   asserting that something was drawn.
8. One user gesture is one step of undo history. Changing the selection is not
   an edit and never records a step; a gesture that changes nothing restores
   the redo it suspended; reopening an editor loads restored annotations as the
   initial state, so the first undo cannot erase them.
9. Detection of sensitive data reports only findings. Nothing found means no
   window at all, and closing the editor cancels a scan in flight.

## Delivery Formats

1. A copied screenshot offers PNG, TIFF and a file URL, as before. PNG and the
   file URL are real data; TIFF is promised and encoded only if the receiving
   application asks for it.
2. TIFF is never encoded eagerly. Measured on a 3456x2234 frame: one TIFF
   encode costs about 30 MB of process footprint and does not give it back,
   linearly per capture, while PNG costs about nothing. A few captures in a row
   pushed the process into hundreds of megabytes, the machine into memory
   pressure, and display capture into the slowdown that made the hotkey look
   dead.
3. A prepared artifact retains the PNG and the file URL only - never a
   full-resolution decoded frame or an uncompressed TIFF.

## Capture Robustness

1. A capture is never refused because the multi-display batch is skewed in
   time. The delivered screenshot comes from one display; skew affects only the
   frozen backdrop on the other screens. Skew is measured, carried on the batch
   and logged when it exceeds the budget.
2. A refused capture is visible to the user. Notifying once per process turns
   every later refusal into silence indistinguishable from a dead hotkey, so a
   successful capture re-arms the notice.
3. A presentation failure tears the overlay down through the same path as a
   normal dismissal: frozen windows disappear first, then the system cursor
   returns. Leaving that to the session owner left the cursor suppressed until
   teardown, and the next capture started with a broken cursor.

## UI Architecture

1. UI architecture changes must improve interaction consistency, state
   ownership, and testability, not only visual styling.
1a. Custom `hitTest` overrides follow the AppKit contract: the incoming point
   is in the superview's coordinate system. Test harnesses dispatch clicks
   through `window.sendEvent`, never by calling event methods on views
   directly — a harness that computes its own hit chain can encode the same
   bug as the product.
1b. Measuring a Native SDK surface by rendering it into a probe frame must be
   followed by a render at the real size. A restored frame with a stale raster
   is scaled into place and reads as a blob of pixels.
2. A new UI framework or shell model must not weaken the capture contract:
   hotkey-time pixels, fast selection entry, capture exclusion, no tray blink,
   no stale screenshots, and no duplicate cursor remain mandatory.
3. Screenshot capture, global hotkeys, overlay windows, cursor ownership,
   capture exclusion, and clipboard writes are product-critical system
   integrations. They cannot be treated as replaceable styling details.
4. Capture admission is one explicit main-actor state machine:
   `idle -> snapshotting -> selecting -> released -> idle`. Released captures
   may finish independently, but all observable delivery is sequence-owned:
   cards remain in capture order and an older completion cannot overwrite a
   newer clipboard result.
5. The production pixel provider is an isolated direct CoreGraphics one-shot.
   ScreenCaptureKit, `/usr/sbin/screencapture`, warmed streams, and frame caches
   are prohibited from the primary path.
6. Selection rendering reuses the established QuickShot cursor/frame geometry;
   it must not be rebuilt as a visually approximate replacement.
7. Every visible command control on hub, thumbnail, pinned, and settings
   surfaces uses an official Native SDK primitive. Local AppKit control
   replicas and SDK-owned color/radius/state overrides are prohibited.
8. The design system covers surfaces QuickShot creates — floating chrome it
   owns over other applications. Surfaces the system owns keep the system's
   own behavior, because there predictability outweighs brand: the menu bar
   entry opens a plain `NSMenu`, so keyboard navigation, VoiceOver, press-drag
   selection, status-item highlight, material, and multi-display placement come
   from AppKit rather than being reimplemented.
9. AppKit owns window hosting, the system status item and its menu,
   traffic-light controls, image presentation, and resize/drag integration.
   Native SDK owns command geometry, tokens, hover, pressed state, hit testing,
   and typed dispatch on the surfaces listed in 7.
10. Swift reads control and motion metrics from the pinned House Dark token pack and
   fitting geometry from runtime semantics. It must not maintain approximate
   duplicate widths or unexplained padding reserves.
11. The visual scheme is fixed to House Dark. High Contrast and Reduce Motion
   changes are forwarded from macOS into the embedded Native SDK runtime and
   must repaint the complete surface in one transition.
12. Production and the default headless regression suite link a `ReleaseFast`
   Native UI library so timing gates exercise the shipped renderer path. Debug
   is reserved for explicit diagnostics.
13. Native SDK `button-group` is reserved for model-owned exclusive choices.
   Independent commands use a `row`; House `button-group` provides the attached
   segmented treatment only for exclusive selection.

## Regression Gates

1. Tests must cover fresh session-owned snapshots, cursor exclusivity,
   cursor-lease balance and ordering, frame/cursor geometry, inner-overlay
   behavior, crop coordinates, teardown,
   tray clickability, hub action clickability, thumbnail close clicks, and
   stale-result rejection.
2. Verification must include zero, one, and multiple existing screenshots in the
   tray.
3. Runtime verification on the user's active machine should prefer log-only
   checks unless synthetic input is explicitly enabled.
4. Headless component tests must cover actual runtime semantics, bounds,
   non-overlap, hover ownership, click dispatch, complete theme repaint, reveal
   ordering, reveal duration, render count, and first-frame budget.
5. Live-window click tests remain opt-in through
   `QUICKSHOT_RUN_LIVE_UI_TESTS=1`; the default suite must not take over the
   user's screen.
6. Release verification includes ten sequential captures, normal and fullscreen
   applications, hover/tooltips, mixed-scale displays, negative display origins,
   cancellation, and the two latency budgets.
7. Headless lifecycle tests include a complete mouse-down/drag/mouse-up before
   snapshot readiness, `Esc` in every phase, randomized crop/encode completion
   order, stale callback rejection, and fail-closed protection-audit failure.
8. Resource gates prove one reusable artifact per screenshot, cleanup after
   card removal/pasteboard replacement/shutdown/crash recovery, and bounded
   memory plus temporary-file use across 100 sequential captures.
9. Release compilation uses Swift 6 complete strict concurrency with zero
   warnings. The Native UI dependency is revision-pinned, and a failed build or
   signing step leaves the previous valid application untouched.
