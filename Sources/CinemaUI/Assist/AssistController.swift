import Foundation
import CoreGraphics
import SonyCameraKit

/// Owns the assist pipeline for one monitor: debounces findings, asks the on-device model to phrase
/// them when it is available, exposes the lines and the pending focus point, and applies fixes.
@MainActor @Observable
public final class AssistController {
    public private(set) var lines: [AdviceLine] = []
    public private(set) var pendingAF: CGPoint?            // display coordinates, top-left origin
    public private(set) var applied: String?               // finding id shown as APPLIED for a moment
    public let availability: ShotAdvisorAvailability
    private let useModel: Bool
    private var debouncer = AssistDebouncer()
    private var findings: [Finding] = []
    private var lastSignature = ""
    private var lastModelCall = Date.distantPast
    private var generation = 0
    private var lastNonEmpty = Date.distantPast
    private var lookFirstShown: [String: Date] = [:]
    private var lookDone: Set<String> = []
    /// A look suggestion stays this long, then leaves for the session unless the operator applies it.
    public static let lookDwell: TimeInterval = 20
    public static let fadeAfter: TimeInterval = 6
    public static let modelInterval: TimeInterval = 1.5

    public init(useModel: Bool = true) {
        availability = ShotAdvisorAvailability.current
        self.useModel = useModel && availability == .available
        #if canImport(FoundationModels)
        if self.useModel, #available(macOS 26, iOS 26, *) { ShotAdvisor.prewarm() }
        #endif
    }

    /// True while there are lines, and for `fadeAfter` seconds after the last one cleared.
    public var visible: Bool { !lines.isEmpty || Date().timeIntervalSince(lastNonEmpty) < Self.fadeAfter }

    public func fix(for id: String) -> Fix? { findings.first { $0.id == id }?.fix }

    public func ingest(measurements m: SceneMeasurements, state: CameraState, profile: PictureProfile, projectFPS: Int, shootingMode: ShootingMode, mist: Double = 0) {
        let raw = AssistRules.findings(m, state: state, profile: profile, projectFPS: projectFPS, shootingMode: shootingMode, mist: mist)
            .filter { $0.kind != .look || !lookDone.contains($0.id) }
        findings = debouncer.update(with: raw)
        for f in findings where f.kind == .look {
            let first = lookFirstShown[f.id] ?? Date()
            lookFirstShown[f.id] = first
            if Date().timeIntervalSince(first) > Self.lookDwell { lookDone.insert(f.id) }
        }
        if case .touchAF(let x, let y)? = findings.first(where: { $0.id == "focus-missed" })?.fix?.command {
            pendingAF = CGPoint(x: x, y: y)
        } else { pendingAF = nil }
        let signature = findings.map { "\($0.id):\($0.fact)" }.joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        if ProcessInfo.processInfo.environment["CINEMAHUD_TRACE"] == "1" {
            NSLog("assist: faces=%d mean=%.0f white=%.3f black=%.3f af=%.2f raw=[%@] shown=[%@]", m.faces.count, m.meanLuma, m.whiteClip, m.blackClip,
                  m.afSharpness, raw.map(\.id).joined(separator: ","), signature)
        }
        lines = AdviceLine.reconcile(model: nil, findings: findings)
        if !lines.isEmpty { lastNonEmpty = Date() }
        guard useModel, !findings.isEmpty, Date().timeIntervalSince(lastModelCall) >= Self.modelInterval else { return }
        lastModelCall = Date()
        generation += 1
        let gen = generation
        let prompt = AdvisorPrompt.build(findings: findings, measurements: m, state: state, profile: profile, projectFPS: projectFPS)
        let snapshot = findings
        Task { [weak self] in
            #if canImport(FoundationModels)
            guard #available(macOS 26, iOS 26, *) else { return }
            let result = await ShotAdvisor.advise(prompt: prompt)
            guard let self, self.generation == gen, let result else { return }
            self.lines = AdviceLine.reconcile(model: result, findings: snapshot)
            #endif
        }
    }

    /// Runs the finding's fix through the session and shows APPLIED briefly. `rotation` is the
    /// display rotation, so a focus point measured on the rotated picture reaches the camera in
    /// sensor coordinates, the same way a tap on the picture does.
    public func apply(_ id: String, session: CameraSession, rotation: Int = 0, monitor: OverlaySettings? = nil) {
        guard let fix = fix(for: id) else { return }
        if findings.first(where: { $0.id == id })?.kind == .look { lookDone.insert(id) }
        Task {
            switch fix.command {
            case .setISO(let v): await session.setISO(v)
            case .setExposureCompensation(let i): await session.setExposureCompensation(index: i)
            case .setShutterSpeed(let v): await session.setShutterSpeed(v)
            case .touchAF(let x, let y):
                let p = Self.sensorPoint(CGPoint(x: x, y: y), rotation: rotation)
                await session.touchAF(x: p.x, y: p.y); pendingAF = nil
            case .autofocus: await session.autofocus()
            case .setFNumber(let v): await session.setFNumber(v)
            case .monitorMist(let level): monitor?.mist = level
            }
            applied = id
            try? await Task.sleep(for: .seconds(1.5))
            if applied == id { applied = nil }
        }
    }

    /// Display-space point (after `rotation`) → sensor space, mirroring MonitorView's tap handling.
    public static func sensorPoint(_ p: CGPoint, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: return CGPoint(x: p.y, y: 1 - p.x)
        case 270: return CGPoint(x: 1 - p.y, y: p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        default: return p
        }
    }
    /// Sensor-space point → display space (after `rotation`).
    public static func displayPoint(_ p: CGPoint, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case 270: return CGPoint(x: p.y, y: 1 - p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        default: return p
        }
    }
}
