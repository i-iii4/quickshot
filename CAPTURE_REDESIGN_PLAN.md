# Capture UX Redesign Plan

## Target

QuickShot should feel like a direct selection tool, not like a capture pipeline
the user has to wait for.

Status: implemented in the current branch. Remaining verification should focus
on the user-visible acceptance scenarios, not on restoring the old freeze path.
The next architecture investigation is the interface-model spike documented in
`INTERFACE_MODEL_RESEARCH.md`.

The target flow:

1. Hotkey.
2. Immediate selection mode.
3. Normal-looking live screen before drag.
4. Custom cursor only.
5. Drag starts.
6. Frame and lightweight inner overlay appear.
7. Mouse-up completes the region.
8. Fresh screenshot is delivered to tray and clipboard.

## What Changes

- The old outside dimming model is removed from the target UX.
- The overlay is now inside the selected rectangle.
- The overlay is lighter and appears only after selection begins.
- The area outside the selection remains visually untouched.
- Any waiting belongs after mouse-up, not before selection starts.
- Old screenshots are never acceptable as a fallback result.
- QuickShot UI is excluded through the capture filter, without visually hiding
  the tray.

## Work Plan

1. Rewrite the capture entry around immediate selection mode.
2. Replace outside dimming with the inner-overlay selection design.
3. Keep the cursor/frame as one coherent visual system.
4. Complete capture from the released selection and reject stale results.
5. Exclude QuickShot from captured pixels without blinking the tray.
6. Preserve tray/hub interactions while the capture path changes.
7. Add regression coverage for the UX contract, especially:
   - no overlay before drag;
   - overlay only inside the selected area;
   - no duplicate cursor;
   - no stale screenshot;
   - no visible tray hide/show during fresh capture;
   - buttons remain clickable with zero, one, and multiple screenshots.

## Acceptance

The feature is acceptable only when the user can press the hotkey and begin
dragging immediately, without seeing an old frozen screen, a dark waiting layer,
or a delayed selection affordance.
