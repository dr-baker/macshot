# Stitch screenshots

Open a screenshot in the main editor and select **Stitch**, the scissors tool in the bottom toolbar. Choose **Remove Rows** or **Remove Columns** in its options row, then drag over the space you want to remove. The highlighted band shows the amount being removed. Release to reconnect the remaining content with a fading blur and a center line. This also works on a single large screenshot.

Choose another drawing tool to annotate the result. The editor keeps the same canvas, zoom, top bar, copy and save controls, and undo history. Original image pixels and annotations remain editable.

- **Remove Rows:** drag over a horizontal band to remove it and reconnect the content above and below.
- **Remove Columns:** drag over a vertical band to reconnect its left and right edges.
- **Move:** drag individual pieces. Nearby edges snap together; hold Option for free placement. Arrow keys move a selected piece by one pixel, or ten with Shift.

Touching edges get a soft, wavy seam. Open **Seams** in the Stitch options row to adjust color, line width, wave height, blur, and fade width. The blur is strongest at the center line and fades to untouched pixels across the selected width. Toggle **Show stitch seams** to hide the effect. These controls apply to all joins in the current stitch. Undo and redo cover cuts, movement, and seam changes.

Use **Add Capture** to capture another region into the current Stitch document. While drawing a region, dashed guides suggest matching widths and heights from nearby pieces and continuous rows or columns. A guide turns purple when the selection snaps to that size. Nearby alternatives appear as you approach them; hold **Option** for an arbitrary size. The same guides are available after the first shot in Stitch Capture. You can also paste or drag image files onto the canvas. Open **Pieces** in the Stitch options row to select a thumbnail, change its stacking order, or remove it.

Use the arrangement menu in the Stitch options row to choose **Free Move** or **Packed**. Free Move retains precise overlap and lets you place each piece independently. Packed closes gaps and arranges pieces in tight rows or columns, using the existing layout to choose the direction. While dragging, the grid shows the proposed slot and rearranges neighboring pieces. Release to place the piece, or press Escape to cancel. Switching arrangements, reordering, and background changes support undo.

Open **Canvas** in the Stitch options row to change the fill for missing image areas. **Adjacent edge colors** is the default and samples broad adjacent neighborhoods and smoothly blends their dominant background colors into gaps. Text, icons, and borders are filtered out of the fill. **Solid color** uses your chosen color. **Transparent** leaves missing areas transparent in exports and shows a checkerboard in the editor. Captured pixels remain intact.

## Capture a page in pieces

1. Press **Command–Shift–J**, or choose **Stitch Capture** from the menu bar or File menu.
2. Select the first region with Macshot's normal selection overlay.
3. Each selected region is added automatically, and the selector stays ready for the next shot. Hold **Space** to return input to the page for scrolling or navigation. Release Space to select from a fresh screenshot. Regions can have different positions and sizes. **Undo** removes the last capture and restores the previous alignment reference.
4. Press **Enter** or click **Finish** to open the collected pieces in the main editor. Finish works while the next selection is open. **Escape** cancels the session. The floating panel has only Undo and Finish controls; the first capture remains the anchor.

Image overlap determines placement when a match is reliable. Otherwise, screen position and observed scrolling suggest which edge to join. Macshot places the new capture against that edge and aligns the perpendicular edge, removing the unused distance between selections. It retains every captured pixel. Captures from displays with different pixel densities use the first display's scale. Estimated pieces are labeled so you can adjust them in the editor. A repeated capture is skipped only when every pixel and its estimated position match.

The shortcut can be changed in Settings alongside the other capture shortcuts. Screen Recording access is required. A session holds up to 24 captures, subject to image-memory and canvas limits.

## Keep the result

The main editor's **Copy**, **Save**, **Pin**, **OCR**, and sharing actions work while Stitch is selected and honor the same output preferences. Save's context menu retains the alternate destination action. Selecting effects or beautify returns to the normal image preview and applies those settings to the stitched result on export.

History stores original source images, source crops, piece positions, arrangement, canvas fill, seam settings, and separate annotations. Reopening an editable history entry lets you continue arranging its pieces. Copied images and exported PNG files are flattened. Crop and flip retain pieces when the cropped canvas can be represented by their bounds. A crop containing only uncovered outer margins uses the raster result; undo restores the original pieces.

Closing the editor uses its normal unsaved changes sheet and history workflow. Changing tools keeps the same editor window and retains separate annotations.

New Stitch labels use English fallback in locales awaiting translation.

## Validation

Automated checks cover the native toolbar and contextual controls, single-image horizontal and vertical cuts, shared annotation undo, tool switching without changing zoom or the editor root, pixel-to-point canvas projection, dimension recommendations, continuous spans without bridging gaps, alternate sizes, reverse drags, Option and Shift overrides, display scale conversion, registered layout coordinates, varied region sizes, spatial placement, overlap matching, repeat/queued captures, failure/retry, Finish, cancellation, keyboard routing, raw selection isolation, and the fading blur. Renderer fixtures verify both seam orientations and untouched pixels outside the blur band.

Runtime checks use this Mac's current OS. macOS 13 remains the deployment target; a separate Ventura installation has not been tested.
