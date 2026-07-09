# Interface Model Research

## Goal

QuickShot needs a stronger interface model, not just better-looking buttons.
The current capture contract is UX-first; the next design investigation should
ask whether the application shell can be built on a more coherent component,
state, and automation model.

## Candidate

Native SDK (`vercel-labs/native`) is the first candidate for a spike.

Useful starting points:

- https://github.com/vercel-labs/native
- https://zero-native.dev/
- https://zero-native.dev/quick-start
- https://zero-native.dev/native-ui
- https://zero-native.dev/automation

Native SDK describes itself as a toolkit for native desktop applications:
declarative `.native` markup, Zig application logic, a predictable
message-based state model, a modern component library, a native renderer, and
tooling for building, running, packaging, and testing apps without shipping a
browser or WebView in the binary.

## Why We Are Looking

The active need is not a new button skin. The product needs a cleaner interface
architecture:

- consistent command buttons, action pills, cards, hover states, focus, and
  pointer behavior;
- a UI model that makes regressions in clickability and collapse/expand harder
  to introduce;
- automation that can verify real interaction stories instead of only static
  source markers;
- a component language closer to the Vercel/Geist interaction model without
  copying proprietary Vercel components.

Historical capture regressions remain important, but the Native SDK spike must
not be framed as a screenshot-engine replacement. Screen capture, hotkeys,
window levels, cursor ownership, and capture exclusion are still macOS-specific
system integrations.

## Evaluation Questions

1. Can Native SDK build a menu-bar/tray-style QuickShot shell?
2. Can it express the compact hub, screenshot cards, hover action pills, and
   thumbnail controls with less custom AppKit glue?
3. Can it support or cleanly bridge the required macOS integrations:
   global hotkey, ScreenCaptureKit fresh region capture, exclusion of QuickShot
   UI from captured pixels, overlay window levels, cursor ownership, and
   clipboard writes?
4. Can automation verify the flows that repeatedly regressed:
   hover reveal, button clickability, collapse/expand, close, copy, save, and
   multiple existing screenshots?
5. Can the existing capture UX contract be preserved:
   immediate selection entry, no stale screenshots, no tray blink, and no
   visible duplicate cursor?

## Non-Goals

- Do not blindly rewrite QuickShot because a new framework exists.
- Do not replace the working capture path before the shell and capture bridge
  are proven.
- Do not treat Native SDK as a visual-only button library.
- Do not accept a framework if it improves component styling but weakens
  screenshot timing, capture freshness, global shortcuts, or overlay behavior.

## Spike Plan

1. Run the official minimal example and confirm the local toolchain works.
2. Build a no-capture QuickShot shell prototype: hub, cards, hover action pills,
   collapse/expand, close/copy/save affordances.
3. Test automation coverage against the prototype for pointer and keyboard
   stories.
4. Probe native app capabilities: menu bar/tray presence, borderless floating
   windows, transparent overlay windows, global shortcuts, and clipboard.
5. If required, prove a narrow ScreenCaptureKit bridge while keeping the current
   Swift/AppKit capture implementation as the reference behavior.
6. Decide between three outcomes:
   keep Swift/AppKit and port only the interaction model;
   use Native SDK for the shell while keeping capture in a macOS bridge;
   or reject the framework if it cannot preserve the capture contract.

## Decision Standard

The spike is successful only if it improves the interface model while preserving
the screenshot product contract. Better-looking controls are not enough.
