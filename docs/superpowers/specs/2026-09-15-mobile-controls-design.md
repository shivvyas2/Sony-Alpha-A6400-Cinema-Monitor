# CinemaHUD Mobile — touch controls, professional layout, settings, legal pages

Date: 2026-09-15

## Goal

Make the iPhone / iPad app a real field monitor rather than the Mac layout squeezed onto a phone:
touch-first screens in both orientations, a photo / video switch, guide options, power-zoom and
manual-focus controls with focus assist, recording-format controls, a proper Settings screen, and
Privacy Policy and Terms of Use pages. Nothing on the Mac changes.

## Facts that shape the design

- The iOS app (`iOS/CinemaHUDMobile`) currently renders the shared `MonitorView` / `PhotoView` from
  `CinemaUI`, whose chrome (`HUDBars`: strips, edge buttons, the 330-pt `SettingsPanel`) is sized for
  a desktop window. That is why the menu overflows a phone.
- Transports on the phone: **Wi-Fi** direct to the camera (Sony Camera Remote API) or the **Mac
  bridge** (the Mac's USB session relayed over the LAN). Capabilities differ:
  - Zoom: Wi-Fi only, and only when a power-zoom lens is mounted (the camera then lists `actZoom`
    in `availableApiList` and reports `zoomInformation`). The α6400's USB protocol has no zoom drive.
  - Manual focus drive: USB / bridge only (`focusDrive`, `session.focusDriveAvailable`). Sony's Wi-Fi
    API has no MF drive.
  - Shoot mode (still / movie): settable over Wi-Fi (`setShootMode`); over USB / bridge the body's
    dial decides.
  - Still size and aspect: USB / bridge via the settings list (`Image size`, `Aspect ratio`); Wi-Fi
    via `setStillSize` when advertised.
  - Movie quality and file format: Wi-Fi via `setMovieQuality` / `setMovieFileFormat` when
    advertised. Not exposed by the USB protocol on this body; the app says "set on camera".
- `ScrollStepper` on iOS is a vertical drag gesture (`ScrollWheelCatcher.swift`); `MetalFrameView`
  and `FrameProcessor` take a raw-value `CIImage` flipped once in the renderer (no second flip).
- Every control is gated by what the connected camera actually advertises, so nothing appears that
  cannot work.

## Non-goals

- Changing the Mac app's views or keyboard behaviour.
- Camera menu items beyond those listed (drive, metering etc. stay in the generic settings list).
- Cloud sync, accounts, analytics (none exist; the privacy policy says so).

## Layout

New `Mobile*` views in `CinemaUI` compiled for iOS only (`#if !os(macOS)`), reusing the picture
pipeline (`MetalFrameView`, `FrameProcessor`, `LiveSharpnessMeter`, `ReviewView`, `FocusAnalyzer`).

- **Landscape (iPhone and iPad):** picture fills the screen at native aspect, letterboxed on black.
  Left rail: monitor tools (GUIDES, PEAK, ZEBRA, 2×, LUT, SCOPE) as 44-pt icon buttons that scroll
  if the height is short. Right rail: camera actions (AF, AEL, FOCUS, ZOOM, STILL, REC/SHOT).
  Bottom band: exposure readouts (shutter, iris, ISO, EV, WB, focus mode) that scroll horizontally
  on narrow phones. Top band: mode switch, transport, battery, media, REC state, gear.
- **Portrait:** picture on top at native aspect; below it a control deck: mode switch row, exposure
  readouts in a horizontal scroller, then two rows of tool buttons, then the record / shutter button.
  The deck scrolls if the screen is short.
- **iPad:** landscape layout with 52-pt targets and the exposure readouts spaced wider; sheets open
  as popovers anchored to their button.
- All layouts respect safe areas (Dynamic Island, home indicator, rounded corners). No fixed widths
  wider than the screen; every hit target ≥ 44 pt.
- Readouts open a **bottom sheet** (`.presentationDetents([.medium])`) with the candidate list;
  a vertical drag on the readout steps it (existing `ScrollStepper`).
- Tapping the picture sets the AF point (Wi-Fi) or the focus-check point (USB / bridge) as today.
- Photo mode on mobile reuses `PhotoHUD`'s pieces but in the mobile chrome; auto review uses the
  existing `ReviewView` (pinch-to-zoom replaces scroll-to-zoom on touch).

## Controls

### Photo / Video switch
Segmented control (VIDEO | PHOTO) in the top band. Over Wi-Fi it calls `setShootMode` and the
app follows the resulting dial state. Over USB / bridge it toggles the app's `ShootingModeResolver`
override and, if the body's dial disagrees, shows a one-line hint "Turn the dial to a stills / movie
position for the camera to follow."

### Guides
`OverlaySettings` gains `guideRatio: FrameGuideRatio` (1.85, 2.00, 2.35, 2.39, 4:3, 1:1, 9:16),
`safeAreas: Bool`, `diagonals: Bool`; `grid` (thirds), `centerMarker`, `frameGuides` already exist.
A **Guides sheet** lists: Thirds, Centre marker, Action / title safe, Diagonals, Frame lines (with the
ratio picker), plus "Clear all". `FrameOverlays` is extended to draw the new options (shared with
the Mac, where they are simply off by default).

### Zoom
Shown when `state.supports("actZoom")`. A W ◀ ▶ T rocker (press-and-hold starts, release stops;
tap = one step) and a position bar from `state.zoomPosition`. On USB / bridge the ZOOM button opens a
sheet explaining zoom needs the Wi-Fi connection and a power-zoom lens.

### Focus
A **Focus sheet**: AF mode (AF-S / AF-C / MF / DMF from `focusModeCandidates`), manual focus wheel
(drag = near / far in fine steps; buttons for ◀◀◀ ◀ ▶ ▶▶▶ using `focusDrive`, enabled by
`focusDriveAvailable`), focus peaking on/off with colour (red, yellow, white, blue), 2× magnify, and
the AF-region sharpness meter (from `LiveSharpnessMeter`), now available in video mode too. On
Wi-Fi the MF wheel is replaced by "Manual focus drive needs USB or the Mac bridge."

`OverlaySettings` gains `peakingColor: PeakingColor`; `FrameProcessor.pipeline` takes the colour.

### Recording format
A **Format sheet**: still size and aspect (from the settings list on USB / bridge, or `setStillSize`
on Wi-Fi), movie quality and movie file format (Wi-Fi when advertised), monitor crop ratio, project
frame rate. Rows the camera does not expose show "Set on camera" in grey.

## Settings screen

Gear button → full-screen `MobileSettingsView` (NavigationStack, grouped list):
- Connection: current transport and camera name, Disconnect.
- Display: feed colour space, MetalFX upscaling, detail recovery, smooth motion, live denoise,
  picture profile, LUT on/off.
- Guides (same options as the sheet), Focus assist (peaking colour, meter on/off).
- Captures: where files are saved (Files app → CinemaHUD), how many this session.
- About: app name, version, "Not affiliated with Sony".
- **Privacy Policy** and **Terms of Use**: full pages rendered from bundled Markdown-like text.

### Privacy Policy (content)
Written for an individual developer, Shiv Vyas, contact email marked `[contact email]` for the user
to fill in. States: the app collects no personal data, has no accounts, analytics or ads; it
communicates only with the camera or a Mac on the local network; captured images and settings stay
on the device; the Local Network permission is used solely to find and talk to the camera / Mac;
no data is sold or shared; contact and effective date.

### Terms of Use (content)
Provided as-is without warranty; use at your own risk with camera equipment; not affiliated with,
endorsed by or sponsored by Sony (Sony, α and Alpha are Sony's trademarks); the user is responsible
for their recordings and for complying with local laws; governing terms may change with notice in
the app; contact.

## Library additions (`SonyCameraKit`)

- `SonyCameraClient`: `actZoom(direction:movement:)` (exists), `setStillSize(aspect:size:)`,
  `getSupportedStillSize()`, `setMovieQuality(_:)`, `getSupportedMovieQuality()`,
  `setMovieFileFormat(_:)`, `getSupportedMovieFileFormat()`.
- `CameraState`: `zoomPosition` (exists), `stillSize: (aspect, size)?`, `stillSizeCandidates`,
  `movieQuality`, `movieQualityCandidates`, `movieFileFormat`, `movieFileFormatCandidates`, decoded
  from the `stillSize`, `movieQuality`, `movieFileFormat` event items.
- `CameraBackend`: `zoom(direction:movement:)`, `setStillSize`, `setMovieQuality`,
  `setMovieFileFormat` with default `UnsupportedOperation` implementations; Wi-Fi implements them;
  USB maps still size / aspect to its existing settings; bridge relays them (`BridgeCommand` cases)
  and `BridgeState` carries the new fields.
- `CameraSession`: async wrappers plus `zoomAvailable`, `movieFormatAvailable` convenience flags.

## Error handling

- Unsupported operations surface as the existing one-line HUD status, never as alerts.
- Zoom rocker release always sends `stop`, including when the view disappears.
- Sheets dismiss on disconnect.

## Files

New (CinemaUI, iOS only): `MobileMonitorView.swift`, `MobilePhotoView.swift`, `MobileChrome.swift`
(rails, bands, readout, mode switch), `MobileSheets.swift` (guides, focus, zoom, format),
`MobileSettingsView.swift`, `LegalPages.swift` (policy + terms text and page view), `Guides.swift`
(FrameGuideRatio, PeakingColor; shared).
Changed: `Settings.swift` (new overlay fields), `MonitorView.swift`'s `FrameOverlays` (new guide
kinds), `FrameProcessor.swift` (peaking colour), `CameraState.swift`, `SonyCameraClient.swift`,
`WiFiBackend.swift`, `CameraBackend.swift`, `CameraSession.swift`, `Bridge/*`,
`iOS/CinemaHUDMobile/CinemaHUDMobileApp.swift` (route to the mobile views), `Info.plist` /
project (all orientations on iPhone and iPad).

## Testing

- Unit: event decoding for stillSize / movieQuality / movieFileFormat / zoomInformation; capability
  gating helpers; FrameGuideRatio values; bridge command round-trip for the new ops.
- Simulator: iPhone 15 Pro and iPad Pro, portrait and landscape, against `tools/camerasim.py`
  (extended to advertise actZoom, setStillSize, setMovieQuality, setMovieFileFormat and to honour
  them) — screenshots checked for overflow and target sizes.
- Review by the other session from a clean worktree; hardware check of zoom (with the 16-50 PZ
  lens) and MF over the bridge on the α6400 pending.
