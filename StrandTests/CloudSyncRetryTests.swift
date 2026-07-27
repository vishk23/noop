// Tests the CLOUD_SYNC-gated retry/backoff policy; compiled only when the flag is set (StrandTests
// shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
@testable import Strand

/// Pure tests for `CloudSyncRetryPolicy`'s schedule and `withCloudSyncRetry`'s decisions. Both the
/// clock and the random draw are injected, so nothing here sleeps and nothing here is flaky — the same
/// reason `CloudSyncGate.begin(now:)` takes its instant as a parameter rather than reading `Date()`.
final class CloudSyncRetryPolicyTests: XCTestCase {

    // MARK: - The schedule

    func testFirstAttemptNeverWaits() {
        XCTAssertEqual(CloudSyncRetryPolicy.standard.delayS(beforeAttempt: 1, jitterUnit: 0.5), 0)
    }

    /// Exponential, not linear: each retry waits `multiplier`x the last. Checked at the midpoint of the
    /// jitter band (`jitterUnit: 0.5`), where the scale factor is exactly 1 and the nominal value shows
    /// through.
    func testDelayGrowsExponentiallyFromTheBase() {
        let p = CloudSyncRetryPolicy.standard
        XCTAssertEqual(p.delayS(beforeAttempt: 2, jitterUnit: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(p.delayS(beforeAttempt: 3, jitterUnit: 0.5), 3, accuracy: 0.0001)
        XCTAssertEqual(p.delayS(beforeAttempt: 4, jitterUnit: 0.5), 9, accuracy: 0.0001)
    }

    func testDelayIsCappedByMaxDelay() {
        let p = CloudSyncRetryPolicy.standard
        XCTAssertEqual(p.delayS(beforeAttempt: 12, jitterUnit: 0.5), p.maxDelayS, accuracy: 0.0001)
    }

    /// The jitter band exists so that every phone a server outage knocked offline does not come back on
    /// the same schedule the moment it recovers. Its width is `jitterFraction` either side of nominal.
    func testJitterSpreadsTheDelayAcrossItsBandAndNeverGoesNegative() {
        let p = CloudSyncRetryPolicy.standard
        XCTAssertEqual(p.delayS(beforeAttempt: 2, jitterUnit: 0), 0.75, accuracy: 0.0001)
        XCTAssertEqual(p.delayS(beforeAttempt: 2, jitterUnit: 1), 1.25, accuracy: 0.0001)
        // An out-of-range draw is clamped rather than producing a negative sleep.
        XCTAssertEqual(p.delayS(beforeAttempt: 2, jitterUnit: -5), 0.75, accuracy: 0.0001)
        XCTAssertEqual(p.delayS(beforeAttempt: 2, jitterUnit: 99), 1.25, accuracy: 0.0001)
    }

    /// The budget is deliberately small because the target cadence is a sync on every phone unlock: the
    /// cost of giving up is one more unlock, not one more day. If a change ever makes a failing sync
    /// sit for a minute, this test is the one that should stop it.
    func testTheWholeStandardLadderIsOverInSecondsNotMinutes() {
        let p = CloudSyncRetryPolicy.standard
        let worstCase = (2...p.maxAttempts).reduce(0.0) { $0 + p.delayS(beforeAttempt: $1, jitterUnit: 1) }
        XCTAssertLessThan(worstCase, 6)
    }

    /// The whole-database POST gets ONE retry, not two — resending 100-300MB costs the user more than
    /// the wait it saves.
    func testBulkUploadAllowsExactlyOneRetry() {
        XCTAssertEqual(CloudSyncRetryPolicy.bulkUpload.maxAttempts, 2)
        XCTAssertLessThan(CloudSyncRetryPolicy.bulkUpload.maxAttempts, CloudSyncRetryPolicy.standard.maxAttempts)
    }
}

final class WithCloudSyncRetryTests: XCTestCase {

    /// Records the delays asked for, so a test can assert on the schedule without living through it.
    private final class SleepSpy {
        var delays: [Double] = []
        func sleep(_ s: Double) async throws { delays.append(s) }
    }

    func testSucceedsWithoutRetryingWhenTheBodySucceeds() async throws {
        let spy = SleepSpy()
        var calls = 0
        let value = try await withCloudSyncRetry(.standard, sleep: spy.sleep, jitter: { 0.5 }) {
            calls += 1
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(spy.delays.isEmpty)
    }

    func testRetriesARetryableErrorUntilItSucceeds() async throws {
        let spy = SleepSpy()
        var calls = 0
        let value = try await withCloudSyncRetry(.standard, sleep: spy.sleep, jitter: { 0.5 }) {
            calls += 1
            if calls < 3 { throw CloudSyncError.serverFault(status: 500, code: "x", detail: "") }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(spy.delays, [1, 3])
    }

    /// 507 is the case the old flat error got backwards. It is a failure of the SERVER's storage, not of
    /// the phone's backup, so it must be retried — pinned here because "insufficient space sounds like a
    /// client problem" is exactly the intuition that produced the bug.
    func testOutOfSpaceIsRetried() async throws {
        let spy = SleepSpy()
        var calls = 0
        _ = try? await withCloudSyncRetry(.standard, sleep: spy.sleep, jitter: { 0.5 }) {
            calls += 1
            throw CloudSyncError.serverOutOfSpace(code: "insufficient_space", detail: "")
        }
        XCTAssertEqual(calls, CloudSyncRetryPolicy.standard.maxAttempts)
    }

    func testTerminalErrorsAreThrownOnTheFirstAttempt() async {
        for terminal: CloudSyncError in [
            .unauthorized(status: 401, detail: ""),
            .rejected(status: 400, code: "corrupt_sqlite", detail: ""),
            .featureNotConfigured(feature: "deepbuf", detail: ""),
            .cancelled,
            .decode,
        ] {
            let spy = SleepSpy()
            var calls = 0
            do {
                _ = try await withCloudSyncRetry(.standard, sleep: spy.sleep, jitter: { 0.5 }) {
                    calls += 1
                    throw terminal
                }
                XCTFail("expected \(terminal) to be rethrown")
            } catch {
                XCTAssertEqual(error as? CloudSyncError, terminal)
            }
            XCTAssertEqual(calls, 1, "\(terminal) must not be retried")
            XCTAssertTrue(spy.delays.isEmpty, "\(terminal) must not wait")
        }
    }

    /// Anything that isn't a `CloudSyncError` is not this engine's business and propagates untouched —
    /// it has no retryability to consult, and guessing would be worse than not trying.
    func testNonCloudSyncErrorsPropagateImmediately() async {
        struct Other: Error {}
        var calls = 0
        do {
            _ = try await withCloudSyncRetry(.standard, sleep: { _ in }, jitter: { 0.5 }) {
                calls += 1
                throw Other()
            }
            XCTFail("expected the error to propagate")
        } catch {
            XCTAssertTrue(error is Other)
        }
        XCTAssertEqual(calls, 1)
    }

    /// A cancelled backoff must abandon the sync, not resume it. This is the `BGAppRefreshTask`
    /// expiration path: iOS may suspend the process the instant `setTaskCompleted` runs, so sitting in a
    /// sleep and then issuing another request is exactly the shape that leaves work parked forever.
    func testACancelledBackoffAbandonsTheRetryLoop() async {
        var calls = 0
        do {
            _ = try await withCloudSyncRetry(.standard, sleep: { _ in throw CancellationError() },
                                              jitter: { 0.5 }) {
                calls += 1
                throw CloudSyncError.network("dropped")
            }
            XCTFail("expected cancelled to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .cancelled)
        }
        XCTAssertEqual(calls, 1)
    }

    /// `.none` is the escape hatch for a caller that must fail fast; it must genuinely mean zero retries.
    func testNonePolicyNeverRetries() async {
        var calls = 0
        _ = try? await withCloudSyncRetry(.none, sleep: { _ in }, jitter: { 0.5 }) {
            calls += 1
            throw CloudSyncError.network("offline")
        }
        XCTAssertEqual(calls, 1)
    }
}
#endif // CLOUD_SYNC
