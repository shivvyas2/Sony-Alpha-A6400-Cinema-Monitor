import Foundation
import CoreGraphics

/// Exposure as it was when the file arrived (within a second or two of the shutter), for the review header.
public struct ExposureSnapshot: Sendable, Equatable {
    public var shutterSpeed: String?
    public var fNumber: String?
    public var iso: String?
    public var ev: String?
    public var focusMode: String?

    public init(state: CameraState) {
        shutterSpeed = state.shutterSpeed; fNumber = state.fNumber; iso = state.iso
        ev = state.exposureCompensation.flatMap { $0.index == 0 ? nil : $0.label }
        focusMode = state.focusMode
    }

    public var summary: String {
        [shutterSpeed, fNumber.map { "F" + $0 }, iso.map { "ISO " + $0 }, ev.map { "EV " + $0 }].compactMap { $0 }.joined(separator: "   ")
    }
}

/// One press of the shutter: up to one JPEG and one RAW.
public struct CapturedShot: Sendable, Equatable, Identifiable {
    public let id: Int
    public var jpeg: CapturedImage?
    public var raw: CapturedImage?
    public var takenAt: Date
    public var exposure: ExposureSnapshot
    /// AF point as fractions (0…1, top-left origin) of the frame; nil = wide area, treated as the centre.
    public var afPoint: CGPoint?
    public var transferring = true
    public var error: String?

    public init(id: Int, takenAt: Date, exposure: ExposureSnapshot, afPoint: CGPoint?) {
        self.id = id; self.takenAt = takenAt; self.exposure = exposure; self.afPoint = afPoint
    }

    public var primary: CapturedImage? { jpeg ?? raw }
    public var hasBoth: Bool { jpeg != nil && raw != nil }
}

/// This session's shots, oldest first. Groups the files of a shot by `shotIndex`.
public struct ShotLog: Sendable, Equatable {
    public private(set) var shots: [CapturedShot] = []
    public init() {}

    public enum Change: Equatable { case newShot(CapturedShot), updated(CapturedShot), none }

    public mutating func apply(_ event: CaptureEvent, exposure: ExposureSnapshot, afPoint: CGPoint?) -> Change {
        switch event {
        case .image(let img):
            if let i = shots.firstIndex(where: { $0.id == img.shotIndex }) {
                if img.kind == .jpeg { shots[i].jpeg = img } else { shots[i].raw = img }
                return .updated(shots[i])
            }
            var s = CapturedShot(id: img.shotIndex, takenAt: img.takenAt, exposure: exposure, afPoint: afPoint)
            if img.kind == .jpeg { s.jpeg = img } else { s.raw = img }
            shots.append(s)
            return .newShot(s)
        case .finished(let idx):
            guard let i = shots.firstIndex(where: { $0.id == idx }) else { return .none }
            shots[i].transferring = false
            return .updated(shots[i])
        case .failed(let idx, let message):
            guard let i = shots.firstIndex(where: { $0.id == idx }) else { return .none }
            shots[i].transferring = false
            shots[i].error = message
            return .updated(shots[i])
        }
    }

    public func shot(_ id: Int) -> CapturedShot? { shots.first { $0.id == id } }

    public func neighbor(of id: Int, offset: Int) -> CapturedShot? {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return nil }
        let j = i + offset
        return shots.indices.contains(j) ? shots[j] : nil
    }
}
