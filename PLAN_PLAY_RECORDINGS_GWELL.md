# Plan: play CAM2 (Yoosee/Gwell) SD recordings in OpenCam

Status: **research/planning, no app code yet.** Pick up at "Next action".

## The problem
CAM2 = `192.168.0.116`, a Yoosee/Gwell camera. OpenCam plays SD recordings over DVRIP
(`lib/dvrip.dart`), which CAM1 supports. CAM2 does **not**: its DVRIP port 34567 is
closed (`Connection refused`). We want CAM2's SD recordings in OpenCam like the others.

## What we established (evidence)
- **Open TCP ports (scanned 1–10000):** 21, 23, 554, 5000. Ports 21/23 are dead inetd
  stubs (`can't execute '/sbin/ftpd'`, `telnetd: applet not found`) — no usable FTP/telnet by default.
- **ONVIF on 5000** answers. `GetServices` lists only the events service — **no Profile G**
  (no recording/search/replay), so SD playback can't go over ONVIF.
- **ONVIF `GetDeviceInformation`:** Manufacturer `Technology`, Model `IPC`,
  Firmware `37.00.14`, HardwareId `Ver 2.1`. These are the generic Gwelltimes/Anyka
  ONVIF strings.
- **Phone app test:** with the router's internet unplugged, the Yoosee app will NOT play
  CAM2's SD card (live view may still work). So SD playback is **cloud/P2P-assisted** — a
  Gwell server does the login/handshake. Reverse-engineering that P2P protocol is weeks of
  work, needs the cloud, and breaks whenever Gwell changes its servers. **Rejected as the path.**
- **Windows client** is extracted at `~/Downloads/Yoosee_setup1.0.0.14` (Qt app, ships
  `IOT_LIB.dll`+`.pdb`, `GWPlayerLibV1`, etc., with full x64 PDB symbols:
  `PlaybackFileMgr`, `PlaybackPlayer`, `is_LAN_connectable`, `command_lan_get_device_list`).
  Decompilable if we ever must, but the shell path below is far cheaper.

## The chosen path: get a shell on the camera, read the SD files directly
Reference (user's own camera, interoperability only):
[github.com/gabrielmaialva33/camera-hack](https://github.com/gabrielmaialva33/camera-hack)
(MIT). It documents Yoosee/Gwell cameras on **Anyka AK3918** running embedded Linux
(kernel 3.4.x, read-only squashfs rootfs, **no root password**), where the firmware runs
**`autorun.sh` from the SD card root at boot**. If CAM2 honors that hook, we drop a one-line
script to start a telnet/SSH daemon, log in as root over the LAN, and the SD recordings are
just files on the camera's own filesystem — no cloud, no P2P, no soldering.
Use only the benign part (reading our own camera's own files); ignore the repo's
credential-extraction / cloud-API / exploit tooling.

**Is it the same camera?** Likely but unproven. CAM2's generic Gwell ONVIF strings match the
family; the repo's ONVIF advisory targets firmware 38.x and CAM2 is 37.00.14 (one generation
apart). The SoC (AK3918) and the autorun hook are only *proven* once we read the SD or get a
shell (Gate 0/1).

## Gates (cheapest first, stop at any failure)
- **Gate 0 — read the SD on the PC (zero camera changes).** Power CAM2 off, pull the microSD,
  mount read-only on the PC. If recordings are readable files in a normal container
  (`ffprobe` one), the shell path may be unneeded — OpenCam just browses a folder. Also note
  whether the card root already has `autorun.sh`/`debug.ini` (confirms the boot hook).
- **Gate 1 — LAN shell, no hardware.** Write `autorun.sh` at the SD root:
  `#!/bin/sh` then `telnetd &` (and `dropbear` if present), `chmod +x`. Reinsert, boot,
  `nc -z 192.168.0.116 23`. Opens → `telnet` in as root (no password); `cat /proc/cpuinfo`
  confirms AK3918. Nothing → firmware ignores SD autorun; fallback is UART (open case,
  USB-TTL to 3 pads @115200, interrupt U-Boot at `anyka#`) — decide then; if user won't open
  the case, stop and keep "use the Yoosee app".
- **Gate 2 — locate recordings (from the shell).** `mount` (SD likely `/mnt/disc1`), find the
  recording dir and file format (`ls -R`, copy one out, `ffprobe`). Choose lightest LAN serving:
  scp, a tiny on-camera HTTP server, or SSH. If frames are raw Xiongmai-style, reuse `XmDemux`
  from `lib/dvrip.dart`. Persist the autorun so it survives reboot.
- **Gate 3 — Python prototype** `tools/yoosee_probe.py`: list a day, download 30 s, play with
  `mpv`. Read-only toward the camera. Only after this works do we write app code.

## Phase D — app code (only after Gate 3)
- `lib/yoosee.dart` mirrors `Dvrip` (`lib/dvrip.dart`): `open(Camera)`, `clips(day)` reusing the
  `Clip` typedef, and a download/stream method over SSH/scp or HTTP (not DVRIP).
- `lib/recordings_page.dart`: pick the client per camera; reuse the existing loopback-HTTP + mpv
  playback path.
- `lib/camera.dart` + `lib/settings_page.dart`: add SD path / SSH port fields only if needed
  (store in the existing camera JSON blob).
- `test/yoosee_test.dart`: list-parse / demux tests (pattern: `test/dvrip_test.dart`).
- Document the method in `docs/plan.md` section 4b.

## Risks
- Depends on CAM2 honoring SD `autorun.sh`; otherwise needs opening the case (UART). Bricking
  risk is low (rootfs is read-only squashfs; changes live on SD/`/data`) but non-zero.
- A no-password telnet/SSH is a LAN-only exposure — accept knowingly, or set a dropbear key.
- Needs the camera reachable on the LAN; no internet required once the shell is in.

## Next action
**Gate 0.** User powers off CAM2, plugs its microSD into the PC (USB adapter OK), and says
when it's mounted. Then inspect the card **read-only** — no writes until Gate 1 is approved.

## Verification (final)
CAM2 → Recordings in OpenCam lists today's clips and plays/seeks one; `flutter analyze` and
`flutter test` pass; CAM1 DVRIP recordings still work.
