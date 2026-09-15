# CinemaHUD

A native macOS app that turns a Sony α6400 into a remote-monitored cinema camera: live view on
your Mac with a cinema-style HUD for shutter, iris, ISO, white balance, EV and focus, plus
click-to-focus, still capture, movie record, focus peaking, zebras, framing guides and cinema
aspect crops that fill an ultrawide monitor.

It connects either over **USB** (the camera's "PC Remote" mode, PTP with Sony's extensions,
driven directly through IOUSBHost) or over the camera's own **Wi-Fi** (the Sony Camera Remote API,
the same protocol PlayMemories Mobile / Imaging Edge Mobile use). No Sony software or drivers required.

## Using it

### USB (recommended: lowest latency, no dropouts)

1. **Camera:** MENU → Setup → *USB Connection* → **PC Remote**. Turn the mode dial to M (or Movie M).
2. Connect the USB cable, open **CinemaHUD**, click **Connect USB**.

If the camera mounts as a drive instead, it is still in Mass Storage mode: eject it, change the
setting, and reconnect. If macOS's Image Capture or Photos has grabbed the camera, quit them and replug.

### Wi-Fi

1. **Camera:** MENU → Network → *Ctrl w/ Smartphone* → **On**, then *Connection*.
   The screen shows an SSID like `DIRECT-xxxx:ILCE-6400` and a password.
2. **Mac:** join that Wi-Fi network.
3. Click **Discover**. If nothing is found, type `192.168.122.1:8080`
   into the address box and click **Connect** (that is the camera's fixed address in this mode).

The app drops stale frames and always shows the newest one, and reconnects by itself if the
link hiccups.

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
| Frame lines (thirds + action-safe corners) / 2.39 guide shading / center marker | FRAME, GUIDE buttons | G, F, C |
| Focus peaking / zebras | PEAK, ZEBRA buttons | P, Z |
| False color exposure map | FALSE button | V |
| Luma waveform scope | SCOPE button | W |
| Enhanced upscaling (MetalFX) | ENHANCE button | E |
| Smooth motion (interpolated ×2) | MOTION button | M |
| Project frame rate (shutter angle, timecode) | FPS readout | |
| Aspect crop: native, 16:9, 1.85, 2.00, 2.35, 2.39 | crop button cycles | 1 – 6 |
| Hide the HUD | | H |
| Full screen | View › Enter Full Screen | ⌃⌘F |

**Ultrawide monitors:** pick a scope crop (2.35 or 2.39) and enter full screen. The live view
is cropped to that ratio and fills a 21:9 display edge to edge instead of letterboxing.

Readouts are dimmed when the camera does not currently allow that change (for example, nothing
is adjustable in Intelligent Auto, and shutter speed cannot be set in Aperture priority).

### The HUD

The layout follows a cinema camera body. The top strip shows recording state and duration,
free-running timecode with frames at the project frame rate, a take counter, camera and mode,
then media remaining and battery. The bottom band is the readout row: FPS (project), SHUTTER as
a shutter angle with the speed underneath, EI, IRIS, WB, EV and FOCUS. Click a readout to pick a
value or scroll over it to step. While recording, the frame gets a red border and the timecode
turns red. Color is used only for state: red recording, green confirmed, amber warnings.

**False color** maps exposure to bands: purple and blue for crushed shadows, green for mid grey
(38–46 IRE), pink for skin (52–58 IRE), yellow and orange approaching clip, red for clipped.
**Scope** shows a luma waveform of the current frame.

### Enhanced mode

**ENHANCE** (E) renders the live view through Apple's MetalFX spatial upscaler on the GPU,
reconstructing edges when the 1024×680 feed is stretched to a 4K or Retina display. It adds no
latency. On GPUs without MetalFX, or when the window is smaller than the feed, it falls back to
Lanczos resampling. The top bar shows the output resolution and which path is active (MFX or
LANCZOS). It is a nicer picture, not a truer one: the camera still sends 1024×680, so it will
not reveal detail or focus the sensor feed does not contain. Frame rate is unchanged.

### Smooth motion

**MOTION** (M) doubles the displayed frame rate, 15 → 30 fps over USB, by synthesizing the frame
between each pair of real frames: Vision computes dense optical flow between them and a Metal
kernel warps both toward the midpoint. Because the midpoint needs the following frame, the picture
is shown one input frame later (about 66 ms at 15 fps); the top bar shows the added delay. Motion
looks smoother, but nothing new is captured. Turn it off when you need the lowest latency, such as
pulling focus.

### Live view quality and frame rate

The α6400 generates its remote live view at 1024×680. Over USB the body delivers it at 15 fps,
which is the camera's limit for this protocol, not the app's. The app polls continuously and
displays each frame as soon as it arrives. For full-resolution, 30/60 fps monitoring use the
camera's HDMI output into a UVC capture device; that is the next planned video source.

### Verified on hardware (α6400, firmware 2.00, USB)

Connect, live view, shutter / iris / ISO stepping (lands on the nearest value the current mode
offers), movie record start/stop with true recording state, battery. Touch AF is Wi-Fi only.
Still capture and half-press AF over USB are implemented but were only exercised in movie mode,
where the body ignores them; test them in a stills mode.

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

```sh
tools/probe.sh                     # Wi-Fi: versions, available APIs, first event, liveview URL
swift run usbprobe                 # USB: device info, every property, one liveview frame, fps
swift run usbprobe --set shutter=1/50 --rec --af --shoot --watch   # exercise controls
PTP_DEBUG=1 swift run usbprobe     # trace every PTP transaction
```

## Layout

- `Sources/SonyCameraKit` — protocol library. `CameraBackend` abstracts the transport; `WiFiBackend` (SSDP discovery, JSON-RPC client, liveview stream parser) and `USB/SonyUSBBackend` (IOUSBHost transport, PTP transactions, Sony SDIO handshake, property parsing, notch stepping) both feed `CameraSession`, the observable object the UI talks to.
- `Sources/usbprobe` — command-line hardware probe for the USB path.
- `Sources/CinemaHUD` — SwiftUI app: connect screen, monitor view with overlays, HUD bars, Core Image peaking/zebra.
- `Tests/SonyCameraKitTests` — parser, event decoding, request encoding, device description parsing.
- `tools/camerasim.py` — fake camera. `tools/probe.sh` — hardware check.
- `scripts/build-dmg.sh` — release build, `.app` assembly, ad-hoc codesign, DMG.
- `docs/superpowers/specs/` — design spec.

## Status

USB path verified on a physical α6400. Wi-Fi path built to the published Camera Remote API and
exercised end to end against the simulator; not yet verified on the body.
