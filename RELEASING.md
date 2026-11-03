# Releasing

Releases are Git tags. On a `vX.Y.Z` tag, CI builds the AppImage, the Flatpak and the APK and attaches each to the GitHub release; VirusTotal then scans each and adds its report to the notes.

1. Pick the version (`1.0.1`). Update:
    - [pubspec.yaml](./pubspec.yaml) → `version: 1.0.1+2` (the number after `+` is the Android versionCode; always increase it)
    - [metainfo](./packaging/dev.opencamera.opencamera.metainfo.xml) → add a `<release version="1.0.1" date="YYYY-MM-DD">` entry (newest first). `flatpak.yml` fails the tag without it.
2. Run `dart format lib test && flutter analyze && flutter test`.
3. Commit, merge to `master`, wait for CI.
4. Tag and push (the tag must equal the version, or the workflows fail):

    ```sh
    git tag v1.0.1 -m "OpenCamera 1.0.1"
    git push origin v1.0.1
    ```

5. Smoke-test the downloaded AppImage, Flatpak and APK.

## One-time setup

- Flatpak remote (gives users `flatpak update`; also needed for system-wide installs):
    1. Run `packaging/new-signing-key.sh`. It writes the public half to `packaging/signing-key.b64` (commit it) and the private half to `~/.local/share/opencamera-flatpak-private-signing.asc`.
    2. Store the private half as the secret `FLATPAK_GPG_PRIVATE_KEY`: `gh secret set FLATPAK_GPG_PRIVATE_KEY < ~/.local/share/opencamera-flatpak-private-signing.asc`. Back it up in a password manager, then delete the file. Losing it breaks every user's remote.
    3. Settings → Pages → Source: **GitHub Actions**.
    4. Settings → Environments → `github-pages` → add deployment tag rule `v*` (Pages creates it branch-only, so the first tag deploy is refused otherwise).
    Tags fail without steps 1–2. Never deploy Pages from `master`: every deploy replaces the whole site, including the Flatpak repo.
- AppImage updates: nothing to set up. The `.zsync` is built and attached to each release; `AppImageUpdate` reads the update info embedded in the file.
- VirusTotal (optional, or delete `virustotal.yml`): Settings → Secrets and variables → Actions → secret `VIRUSTOTAL_API_KEY`.
- Android: releases are signed with the debug key until a real keystore is wired into `android/app/build.gradle.kts`.
