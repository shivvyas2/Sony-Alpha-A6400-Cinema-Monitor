import Foundation

/// Wire format shared by the Mac bridge server and the iOS bridge client.
/// The Mac keeps the camera on USB (or Wi-Fi) and re-serves the camera's own JPEG frames untouched,
/// plus state and controls, over the local network.
public enum Bridge {
    public static let serviceType = "_cinemahud._tcp"
    public static let defaultPort: UInt16 = 8899
    public static let streamBoundary = "cinemahudframe"
}

/// Codable mirror of `CameraState` + the settings menu, sent as JSON.
public struct BridgeState: Codable, Sendable, Equatable {
    public var transport: String            // underlying transport on the Mac: "USB" / "Wi-Fi"
    public var cameraName: String
    public var availableAPIs: [String]
    public var cameraStatus: String
    public var liveviewStatus: Bool
    public var shootMode: String?
    public var shootModeCandidates: [String]
    public var exposureMode: String?
    public var exposureModeCandidates: [String]
    public var shutterSpeed: String?
    public var shutterSpeedCandidates: [String]
    public var fNumber: String?
    public var fNumberCandidates: [String]
    public var iso: String?
    public var isoCandidates: [String]
    public var whiteBalanceMode: String?
    public var colorTemperature: Int?
    public var whiteBalanceCandidates: [String]
    public var evIndex: Int?, evMin: Int?, evMax: Int?, evStep: Int?
    public var focusMode: String?
    public var focusModeCandidates: [String]
    public var focusStatus: String?
    public var touchAFSet: Bool
    public var touchAFX: Double?, touchAFY: Double?
    public var batteryStatus: String?, batteryNumer: Int?, batteryDenom: Int?
    public var storage: [StorageEntry]
    public var recordingTimeSeconds: Int
    public var numberOfShots: Int
    public var focalLengthMM: Double?
    public var ccShift: Int?, abShift: Int?
    public var settings: [SettingEntry]
    public var focusDriveAvailable: Bool
    public var stillAspect: String?, stillSizeName: String?
    public var stillSizeCandidates: [String] = []        // "aspect|size"
    public var movieQuality: String?
    public var movieQualityCandidates: [String] = []
    public var movieFileFormat: String?
    public var movieFileFormatCandidates: [String] = []
    public var zoomPosition: Int?

    public struct StorageEntry: Codable, Sendable, Equatable { public var images: Int?; public var minutes: Int?; public var description: String; public var target: Bool }
    public struct SettingEntry: Codable, Sendable, Equatable { public var id, name, group, current: String; public var candidates: [String]; public var settable: Bool }

    public init(state s: CameraState, settings: [CameraSetting], transport: CameraTransportKind, cameraName: String) {
        self.transport = transport.rawValue; self.cameraName = cameraName
        availableAPIs = Array(s.availableAPIs).sorted()
        cameraStatus = s.cameraStatus; liveviewStatus = s.liveviewStatus
        shootMode = s.shootMode; shootModeCandidates = s.shootModeCandidates
        exposureMode = s.exposureMode; exposureModeCandidates = s.exposureModeCandidates
        shutterSpeed = s.shutterSpeed; shutterSpeedCandidates = s.shutterSpeedCandidates
        fNumber = s.fNumber; fNumberCandidates = s.fNumberCandidates
        iso = s.iso; isoCandidates = s.isoCandidates
        whiteBalanceMode = s.whiteBalanceMode; colorTemperature = s.colorTemperature; whiteBalanceCandidates = s.whiteBalanceCandidates
        evIndex = s.exposureCompensation?.index; evMin = s.exposureCompensation?.minIndex; evMax = s.exposureCompensation?.maxIndex; evStep = s.exposureCompensation?.stepIndex
        focusMode = s.focusMode; focusModeCandidates = s.focusModeCandidates; focusStatus = s.focusStatus
        touchAFSet = s.touchAFSet; touchAFX = s.touchAFPoint?.x; touchAFY = s.touchAFPoint?.y
        batteryStatus = s.battery?.status; batteryNumer = s.battery?.levelNumer; batteryDenom = s.battery?.levelDenom
        storage = s.storage.map { StorageEntry(images: $0.numberOfRecordableImages, minutes: $0.recordableTimeMinutes, description: $0.description, target: $0.recordTarget) }
        recordingTimeSeconds = s.recordingTimeSeconds; numberOfShots = s.numberOfShots
        focalLengthMM = s.focalLengthMM; ccShift = s.ccShift; abShift = s.abShift
        self.settings = settings.map { SettingEntry(id: $0.id, name: $0.name, group: $0.group, current: $0.current, candidates: $0.candidates, settable: $0.settable) }
        focusDriveAvailable = transport == .usb
        stillAspect = s.stillSize?.aspect; stillSizeName = s.stillSize?.size
        stillSizeCandidates = s.stillSizeCandidates.map(\.id)
        movieQuality = s.movieQuality; movieQualityCandidates = s.movieQualityCandidates
        movieFileFormat = s.movieFileFormat; movieFileFormatCandidates = s.movieFileFormatCandidates
        zoomPosition = s.zoomPosition
    }

