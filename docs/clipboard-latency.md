# Clipboard copy latency

The measured copy pipeline reaches readable PNG and TIFF bytes sooner for every fixture. The biggest gains come from overlapping independent encoders and avoiding redundant pixel rendering. Accordion projection remains the largest CPU cost.

## Warm Release results

These are synthetic pipeline timings on an Apple M3 Max with 14 CPU cores and 36 GiB RAM, running macOS 26.6.2. Both runs use the same geometry from `fb07674`, the same Release flags, and the same fixture dimensions. Later Accordion geometry changes are excluded from this comparison.

| Fixture | Before, ms | After, ms | Reduction |
| --- | ---: | ---: | ---: |
| Ordinary, 1920 × 1080 | 19.28 | 13.35 | 31% |
| Retina, 6016 × 3384 | 180.71 | 113.93 | 37% |
| Redacted, 3840 × 2160 | 86.69 | 56.23 | 35% |
| Beautify with vivid effects, 3840 × 2160 | 338.92 | 262.89 | 22% |
| Accordion, 3840 × 2160 source | 592.88 | 531.44 | 10% |

`ClipboardLatencyTests` sends a real synthetic Command-C event through `OverlayView.performKeyEquivalent`. Its delegate mirrors the controller's compositing, presentation, clipboard, and history-image path. The endpoint reads both PNG and TIFF bytes from a named pasteboard. Each fixture discards one warm-up and reports the median of five measured runs. History saves finish before the next iteration.

These measurements exclude actual controller teardown, editable-state preparation, thumbnail UI, first-idle latency, and pasting into a consumer application. They are not native end-to-end UI measurements. Raw samples are in [clipboard-latency-results.json](clipboard-latency-results.json).

## Capture and editor path

1. `OverlayView.handleEditorKeyEvent` uses `KeyboardShortcutMatcher`. Text-field commands and selected-annotation copying retain their existing routing. Screenshot copying calls `overlayViewDidConfirm` when no annotation selection owns Command-C.
2. Capture uses `OverlayWindowController.capturePresentedImage`. The editor uses `DetachedEditorWindowController.captureHistorySave`. Both composite through `captureSelectedRegion` and finish through `ScreenshotPresentation`. The compositor draws pixelate annotations first, then spotlight dimming, then other annotations. Projected output samples this finished flat composite.
3. `ScreenshotPresentation` applies effects, Beautify, and optional Accordion projection. Ordinary rendering retains its existing frame behavior. The projection renderer is unchanged by this work.
4. The controller snapshots raw pixels, annotation clones, and `CaptureEditState` for editable history. Stitch source PNGs and saved documents are cached by `ImageEditingView`. Original custom background PNG bytes are now retained across history reads. Programmatically assigned backgrounds encode once from their native CGImage. The Release results above predate this change and exclude editable-state preparation.
5. `ImageEncoder.PreparedImage` owns separately rasterized pixels and frozen output settings on the main actor. A worker performs Retina downscaling and encodes the representations. The main actor then checks the copy generation and pasteboard change count before declaring and writing every format.
6. History snapshots still run on the main actor. `HistoryStorage` writes final PNG, raw PNG, thumbnails, annotations, editable-state sidecars, and the index on its utility queue. History persistence does not wait for successful clipboard publication. OCR runs only through explicit OCR or redaction actions, not an ordinary copy.

The 6K baseline stage medians included 114 ms of PNG encoding, 29 ms of TIFF encoding, 6 ms of capture rendering, 12 ms of clipboard pixel freezing, and 9 ms of pasteboard writing. Those isolated stage times must not be added to the full-pipeline result because history and encoding can overlap. Beautify rendering cost about 168 ms. Effects cost about 30 ms before removing the TIFF round trip. Accordion's serial projection remains dominant.

## Retained changes

- PNG, TIFF, and the optional configured format encode concurrently from the same frozen pixels. Publication remains eager and keeps the configured format first, followed by PNG and TIFF. No file URL or delayed data provider is introduced.
- Clipboard PNG limits row-filter search to UP and SUB. File encoding keeps its existing compression policy. On the projected-paper sample, adaptive filtering took about 59 ms for 1.14 MB. UP plus SUB took about 55 ms for 1.32 MB. Clipboard PNG size can increase while remaining lossless.
- Plain captures and raw history images crop the existing CGImage when source and selection pixel grids align. Annotations, scaled drawing, fractional source-grid offsets, and outside-source padding retain the compositor. Pixel dimensions are checked before returning a crop.
- Effects consume the native CGImage directly rather than encoding TIFF and decoding it before applying Core Image filters.
- A locked, nonisolated generation counter supports worker checks without crossing actor boundaries. Already superseded queued jobs can skip encoding. Jobs already encoding finish their CPU work but cannot publish over a newer copy or an external clipboard change.

