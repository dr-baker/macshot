# Deploy a local build

Edit the active development checkout in Xcode or your editor, then run this
from any directory:

```sh
macshot-deploy
```

`~/.local/bin/macshot-deploy` points to the active checkout's
`scripts/deploy-local.sh`. Check its target with `readlink ~/.local/bin/macshot-deploy`.
When switching branches in a separate worktree, run this from the new checkout:

```sh
ln -sfn "$PWD/scripts/deploy-local.sh" ~/.local/bin/macshot-deploy
```

The command builds the `macshot Dev` scheme for macOS 26 and signs its Release app with the installed Developer ID Application
certificate. It then quits the previous development copy, installs the new copy
at `/Applications/Macshot Pro Dev.app`, launches it, and verifies the bundle ID,
signature, and process. Build output is in `build/local-dev/build.log`. Run
`macshot-deploy --build-only` to compile and sign without installing.

The unsigned Xcode product stays untouched in `build/local-dev/Build/Products`.
Signing uses a separate copy in `build/local-dev/signed`, so another incremental
build can reuse its original dependency artifacts.

The development copy has bundle ID `com.drbaker.macshot.dev`. Its identity stays
the same across builds so macOS can retain permissions after the first grant.
It does not start Sparkle or offer update controls; upstream releases cannot
replace your local build. It can coexist with the upstream app, though both
apps should not run together because their global shortcuts can conflict.

Normal and offline builds target macOS 13. All variants use the same app-owned
screenshot appearance code. Native Clear glass requires macOS 26 and the
supported window appearance hooks; other systems use Classic panels.

The scheme names (`macshot` and `macshot Dev`) and repository paths remain stable.
The first renamed deployment retires `/Applications/macshot Dev.app` after
verifying the replacement. Its bundle ID and signing identity are preserved,
so your preferences, history, and permission grants stay with the app.

## Tune screenshot controls

Open **Settings → Appearance**. Choose **Clear**, **Regular**, or **Classic**, then select
**Theme**, **Custom**, or **None** for the tint. Theme follows the background
color. Custom keeps a separate color. Classic uses the background directly;
its strength control applies only to Custom tint.

Choose **System**, **Light**, or **Dark** appearance. Built-in themes include
matching palettes for both appearances; custom colors remain explicit.
**Use macOS accent color** derives a quiet background in OKLCH, preserving hue
while reducing chroma and choosing lightness for the selected appearance.
Turning it off restores the chosen Macshot Pro palette. Settings buttons and sliders
use the chosen accent through supported native tint APIs.
Sunset pairs a pink background with orange accents.

The preview uses the real screenshot controls without allowing edits to sample
content. One saved style applies to area capture, the screenshot editor, Stitch
Capture, and screenshot menus. Open controls update in place.

Clear starts with a 70% theme background tint and keeps its active appearance when the
window loses focus. The appearance policy preserves actual keyboard focus and
window activation. All finishes choose black or white foreground controls from
the configured colors using sRGB contrast. Glyphs have no contrast halos or
shadows. Contrast updates require no screen sampling or timers.

### Renderer

`ScreenshotGlass.swift` selects native SwiftUI `Glass.clear` or `Glass.regular`.
`ScreenshotGlassGroupView` keeps one persistent SwiftUI host per capture or
editor view. Tool strips, options, and submenus share a `GlassEffectContainer`
with stable identities. Tooltips, size labels, instructions, and the editor top
bar render outside that container so hovering cannot merge them with the tools.
AppKit retains the controls, responder chains, and drag tracking.

Submenus open beside their controls in the same window when space permits.
They share the glass scene and use a short anchored reveal. Escape, an outside
click, or clicking the active control dismisses a submenu. Menus that cannot fit
use a native popover. Reduce Motion removes movement and glass morphing.
Reduce Transparency uses Classic. Layout coalesces geometry updates and skips
unchanged SwiftUI state.

The window appearance bridge keeps glass active without claiming keyboard
focus. Macshot Pro owns the renderer and its tint settings directly.

If the certificate changes, set `MACSHOT_SIGNING_IDENTITY` to the full name of
the identity you want to use. Keep using the same identity for later deploys to
avoid another macOS permission prompt.

## Release builds

Normal and offline builds use `com.drbaker.macshot.pro` and
`com.drbaker.macshot.pro.offline`, respectively. Source builds have no Sparkle
signing key and do not check for updates. The release workflow requires the
fork's own `SPARKLE_PUBLIC_KEY` and `SPARKLE_PRIVATE_KEY`, Developer ID signing
credentials, and notarization credentials. It publishes fork-owned DMGs and
variant-specific appcasts. No upstream Homebrew tap is modified.

### Prepare a local release

Local releases use your Developer ID certificate and the `macshot-pro` Sparkle
key in Keychain. Private signing keys are not written to release files.

Download the [Sparkle 2.9.0 release tools](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.0)
and create the fork's key once:

```sh
/path/to/Sparkle/bin/generate_keys --account macshot-pro
```

Build, sign, and package the normal and offline apps:

```sh
scripts/prepare-release.sh \
  --version 0.1.0 \
  --build-number "$(date -u +%s)" \
  --sparkle-tools /path/to/Sparkle/bin \
  --signing-identity 'Developer ID Application: Daniel Richard Baker (45W5CFCVQF)'
```

Commit the intended source first; preparation requires a clean checkout.
Ignored build output is allowed.
The output in `build/release/v<version>-<build-number>/` contains both universal
apps, disk images, and a manifest with their metadata and hashes. The
preparation step does not publish or notarize them.
Submit the disk images using a validated Apple notarization Keychain profile,
then staple and validate the accepted tickets before publishing.
Generate Sparkle signatures and final hashes after stapling, which changes the
disk image bytes. Publish the release assets before updating their appcasts.

### Enable releases from GitHub Actions

Set the signing, notarization, and Sparkle repository secrets before setting the
`MACSHOT_CI_RELEASES` repository variable to `true`. Until then, tag pushes skip
the CI release job. Manual workflow runs still check for the required secrets.
Build numbers use UTC Unix time so local and CI releases share one increasing
sequence. Resumed notarization runs retain the original app's build number.

## Publish and sync the fork

This checkout uses `origin` for [Daniel's fork](https://github.com/dr-baker/macshot)
and `upstream` for [the original project](https://github.com/sw33tLie/macshot).
Commit your edits, verify them with tests and `macshot-deploy`, then publish the
completed work on `main`:

```sh
git push origin main
```

To bring in upstream changes:

```sh
git fetch upstream
git merge --no-ff upstream/main
macshot-deploy
```

Resolve any merge conflicts in the local development guards and script before
deploying. Merge feature branches with `--no-ff` so each feature has a clear
entry in the history.

## Frame a screenshot

Open **Beautify**, then **Background and Frame**. Choose **Gradients** or
**Wallpapers**. The wallpaper gallery uses full-resolution images and still frames
from wallpapers installed with macOS. Available choices depend on this Mac.
The selected image is saved with the capture, so reopening history does not
depend on the wallpaper file or the current desktop.

Choose **Compact** for a narrow 12-point frame, coordinated corners, and a short
shadow. **Roomy** restores wider spacing. The padding slider reaches zero for
edge-to-edge output. New captures start with narrow spacing; saved preferences
and existing history retain their frame dimensions. Custom images remain in
the Gradients picker. Wallpaper decoding and thumbnails run off the main thread.
