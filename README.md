<p align="center">
  <img src="assets/logo.svg" alt="Macshot Pro" width="96" />
</p>

<h1 align="center">Macshot Pro</h1>

<p align="center">Capture, annotate, and condense. Native to macOS.</p>

<p align="center">
  <a href="https://github.com/dr-baker/macshot/releases/latest/download/Macshot-Pro.dmg">Download</a> ·
  <a href="docs/stitch-capture.md">Stitch guide</a> ·
  <a href="CONTRIBUTING.md">Contribute</a> ·
  <a href="LICENSE">GPLv3</a>
</p>

Macshot Pro builds on the excellent [Macshot](https://github.com/sw33tLie/macshot) by [sw33tLie](https://github.com/sw33tLie) and its [contributors](https://github.com/sw33tLie/macshot/graphs/contributors). I maintain this fork for the way I use screenshots: modern macOS controls, less setup friction, and new tools as I need them.

## What's different

- **Guided permissions.** [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow) walks you through Accessibility setup, including a draggable app card.
- **Glass that fits your style.** Clear and Regular Liquid Glass, a Classic finish, light and dark appearance, and configurable colors and tint strength. Use your macOS accent color or pick your own.
- **Stitch.** Cut out rows or columns to condense a large screenshot. Join the remaining content with a fading blur, a paper tear, or a fold. You can also collect multiple captures, line them up with snap guides, and rearrange them in the same editor.

The baseline is **macOS 13 or later**. Native Liquid Glass requires **macOS 26**; earlier systems use the tinted Classic controls.

## Still Macshot

The original capture and annotation workflow is here, along with screen recording and video editing, scroll capture, OCR, redaction, beautify, and editable history. Built with Swift, AppKit, and SwiftUI. Free and open source.

## Try it

[Download Macshot Pro](https://github.com/dr-baker/macshot/releases/latest/download/Macshot-Pro.dmg), open the disk image, and drag the app to **Applications**. Launch it and allow Screen Recording when prompted. Xcode is only needed to build from source.

An [offline build](https://github.com/dr-baker/macshot/releases/latest/download/Macshot-Pro-Offline.dmg) removes upload and cloud integrations. Both builds support Apple Silicon and Intel Macs.

Press **⌘⇧X** to capture an area. In the editor, press **S** for Stitch and drag across the space you want to remove. Press **⌘C** to copy the result. For a sequence of captures, start with **⌘⇧J** and finish with **Enter**.

## Build from source

Use Xcode 26 or later:

```sh
git clone https://github.com/dr-baker/macshot.git macshot-pro
cd macshot-pro
open macshot.xcodeproj
```

Select the **macshot** scheme, choose your signing team, and run. Allow Screen Recording when prompted.

For a signed development install, see the [local build workflow](docs/local-development.md). [Release history](https://github.com/dr-baker/macshot/releases).

## Credits and license

Thank you to sw33tLie and everyone who built Macshot, and to [jaywcjlove](https://github.com/jaywcjlove) for PermissionFlow. This fork is maintained independently by [Daniel Baker](https://github.com/dr-baker).

[GPLv3](LICENSE). Original attribution and dependency license notices are preserved in [NOTICE.md](NOTICE.md). See [privacy](PRIVACY.md) and [security](SECURITY.md) for this fork's policies.
