# Releasing

Releases are Git tags. On a `vX.Y.Z` tag, CI builds the AppImage, the Flatpak and the APK and attaches each to the GitHub release; VirusTotal then scans each and adds its report to the notes.

1. Pick the version (`1.0.0`). Update:
    - [pubspec.yaml](./pubspec.yaml) → `version: 1.0.0+1` (the number after `+` is the Android versionCode; always increase it)
    - [metainfo](./packaging/dev.opencam.opencam.metainfo.xml) → add a `<release version="1.0.0" date="YYYY-MM-DD">` entry (newest first). `flatpak.yml` fails the tag without it.
2. Run `dart format lib test && flutter analyze && flutter test`.
3. Commit, merge to `master`, wait for CI.
4. Tag and push (the tag must equal the version, or the workflows fail):

    ```sh
    git tag v1.0.0 -m "OpenCam 1.0.0"
    git push origin v1.0.0
    ```

5. Smoke-test the downloaded AppImage, Flatpak and APK.

## One-time setup

- Flatpak remote (gives users `flatpak update`; also needed for system-wide installs):
    1. Run `packaging/new-signing-key.sh`. It writes the public half to `packaging/signing-key.b64` (commit it) and the private half to `~/.local/share/opencam-flatpak-private-signing.asc`.
    2. Store the private half as the secret `FLATPAK_GPG_PRIVATE_KEY`: `gh secret set FLATPAK_GPG_PRIVATE_KEY < ~/.local/share/opencam-flatpak-private-signing.asc`. Back it up in a password manager, then delete the file. Losing it breaks every user's remote.
    3. Settings → Pages → Source: **GitHub Actions**.
    4. Settings → Environments → `github-pages` → add deployment tag rule `v*` (Pages creates it branch-only, so the first tag deploy is refused otherwise).
    Tags fail without steps 1–2. Never deploy Pages from `master`: every deploy replaces the whole site, including the Flatpak repo.
- AppImage updates: nothing to set up. The `.zsync` is built and attached to each release; `AppImageUpdate` reads the update info embedded in the file.
- VirusTotal (optional, or delete `virustotal.yml`): Settings → Secrets and variables → Actions → secret `VIRUSTOTAL_API_KEY`.
- Android signing: tag builds fail without a release keystore (plain pushes and fork PRs fall back to the debug key). One-off setup, outside the repo and outside Dropbox:
    1. `keytool -genkeypair -v -keystore ~/.local/share/opencam-release.jks -alias opencam -keyalg RSA -keysize 4096 -validity 10000`
    2. Secrets: `base64 -w0 ~/.local/share/opencam-release.jks | gh secret set ANDROID_KEYSTORE_B64`, then `gh secret set ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` (`opencam`). Use the same password you gave keytool; it is also the key password.
    3. Back the keystore up in a password manager. Losing it means users must uninstall to update, like a changed key.
  Installs of earlier debug-signed APKs need one uninstall (which removes the saved cameras) before the first release-signed one installs.
