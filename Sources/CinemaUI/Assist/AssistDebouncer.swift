import Foundation

/// A finding shows after `required` consecutive passes and clears after `required` consecutive
/// absences, so the strip does not flicker with the analyzer.
public struct AssistDebouncer: Sendable {
    public var required = 2
    private var present: [String: Int] = [:]
    private var absent: [String: Int] = [:]
    private var held: [String: Finding] = [:]
    private var order: [String] = []
    public init(required: Int = 2) { self.required = required }

    public mutating func update(with findings: [Finding]) -> [Finding] {
        let ids = Set(findings.map(\.id))
        for f in findings {
            present[f.id, default: 0] += 1
            absent[f.id] = 0
            held[f.id] = f
        }
        for id in held.keys where !ids.contains(id) {
            absent[id, default: 0] += 1
            present[id] = 0
            if absent[id]! >= required { held[id] = nil; present[id] = nil; absent[id] = nil }
        }
        // Current findings first, in rule order; then held-over ones in the order they were last seen.
        var result: [Finding] = []
        var seen = Set<String>()
        for f in findings where present[f.id, default: 0] >= required { result.append(f); seen.insert(f.id) }
        for id in order where !seen.contains(id) && !ids.contains(id) { if let f = held[id] { result.append(f); seen.insert(id) } }
        order = result.map(\.id)
        return result
    }
}

public extension AdviceLine {
    static let maxLength = 40

    /// Lines for the first two findings: the model's text where it explained that finding and the
    /// text is usable, else the fact. A model line is usable when it is short enough for the strip
    /// and contains no digits (digits mean it copied a measurement instead of phrasing it).
    static func reconcile(model: [(finding: String, text: String)]?, findings: [Finding]) -> [AdviceLine] {
        var byID: [String: String] = [:]
        for l in model ?? [] {
            let id = l.finding.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
            if byID[id] == nil { byID[id] = l.text }
        }
        return findings.prefix(2).map { f in
            if let raw = byID[f.id] {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
                if !t.isEmpty, t.count <= maxLength, t.rangeOfCharacter(from: .decimalDigits) == nil {
                    return AdviceLine(id: f.id, text: t.uppercased(), fromModel: true)
                }
            }
            return AdviceLine(id: f.id, text: f.fact, fromModel: false)
        }
    }
}
