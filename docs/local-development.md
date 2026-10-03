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

The command
builds a Release app and signs it with the installed Developer ID Application
certificate. It then quits the previous development copy, installs the new copy
at `/Applications/macshot Dev.app`, launches it, and verifies the bundle ID,
signature, and process. Build output is in `build/local-dev/build.log`. Run
`macshot-deploy --build-only` to compile and sign without installing.

The development copy has bundle ID `com.drbaker.macshot.dev`. Its identity stays
the same across builds so macOS can retain permissions after the first grant.
It does not start Sparkle or offer update controls; upstream releases cannot
replace your local build. It can coexist with the upstream app, though both
apps should not run together because their global shortcuts can conflict.

If the certificate changes, set `MACSHOT_SIGNING_IDENTITY` to the full name of
the identity you want to use. Keep using the same identity for later deploys to
avoid another macOS permission prompt.

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
