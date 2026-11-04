# OpenCam

Flutter viewer for LAN IP cameras (Linux desktop + Android). It plays the cameras' RTSP streams directly with `media_kit` (libmpv/ffmpeg), so H.265 works and no PC or cloud is needed. It replaces the Yoosee and iCSee vendor apps.

Status: grid viewer works in code but is still being tested on devices. PTZ works on all four cameras; packaging/CI and remote access are not done yet (see `docs/plan.md`).

## Using the app

1. Open **Settings** (gear icon) and tap **+** for each camera:
   - **Name**, **Host / IP**, **User**, **Password**.
   - **RTSP over UDP**: turn on for Yoosee cameras (CAM2). mpv defaults to TCP and those cameras only answer on UDP.
   - **Split stacked picture**: turn on for two-lens cameras (CAM1). It shows the top and bottom lens as two cells from one stream.
2. Back on the grid, tap a cell for fullscreen. It keeps the same stream and connection as the tile (no reconnect) and has the same option buttons; tap **SD** there to switch to HD.
3. The speaker icon mutes or unmutes a camera (muted by default).
4. In fullscreen, cameras with ONVIF PTZ show arrows on the right: hold to move, release to stop. Under the arrows:
   - **⇄ Invert left/right**: turn on if the camera pans the wrong way (the cameras don't report it).
   - **Lens that moves** (two-lens cameras only): tap to cycle unknown / top / bottom. Once set, zooming on the other lens hides the arrows.

   Both are saved per camera.

Notes:

- iCSee / Xiongmai cameras ignore the `/onvifN` path and always send the full-size stream. The **SD** icon (on by default, same for every camera, on the tile and in fullscreen) plays the low-res stream; turn it off for HD. For iCSee cameras the app uses their real low-res stream (`stream=1`, e.g. 640x720 / 800x448 instead of 2304 wide, far less CPU); other brands use `/onvif2`, and the app detects which one works. The **SD/HD** badge at the top shows the size of the picture you get.
- URLs are built as `rtsp://USER:PASS@HOST:554/onvif2` (SD) and `/onvif1` (HD). Special characters in the password are encoded for you.
- The camera list, including passwords, is stored with `flutter_secure_storage` (system keyring), never in source or plain files.
- A stalled or dead stream is reopened automatically with backoff. Streams stop while the app is in the background.
- Give the cameras DHCP reservations on the router, otherwise their IPs can change.

## Requirements

- Flutter stable (tested with 3.47), Dart SDK from the same install. Put its `bin` on your PATH, e.g. in `~/.zshrc`: `export PATH="$HOME/development/flutter/bin:$PATH"`, then check with `flutter doctor`.
- Linux: the usual Flutter Linux toolchain plus the libraries `flutter_secure_storage` needs (a keyring such as GNOME Keyring must be running):

    ```sh
    sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev
    ```

- Android: Android SDK, `adb`, and a device or emulator. Hardware HEVC decoding depends on the device.

## Run

```sh
flutter pub get
flutter run -d linux          # desktop
flutter run -d <android-id>   # see `flutter devices`
```

## Build

```sh
flutter build linux --release     # build/linux/x64/release/bundle/
flutter build apk --release       # build/app/outputs/flutter-apk/app-release.apk
```

On Android `media_kit_libs_video` bundles libmpv; on Linux it does not, so a plain `flutter build linux` needs `libmpv-dev` (install it) and the packages below ship their own libmpv.

### Releases (GitHub Actions)

`ci.yml` runs format, analyze, test, a Linux build and packaging-metadata validation on every push/PR. `appimage.yml`, `flatpak.yml` and `android.yml` build on every push/PR too, and on a tag `vX.Y.Z` attach to the GitHub release (see [RELEASING.md](RELEASING.md)); `virustotal.yml` scans them:

- `OpenCam-<version>-x86_64.AppImage` (`packaging/build-appimage.sh`; needs GTK3 and libsecret on the host)
- `OpenCam-<version>-x86_64.flatpak` (`packaging/dev.opencam.opencam.yml`; builds mpv/ffmpeg from source)
- `OpenCam-<version>.apk`

Not verified yet: the AppImage and Flatpak have not been built locally, and the APK is signed with the debug key.

## Check

```sh
dart format lib test
flutter analyze
flutter test
```

## Layout

| File                     | Purpose                                                  |
|--------------------------|----------------------------------------------------------|
| `lib/camera.dart`        | Camera model, RTSP URL building, JSON                    |
| `lib/store.dart`         | Load/save the camera list in secure storage              |
| `lib/session.dart`       | One player per camera: stream swap, mute, stall watchdog |
| `lib/grid_page.dart`     | Grid, fullscreen, lifecycle handling                     |
| `lib/settings_page.dart` | Add/edit/delete cameras                                  |
| `lib/ptz.dart`           | ONVIF pan/tilt (WS-Security SOAP over HTTP)              |

## Troubleshooting

- **Tile stays black or spins:** run from a terminal and read the `mpv` log lines; check the camera is reachable with `ffplay rtsp://USER:PASS@IP:554/onvif2`.
- **Yoosee camera never connects:** enable *RTSP over UDP* for it.
- **Linux build fails on libsecret:** install the packages above.
- **`CMakeCache.txt directory is different` / `Unable to generate build files`:** the project folder was moved or renamed. Run `flutter clean` and build again.
- **Path with a comma** (e.g. `Apps, scritps`) breaks the Dart tooling; keep this project outside such folders.

## Tools (`tools/`)

- `dvr_check.py`: read-only DVRIP (port 34567) login and config check.
- `onvif_probe.py`: read-only ONVIF probe (services, profiles, PTZ nodes). Cameras 1/3/4 answer on port 8899, CAM2 on 5000.

Credentials live in `tools/.env` (`CAMn_HOST`, `CAMn_USER`, `CAMn_PASS`), which is git-ignored. Create it yourself on a fresh clone. Run the Python tools from `tools/`:

```sh
cd tools && set -a && . .env && set +a && python3 -I onvif_probe.py
```

The plan and status live in `docs/plan.md`.
