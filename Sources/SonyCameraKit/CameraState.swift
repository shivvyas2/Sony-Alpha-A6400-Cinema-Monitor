import Foundation

public struct BatteryInfo: Sendable, Equatable {
    public var status: String      // "Active", "Inactive", "Unknown"
    public var additionalStatus: String
    public var levelNumer: Int
    public var levelDenom: Int
    public var fraction: Double { levelDenom > 0 ? Double(levelNumer) / Double(levelDenom) : 0 }
}

public struct StorageInfo: Sendable, Equatable {
    public var numberOfRecordableImages: Int?
    public var recordableTimeMinutes: Int?
    public var description: String
    public var recordTarget: Bool
}

public struct ExposureCompensation: Sendable, Equatable {
    public var index: Int
    public var minIndex: Int
    public var maxIndex: Int
    /// 1 = 1/3 EV steps, 2 = 1/2 EV steps
    public var stepIndex: Int
    public init(index: Int, minIndex: Int, maxIndex: Int, stepIndex: Int) {
        self.index = index; self.minIndex = minIndex; self.maxIndex = maxIndex; self.stepIndex = stepIndex
    }
    public var stepEV: Double { stepIndex == 2 ? 0.5 : 1.0 / 3.0 }
    public var ev: Double { Double(index) * stepEV }
    public var label: String {
        let v = ev
        if abs(v) < 0.01 { return "0" }
        return String(format: "%@%.1f", v > 0 ? "+" : "", v)
    }
}

/// Snapshot of everything the HUD shows, merged from successive `getEvent` results.
public struct CameraState: Sendable, Equatable {
    public var availableAPIs: Set<String> = []
    public var cameraStatus: String = "Unknown"   // IDLE, StillCapturing, MovieRecording, ...
    public var liveviewStatus: Bool = false
    public var shootMode: String?                 // still, movie
    public var shootModeCandidates: [String] = []
    public var exposureMode: String?              // Program Auto, Aperture, Shutter, Manual, ...
    public var exposureModeCandidates: [String] = []

    public var shutterSpeed: String?
    public var shutterSpeedCandidates: [String] = []
    public var fNumber: String?
    public var fNumberCandidates: [String] = []
    public var iso: String?
    public var isoCandidates: [String] = []
    public var whiteBalanceMode: String?
    public var colorTemperature: Int?
    public var whiteBalanceCandidates: [String] = []
    public var exposureCompensation: ExposureCompensation?
    public var focusMode: String?
    public var focusModeCandidates: [String] = []
    public var focusStatus: String?               // Not Focusing, Focusing, Focused, Failed
    public var touchAFSet: Bool = false
    public var touchAFPoint: (x: Double, y: Double)?

    public var battery: BatteryInfo?
    public var storage: [StorageInfo] = []
    public var recordingTimeSeconds: Int = 0
    public var numberOfShots: Int = 0
    public var zoomPosition: Int?
    public var stillSize: StillSize?
    public var stillSizeCandidates: [StillSize] = []
    public var movieQuality: String?
    public var movieQualityCandidates: [String] = []
    public var movieFileFormat: String?
    public var movieFileFormatCandidates: [String] = []
    public var lastPictureURLs: [String] = []
    /// Lens focal length in mm when the camera reports it (USB).
    public var focalLengthMM: Double?
    /// White balance colour compensation (green ↔ magenta) and amber ↔ blue shifts, in camera steps.
    public var ccShift: Int?
    public var abShift: Int?

    public var isRecording: Bool { cameraStatus == "MovieRecording" }
    public var shotsRemaining: Int? { storage.first(where: { $0.recordTarget })?.numberOfRecordableImages ?? storage.first?.numberOfRecordableImages }
    public var recordableMinutes: Int? { storage.first(where: { $0.recordTarget })?.recordableTimeMinutes ?? storage.first?.recordableTimeMinutes }

    public func supports(_ api: String) -> Bool { availableAPIs.contains(api) }

    public init() {}

    public static func == (a: CameraState, b: CameraState) -> Bool {
        a.availableAPIs == b.availableAPIs && a.cameraStatus == b.cameraStatus && a.liveviewStatus == b.liveviewStatus
        && a.shootMode == b.shootMode && a.exposureMode == b.exposureMode && a.shutterSpeed == b.shutterSpeed
        && a.fNumber == b.fNumber && a.iso == b.iso && a.whiteBalanceMode == b.whiteBalanceMode
        && a.colorTemperature == b.colorTemperature && a.exposureCompensation == b.exposureCompensation
        && a.focusMode == b.focusMode && a.focusStatus == b.focusStatus && a.touchAFSet == b.touchAFSet
        && a.touchAFPoint?.x == b.touchAFPoint?.x && a.touchAFPoint?.y == b.touchAFPoint?.y
        && a.battery == b.battery && a.storage == b.storage && a.recordingTimeSeconds == b.recordingTimeSeconds
        && a.numberOfShots == b.numberOfShots && a.zoomPosition == b.zoomPosition
        && a.focalLengthMM == b.focalLengthMM && a.ccShift == b.ccShift && a.abShift == b.abShift
        && a.shutterSpeedCandidates == b.shutterSpeedCandidates && a.fNumberCandidates == b.fNumberCandidates
        && a.isoCandidates == b.isoCandidates && a.focusModeCandidates == b.focusModeCandidates
        && a.whiteBalanceCandidates == b.whiteBalanceCandidates && a.lastPictureURLs == b.lastPictureURLs
        && a.stillSize == b.stillSize && a.stillSizeCandidates == b.stillSizeCandidates
        && a.movieQuality == b.movieQuality && a.movieQualityCandidates == b.movieQualityCandidates
        && a.movieFileFormat == b.movieFileFormat && a.movieFileFormatCandidates == b.movieFileFormatCandidates
    }

