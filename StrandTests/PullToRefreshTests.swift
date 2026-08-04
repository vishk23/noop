import XCTest
@testable import Strand

/// Unit tests for `PullToRefresh.run`, the shared composition behind every ScreenScaffold pull gesture
/// (the #334 Liquid-Today idiom generalised): a pull must first KICK the gated manual strap offload,
/// then run the screen's local re-read — never the local re-read alone, which silently succeeded at a
/// no-op and made stale data look freshly fetched. Mirrors the Android Today pull-to-sync contract
/// (`todayPullToSyncEnabled` + `viewModel.syncNow()` in TodayScreen.kt).
final class PullToRefreshTests: XCTestCase {

    /// The acquire path: with a sync kick injected, a pull fires the strap-offload kick BEFORE the
    /// local re-read, so the gesture actually requests fresh data rather than redrawing the old rows.
    func testKicksStrapSyncThenRunsLocalRefresh() async {
        var order: [String] = []
        await PullToRefresh.run(strapSyncKick: { order.append("kick") },
                                refresh: { order.append("refresh") })
        XCTAssertEqual(order, ["kick", "refresh"])
    }

    /// The no-strap-context path (previews, hosts that never injected a kick): the local re-read still
    /// runs — the gesture keeps its redraw value and adds no fake work.
    func testNilKickStillRunsLocalRefresh() async {
        var refreshed = false
        await PullToRefresh.run(strapSyncKick: nil, refresh: { refreshed = true })
        XCTAssertTrue(refreshed)
    }
}
