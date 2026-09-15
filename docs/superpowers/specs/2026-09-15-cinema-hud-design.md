# CinemaHUD — macOS remote control + live view for Sony a6400

Date: 2026-09-15

## Goal

A native macOS app (shipped as a `.dmg`) that connects to a Sony a6400 over Wi-Fi,
shows its live view full-screen, and overlays a cinema-camera style HUD with the
current shutter speed, aperture (iris), ISO, white balance, exposure compensation
and focus mode. The user can change those values, trigger autofocus, click on the
image to set the AF point, take a still, and start/stop movie recording.

## Non-goals (v1)

- USB tethering (PTP "PC Remote"). Different protocol; can be added later.
- Image transfer / browsing the memory card.
- Waveform / vectorscope. A luma histogram is optional and cheap; anything more is out.
- App Store distribution / notarization. The DMG is ad-hoc signed.

## Protocol

The a6400 in **"Ctrl w/ Smartphone"** mode exposes the Sony **Camera Remote API**
(the protocol PlayMemories Mobile / Imaging Edge Mobile use):

- Camera creates a Wi-Fi AP `DIRECT-xxxx:ILCE-6400`; the Mac joins it.
- Discovery: SSDP `M-SEARCH` on `239.255.255.250:1900` for
  `urn:schemas-sony-com:service:ScalarWebAPI:1`. The response's `LOCATION` points to a
  device-description XML that contains the `camera` service URL
  (in practice `http://192.168.122.1:8080/sony`). If SSDP yields nothing, the app
  probes that default URL directly.
- Control: JSON-RPC over HTTP POST to `<service>/camera`,
  body `{"method":"getEvent","params":[true],"id":1,"version":"1.0"}`.
- Events: `getEvent` long-polling. Each element of `result` is either `null` or an
  object with a `type` field; we index by `type`, never by position.
- Live view: `startLiveview` returns a URL. The body is an endless stream of packets:
  8-byte common header (`0xFF`, payload type, 2-byte sequence, 4-byte timestamp),
  128-byte payload header (start code `24 35 68 79`, 3-byte payload size,
  1-byte padding size, …), then the JPEG payload, then padding.
  Payload type `0x01` is a JPEG frame; `0x02` is frame info (focus frames) and is ignored in v1.
- Some bodies need `startRecMode` before shooting APIs appear; the client calls it
  only when it appears in `availableApiList`.

## Architecture

Swift Package with two Swift targets plus a Python simulator:

1. **`SonyCameraKit`** (library, no UI)
   - `SSDPDiscovery` — sends M-SEARCH, parses responses, fetches device description, returns service URL.
   - `SonyCameraClient` — async JSON-RPC calls; typed wrappers for the methods we use.
   - `LiveviewStreamParser` — pure function-style parser: feed bytes, get `Data` JPEG frames out. Tested with fixtures.
   - `CameraEvent` / `CameraState` — decoded `getEvent` into a struct (status, shutter, fNumber, iso, wb, ev, focusMode, candidates for each, recording time, battery, shots remaining, available APIs).
   - `CameraSession` — `@MainActor @Observable`: owns the client, the event loop task, the liveview task; publishes `state`, `latestFrame` (CGImage), `connectionPhase`, `lastError`. All UI talks only to this.

2. **`CinemaHUD`** (executable, SwiftUI)
   - `ConnectView` — discovery / manual address / status.
   - `MonitorView` — live view image, aspect-fit, letterboxed on black, with overlays (grid, safe area, peaking, zebra) and click-to-AF.
   - `HUDOverlay` — top bar (REC dot + recording time, camera status, battery, shots left), bottom bar of `HUDReadout`s (SHUTTER, IRIS, ISO, WB, EV, FOCUS). Click a readout to open a popover of the candidate values; scroll wheel steps through them.
   - `ToolbarView` — AF (half press), SHOOT, REC, overlay toggles.
   - Aspect crop (native, 16:9, 1.85, 2.00, 2.35, 2.39): crops the feed top/bottom and aspect-fits
     the crop, so a scope ratio fills an ultrawide (21:9) monitor edge to edge in full screen.
     Click-to-AF coordinates are mapped back through the crop to full-frame percentages.
   - Keyboard: space = AF, return = shoot, R = record, G = grid, F = guides, C = center, P = peaking,
     Z = zebra, H = hide HUD, 1–6 = aspect crop.

3. **`tools/camerasim.py`** — a fake a6400 in Python (Pillow for frames): SSDP responder +
   JSON-RPC server + liveview stream generator. Honors the set* calls so the HUD updates,
   and its synthetic scene's brightness follows shutter/iris/ISO/EV.

Tests (`SonyCameraKitTests`): liveview parser (single frame, split across chunks,
padding, garbage before start byte), event decoding from a recorded-style JSON
fixture, JSON-RPC request encoding.

## Packaging

`scripts/build-dmg.sh`:
`swift build -c release` → assemble `build/CinemaHUD.app` (`Info.plist`,
`Contents/MacOS/CinemaHUD`, icon) → `codesign --force --sign -` →
`hdiutil create` a compressed DMG with an `/Applications` symlink → `build/CinemaHUD.dmg`.

`Info.plist` carries `NSLocalNetworkUsageDescription` (macOS prompts for local-network
access on first SSDP send) and `NSAppTransportSecurity` allowing plain HTTP, since the
camera speaks HTTP only.

## Error handling

- Connection phases: `idle → discovering → connecting → streaming`, with `failed(message)`.
- Every JSON-RPC error carries the Sony error code and message and surfaces in the HUD status line.
- The event loop retries with backoff; if the liveview stream drops it is restarted automatically
  while the session is alive.
- Controls whose API is not in `availableApiList` are shown dimmed and are not sent.

## Verified vs. unverified

The app is built to the published protocol and exercised against `CameraSim`.
It has **not** been tested on a physical a6400 during this session.
