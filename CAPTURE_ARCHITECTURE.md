# QuickShot Capture Architecture

Status: direct snapshot engine and frozen custom selection are implemented.
Headless gates, production build, direct runtime latency probe, and the manual
single-cursor lifecycle check pass. Fullscreen Spaces and unusual multi-display
layouts remain explicit release checks on applicable hardware.

## Decision

QuickShot returns to its established custom selector and adopts a CleanShot-like
freeze-first pipeline:

```text
hotkey
  -> direct CoreGraphics snapshots before QuickShot activation
  -> immutable per-display frozen backdrops
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

The deprecated CoreGraphics dependency is isolated behind this provider so it
can be replaced without changing selection UI, session lifecycle, crop logic, or
delivery.

### CaptureSession

Owns one explicit lifecycle:

```text
idle -> snapshotting -> selecting -> delivering -> idle
```

Repeated triggers are ignored until the current session reaches a terminal
state. Success, cancellation, failure, and shutdown share one idempotent cleanup
path.

### FrozenSelectionController

Builds one overlay per display only after all required snapshots are ready. A
static backdrop layer holds the frozen image; the existing lightweight selection
chrome is rendered above it. QuickShot may then own input and hide the system
pointer because the source hover appearance is already preserved in pixels.

Mouse-up crops the session-owned backdrop. It never initiates another screen
capture.

### WindowCaptureProtection

Every QuickShot-owned window remains `sharingType = .none`, including tray,
cards, settings, status-menu surfaces, and selection windows. Protection is
reapplied before capture; the tray is never hidden, moved, or faded.

## Implementation Result

1. The established selection geometry is reused without visual approximation.
2. `DirectScreenSnapshotProvider` resolves the runtime CoreGraphics symbol and
   captures displays concurrently without retaining a cache.
3. `CaptureSession` owns the explicit freeze-first lifecycle and validates the
   session ID plus the complete display set before showing UI.
4. Frozen bitmaps and selection chrome render as separate layers. One
   session-owned `CursorLease` acquires a single AppKit hide before any frozen
   window is visible and releases it only after every overlay is removed.
5. Frozen windows reveal only after QuickShot activation. All display overlays
   share one visible custom-crosshair owner, so neither the source pointer nor a
   crosshair from another display can remain beside the active crosshair.
6. Mouse-up crops only the initial image. ScreenCaptureKit, the system capture
   process, temporary PNGs, and second capture paths are absent from production.
7. Headless geometry, provider, cursor-lease, lifecycle, stale-path, and UI
   regression gates run by default. Visible runtime probes remain opt-in.

## Definition Of Done

- Hotkey-time hover, tooltip, menu, and active appearance are present in pixels.
- Exactly one custom cursor is visible before and during drag.
- The cursor and frame retain the established geometry in every drag quadrant.
- No previous frame, stream cache, temporary PNG, or second capture is used.
- QuickShot UI never appears in the frozen backdrop or final crop.
- Normal and fullscreen Spaces, mixed-scale displays, and negative origins work.
- `Esc`, failure, completion, and shutdown restore cursor, focus, and windows.
- Ten sequential captures succeed with zero stale or missing cards.
- Hotkey-to-selector is at most `120ms` p95 and mouse-up-to-card at most `100ms`
  p95 on the development machine.

The automated portion and single-cursor runtime acceptance are green. Fullscreen
Spaces, immediate drag on slow capture starts, and unusual multi-display layouts
remain explicit hardware-dependent release checks.
