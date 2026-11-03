# Plan: Flutter camera viewer (Linux desktop + Android)

## Context
4 LAN cameras that currently need the Yoosee and iCSee apps. Local RTSP works on all four (verified with ffplay, go2rtc and mpv), so a single app can replace both vendor apps. Browsers can't decode the H.265 streams, so the viewer must be native. Decision: Flutter with `media_kit` (libmpv/ffmpeg), one codebase for Linux and Android, connecting to the cameras directly so the PC can stay off.

## Known facts
| Cam (.env) | IP | Vendor | Stream | Notes |
|---|---|---|---|---|
| CAM1 | 192.168.0.115 | iCSee (Xiongmai X6C-WEQ) | HEVC 2304x2592 (two lenses stacked), G.711 audio | Port 34567 login works with python-dvr; stream encoding is H.265 and stays that way |
| CAM2 | 192.168.0.116 | Yoosee | H.264 640x360 | Only port 554 open; RTSP answers over UDP only (mpv defaults to TCP) |
| CAM3 | 192.168.0.117 | iCSee | HEVC 2304x1296, G.711 audio | python-dvr login failed |
| CAM4 | 192.168.0.118 | iCSee | HEVC 2304x1296, G.711 audio | python-dvr login failed |

- RTSP paths that worked on all cameras: `rtsp://USER:PASS@IP:554/onvif1` (main) and `/onvif2` (second stream). The iCSee cameras ignore the path: `/onvif1`, `/onvif2` and `/onvif3` all return the 2304-wide main stream. Their real sub stream is `rtsp://IP:554/user=U&password=P&channel=1&stream=1.sdp?` (CAM1 640x720, CAM3 800x448); the app uses it through the per-camera `xm` (SD) toggle.
- Credentials live in `tools/.env` (git-ignored) (`CAMn_HOST`, `CAMn_USER`, `CAMn_PASS`). CAM1's username is not `admin`.
- Cameras report pan/tilt and motion detection. Unverified: how to drive PTZ (ONVIF on port 8899, or python-dvr over 34567).
- Router: TP-Link EC220-G5, public WAN IP (no CGNAT), OpenVPN server and No-IP DDNS available.

## Phases
0. **Prerequisites (user, no code):** DHCP reservations for the four cameras; keep the vendor apps installed and the passwords written down.
1. **Proof of concept:** install the Flutter SDK (the user runs any sudo steps), create the project, add `media_kit` + `media_kit_video` + `media_kit_libs_video`. Play one hard-coded stream on Linux and on an Android device. Success: CAM3 (HEVC) and CAM2 (H.264) play with hardware decoding. If it fails, fall back to `fvp` or a native player.
2. **Grid app:**
   - Settings screen: camera name, host, user, password, RTSP transport (TCP/UDP; CAM2 needs UDP). Port 554 and paths `/onvif1`, `/onvif2` are defaults, not fields (add only if a camera needs it). Store the whole camera list as one JSON blob in `flutter_secure_storage`, never in source. Build URLs with `Uri` and `userInfo` so `@ : / #` in a password are percent-encoded (one unit test).
   - 2x2 grid (responsive for phone portrait), tap for fullscreen, mute toggle per camera (audio off by default).
   - Reconnect needs a stall watchdog, not only error handling: mpv does not reconnect RTSP and a dead camera often just freezes the frame. Reopen with backoff on `error`/`completed` or when position does not advance for N seconds.
   - Stream selector: main or second stream; use the second stream in the grid. The iCSee `onvif2` is still 2304 wide: use the `xm` toggle (vendor `stream=1` URL) there. Measure CPU/battery on the real phone; if still too heavy, page the grid on phones.
   - One RTSP connection per camera: fullscreen swaps the grid player to the main stream instead of opening a second session. Stop all players when the app goes to background, reopen on resume.
   - CAM1: one player, two `Video` widgets of the same controller, each clipped (`ClipRect` + `Align` top/bottom half). No second decode or connection.
   - Linux note for phase 4: `flutter_secure_storage` needs libsecret and a keyring; Flatpak needs `--talk-name=org.freedesktop.secrets`.
