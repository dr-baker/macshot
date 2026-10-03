# Stitch screenshots

Select **Stitch**, the scissors tool in the bottom toolbar of a selected capture or the main editor. Selecting it during capture opens that image in the main editor. Settings → Tools changes its visibility immediately, including in open editors. Drag over the space you want to remove. A vertical drag selects a horizontal band; a horizontal drag selects a vertical band. The highlighted band shows what will be removed before you release. Release to reconnect the remaining content with a fading blur and a center line. This also works on a single large screenshot.

Choose another drawing tool to annotate the result. The editor keeps the same canvas, zoom, top bar, copy and save controls, and undo history. Original image pixels and annotations remain editable.

Faint guides mark capture edges, existing joins, and large clear gaps. Both ends of a removal band snap near a guide; the matched guide turns purple. Gap suggestions leave room for the seam blur and require clear space across all intersecting captures. Hold **Option** to bypass snapping, even after starting the drag. Guides stay fixed during a drag as background analysis finishes.

- **Remove Space:** drag vertically to reconnect the content above and below, or horizontally to reconnect its left and right edges. The band direction stays fixed once the drag resolves. A click or an unresolved diagonal gesture removes nothing.
- **Move:** drag individual pieces. Click an empty area of the canvas or its surrounding gray background to clear the selection border. Nearby edges snap together in Free Move; hold Option for free placement. In Free Move, arrow keys move a selected piece by one pixel, or ten with Shift. Packed pieces can be dragged or reordered through the Pieces controls.

Touching edges get a soft, wavy seam by default. Open **Seams** in the Stitch options row to choose a treatment from its visual previews:

- **Wave:** a fine, wavy line in a fading blur.
- **Blend:** a soft blur without a line.
- **Torn:** an exposed paper strip with ragged edges, fibers, and a small cast shadow. Adjust paper color, paper width, and roughness.
- **Fold:** a matte accordion pleat with a broad face, a tucked return, a narrow paper lip, and a small fading shadow. The paper follows nearby background colors, and the creases converge into the image at each end. Adjust fold depth and strength.
- **Break:** a fine line interrupted by two cut marks.

The panel shows only the controls for the current treatment. Wave and Break have line color, blur, fade width, line width, and shape controls. Blend has blur and fade width. Torn and Fold keep captured content crisp and do not use blur. Each treatment retains its shape settings when you switch. The native **Color** swatch edits line color for Wave and Break, paper color for Torn, and opens **Seams** for Blend and Fold. Blur is strongest at the join and fades to untouched pixels across the selected width. Toggle **Show stitch seams** to hide the effect. These settings apply to all joins in the current stitch. Undo and redo cover cuts, movement, and treatment changes. Crop, flip, previews, copied images, and saved files use the same treatment renderer; magnifiers refresh to show the current seam while censor bakes stay intact.

Use **Add Capture** to capture another region into the current Stitch document. While drawing a region, dashed guides suggest matching widths and heights from nearby pieces and continuous rows or columns. A guide turns purple when the selection snaps to that size. Nearby alternatives appear as you approach them; hold **Option** for an arbitrary size. In Stitch Capture, faint guides are visible before you start the next selection. They show the previous capture's screen edges and nearby layout references, so you can line up the starting corner as well as the final size. You can also paste or drag image files onto the canvas. Open **Pieces** in the Stitch options row to select a thumbnail, change its stacking order, or remove it.

Use the arrangement menu in the Stitch options row to choose **Free Move** or **Packed**. Free Move retains precise overlap and lets you place each piece independently. Packed closes gaps and arranges pieces in tight rows or columns, using the existing layout to choose the direction. Its Pieces list follows canvas order, with **Move earlier** and **Move later** controls for reordering. Free Move lists the frontmost layers first and uses layer controls. While dragging, the grid shows the proposed slot and rearranges neighboring pieces. Release to place the piece, or press Escape to cancel. Switching arrangements, reordering, and background changes support undo.

