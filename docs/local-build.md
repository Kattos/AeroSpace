# Local release build

`./build-local.sh` builds, signs and installs a local AeroSpace without Xcode. It is for
everyday development on this machine, not for publishing. `build-release.sh` remains the
upstream release pipeline (Xcode app bundle, universal binaries, cask).

What it does:

1. Runs `generate.sh --ignore-xcodeproj --ignore-cmd-help --build-version <version> --generate-git-hash`,
   where `<version>` is the latest git tag (`v0.21.3-Beta` becomes `0.21.3`, and an untagged
   repo falls back to `0.0.0-SNAPSHOT`; the `MARKETING_VERSION` in `xcode/project.yml` is an
   XcodeGen template variable, not a literal). The generated sources are restored from a
   backup on exit, including on failure, so local edits to them are preserved.
2. Builds the SwiftPM release products with `-Xswiftc -warnings-as-errors` for this machine's
   architecture.
3. Assembles a self-contained `AeroSpace.app` (bundle id `bobko.aerospace`, `LSUIElement`,
   `resources/AeroSpace.entitlements`, `default-config.toml`, `AppIcon.icns`) in a staging
   directory beside the install target.
4. Signs the final app once with `--identifier bobko.aerospace` and the entitlements, signs a
   copy of the CLI, and verifies both strictly. The designated requirement must pin the
   certificate leaf rather than a cdhash, otherwise the script stops.
5. Installs `~/Applications/AeroSpace.app` by renaming the staged bundle into place, and
   repoints `~/.local/bin/aerospace` at the freshly built SwiftPM release binary.

Because the certificate and the bundle identifier stay the same, ordinary rebuilds keep the
same app identity.

## One-time: create the signing certificate

Any AeroSpace build that is not signed with a stable identity looks like a different app to
macOS, and macOS then silently drops Accessibility access. Create the certificate once:

1. Open Keychain Access, menu `Keychain Access > Certificate Assistant > Create a Certificate...`.
2. Name: `aerospace-codesign-certificate` (the default in the script and in `generate.sh`).
3. Identity Type: `Self Signed Root`, Certificate Type: `Code Signing`.
4. Create it in the `login` keychain. A long validity period is fine; the certificate is only
   used locally.

The first `codesign` run may ask for permission to use the private key. Choose
`Always Allow`, otherwise every rebuild prompts.

Notes:

- `security find-identity -v` reports this certificate as untrusted and lists zero valid
  identities. That is expected for a self-signed certificate; the script therefore looks the
  identity up with `security find-identity -p codesigning`, which does list it.
- If several certificates share the name, `--codesign-identity <SHA-1 fingerprint>` selects one.
  The script prints the fingerprint it uses on every run.

## Running

```bash
./build-local.sh
```

Options: `--codesign-identity <name-or-SHA-1>`.

The repo path must not contain spaces, and must not live under `$TMPDIR`: `generate.sh` relies
on bare globs, and SwiftPM refuses to build under `$TMPDIR`. The script checks both up front.

- Building is allowed while `~/Applications/AeroSpace.app` runs. The script only refuses at
  the final swap, after the build, so a running app costs one re-run, not a whole rebuild.
  It does not quit or restart anything: quit AeroSpace and re-run.
- It replaces `~/Applications/AeroSpace.app` only if that path is a real bundle directory
  owned by you, with bundle id `bobko.aerospace` and the same designated requirement as the
  new build. Anything else is refused. If no app is installed yet, the first install proceeds.
- It refuses to replace `~/.local/bin/aerospace` if that path is a regular file rather than a
  symlink, and refuses a symlinked or foreign-owned `~/Applications`, `~/.local` or
  `~/.local/bin`.
- Missing `~/Applications` or `~/.local/bin` directories are created; existing ones are used
  only if they are real directories owned by you. A pre-existing `~/Applications/AeroSpace.app`
  that is a symlink, a plain file or another app's bundle is refused.
- Logs: `.build/local-release/generate.log`, `.build/local-release/swift-build.log`. The signed
  CLI copy stays at `.build/local-release/aerospace`; the generated-source backup lives in
  `.build/local-release/generated-backup` while the script runs and is removed on exit.
- Re-running the script is the normal upgrade path. The previous bundle is moved aside inside
  the same staging directory and restored if the rename fails.
- CI does not run this script; after changing it, run it once by hand. `bash -n build-local.sh`
  only checks syntax.

## Permissions

The first install at this fixed path needs one manual grant:

1. Launch `~/Applications/AeroSpace.app` (or let `start-at-login` start it).
2. Grant Accessibility and, if `workspace-chooser.exclude-keys` is used, Input Monitoring.

With the same certificate and bundle id, later rebuilds normally keep the grants because macOS
keys them to the designated requirement. This is not a promise: clearing permissions, a
Keychain reset, a certificate change or renewal can make macOS ask again. If AeroSpace reports
that it lacks Accessibility permission although the checkbox is on, remove the stale entry in
System Settings > Privacy & Security and grant again.

## Limits

- Single architecture, no hardened runtime, not notarized. Fine locally, not distributable.
- The certificate expires (the current one in 2027). After expiry signing fails until a new
  certificate is created, and macOS asks for the permissions again.
- Only the app bundle, the CLI artifact and the CLI symlink are touched. `aerospace.toml`,
  `~/.aerospace.toml` and other installs are not modified.
- The version comes from the latest tag, so `AeroSpace.app` reports that version rather than
  the exact commit. The git hash is still embedded in the binary.