3. **PTZ:** the read-only probe is cheap, so run it alongside phase 2; its result also tells whether the camera's stream config is reachable. ONVIF first (SOAP over HTTP with WS-Security digest, port 8899: GetCapabilities, GetProfiles, PTZ GetNodes) on CAM1/3/4; fall back to DVRIP (port 34567, `dvr_check.py`) only if ONVIF fails, since that means porting a binary protocol to Dart. If ONVIF works, the CAM3/CAM4 DVRIP login failure does not block PTZ. CAM2 (only 554 open) likely has no LAN PTZ: run `nmap -p-` on it before giving up (Yoosee ONVIF is sometimes on 5000). Overlay: press-and-hold = ContinuousMove, release = Stop, plus a client-side safety Stop after a timeout in case the release is lost. Show arrows only on cameras that report a PTZ node.
   - **Probe result (`onvif_probe.py`, read-only):** CAM1/3/4 answer ONVIF on 8899 with media + PTZ services and `NODE_000`, so ONVIF works and DVRIP is not needed. CAM2 answers ONVIF on port **5000** (profiles listed) but its PTZ service closes the connection on GetNodes; unresolved. Next: ContinuousMove/Stop test, then the Dart client (`http` + `crypto`).
   - **Status: done and tested on the real cameras.** Dart client in `lib/ptz.dart` (`HttpClient` + `crypto`) with a fullscreen D-pad. CAM2 (Yoosee, port 5000) drops GetNodes and Stop but accepts ContinuousMove, so GetNodes is not required (a PTZ configuration in the profile is enough) and a zero-speed move replaces a failed Stop. CAM1 does not report its pan direction (mirror/flip are off) or which of its two lenses moves (one ONVIF video source and PTZ config), so those are per-camera options (`panInvert`, `ptzLens`) set once in fullscreen. Automatic calibration by comparing frames was left out. Zoom was tried and removed: CAM1/3/4 advertise a zoom range over ONVIF (the same on every Xiongmai model) but none of the cameras zoomed, so they have no zoom lens.
4. **Packaging and CI (GitHub Actions):** Linux bundle, Android APK/AAB, Flatpak (needs libmpv bundled; local Flatpak builds need FUSE as in the global notes). iOS excluded.
5. **Remote access:** enable the router's OpenVPN server and No-IP DDNS, test from mobile data. The app prefers the lighter stream when remote.
6. **Alerts (later):** motion events are pushed by the camera only to a connected client, so real push needs an always-on listener (Raspberry Pi + ntfy). Decide separately. Check whether the cameras have a microSD slot for on-camera recording.
7. **Optional hardening:** block the cameras' internet access at the router once the VPN works, so firmware cannot change silently.

## Verification
- Phase 1: one stream plays on Linux and Android; `flutter run -d linux` and a physical Android device.
- Phase 2: all four cameras visible together (CAM2 via UDP); check CPU and hardware decode; kill a camera's network and also power-cycle it, and confirm the tile recovers; Android in background holds no streams; a password with special characters works.
- Phase 3: each arrow moves the camera, and stop works, even if the button release is lost (app backgrounded mid-move).
- Phase 5: connect over mobile data with Wi-Fi off.
- Each phase: `flutter analyze` and `flutter test`.

## Risks / unknowns
- `media_kit` with these exact cameras (HEVC, the stacked CAM1 picture) is unproven until phase 1.
- Android hardware HEVC decoding depends on the device.
- The cameras may limit simultaneous RTSP connections when several clients connect directly.
- Firmware updates could disable RTSP (see phase 7).

## Project location
Everything lives in this repo, `~/opencamera-app` (outside Dropbox: the Dart tooling breaks on the comma in `Apps, scritps`, and `build/` stays out of sync). App code in `lib/`, helper scripts and go2rtc config in `tools/`, this plan in `docs/`.

## Existing pieces to reuse
- `tools/dvr_check.py` and `tools/onvif_probe.py` plus the venv at `~/venvs/opencamera`: the DVRIP login and config reading.
