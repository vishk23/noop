// Tests the CLOUD_SYNC-gated cloud sync reentrancy gate; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
@testable import Strand

/// Regression cover for the gate leak that silently stopped a real device from syncing for 10 days.
/// `runGatedSync` claimed `CloudSyncGate` and released it on the line AFTER the sync, which only holds
/// if the sync RETURNS — so a sync that never returned (a request with no effective deadline, or a task
/// iOS suspended mid-flight and never resumed) left the gate held for the life of the process. Every
/// entry point — manual "Sync now", the on-launch catch-up, `BGAppRefreshTask`, the silent-push handler
/// — funnels through that one function, so all of them then bailed instantly with "Sync already in
/// progress" and the only escape was the UI's Override button.
///
/// Two properties are pinned here, because it takes both to be safe: `withGate` releases on every path
/// that UNWINDS (return, throw, cancellation), and `staleHoldS` reclaims a hold that never unwinds at
/// all — the second is what un-wedges an install that is already stuck.
///
/// Every test builds its OWN `CloudSyncGate()` rather than touching `CloudSyncGate.shared`: the shared
/// instance is process-wide state, and `StrandTests` runs inside the full app via `TEST_HOST`, so the
/// host app could plausibly be sitting in it.
final class CloudSyncGateTests: XCTestCase {
    /// Fixed clock for the staleness tests — `begin(now:)` takes the instant as a parameter precisely
    /// so the bound is testable without sleeping through two real hours.
    private let t0 = Date(timeIntervalSince1970: 1_752_300_000)

    private struct SyncFailed: Error {}

    // MARK: - Normal operation

    func testWithGateRunsTheBodyAndReleasesOnNormalReturn() async {
        let gate = CloudSyncGate()

        let result = await gate.withGate { _ -> String in "synced" }

        XCTAssertEqual(result, "synced")
        XCTAssertNil(gate.currentHoldStart, "the gate must be free once the sync returns")
    }

    /// The behaviour the gate exists for: a second sync starting while a fresh one is genuinely running
    /// stands down instead of running a concurrent upload against the same store and server.
    func testSecondClaimIsDeniedWhileAFreshSyncHoldsTheGate() {
        let gate = CloudSyncGate()
        XCTAssertTrue(gate.begin(now: t0).granted)

        let second = gate.begin(now: t0.addingTimeInterval(30))

        XCTAssertFalse(second.granted)
        XCTAssertFalse(second.reclaimed)
        XCTAssertEqual(second.previousHoldS ?? -1, 30, accuracy: 0.001,
                       "a denial should still report how long the incumbent has held the gate")
    }

    func testWithGateSkipsTheBodyEntirelyWhenDenied() async {
        let gate = CloudSyncGate()
        XCTAssertTrue(gate.begin(now: t0).granted)
        var bodyRuns = 0

        let result = await gate.withGate(now: t0.addingTimeInterval(60)) { _ -> String in
            bodyRuns += 1
            return "should not happen"
        }

        XCTAssertNil(result, "a denied claim returns nil rather than a result")
        XCTAssertEqual(bodyRuns, 0, "the gated work must not run at all when the gate is held")
    }

    // MARK: - Release on every unwinding path (the leak itself)