    public var cameraState: CameraState {
        var s = CameraState()
        s.availableAPIs = Set(availableAPIs)
        s.cameraStatus = cameraStatus; s.liveviewStatus = liveviewStatus
        s.shootMode = shootMode; s.shootModeCandidates = shootModeCandidates
        s.exposureMode = exposureMode; s.exposureModeCandidates = exposureModeCandidates
        s.shutterSpeed = shutterSpeed; s.shutterSpeedCandidates = shutterSpeedCandidates
        s.fNumber = fNumber; s.fNumberCandidates = fNumberCandidates
        s.iso = iso; s.isoCandidates = isoCandidates
        s.whiteBalanceMode = whiteBalanceMode; s.colorTemperature = colorTemperature; s.whiteBalanceCandidates = whiteBalanceCandidates
        if let i = evIndex { s.exposureCompensation = ExposureCompensation(index: i, minIndex: evMin ?? -9, maxIndex: evMax ?? 9, stepIndex: evStep ?? 1) }
        s.focusMode = focusMode; s.focusModeCandidates = focusModeCandidates; s.focusStatus = focusStatus
        s.touchAFSet = touchAFSet
        if let x = touchAFX, let y = touchAFY { s.touchAFPoint = (x, y) }
        if let n = batteryNumer, let d = batteryDenom { s.battery = BatteryInfo(status: batteryStatus ?? "Active", additionalStatus: "", levelNumer: n, levelDenom: d) }
        s.storage = storage.map { StorageInfo(numberOfRecordableImages: $0.images, recordableTimeMinutes: $0.minutes, description: $0.description, recordTarget: $0.target) }
        s.recordingTimeSeconds = recordingTimeSeconds; s.numberOfShots = numberOfShots
        s.focalLengthMM = focalLengthMM; s.ccShift = ccShift; s.abShift = abShift
        if let a = stillAspect, let z = stillSizeName { s.stillSize = StillSize(aspect: a, size: z) }
        s.stillSizeCandidates = stillSizeCandidates.compactMap { id in
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? StillSize(aspect: parts[0], size: parts[1]) : nil
        }
        s.movieQuality = movieQuality; s.movieQualityCandidates = movieQualityCandidates
        s.movieFileFormat = movieFileFormat; s.movieFileFormatCandidates = movieFileFormatCandidates
        s.zoomPosition = zoomPosition
        return s
    }

    public var cameraSettings: [CameraSetting] {
        settings.map { CameraSetting(id: $0.id, name: $0.name, group: $0.group, current: $0.current, candidates: $0.candidates, settable: $0.settable) }
    }
}

/// A control request from the client. `value` / `index` / `x,y` depend on `op`.
public struct BridgeCommand: Codable, Sendable {
    public var op: String
    public var value: String?
    public var value2: String?
    public var index: Int?
    public var x: Double?
    public var y: Double?
    public init(op: String, value: String? = nil, value2: String? = nil, index: Int? = nil, x: Double? = nil, y: Double? = nil) {
        self.op = op; self.value = value; self.value2 = value2; self.index = index; self.x = x; self.y = y
    }
}

public struct BridgeReply: Codable, Sendable { public var ok: Bool; public var error: String?; public init(ok: Bool, error: String? = nil) { self.ok = ok; self.error = error } }

/// Fan-out of values to any number of async consumers (frames, state).
public final class Broadcaster<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]
    public init() {}
    public func stream(buffering: AsyncStream<T>.Continuation.BufferingPolicy = .bufferingNewest(2)) -> AsyncStream<T> {
        AsyncStream(bufferingPolicy: buffering) { cont in
            let id = UUID()
            lock.withLock { continuations[id] = cont }
            cont.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) } }
        }
    }
    public func send(_ v: T) { lock.withLock { continuations.values }.forEach { $0.yield(v) } }
    public var subscriberCount: Int { lock.withLock { continuations.count } }
}