Parallel Accordion rows were discarded. The paired same-binary test measured roughly 251 ms serial versus 344 ms parallel. UP-only PNG filtering was also discarded: projected-paper encoding took about 80 ms and produced 3.21 MB.

## Verification and benchmark entry points

The final paired Release run passed 65 selected tests. Checks cover 1x and 2x source crops, fractional selections and source origins, offset drawing rectangles, transparent padding, Display P3, translucent pixels, redaction output, all available configured formats, flavor order, source lifetime, downscaling, overlapping copy requests, and external pasteboard changes. Effects are compared with the former TIFF input across presets, including a 2x Display P3 fixture with at most one RGBA8 rounding step of difference.

The benchmark invocation is:

```sh
TEST_RUNNER_MACSHOT_CLIPBOARD_BENCHMARK=1 \
MACSHOT_KEEP_TEST_RESULTS=1 CONFIGURATION=Release \
scripts/run-tests.sh ClipboardLatencyTests
```

`testKeyToReadablePasteboardBenchmark` measures readiness. `testStageBenchmark` reports isolated stages. `testPNGCompressionBenchmark` compares compression filters on identical projected pixels. These tests skip unless explicitly enabled.

The initial Release XCTest compile crashed in Swift 6.3.3's `EarlyPerfInliner` on the existing generic `Locked<Value>` test helper destructor. Both paired Release runs used the same temporary empty destructor marked `@_optimize(none)` on that helper. The helper is not used by this pipeline. That workaround and the machine's local compiler-wrapper paths are excluded from commits. Normal Debug tests require neither the destructor workaround nor benchmark activation.

The combined geometry and clipboard tree receives the final full Debug suite and signed deployment in the coordinating MACSHOT chat. Native copy verification remains a separate check from these synthetic timings.

## Native presentation reuse

Copy now reuses the finished native presentation after the Accordion preview settles. Camera and pleat changes preserve the flat annotated sheet and effected pixels. They replace the projected output and reuse the prepared wallpaper when its output dimensions stay the same. Source, selection, annotation, effect, background, and projection changes invalidate the corresponding cached result. Copies during annotation manipulation render current geometry without retaining drag frames.

Raw history reads and annotated composites share a 32 MiB raster budget. Raw reads cannot evict the annotated input when both do not fit. Each presentation cache retains one result with a 128 MiB budget, including wallpaper, prepared background, and reserved final output. Larger images retain their uncached path. Preview textures and projected preview outputs remain bounded to 2000 pixels and are never used for native clipboard output. Larger previews warm the native result on a utility queue after 350 ms without interaction. An early copy can still require the full render.

The same-binary Debug benchmark includes editable-state preparation, raw and annotated history capture, clipboard encoding, and checking readable PNG and TIFF bytes. It uses a 1920 × 1080 synthetic Accordion, wallpaper, and redaction fixture, discarding one warm-up and reporting three measured runs.

| Copy state | Median, ms |
| --- | ---: |
| Previous rendering and wallpaper serialization, emulated | 3674.43 |
| New path, cold presentation | 3891.53 |
| New path, settled native presentation | 23.80 |

These are Debug synthetic pipeline measurements. They exclude physical key delivery and controller teardown. They do not replace the earlier Release measurements. The emulated baseline uses the previous render and TIFF-to-PNG history operations within the new binary.

A separate 3840 × 2160 wallpaper benchmark measured 259.85 ms per old history state read and 242.99 ms for a first native PNG encoding. Repeated cached or original-PNG-seeded reads were below 0.001 ms. Native Copy reads this state twice. The original selected wallpaper PNG avoids both encodings.

Enable these checks with `TEST_RUNNER_MACSHOT_SETTLED_COPY_BENCHMARK=1` for `ClipboardLatencyTests/testSettledAccordionCopyBenchmark`, `TEST_RUNNER_MACSHOT_BACKGROUND_STATE_BENCHMARK=1` for `CaptureEditStateBackgroundLatencyTests`, and `TEST_RUNNER_MACSHOT_PRESENTATION_CACHE_BENCHMARK=1` for `ScreenshotPresentationCacheTests/testNativePresentationReuseBenchmark`. Ordinary test runs skip the benchmarks.

## Full-size paper mesh

The full-size mesh inserts the actual removed paper length and derives output dimensions from its projected bounds. A paired Debug rerun on 2026-10-09 used the same 1920 × 1080 fixture and benchmark method above. Median readiness was 4142.28 ms for the emulated previous path, 4170.89 ms for a cold presentation, and 27.98 ms after the native presentation settled. The projected image is larger than the earlier fitted canvas, so these timings measure a different output size.

The cache reserves the actual projected raster and regenerates the background when its dimensions change. Native Copy retains its source pixel density; bounded preview pixels remain separate. These measurements include readable PNG and TIFF bytes and history preparation, and exclude physical key delivery and controller teardown.
