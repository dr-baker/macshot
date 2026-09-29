# Stitch screenshots

Open an image in the editor and click the scissors button in its top bar to open Stitch.

- **Remove Rows:** drag over a horizontal band to remove it and reconnect the content above and below.
- **Remove Columns:** drag over a vertical band to reconnect its left and right edges.
- **Move:** drag individual pieces. Nearby edges snap together; hold Option for free placement. Arrow keys move a selected piece by one pixel, or ten with Shift.

Touching edges get a soft, wavy seam. The sidebar controls its color, line width, wave height, blur, and fade width. Toggle **Show stitch seams** to hide the effect. These controls apply to all joins in the current stitch. Undo and redo cover cuts, movement, and seam changes.

Add more images with **Add Images**, paste, or drag image files onto the canvas. Use **Bring Forward** to choose which piece covers an overlap, and the trash button to remove a selected piece.

## Capture a page in pieces

1. Press **Command–Shift–J**, or choose **Stitch Capture** from the menu bar or File menu.
2. Select a region on the display under the pointer. That region stays fixed for the session.
3. Scroll or move around the page, then press the shortcut again for each capture. The floating panel's **Capture** button does the same thing.
4. Press **Enter** to finish and open Stitch. **Escape** cancels the session. The panel also has Finish and Cancel buttons.

Image overlap determines placement when a match is reliable. Scroll direction guides estimated placement when content has no reliable overlap. Estimated pieces are labeled so you can adjust them in the editor. Exact repeated captures are skipped when matching identifies them.

The shortcut can be changed in Settings alongside the other capture shortcuts. Screen Recording access is required. Selection stays on one display; finish and start another session after changing display geometry. A session holds up to 24 captures, subject to image-memory and canvas limits.

## Keep the result

**Copy** and **Save PNG** export the stitched image at its original pixel resolution. **Annotate** opens the rendered result in the regular editor. The Stitch window retains its movable pieces while it stays open. PNG files and clipboard images are flattened; they do not store editable pieces.

New Stitch labels use English fallback in locales awaiting translation.

## Validation

- Full headless suite: 814 tests passed. The final Stitch checks passed all 12 tests, including the added piece-count limit regression.
- Normal, offline, and signed local Release builds passed with the macOS 13 deployment target.
- Installed-app checks covered row and column cuts, undo/redo, dragging pieces, PNG export, capture-region selection, repeated capture, estimated placement, overlap matching, and Finish opening the editable workspace.
- The UI automation sends app-directed keystrokes, so global hardware shortcut delivery and Enter while another app is active still need a physical-keyboard check. The capture controls exercise the same session actions.
- Runtime checks used this Mac's current OS. macOS 13 was checked as a build target, not on a separate Ventura installation.
