# CinemaHUD — Pro Photo mode

Date: 2026-09-15

## Goal

Add a second shooting mode to CinemaHUD for stills. Video mode stays exactly as it is.
Photo mode gives a Sony-body-style shooting display, confirms focus before the shot, and
after every shot pulls the original files (JPEG and RAW) off the camera and shows the real
capture at 100% pixels so the user can judge quality and focus from the actual image
rather than from the 1024×680 live view.

## Facts that shape the design

- The α6400 live view is 1024×680 by the camera's own limit. Upscaling it (MetalFX, already
  present) makes a bigger picture, not a truer one. Real quality only exists in the captured file.
- USB (PC Remote): after a shot the camera holds the captured objects in memory behind handle
  `0xFFFFC001`; property `0xD215` (ObjectInMemory) reads `0x8000 + n` while `n` objects wait.
  With File Format = RAW+JPEG the camera queues two objects (JPEG then ARW). Each `GetObject`
  on the handle pops one. The camera menu must have *Still Img. Save Dest.* set to **PC** or
  **PC+Camera**; the app cannot change that setting on this protocol.
- Wi-Fi (Camera Remote API): `actTakePicture` returns a postview URL; `setPostviewImageSize`
  `"Original"` makes that the full-size JPEG. RAW cannot be transferred during remote shooting
  over this API, so Wi-Fi delivers JPEG only.
- The camera reports which side of the dial it is on: `shootMode` "still"/"movie" over Wi-Fi;
  over USB it is derived from the exposure program (`>= 0x8050` is a movie program).
- Focus confirmation is available as `focusStatus` (Not Focusing / Focusing / Focused / Failed)
  on both transports. Neither transport gives the AF frame rectangle on this body, so the AF
  region the app uses is the last click-to-AF point, or the frame centre if none.
