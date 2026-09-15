#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26, iOS 26, *)
@Generable
struct AssistAdviceLine {
    @Guide(description: "The id of the finding this line explains, exactly as given in brackets")
    var finding: String
    @Guide(description: "At most eight words, the clipped voice of a camera assistant")
    var text: String
}

@available(macOS 26, iOS 26, *)
@Generable
struct AssistAdvice {
    @Guide(description: "At most two lines, most important first", .maximumCount(2))
    var lines: [AssistAdviceLine]
}

/// Phrases findings with Apple's on-device model. One fresh session per call keeps the small
/// context from filling; every failure returns nil and the HUD falls back to the findings' facts.
@available(macOS 26, iOS 26, *)
public enum ShotAdvisor {
    static var availability: ShotAdvisorAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .deviceNotEligible
        }
    }

    public static func prewarm() {
        guard availability == .available else { return }
        LanguageModelSession(instructions: AdvisorPrompt.instructions).prewarm()
    }

    /// nil when unavailable, on any error, or after `timeout` seconds.
    public static func advise(prompt: String, timeout: TimeInterval = 2) async -> [(finding: String, text: String)]? {
        guard availability == .available else { return nil }
        let session = LanguageModelSession(instructions: AdvisorPrompt.instructions)
        return await withTaskGroup(of: [(finding: String, text: String)]?.self) { group in
            group.addTask {
                do {
                    let r = try await session.respond(to: prompt, generating: AssistAdvice.self)
                    return r.content.lines.map { (finding: $0.finding, text: $0.text) }
                } catch { return nil }
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
#endif
