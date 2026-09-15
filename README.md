# CinemaHUD

A native macOS app that turns a Sony α6400 into a remote-monitored cinema camera: live view on
your Mac with a cinema-style HUD for shutter, iris, ISO, white balance, EV and focus, plus
click-to-focus, still capture, movie record, focus peaking, zebras, framing guides and cinema
aspect crops that fill an ultrawide monitor.

It talks to the camera over the camera's own Wi-Fi using the Sony Camera Remote API, the same
protocol PlayMemories Mobile / Imaging Edge Mobile use. No Sony software or drivers required.

## Using it

1. **Camera:** MENU → Network → *Ctrl w/ Smartphone* → **On**, then *Connection*.
   The screen shows an SSID like `DIRECT-xxxx:ILCE-6400` and a password.
2. **Mac:** join that Wi-Fi network.
3. Open **CinemaHUD** and click **Discover**. If nothing is found, type `192.168.122.1:8080`
   into the address box and click **Connect** (that is the camera's fixed address in this mode).

### First launch on macOS

The DMG is ad-hoc signed, not notarized. macOS will refuse to open it the first time.
Either right-click the app → **Open** → **Open**, or go to System Settings → Privacy & Security
and click **Open Anyway**. macOS will also ask for **Local Network** permission the first time you
click Discover; allow it.

### Controls

| Action | Mouse | Key |
|---|---|---|
| Change shutter / iris / ISO / EV / WB / focus | click the readout, or scroll over it | |
| Autofocus (half-press) | AF button | Space |
| Take a still | SHOT button | Return |
| Start / stop movie recording | REC button | R |
| Set AF point | click on the image | |
| Thirds grid / 2.39 guide shading / center marker | GRID, GUIDE buttons | G, F, C |
| Focus peaking / zebras | PEAK, ZEBRA buttons | P, Z |
| Aspect crop: native, 16:9, 1.85, 2.00, 2.35, 2.39 | crop button cycles | 1 – 6 |
| Hide the HUD | | H |
| Full screen | View › Enter Full Screen | ⌃⌘F |

**Ultrawide monitors:** pick a scope crop (2.35 or 2.39) and enter full screen. The live view
is cropped to that ratio and fills a 21:9 display edge to edge instead of letterboxing.

Readouts are dimmed when the camera does not currently allow that change (for example, shutter
speed cannot be set while the mode dial is on Aperture priority).

## Building

Requires Xcode 15+ command line tools (Swift 5.9+) and macOS 14+.

```sh
swift test                 # unit tests for the protocol layer
./scripts/build-dmg.sh     # → build/CinemaHUD.app and build/CinemaHUD.dmg
```

### Developing without a camera

`tools/camerasim.py` is a fake α6400 (needs Python 3 with Pillow). It answers SSDP discovery,
JSON-RPC and streams a synthetic live view whose brightness follows the exposure settings.

```sh
python3 tools/camerasim.py                       # JSON-RPC on :8080
CINEMAHUD_ADDRESS=127.0.0.1:8080 swift run CinemaHUD
```

Other development environment variables: `CINEMAHUD_WINDOW=WxH`, `CINEMAHUD_OVERLAYS=peaking,zebra,crop=2.39,hidehud`,
`CINEMAHUD_SNAPSHOT=/path.png` (renders the window to a PNG), `CINEMAHUD_QUIT=1`.

### Checking a real camera

With the Mac on the camera's Wi-Fi:

```sh
tools/probe.sh                     # prints versions, available APIs, first event, liveview URL
```

## Layout

- `Sources/SonyCameraKit` — protocol library: SSDP discovery, JSON-RPC client, liveview stream parser, event → `CameraState` decoding, and `CameraSession` (the observable object the UI talks to).
- `Sources/CinemaHUD` — SwiftUI app: connect screen, monitor view with overlays, HUD bars, Core Image peaking/zebra.
- `Tests/SonyCameraKitTests` — parser, event decoding, request encoding, device description parsing.
- `tools/camerasim.py` — fake camera. `tools/probe.sh` — hardware check.
- `scripts/build-dmg.sh` — release build, `.app` assembly, ad-hoc codesign, DMG.
- `docs/superpowers/specs/` — design spec.

## Status

Built to the published Camera Remote API and exercised end to end against the simulator.
Not yet verified on a physical α6400.