- macOS ImageIO decodes Sony ARW natively (the ILCE-6400 is on Apple's RAW support list).

## Non-goals

- Changing anything in video mode: `MonitorView`, `HUDBars`, strips, tools, keys, look.
- Browsing the memory card or transferring older shots.
- RAW development controls (exposure, WB) on the review screen. Decode and show only.
- Changing camera menu settings (file format, save destination). The app tells the user
  what to set.

## Mode selection

`OverlaySettings.shootingMode: ShootingMode` (`.video`, `.photo`).

- **Follows the dial.** Whenever `CameraState.shootMode` changes, the mode follows it:
  "movie" → video, "still" → photo. The override below is cleared on a dial change.
- **Override.** Tab toggles the mode by hand and sets `modeOverride` so the next state poll
  does not flip it back. The override lasts until the dial moves.
- Before a camera is connected the app shows whichever mode was last used.
- `ContentView` routes: `.video` → `MonitorView` (unchanged), `.photo` → `PhotoView`.
- The Camera menu gets a "Photo Mode" toggle with the Tab shortcut. Video-only shortcuts
  (record, scopes, crops, LUT, motion, denoise) remain in the menus but act on the video view
  only; in photo mode they do nothing.

## Photo view

`PhotoView` = picture layer + `PhotoHUD` overlay, or `ReviewView` when a capture is being
reviewed. Background black; the picture is aspect-fit with no crop ratios.

### Picture

- Same frame source as video mode (`session.frame`), rendered through `MetalFrameView` with
  the MetalFX spatial scaler always on, so the feed fills the display at its native
  resolution (4K/5K/6K monitors get a full-resolution reconstruction).
- Focus peaking (P) and 2× magnify (X) work here via the existing `FrameProcessor`.
- Click on the picture sets the AF point exactly as in video mode.

### PhotoHUD, Sony display style

Drawn over the picture in white, Sony-like type, translucent dark bands only behind the top
and bottom rows so text stays legible. Reference: the Sony body LCD in stills mode.

- **Top row:** mode badge (P / A / S / M / AUTO from `exposureMode`), shots remaining (from
  `shotsRemaining`), file format badge (RAW+J / RAW / JPEG, from the camera's `imageSize`/
  file-format settings when readable, else last known), transport, battery percent.
- **Left column:** focus mode (AF-S / AF-C / MF / DMF), focus area label (SPOT when a
  click-to-AF point is set, WIDE otherwise), drive mode if known.
- **Right column:** white balance, DRO/picture profile label.
- **Bottom row:** shutter, aperture (F2.8), EV with the Sony ± bar, ISO. Each is a
  `StripReadout`-style control: click for a candidate list, scroll to step. These reuse the
  existing readout component, restyled, so behaviour matches video mode.
- **Focus indicator (bottom left, Sony's ●):** hidden when not focusing; steady green when
  `focusStatus == Focused`; blinking red when `Failed`; hollow grey while `Focusing`.
- **AF frame:** bracket corners at the AF point, green when focused, white otherwise.
- **Live sharpness meter:** a small bar next to the focus indicator showing the Laplacian
  sharpness of the AF region on the live frame, normalised to the frame's own peak, so the
  user sees focus settle before pressing the shutter. Updated every frame, computed on a
  downscaled crop so it costs well under a millisecond.
- **Shutter button:** large round button bottom right (SHOT). Return also fires it.
- **Filmstrip:** thumbnails of this session's captures along the bottom edge, newest right.
  Click one to open it in review.

## Capture pipeline

### Kit types

```swift
public struct CapturedImage: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case jpeg, raw }
    public let id: UUID
    public let url: URL          // on disk
    public let kind: Kind
    public let filename: String  // camera's name, e.g. DSC01234.ARW
    public let takenAt: Date
    public let shotIndex: Int    // groups JPEG + RAW of the same shot
}
```

`CameraBackend` gains:

```swift
func capturedImages() -> AsyncStream<CapturedImage>
```

### USB

- `takePicture()` increments `shotIndex`, presses the shutter as today, then runs the
  download loop **on a dedicated task that is not restarted per shot** (a queue), so two quick
  shots do not race for the handle.
- Download loop: poll `0xD215` every 200 ms for up to 15 s. While its value is `>= 0x8001`,
  `GetObjectInfo` + `GetObject` on `0xFFFFC001`, write the file with the camera's filename into
  `Pictures/CinemaHUD/<yyyy-MM-dd>/`, yield a `CapturedImage` (kind from the extension /
  ObjectFormat: `0xB101`-ish RAW vs `0x3801` JPEG), and re-read `0xD215`. Stop when it drops
  below `0x8001`. A 24 MP ARW is ~24 MB and takes 1–3 s over USB 2; the JPEG arrives first
  and is shown immediately, the RAW is attached to the same shot when it lands.
- If `0xD215` never rises, the session gets a one-line hint: "No file received. Set Still Img.
  Save Dest. to PC on the camera."

### Wi-Fi

- On connect, if `setPostviewImageSize` is in the available API list, call it with
  `"Original"`.
- `takePicture()` calls `actTakePicture`; on `40403` (still capturing) it polls
  `awaitTakePicture` until the URL arrives. The JPEG is downloaded to the same folder layout,
  named from the URL's last path component, and yielded as `.jpeg`.

### Session

`CameraSession` gains `captures: [CapturedShot]` (a shot groups its JPEG and RAW),
`latestShot: CapturedShot?`, `reviewShot: CapturedShot?` and `transferring: Bool`. It consumes
the backend's `capturedImages()` stream alongside the state loop. When a new shot's first file
arrives and the app is in photo mode, `reviewShot` is set to it (auto review, like the body).
Captures persist for the session only; the files persist on disk.

## Review view

Shown instead of the live picture while `reviewShot != nil`.

- The full image is decoded once off the main thread (`CGImageSource`, ARW through ImageIO)
  and cached as a `CGImage` plus a 2048-px-wide proxy for fast panning.
- Layout: image aspect-fit; a **loupe** (a 100%-pixel crop, ~360×240 pt) anchored at the AF
  point in image coordinates, floating near the corner opposite the point. Click anywhere to
  move the loupe's centre; scroll over the image to zoom the main view (fit → 100% → 200%),
  drag to pan when zoomed.
- **Focus verdict** card next to the loupe: sharpness score of the AF region (Laplacian
  variance on the luma of the full-res crop) versus the sharpest 5 % of tiles across the
  whole image. Verdict: **IN FOCUS** (region ≥ 70 % of image peak), **SOFT** (35–70 %),
  **MISSED** (< 35 %). The exact thresholds live in one place and are tuned on hardware.
  Also shows where the sharpest tile is, as a small marker, so a MISSED verdict tells the user
  where focus actually landed.
- **Header:** filename, RAW or JPEG badge, pixel size, shutter / F / ISO / EV at capture
  (from the state snapshot taken when the shutter fired), TRANSFERRING RAW… while the second
  file is still coming.
- **Keys:** Escape or click the LIVE button → back to live view. R → toggle JPEG / RAW
  when both exist. Left / Right → previous / next shot. Return → take another picture (also
  leaves review). Space → AF (leaves review).
- Auto review does not block shooting: pressing Return while reviewing fires the shutter and
  the new shot replaces the review when its file arrives.

## Focus analysis (`FocusAnalyzer`)

Pure functions in `SonyCameraKit` so they are testable without UI:

- `sharpness(of image: CGImage, in rect: CGRect) -> Double` — luma, 3×3 Laplacian, variance.
  Downsamples to at most 512 px on the long edge for the live meter; full-res for review.
- `sharpnessMap(of image: CGImage, tiles: Int) -> [[Double]]` — per-tile scores.
- `verdict(region: Double, peak: Double) -> FocusVerdict` with the thresholds above.

Implemented with vImage / Accelerate for the review case so a 6000×4000 image scores in well
under a second.

## Keyboard summary (photo mode)

| Key | Action |
|---|---|
| Tab | Toggle video / photo override |
| Return | Take picture |
| Space | Autofocus |
| P / X | Peaking / 2× magnify |
| Escape | Leave review |
| R | JPEG ↔ RAW in review |
| ← / → | Previous / next shot in review |
| H | Hide HUD |

Video-mode keys are unchanged.

## Error handling

- Transfer failures surface in the HUD status line and leave the shot listed with a warning
  glyph; the user can retry from the filmstrip context menu.
- Decoding failure (corrupt or unsupported RAW) shows the JPEG if present, else a "cannot
  decode" placeholder with the filename.
- If the disk write fails, the error names the folder.

## Files

New:
- `Sources/SonyCameraKit/CapturedImage.swift` — types above.
- `Sources/SonyCameraKit/FocusAnalyzer.swift` — sharpness functions.
- `Sources/CinemaHUD/PhotoView.swift` — mode root, picture, routing to review.
- `Sources/CinemaHUD/PhotoHUD.swift` — Sony-style overlay, focus indicator, filmstrip.
- `Sources/CinemaHUD/ReviewView.swift` — review, loupe, verdict.
- `Tests/SonyCameraKitTests/FocusAnalyzerTests.swift`, `CaptureLoopTests.swift`,
  `ShootingModeTests.swift`.

Changed:
- `CameraBackend.swift` — `capturedImages()`.
- `SonyUSBBackend.swift` — multi-object download loop, queue, stream.
- `WiFiBackend.swift`, `SonyCameraClient.swift` — postview size, download, stream.
- `CameraSession.swift` — captures, review state, consume stream.
- `CinemaHUDApp.swift` — `ShootingMode`, dial following, Tab, routing, menu items.

Untouched: `MonitorView.swift`, `HUDBars.swift`, `HUDReadout.swift`, `Theme.swift`,
`FrameProcessor.swift`, `MetalFrameView.swift`, `LUT.swift`.

## Testing

- Unit: sharpness ordering on synthetic images (sharp edge vs blurred), verdict thresholds,
  ObjectInMemory loop against a fake `PTPDevice` that queues two objects, Wi-Fi postview
  download against a stub URL, dial-following state machine with override.
- Simulator: `tools/camerasim.py` learns `setPostviewImageSize` and serves a large JPEG for
  the postview so the review screen can be exercised without hardware.
- Hardware (α6400, USB): RAW+JPEG arrives as two files; auto review opens on the JPEG; RAW
  toggles in; verdict agrees with a deliberately missed focus. Tune thresholds here.

## Verified vs. unverified

The protocol facts for USB are from the existing verified backend plus libgphoto2's Sony
driver (0xD215 count semantics). `setPostviewImageSize "Original"` on the α6400 over Wi-Fi is
from Sony's API reference and is unverified on this body until tested.
