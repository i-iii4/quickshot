# QuickShot Capture Architecture

Status: direct snapshot engine, frozen custom selection, foreground-gated cursor
ownership, protected tray layering, and finite tray overflow are implemented.
Headless gates pass. The foreground single-cursor lifecycle and tray pointer
routing have passed manual runtime acceptance. Repeated latency, fullscreen
Spaces, and unusual multi-display layouts remain runtime release gates.

## Decision

QuickShot returns to its established custom selector and adopts a CleanShot-like
freeze-first pipeline:

```text
hotkey
  -> direct CoreGraphics snapshots before QuickShot activation
  -> immutable per-display frozen backdrops
  -> bounded foreground ownership and one cursor lease
  -> custom QuickShot cursor and selection frame
  -> in-memory crop on mouse-up
  -> thumbnail and clipboard
```

The screenshot represents the hotkey moment. The source application's visible
hover state is captured before QuickShot owns focus or pointer input. Selection
then happens over that frozen image.

The previous `/usr/sbin/screencapture` migration is retired because completion
latency was controlled by the system process and varied by several seconds.
The earlier ScreenCaptureKit stream and one-shot paths remain retired because
they produced delayed or stale frames.

## Implemented Visual Layer

The rollback restores the existing, tested visual implementation instead of
redrawing it:

- `SelectionView` and `OverlayController`;
- the fixed vector crosshair and matching selection outline;
- lightweight fill inside the selected area;
- `CaptureTypes` and `CoordinateMath`;
- behavior and visual-matrix tests for all drag directions and small regions.

`FreshRegionCapture` and the system capture session have been removed. The
restored visuals now consume only session-owned direct snapshots.

## Implemented Components

### DirectScreenSnapshotProvider

Owns one direct, in-memory CoreGraphics capture for each active display. It runs
before any QuickShot window is shown or application focus changes. Every session
receives new immutable images; providers cannot expose a previous frame or cache.

All display requests use one ordered compositor lane. Parallel
`CGWindowListCreateImage` calls were measured contending inside the same
WindowServer capture proxy and are prohibited. A single union image is also
prohibited because mixed-DPI desktops are flattened at one scale and lose native
Retina pixels. Each display therefore remains a full-resolution image while the
batch itself is serialized.

The deprecated CoreGraphics dependency is isolated behind this provider so it
can be replaced without changing selection UI, session lifecycle, crop logic, or
delivery.

### CaptureSession

Owns one explicit lifecycle:

```text
idle -> snapshotting -> selecting -> delivering -> idle
```

Only an active selector blocks another trigger. Once mouse-up releases selection,
crop and delivery retain their own session and no longer block the next hotkey.
Success, cancellation, failure, and shutdown share one idempotent cleanup path.

### FrozenSelectionController

Builds one overlay per display only after all required snapshots are ready. A
static backdrop layer holds the frozen image; the existing lightweight selection
chrome is rendered above it. The source hover state is already immutable at this
point. QuickShot then becomes foreground and one AppKit cursor lease replaces the
system pointer with the custom crosshair.

Mouse-up crops the session-owned backdrop. It never initiates another screen
capture.

### SelectionPresentationCoordinator

Owns the complete foreground and cursor transaction. Prepared windows remain
alpha-zero and pointer-passive while activation is pending. Cursor suppression is
forbidden until `didBecomeActive`; only after successful activation and one AppKit
cursor lease does a zero-duration transaction enable input and reveal the frozen
presentation. Rejection, loss, or a `500ms` timeout cancels without revealing UI.

The public forced-activation compatibility call is isolated in this coordinator.
It is needed because arbitrary source applications do not participate in the
modern cooperative yield protocol, while Apple documents that background cursor
suppression is not guaranteed. Teardown removes all overlay content before
restoring the pointer, then yields activation back to the captured source app.

### WindowCaptureProtection

Every QuickShot-owned window remains `sharingType = .none`, including tray,
cards, settings, status-menu surfaces, and selection windows. Protection is
reapplied before capture; the tray is never hidden, moved, or faded.

During selection the frozen backdrop, protected QuickShot interface, and
selection chrome occupy three explicit window levels in that order. The tray
therefore stays visible above the frozen pixels while the transparent selection
chrome remains pointer owner above the tray.

### ThumbnailViewport

The tray has a finite viewport rather than an unbounded list of windows. When it
fills, the viewport follows the newest screenshot and animates the oldest visible
card out; older screenshots remain retained and can be reached by scrolling over
the tray. Manual scrolling disables follow-newest until the viewport returns to
its newest boundary or another screenshot is captured.

Hidden cards remain hidden through tray, insertion, removal, and interrupted
animation completion. No completion path may restore every card indiscriminately
or expose an overflow card at a stale/default coordinate.

## Implementation Result

1. The established selection geometry is reused without visual approximation.
2. `DirectScreenSnapshotProvider` resolves the runtime CoreGraphics symbol and
   captures full-resolution displays through one serial compositor lane without
   retaining a cache.
3. `CaptureSession` owns the explicit freeze-first lifecycle and validates the
   session ID plus the complete display set before showing UI.
4. Frozen bitmaps and selection chrome render as separate layers.
   `SelectionPresentationCoordinator` exclusively owns foreground activation and
   one balanced AppKit cursor lease; overlay code cannot alter cursor state.
5. Prepared windows do not accept pointer input. Confirmed activation, cursor
   replacement, input, and reveal form one ordered transaction. All display overlays
   share one visible custom-crosshair owner, so neither the source pointer nor a
   crosshair from another display can remain beside the active crosshair.
6. Mouse-up crops only the initial image. ScreenCaptureKit, the system capture
   process, temporary PNGs, and second capture paths are absent from production.
7. The protected tray remains visible between backdrop and selection chrome.
8. Overflow is a deterministic scrollable viewport that always reveals the newly
   captured item and never remounts hidden windows at stale coordinates.
9. Headless geometry, provider, cursor-lease, lifecycle, overflow, stale-path, and
   UI regression gates run by default. Visible runtime probes remain opt-in.

## Definition Of Done

- Hotkey-time hover, tooltip, menu, and active appearance are present in pixels.
- Exactly one custom cursor is visible before and during drag.
- The cursor and frame retain the established geometry in every drag quadrant.
- No previous frame, stream cache, temporary PNG, or second capture is used.
- QuickShot UI never appears in the frozen backdrop or final crop.
- Normal and fullscreen Spaces, mixed-scale displays, and negative origins work.
- `Esc`, failure, completion, and shutdown hide windows, restore the cursor, and
  return foreground ownership to the source application in that order.
- Ten sequential captures succeed with zero stale or missing cards.
- When the tray overflows, the newest card is visible, all older cards remain
  scroll-reachable, and no card appears outside a valid layout slot.
- The QuickShot tray stays visible but noninteractive during area selection.
- Hotkey-to-selector is at most `120ms` p95 and mouse-up-to-card at most `100ms`
  p95 on the development machine.

The automated portion is green, and manual runtime acceptance confirms one custom
cursor plus immediate desktop input after capture. The direct API still has an
OS-owned latency tail under capture-service contention, so the `120ms` target is
not declared green from short probes. Repeated snapshot plus activation latency,
fullscreen Spaces, immediate drag, and unusual multi-display layouts remain
explicit hardware-dependent release checks.
