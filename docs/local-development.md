# Deploy a local build

This checkout uses the `local-dev-pipeline` branch. Edit the project in Xcode or
your editor, then run this from any directory:

```sh
macshot-deploy
```

`~/.local/bin/macshot-deploy` points to `scripts/deploy-local.sh`. The command
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

To bring in upstream changes:

```sh
git fetch origin
git merge --no-ff origin/main
scripts/deploy-local.sh
```

Resolve any merge conflicts in the local development guards and script before
deploying. Keep this personal branch local.