    /// THE regression test. Before the fix the release was a trailing statement, so anything that
    /// stopped control reaching it stranded the gate.
    func testGateIsReleasedWhenTheGatedWorkThrows() async {
        let gate = CloudSyncGate()

        do {
            try await gate.withGate { _ -> Void in throw SyncFailed() }
            XCTFail("expected the body's error to propagate out of withGate")
        } catch is SyncFailed {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertNil(gate.currentHoldStart, "a failed sync must not leave the gate held")
    }

    /// The user-visible consequence, stated directly: one failed sync must not cost you every sync
    /// after it. This is what was broken on the device — a sync stopped, and nothing synced again.
    func testASecondSyncProceedsAfterTheFirstOneFailed() async {
        let gate = CloudSyncGate()
        var attempts = 0

        do {
            try await gate.withGate { _ -> Void in
                attempts += 1
                throw SyncFailed()
            }
        } catch {
            // the first sync fails, as it did on the wedged device
        }

        let second = await gate.withGate { _ -> String in
            attempts += 1
            return "ok"
        }

        XCTAssertEqual(second, "ok", "the sync after a failure must actually run, not be gated out")
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(gate.currentHoldStart)
    }

    /// Cancellation is the path `CloudSyncBackgroundRefresh`'s `expirationHandler` takes when iOS cuts a
    /// background refresh short — a routine, every-few-hours event, not an exotic one.
    func testGateIsReleasedWhenTheGatedTaskIsCancelled() async {
        let gate = CloudSyncGate()
        let entered = expectation(description: "gated work started")

        let work = Task {
            await gate.withGate { _ -> Void in
                entered.fulfill()
                try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertNotNil(gate.currentHoldStart, "the gate should be held while the sync is running")

        work.cancel()
        _ = await work.value

        XCTAssertNil(gate.currentHoldStart, "a cancelled sync must not leave the gate held")
    }

    // MARK: - Self-heal: reclaiming a hold that never unwinds

    /// The half that rescues an ALREADY-wedged install. `defer` cannot help a task that is never
    /// resumed — no code of ours runs again in that task, ever — so the gate has to be able to time the
    /// hold out on its own.
    func testAbandonedHoldIsReclaimedOnceItGoesStale() {
        let gate = CloudSyncGate()
        // Taken and never given back: the exact in-memory state the wedged phone was found in. No
        // `end()` call follows this line anywhere in the test.
        XCTAssertTrue(gate.begin(now: t0).granted)

        let rescue = gate.begin(now: t0.addingTimeInterval(CloudSyncGate.staleHoldS))

        XCTAssertTrue(rescue.granted, "a hold older than the bound must not block syncing forever")
        XCTAssertTrue(rescue.reclaimed)
    }

    /// The mirror image, so the escape hatch can't quietly widen into "no gate at all": a hold that is
    /// merely long — a real 300MB upload on a slow link — still keeps other syncs out.
    func testHoldShorterThanTheStaleBoundIsStillDenied() {
        let gate = CloudSyncGate()
        XCTAssertTrue(gate.begin(now: t0).granted)

        let tooEarly = gate.begin(now: t0.addingTimeInterval(CloudSyncGate.staleHoldS - 1))

        XCTAssertFalse(tooEarly.granted)
        XCTAssertFalse(tooEarly.reclaimed)
    }

    func testReclaimReportsHowLongTheAbandonedHoldLasted() {
        let gate = CloudSyncGate()
        XCTAssertTrue(gate.begin(now: t0).granted)

        let rescue = gate.begin(now: t0.addingTimeInterval(10 * 3600))

        // The duration is what the `cloudsync.gateReclaimed` breadcrumb records, so a reclaim leaves
        // evidence of the bug behind instead of silently papering over it.
        XCTAssertEqual(rescue.previousHoldS ?? -1, 10 * 3600, accuracy: 0.001)
    }

    /// A stale-reclaimed sync can come back from the dead — a suspended URLSession continuation that
    /// finally resumes hours later — and its release must not free the gate the rescuing sync now owns.
    /// Without the ticket check this fix would trade a permanent wedge for an intermittent double-sync.
    func testResurrectedHolderCannotReleaseTheGateItAlreadyLost() {
        let gate = CloudSyncGate()
        guard let abandoned = gate.begin(now: t0).ticket else {
            return XCTFail("the first claim on a free gate should be granted")
        }
        let rescue = gate.begin(now: t0.addingTimeInterval(3 * 3600))
        XCTAssertTrue(rescue.reclaimed)

        gate.end(abandoned)

        XCTAssertNotNil(gate.currentHoldStart,
                        "a superseded holder must not release the gate the current holder owns")

        // …and the rescuer's own ticket still works.
        gate.end(rescue.ticket ?? 0)
        XCTAssertNil(gate.currentHoldStart)
    }

    func testEndIgnoresUnknownTicketsAndIsIdempotent() {
        let gate = CloudSyncGate()
        guard let ticket = gate.begin(now: t0).ticket else {
            return XCTFail("the first claim on a free gate should be granted")
        }

        gate.end(ticket &+ 999)
        XCTAssertNotNil(gate.currentHoldStart, "an unknown ticket must not release the gate")

        gate.end(ticket)
        XCTAssertNil(gate.currentHoldStart)
        gate.end(ticket)   // second release: a no-op, not a crash or a state flip
        XCTAssertNil(gate.currentHoldStart)
    }

    // MARK: - The two bounds have to stay in the right order

    /// `staleHoldS` must sit ABOVE the longest a single request can legitimately take, or the gate would
    /// start stealing itself from syncs that are still alive and making progress.
    func testStaleBoundSitsAboveTheLongestSingleRequest() {
        let resourceTimeout = CloudSyncClient.syncSession.configuration.timeoutIntervalForResource

        XCTAssertGreaterThan(CloudSyncGate.staleHoldS, resourceTimeout,
                             "a live-but-slow request must always finish before its gate can be reclaimed")
        XCTAssertLessThan(resourceTimeout, 7 * 24 * 3600,
                          "the point of a private session is escaping URLSession.shared's 7-day resource timeout")
        XCTAssertEqual(CloudSyncClient.syncSession.configuration.timeoutIntervalForRequest, 60,
                       "the inactivity deadline is what actually catches a hung connection")
    }
}
#endif // CLOUD_SYNC
