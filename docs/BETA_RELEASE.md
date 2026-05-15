# MissionSwipe Beta Channel

The beta channel is for friend-machine debugging and validation before publishing a stable release.

## Install Commands

Stable users:

```bash
curl -fsSL https://github.com/steven-alva/MissionSwipe/raw/refs/heads/main/scripts/install_latest.sh | bash
```

Beta testers:

```bash
curl -fsSL https://github.com/steven-alva/MissionSwipe/raw/refs/heads/main/scripts/install_beta.sh | bash
```

Both commands install the same app path and bundle identifier:

- `/Applications/MissionSwipe.app`
- `io.github.stevenalva.MissionSwipe`

This is intentional. Beta should replace the installed app in place so Accessibility permission and settings stay attached to one app identity.

## Build Beta Locally

```bash
scripts/build_beta.sh
```

The build creates:

- `dist/MissionSwipe.app`
- `dist/MissionSwipe-<beta-version>-macos.zip`
- `dist/MissionSwipe-beta-macos.zip`

`MissionSwipe-beta-macos.zip` is the fixed asset used by the beta installer.

## Publish Beta

```bash
scripts/publish_beta.sh
```

The script:

1. Builds a dev-mode beta package.
2. Moves or creates the local `beta` tag at `HEAD`.
3. Force-pushes the `beta` tag.
4. Creates or updates the GitHub prerelease named `MissionSwipe Beta`.
5. Uploads `dist/MissionSwipe-beta-macos.zip` with `--clobber`.

The stable installer uses `/releases/latest`, which ignores prereleases. Publishing beta therefore does not change what stable users receive.

## Promotion Rule

Do not publish debug builds to the stable release. Promote beta to stable only after the tested beta behavior is accepted.
