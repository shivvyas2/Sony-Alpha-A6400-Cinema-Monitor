#if os(macOS)
import AVFoundation
import Foundation
import Observation
import CinemaAudio
import SonyCameraKit

/// Owns the field-audio pieces for the Mac app: the armed input, the take recorder, the Logic
/// transport, and the user's choices. The view feeds it `RecordingEvent`s; it never calls the camera.
@Observable
@MainActor
public final class AudioSessionController {
    public enum Permission: Equatable { case unknown, granted, denied }
    public static let confirmTimeout: TimeInterval = 5

    public private(set) var permission: Permission = .unknown
    public private(set) var devices: [AudioDevice] = []
    public private(set) var selectedDeviceUID: String?
    public private(set) var selectedChannels: [Int] = [1, 2]
    public var sendTimecode = false { didSet { defaults.set(sendTimecode, forKey: Keys.mtc); updateTransport() } }
    public var scene = "" { didSet { defaults.set(scene, forKey: Keys.scene) } }
    public var note = ""
    public var projectFPS = 24 { didSet { if projectFPS != oldValue { updateTransport() } } }
    public private(set) var isArmed = false
    public private(set) var armError: String?
    public private(set) var interruption: String?
    public private(set) var currentTake: TakeRecord?
    public private(set) var takes: [TakeRecord] = []
    public private(set) var transportRunning = false
    public let dayFolder: URL
    public var meters: MeterState { input.meters }
    public var selectedDevice: AudioDevice? { selectedDeviceUID.flatMap { uid in devices.first { $0.uid == uid } } }
    public var mtcRate: MTCRate { MTCRate(projectFPS: projectFPS) }

    @ObservationIgnored private let input = AudioInput(prerollSeconds: TakeRecorder.prerollSeconds)
    @ObservationIgnored private var recorder: TakeRecorder
    @ObservationIgnored private var transport: LogicTransport?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var confirmTimer: Task<Void, Never>?
    @ObservationIgnored private var deviceWatch: Task<Void, Never>?
    private enum Keys { static let device = "audio.deviceUID", channels = "audio.channels", mtc = "audio.mtc", scene = "audio.scene" }

