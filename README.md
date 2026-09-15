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

| Action | Where | Key |
|---|---|---|
| Change FPS, shutter, iris, EI, EV, WB, focus mode | click a top-strip readout, or scroll over it | |
| Autofocus (half-press) / AE lock | AF, AEL (right column) | Space |
| Manual focus nudge (USB, MF/DMF) | NEAR / FAR, or the menu's focus drive row | |
| Take a still | STILL | Return |
| Start / stop movie recording | REC | R |
| Set AF point (Wi-Fi) | click on the picture | |
| Frame lines / 2.39 guide / crop | FRAME, GUIDE, CROP (left column) | G, F, 1–9, 0 |
| Focus peaking / zebras / false color | PEAK, ZEBRA, EXP | P, Z, V |
| 2× magnify | 2.00× | X |
| Scopes: waveform, RGB parade, RGB histogram, vectorscope | SCOPE cycles | W |
| Picture profile / LOG ↔ 709 view / custom .cube LUT | profile badge, LOG/709 button, Overlays menu | L |
| Enhanced upscaling (MetalFX + detail recovery) | ENH | E |
| Smooth motion ×2 / ×4 / ×8 (30 / 60 / 120 fps) | MOTION cycles | M |
| Live denoise NR1 / NR2 (temporal, motion-compensated) | NR cycles | D |
| Camera menu (drive, metering, DRO, flash, focus area, image size, aspect, picture effect, …) | MENU | N |
| Rotate display for vertical mounting | Aspect menu | T |
| Hide the HUD | | H |
| Full screen | View › Enter Full Screen | ⌃⌘F |

### The monitor

The layout follows a cinema viewfinder. The top strip carries exposure: FPS (project), SHUTTER
as an angle with the speed beside it, IRIS, EI, EV, WB with the green/magenta shift as CC, and
FOCUS, plus the profile badge, the exposure mode and the camera index. The bottom strip carries
status: FCL (focal length, USB), PWR, reel and clip (the clip number is the take counter), STBY
in green or REC in red with duration, MEDIA remaining and free-running TC. Tool columns sit on
the edges of the picture; an active tool is orange. Frame lines are red action-safe lines with
edge ticks; recording adds a red border.

### Log, LUTs and picture profiles

The α6400 does not expose Picture Profile over its remote protocol, so it cannot be switched from
the Mac. Set PP7 (S-Log2), PP8/PP9 (S-Log3) or PP10 (HLG) on the camera, then tell the monitor
with the profile badge. **LOG/709** toggles between the flat feed and the built-in conversion to
Rec.709 (S-Log3/S-Gamut3.Cine, S-Log3/S-Gamut3, S-Log2/S-Gamut, HLG/BT.2020 with a soft highlight
roll-off). **Load .cube LUT…** applies your own 3D LUT instead. Scopes read the picture after the LUT.

### Vertical and social formats

CROP cycles through 1:1, 4:5 and 9:16 as well as the cinema ratios, trimming the sides so you frame
for Reels, Stories or feed posts. If the camera is mounted sideways in a cage, rotate the display
by 90° or 270° (T); touch AF coordinates are mapped back to the sensor.

### Enhanced mode

**ENHANCE** (E) renders the live view through Apple's MetalFX spatial upscaler on the GPU,
reconstructing edges when the 1024×680 feed is stretched to a 4K or Retina display. It adds no
latency. On GPUs without MetalFX, or when the window is smaller than the feed, it falls back to
Lanczos resampling. The top bar shows the output resolution and which path is active (MFX or
LANCZOS). It is a nicer picture, not a truer one: the camera still sends 1024×680, so it will
not reveal detail or focus the sensor feed does not contain. Frame rate is unchanged.

### Smooth motion

**MOTION** multiplies the displayed frame rate, ×2, ×4 or ×8 (30, 60 or 120 fps from the
camera's 15), by synthesizing the frames between each pair of real frames: Vision computes dense
optical flow once per pair and a Metal kernel warps both real frames to each in-between time.
Because the in-betweens need the following frame, the picture is shown one input frame later
(about 66 ms at 15 fps); the bottom strip shows the multiplier and the added delay. ×8 only
matters on a 120 Hz (ProMotion) display. Motion looks smoother, but nothing new is captured;
turn it off when pulling critical focus.

### Live denoise

**NR** (D) is a temporal, motion-compensated noise reducer: every incoming frame is blended
with the previous cleaned frame warped along the optical flow, and the blend weight drops to
zero wherever the two disagree, so grain averages out while moving edges stay crisp. NR1 is
light, NR2 strong. It costs one flow computation per frame (about 20 ms) and no extra delay.
Like every monitor tool, it changes only what you see, not what the camera records.

### Colour accuracy

The monitor is colour managed end to end. The camera's live view is an sRGB JPEG; the app tags it
as such (or as Rec.709 / BT.1886 if you choose "Interpret Feed As" in the Overlays menu) and macOS
converts it to the connected display's ICC profile, so a P3 MacBook panel and a calibrated external
monitor both show the same intended colours. The enhanced Metal path is tagged the same way and was
measured to match the plain path within 1/255. Nothing alters the picture unless you switch it on:
the bottom strip shows **NATIVE** when no LUT, effect, denoise, interpolation or sharpening is active.
For the most faithful view on an external monitor, use its sRGB or Rec.709 preset, or a calibrated profile.

### What "true quality" means here

The recording is not affected by any of this. The camera writes its full 4K or 1080p file
internally; the Mac only receives a 1024-pixel-wide monitoring stream. ENHANCE makes that
stream look as close to the recording as a real-time GPU pipeline can: temporal denoise first
(if NR is on), MetalFX edge-aware reconstruction to the display resolution, then an edge-gated
detail-recovery pass that raises local contrast only where there is real structure. It cannot
invent detail the stream never contained, so judge critical focus with PEAK and 2× magnify, and
judge exposure with the scopes and false color, which read the actual pixel values.

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