    /// Merge one `getEvent` result array. Items are matched by their `type` field; nulls are skipped.
    public mutating func apply(event result: JSON) {
        guard let items = result.array else { return }
        for item in items {
            // Some slots are arrays of objects (e.g. batteryInfo list variants); flatten those too.
            if let list = item.array {
                for sub in list { applyItem(sub) }
            } else {
                applyItem(item)
            }
        }
    }

    private mutating func applyItem(_ item: JSON) {
        guard let type = item["type"].string else { return }
        switch type {
        case "availableApiList":
            availableAPIs = Set(item["names"].stringArray)
        case "cameraStatus":
            cameraStatus = item["cameraStatus"].string ?? cameraStatus
        case "liveviewStatus":
            liveviewStatus = item["liveviewStatus"].bool ?? liveviewStatus
        case "shootMode":
            shootMode = item["currentShootMode"].string ?? shootMode
            let c = item["shootModeCandidates"].stringArray; if !c.isEmpty { shootModeCandidates = c }
        case "exposureMode":
            exposureMode = item["currentExposureMode"].string ?? exposureMode
            let c = item["exposureModeCandidates"].stringArray; if !c.isEmpty { exposureModeCandidates = c }
        case "shutterSpeed":
            shutterSpeed = item["currentShutterSpeed"].string ?? shutterSpeed
            shutterSpeedCandidates = item["shutterSpeedCandidates"].stringArray
        case "fNumber":
            fNumber = item["currentFNumber"].string ?? fNumber
            fNumberCandidates = item["fNumberCandidates"].stringArray
        case "isoSpeedRate":
            iso = item["currentIsoSpeedRate"].string ?? iso
            isoCandidates = item["isoSpeedRateCandidates"].stringArray
        case "whiteBalance":
            whiteBalanceMode = item["currentWhiteBalanceMode"].string ?? whiteBalanceMode
            colorTemperature = item["currentColorTemperature"].int ?? colorTemperature
        case "exposureCompensation":
            if let idx = item["currentExposureCompensation"].int {
                exposureCompensation = ExposureCompensation(
                    index: idx,
                    minIndex: item["minExposureCompensation"].int ?? -9,
                    maxIndex: item["maxExposureCompensation"].int ?? 9,
                    stepIndex: item["stepIndexOfExposureCompensation"].int ?? 1)
            }
        case "focusMode":
            focusMode = item["currentFocusMode"].string ?? focusMode
            let c = item["focusModeCandidates"].stringArray; if !c.isEmpty { focusModeCandidates = c }
        case "focusStatus":
            focusStatus = item["focusStatus"].string ?? focusStatus
        case "touchAFPosition":
            touchAFSet = item["currentSet"].bool ?? touchAFSet
            if let coords = item["currentTouchCoordinates"].array, coords.count >= 2,
               let x = coords[0].double, let y = coords[1].double {
                touchAFPoint = (x, y)
            }
        case "batteryInfo":
            if let first = item["batteryInfo"].array?.first {
                battery = BatteryInfo(status: first["status"].string ?? "Unknown",
                                      additionalStatus: first["additionalStatus"].string ?? "",
                                      levelNumer: first["levelNumer"].int ?? 0,
                                      levelDenom: first["levelDenom"].int ?? 0)
            }
        case "storageInformation":
            if let list = item["storageInformation"].array {
                storage = list.map {
                    StorageInfo(numberOfRecordableImages: $0["numberOfRecordableImages"].int.flatMap { $0 < 0 ? nil : $0 },
                                recordableTimeMinutes: $0["recordableTime"].int.flatMap { $0 < 0 ? nil : $0 },
                                description: $0["storageDescription"].string ?? "",
                                recordTarget: $0["recordTarget"].bool ?? false)
                }
            }
        case "recordingTime":
            recordingTimeSeconds = item["recordingTime"].int ?? recordingTimeSeconds
        case "numberOfShots":
            numberOfShots = item["numberOfShots"].int ?? numberOfShots
        case "zoomInformation":
            zoomPosition = item["zoomPosition"].int ?? zoomPosition
        case "stillSize":
            if let a = item["currentAspect"].string, let s = item["currentSize"].string { stillSize = StillSize(aspect: a, size: s) }
        case "movieQuality":
            movieQuality = item["currentMovieQuality"].string ?? movieQuality
            let c = item["movieQualityCandidates"].stringArray; if !c.isEmpty { movieQualityCandidates = c }
        case "movieFileFormat":
            movieFileFormat = item["currentMovieFileFormat"].string ?? movieFileFormat
            let c = item["movieFileFormatCandidates"].stringArray; if !c.isEmpty { movieFileFormatCandidates = c }
        case "takePicture":
            lastPictureURLs = item["takePictureUrl"].stringArray
        default:
            break
        }
    }
}