Open **Canvas** in the Stitch options row to change the fill for missing image areas. **Adjacent edge colors** is the default and samples broad adjacent neighborhoods and smoothly blends their dominant background colors into gaps. Text, icons, and borders are filtered out of the fill. **Solid color** uses your chosen color. **Transparent** leaves missing areas transparent in exports and shows a checkerboard in the editor. Captured pixels remain intact.

Redactions follow the original captured pixels. Removing a band splits a crossing redaction into editable fragments and removes only the covered pixels inside that band. Moving, packing, and changing the stacking order of pieces retain each surviving fragment. Pixelate, blur, erase, and solid censors keep their baked pixels while their source moves; later annotation edits sample the current canvas. Undo and history preserve each fragment's source attachment, clipping, and censor pixels.

## Capture a page in pieces

1. Press **Command–Shift–J**, or choose **Stitch Capture** from the menu bar or File menu.
2. Select the first region with Macshot's normal selection overlay.
3. Each selected region is added automatically, and the selector stays ready for the next shot. Faint reference guides help line up the next starting corner. Nearby edges highlight and snap as you approach them; hold **Option** to select freely. Hold **Space** to return input to the page for scrolling or navigation. Release Space to select from a fresh screenshot. The previous capture's screen edges stay available as references while the page moves. Regions can have different positions and sizes. **Undo** removes the last capture and restores the previous alignment reference.
4. After accepting a capture, press **Enter** or click **Finish** to open the collected pieces in the main editor. Finish works while the next selection is open. **Escape** cancels the session. The floating panel has only Undo and Finish controls; the first capture remains the anchor.

Image overlap determines placement when a match is reliable. Otherwise, screen position and observed scrolling suggest which edge to join. Macshot places the new capture against that edge and aligns the perpendicular edge, removing the unused distance between selections. It retains every captured pixel. Captures from displays with different pixel densities use the first display's scale. Estimated pieces are labeled so you can adjust them in the editor. A repeated capture is skipped only when every pixel and its estimated position match.

The shortcut can be changed in Settings alongside the other capture shortcuts. Screen Recording access is required. A session holds up to 24 captures, subject to image-memory and canvas limits.

## Keep the result

The main editor's **Copy**, **Save**, **Pin**, **OCR**, and sharing actions work while Stitch is selected and honor the same output preferences. Save's context menu retains the alternate destination action. Selecting effects or beautify returns to the normal image preview and applies those settings to the stitched result on export.

History stores original source images, source crops, piece positions, arrangement, canvas fill, seam settings, and separate annotations. Reopening an editable history entry lets you continue arranging its pieces. Copied images and exported PNG files are flattened. Crop and flip retain pieces when the cropped canvas can be represented by their bounds. A crop containing only uncovered outer margins uses the raster result; undo restores the original pieces.

Closing the editor uses its normal unsaved changes sheet and history workflow. Changing tools keeps the same editor window and retains separate annotations.

New Stitch labels use English fallback in locales awaiting translation.

## Validation

Automated checks cover the native toolbar and contextual controls, automatic band direction and axis locking, fractional preview and cut boundaries, shared annotation undo, tool switching without changing zoom or the editor root, pixel-to-point canvas projection, starting guides before the next capture, hover feedback, scroll and Undo references, dimension recommendations, continuous spans without bridging gaps, alternate sizes, reverse drags, stationary Option and Shift overrides, display scale conversion, registered layout coordinates, varied region sizes, spatial placement, overlap matching, repeat/queued captures, failure/retry, Finish, cancellation, keyboard routing, raw selection isolation, and the fading blur. Native rendering fixtures cover idle capture guides and band previews. Renderer fixtures verify both seam orientations and untouched pixels outside the blur band.

Treatment checks cover both orientations, light and dark content, reduced previews, transparent gaps beside short joins, native picker selection and applicable controls, editable history, untouched pixels outside the seam, fractional flips and piece movement with attached censors, magnifier refresh, preserved censor bakes, and immediate raster consistency through crop, flip, Undo, and Redo.

Runtime checks use this Mac's current OS. macOS 13 remains the deployment target; a separate Ventura installation has not been tested.
