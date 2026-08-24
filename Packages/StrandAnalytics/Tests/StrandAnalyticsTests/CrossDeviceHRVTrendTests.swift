import XCTest
@testable import StrandAnalytics

/// CrossDeviceHRVTrend — stitch a full HRV history across a device switch (Oura → WHOOP) into one
/// continuous trend: per-era-relative shape (continuous through the switch) + raw values (scale-honest
/// per device) + boundary markers. Scoring stays per-device; this is the display/trend lens.
final class CrossDeviceHRVTrendTests: XCTestCase {

    private func sd(_ day: String, _ src: String, _ hrv: Double) -> (day: String, sourceId: String, hrv: Double) {
        (day: day, sourceId: src, hrv: hrv)
    }

    func testSingleBrandHistoryIsOneEraNoBoundary() {
        let rows = (1...20).map { sd(String(format: "2026-06-%02d", $0), "my-whoop", 90 + Double($0 % 5)) }
        let r = CrossDeviceHRVTrend.build(rows)
        XCTAssertEqual(r.eras.count, 1)
        XCTAssertEqual(r.eras[0].brand, "whoop")
        XCTAssertFalse(r.points.contains { $0.isEraStart }, "a single-brand history has no device-switch boundary")
    }

    func testOuraToWhoopSwitchMarksBoundaryAndNormalisesPerEra() {
        // Oura era ~131 ms, then a WHOOP era ~91 ms — incompatible scales, no overlap.
        var rows: [(day: String, sourceId: String, hrv: Double)] = []
        for i in 1...15 { rows.append(sd(String(format: "2026-05-%02d", i), "oura-api", 130 + Double(i % 4))) }
        for i in 1...15 { rows.append(sd(String(format: "2026-06-%02d", i), "my-whoop-noop", 90 + Double(i % 4))) }
        let r = CrossDeviceHRVTrend.build(rows)
        XCTAssertEqual(r.eras.map { $0.brand }, ["oura", "whoop"])
        XCTAssertEqual(r.eras[0].nights, 15)
        XCTAssertEqual(r.eras[1].nights, 15)
        // Exactly one boundary, on the first WHOOP night — never on the very first night of history.
        let starts = r.points.filter { $0.isEraStart }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.brand, "whoop")
        XCTAssertEqual(starts.first?.day, "2026-06-01")
        // Per-era normalisation: a typical WHOOP night reads ~0% vs its OWN era, NOT "~31% below" the Oura scale.
        let whoopMid = r.points.first { $0.day == "2026-06-08" }!
        XCTAssertLessThan(abs(whoopMid.eraRelativePct), 5)
        XCTAssertEqual(r.eras[0].centerMs, 131, accuracy: 3)
        XCTAssertEqual(r.eras[1].centerMs, 91, accuracy: 3)
    }

    func testEraRelativeShapeIsContinuousAcrossTheSwitch() {
        // A declining Oura era continues declining on WHOOP: the era-relative series keeps falling across
        // the boundary (continuous shape) though the raw scale steps down.
        var rows: [(day: String, sourceId: String, hrv: Double)] = []
        for i in 1...20 { rows.append(sd(String(format: "2026-05-%02d", i), "oura-api", 150 - Double(i))) }
        for i in 1...20 { rows.append(sd(String(format: "2026-06-%02d", i), "my-whoop", 100 - Double(i))) }
        let r = CrossDeviceHRVTrend.build(rows)
        XCTAssertLessThan(r.points.last { $0.brand == "oura" }!.eraRelativePct, 0)
        XCTAssertLessThan(r.points.last!.eraRelativePct, 0, "the decline continues into the WHOOP era")
        XCTAssertGreaterThan(r.eras[0].centerMs, r.eras[1].centerMs, "raw scale steps down at the switch")
    }

    func testEmptyInput() {
        XCTAssertTrue(CrossDeviceHRVTrend.build([]).points.isEmpty)
    }
}