    public init(base: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dayFolder = DayFolder.url(for: Date(), base: base)
        recorder = TakeRecorder(input: input, dayFolder: dayFolder)
        selectedDeviceUID = defaults.string(forKey: Keys.device)
        if let ch = defaults.array(forKey: Keys.channels) as? [Int], !ch.isEmpty { selectedChannels = ch }
        sendTimecode = defaults.bool(forKey: Keys.mtc)
        scene = defaults.string(forKey: Keys.scene) ?? ""
        takes = recorder.log.takes
        recorder.onChange = { [weak self] r in
            guard let self else { return }
            self.currentTake = self.recorder.current
            self.takes = self.recorder.log.takes
            if case .writeFailed(let m) = r.outcome { self.interruption = "Write failed: \(m)" }
        }
        input.onInterruption = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in self.interrupted(reason) }
        }
        refreshDevices()
        deviceWatch = Task { [weak self] in
            for await _ in AudioDevices.changes() {
                guard let self else { return }
                await MainActor.run { self.refreshDevices(); self.reArmIfDeviceReturned() }
            }
        }
    }

    // MARK: Devices and arming

    public func refreshDevices() { devices = AudioDevices.inputs() }

    /// Picks (and persists) a device and channels, asks for microphone permission once, and arms.
    public func arm(deviceUID: String?, channels: [Int]) async {
        selectedDeviceUID = deviceUID
        defaults.set(deviceUID, forKey: Keys.device)
        selectedChannels = channels
        defaults.set(channels, forKey: Keys.channels)
        armError = nil; interruption = nil
        guard let uid = deviceUID else { disarm(); return }
        refreshDevices()
        guard let device = devices.first(where: { $0.uid == uid }) else { armError = "Device not connected"; disarm(); return }
        if permission != .granted {
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            permission = ok ? .granted : .denied
            guard ok else { armError = "Microphone access denied"; return }
        }
        do {
            try input.arm(device: device, channels: channels)
            isArmed = true
            updateTransport()
        } catch {
            armError = error.localizedDescription
            isArmed = false
        }
    }

    public func setChannels(_ channels: [Int]) async { await arm(deviceUID: selectedDeviceUID, channels: channels) }

    public func disarm() {
        if recorder.isRecording { recorder.abort(reason: .interrupted("disarmed")) }
        input.disarm()
        isArmed = false
        updateTransport()
    }

    private func interrupted(_ reason: AudioInputInterruption) {
        isArmed = false
        switch reason {
        case .deviceRemoved: interruption = "Audio device removed"
        case .configurationChanged: interruption = "Audio configuration changed"
        case .engineStopped(let m): interruption = m
        }
        if recorder.isRecording { recorder.abort(reason: .interrupted(interruption ?? "interrupted")) }
        updateTransport()
    }

    private func reArmIfDeviceReturned() {
        guard !isArmed, interruption == "Audio device removed", let uid = selectedDeviceUID, devices.contains(where: { $0.uid == uid }) else { return }
        Task { await arm(deviceUID: uid, channels: selectedChannels) }
    }

    // MARK: Logic transport

    private func updateTransport() {
        if sendTimecode && isArmed {
            if transport == nil { transport = try? LogicTransport() }
            transport?.startTimecode(rate: mtcRate, clock: { Date() })
            transportRunning = transport?.isRunning ?? false
        } else {
            transport?.stopTimecode()
            transportRunning = false
        }
    }

    // MARK: Recording events

    public func handle(_ event: RecordingEvent, label: TakeLabel, metadata: TakeMetadata) {
        guard isArmed else { return }
        switch event {
        case .pressed(let t):
            guard !recorder.isRecording else { return }
            begin(label: label, metadata: metadata, pressedAt: t)
        case .started(let t):
            if !recorder.isRecording { begin(label: label, metadata: metadata, pressedAt: t) }   // started on the body
            recorder.cameraStarted(at: t)
            confirmTimer?.cancel(); confirmTimer = nil
            meters.resetClip()
        case .stopped(let t):
            guard recorder.isRecording else { return }
            recorder.cameraStopped(at: t)
            transport?.stop()
        }
    }

    private func begin(label: TakeLabel, metadata: TakeMetadata, pressedAt: Date) {
        do {
            try recorder.begin(label: label, metadata: metadata, pressedAt: pressedAt)
            interruption = nil
            transport?.recordStrobe()
            confirmTimer?.cancel()
            confirmTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.confirmTimeout))
                guard !Task.isCancelled, let self, self.recorder.isRecording, self.recorder.current?.confirmedStart == nil else { return }
                self.recorder.abort(reason: .cameraNeverStarted)
                self.interruption = "Camera never started; take discarded"
                self.transport?.stop()
            }
        } catch {
            interruption = error.localizedDescription
        }
    }

    public func resetClip() { meters.resetClip() }

    // MARK: Pure helpers

    /// The HUD's clip label: the next take on a press, the current take once the body confirms.
    nonisolated public static func label(for event: RecordingEvent, takes: Int, cameraIndex: String, reel: Int) -> TakeLabel {
        let clip: Int
        switch event { case .pressed: clip = takes + 1; case .started, .stopped: clip = takes }
        return TakeLabel(cameraIndex: cameraIndex, reel: reel, clip: max(1, clip))
    }

    nonisolated public static func metadata(state: CameraState, projectFPS: Int, scene: String, note: String) -> TakeMetadata {
        var cam: [String: String] = [:]
        cam["shutter"] = state.shutterSpeed; cam["iris"] = state.fNumber; cam["iso"] = state.iso
        cam["focus"] = state.focusMode; cam["mode"] = state.exposureMode; cam["wb"] = state.whiteBalanceMode
        return TakeMetadata(project: "CinemaHUD", projectFPS: projectFPS, scene: scene.isEmpty ? nil : scene, note: note.isEmpty ? nil : note, camera: cam)
    }
}
#endif
