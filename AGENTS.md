# Macshot Pro

## What we're after

Macshot Pro is a native macOS screenshot and recording app. This checkout is also
Daniel's working copy: edits should reach the signed `Macshot Pro Dev` app on this
Mac, where the real capture and menu bar behavior can be checked. Keep that
local workflow reliable and publish verified work to Daniel's GitHub fork.

## Where to go

- [CLAUDE.md](./CLAUDE.md): upstream architecture, build variants, and tests.
- [docs/local-development.md](./docs/local-development.md): local edit and deploy workflow.
- [scripts/deploy-local.sh](./scripts/deploy-local.sh): signed local build and install command.
- [scripts/run-tests.sh](./scripts/run-tests.sh): headless test suite.
- [macshot/](./macshot/): app source and entitlements.
- [.github/workflows/tests.yml](./.github/workflows/tests.yml): upstream test and Release build checks.

## Ground rules

- After changing app code, run `macshot-deploy` and verify that `/Applications/Macshot Pro Dev.app` is signed and running. A successful `xcodebuild` alone does not complete a local app change. Use `--build-only` only when installation is outside the task's scope.
- Keep the `LOCAL_DEV` build separate from the normal and offline variants. Preserve its stable bundle ID and signing identity so macOS permissions survive redeploys. Do not enable Sparkle updates in the local build.
- Keep normal and offline releases on macOS 13 and `Macshot Pro Dev` on macOS 26. Screenshot appearance belongs to Macshot Pro: native Clear glass on supported systems, tinted Classic panels on older systems.
- Use fork-owned release IDs, appcasts, and Sparkle keys. Preserve original Macshot attribution and GPLv3 notices.
- Run `scripts/run-tests.sh` for logic changes. When changing compilation flags, signing, or variant behavior, also check the affected Release builds described in `CLAUDE.md` and the CI workflow.
- Publish to `origin` (`dr-baker/macshot`); fetch upstream changes from `upstream` (`sw33tLie/macshot`). Keep completed work on the fork's `main`. Do not merge with fast-forward unless Daniel specifically asks for it.

## Vocabulary

- **Local dev**: the signed `Macshot Pro Dev` app installed by `macshot-deploy`.
- **Normal**: the fork release with optional uploads and configured fork updates.
- **Offline**: the fork release compiled with `OFFLINE` and no cloud integrations.
