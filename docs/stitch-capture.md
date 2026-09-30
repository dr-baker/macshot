# Stitch screenshots

Open an image in the editor and click the scissors button in its top bar to open Stitch.

- **Remove Rows:** drag over a horizontal band to remove it and reconnect the content above and below.
- **Remove Columns:** drag over a vertical band to reconnect its left and right edges.
- **Move:** drag individual pieces. Nearby edges snap together; hold Option for free placement. Arrow keys move a selected piece by one pixel, or ten with Shift.

Touching edges get a soft, wavy seam. Open the seam control in the bottom toolbar to adjust color, line width, wave height, blur, and fade width. The blur is strongest at the center line and fades to untouched pixels across the selected width. Toggle **Show stitch seams** to hide the effect. These controls apply to all joins in the current stitch. Undo and redo cover cuts, movement, and seam changes.

Add more images with **Add Images**, paste, or drag image files onto the canvas. Open **Pieces** in the top bar to select a thumbnail, change its stacking order, or remove it.

## Capture a page in pieces

1. Press **Command–Shift–J**, or choose **Stitch Capture** from the menu bar or File menu.
2. Select the first region with Macshot's normal selection overlay.
3. Scroll or move around the page, then press the shortcut again and select another region. Each region can have a different position and size. The floating panel's **Add Capture** button does the same thing.
4. Press **Enter** to finish and open Stitch. While selecting another region, Enter finishes with the captures already collected. **Escape** cancels the session. The panel also has Finish and Cancel buttons.

Image overlap determines placement when a match is reliable. Otherwise, screen position and observed scrolling suggest which edge to join. Macshot places the new capture against that edge and aligns the perpendicular edge, removing the unused distance between selections. It retains every captured pixel. Captures from displays with different pixel densities use the first display's scale. Estimated pieces are labeled so you can adjust them in the editor. A repeated capture is skipped only when every pixel and its estimated position match.

The shortcut can be changed in Settings alongside the other capture shortcuts. Screen Recording access is required. A session holds up to 24 captures, subject to image-memory and canvas limits.

## Keep the result

**Copy** and **Save PNG** export the stitched image at its original pixel resolution. **Annotate** opens the rendered result in the regular editor. The Stitch window retains its movable pieces while it stays open. PNG files and clipboard images are flattened; they do not store editable pieces.

New Stitch labels use English fallback in locales awaiting translation.

## Validation

Automated checks cover varied region sizes, spatial placement, overlap matching, repeat/queued captures, failure/retry, Finish, cancellation, keyboard routing, raw selection isolation, and the fading blur. Renderer fixtures verify both seam orientations and untouched pixels outside the blur band.

Runtime checks use this Mac's current OS. macOS 13 remains the deployment target; a separate Ventura installation has not been tested.
