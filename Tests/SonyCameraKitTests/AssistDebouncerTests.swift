import XCTest
@testable import CinemaUI

final class AssistDebouncerTests: XCTestCase {
    private func f(_ id: String, fact: String = "X") -> Finding { Finding(id: id, kind: .exposure, severity: .info, fact: fact, detail: "") }

    func testFindingMustHoldTwoPassesToShow() {
        var d = AssistDebouncer()
        XCTAssertEqual(d.update(with: [f("a")]).map(\.id), [])
        XCTAssertEqual(d.update(with: [f("a")]).map(\.id), ["a"])
    }
    func testFindingMustBeAbsentTwoPassesToClear() {
        var d = AssistDebouncer()
        _ = d.update(with: [f("a")]); _ = d.update(with: [f("a")])
        XCTAssertEqual(d.update(with: []).map(\.id), ["a"])   // still shown after one miss
        XCTAssertEqual(d.update(with: []).map(\.id), [])
    }
    func testShownFindingUpdatesItsFactWhilePresent() {
        var d = AssistDebouncer()
        _ = d.update(with: [f("a", fact: "ONE")])
        XCTAssertEqual(d.update(with: [f("a", fact: "TWO")]).first?.fact, "TWO")
    }
    func testOrderFollowsCurrentFindingsThenHeldOnes() {
        var d = AssistDebouncer()
        _ = d.update(with: [f("a"), f("b")]); _ = d.update(with: [f("a"), f("b")])
        XCTAssertEqual(d.update(with: [f("b")]).map(\.id), ["b", "a"])
    }
    func testReconcileUsesModelTextForKnownIdsAndFactsOtherwise() {
        let findings = [f("a", fact: "FACT A"), f("b", fact: "FACT B"), f("c", fact: "FACT C")]
        let lines = AdviceLine.reconcile(model: [("b", "face is a stop under, open up"), ("zzz", "ignored")], findings: findings)
        XCTAssertEqual(lines, [AdviceLine(id: "a", text: "FACT A", fromModel: false),
                               AdviceLine(id: "b", text: "FACE IS A STOP UNDER, OPEN UP", fromModel: true)])
    }
    func testReconcileFallsBackToFactForLongOrNumericLinesAndCapsAtTwo() {
        let findings = [f("a", fact: "FACT A"), f("b", fact: "FACT B"), f("c")]
        let long = String(repeating: "x", count: 60)
        let lines = AdviceLine.reconcile(model: [("a", long), ("b", "face reads 12 of 55")], findings: findings)
        XCTAssertEqual(lines, [AdviceLine(id: "a", text: "FACT A", fromModel: false),
                               AdviceLine(id: "b", text: "FACT B", fromModel: false)])
    }
    func testReconcileAcceptsBracketedIdsAndStripsTrailingPeriod() {
        let lines = AdviceLine.reconcile(model: [("[[a]]", "Face buried in shadow.")], findings: [f("a", fact: "FACT A")])
        XCTAssertEqual(lines, [AdviceLine(id: "a", text: "FACE BURIED IN SHADOW", fromModel: true)])
    }
    func testReconcileWithNoModelIsFacts() {
        let lines = AdviceLine.reconcile(model: nil, findings: [f("a", fact: "FACT A")])
        XCTAssertEqual(lines, [AdviceLine(id: "a", text: "FACT A", fromModel: false)])
    }
}
