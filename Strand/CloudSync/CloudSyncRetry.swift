// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation

/// How many times, and how far apart, a cloud-sync request is retried.
///
/// The client had NO retry at all. A single 500 from a restarting server, or one dropped connection on
/// a train, ended the whole sync — and the next attempt was not seconds later, it was whenever the next
/// `autoSyncIfDue` (20h) or `backgroundSyncIfDue` (4h) window happened to open, on a process that in
/// practice only runs `autoSyncIfDue` once per launch. One unlucky second could therefore cost a day.
///
/// THE BUDGET IS DELIBERATELY SMALL. The target cadence is a sync every time the phone is opened, so
/// the cost of giving up early is now one more phone-unlock, not one more day — which makes a long
/// in-sync retry ladder the wrong trade. A retry here exists to ride out a blip that a human would not
/// even notice, not to out-wait a real outage. Worst case this adds ~4s to a failing sync, against a
/// `CloudSyncClient.syncSession` request ceiling of 1h and a `CloudSyncGate.staleHoldS` of 2h, so the
/// retry ladder can never be what wedges a sync.
///
/// FULL JITTER-BAND, not a bare doubling: every phone that a server outage knocked offline retries on
/// the same schedule otherwise, and they come back in a thundering herd the moment it recovers.
/// `jitterFraction` spreads each delay across a band around its nominal value.
struct CloudSyncRetryPolicy: Equatable {
    /// Total attempts INCLUDING the first. 1 = no retry at all.
    let maxAttempts: Int
    /// Delay before attempt 2. Each later attempt multiplies by `multiplier`.
    let baseDelayS: Double
    let multiplier: Double
    /// Ceiling on the nominal delay before jitter is applied.
    let maxDelayS: Double
    /// Half-width of the jitter band, as a fraction of the nominal delay. 0.25 => each delay is drawn
    /// uniformly from ±25% of nominal.
    let jitterFraction: Double

    /// Small JSON round trips — `/edits`, `/edits/ack`, `/register-device`, one `/deepbuf` chunk.
    /// Three attempts at ~1s then ~3s: enough to ride out a redeploy, cheap enough that a user watching
    /// the Data Sources card sees a result rather than a hang.
    static let standard = CloudSyncRetryPolicy(maxAttempts: 3, baseDelayS: 1, multiplier: 3,
                                                maxDelayS: 15, jitterFraction: 0.25)

    /// The whole-database `POST /ingest`. ONE retry, not two: the body is a 100-300MB `.noopbak` and
    /// resending it is minutes of cellular data, so a second retry costs the user far more than the
    /// wait it saves. The one retry is still worth having because the most common `/ingest` refusal —
    /// `507 insufficient_space` — is answered from the declared `Content-Length` BEFORE the server
    /// accepts a byte of the body, so that attempt cost nothing to make and nothing to repeat.
    static let bulkUpload = CloudSyncRetryPolicy(maxAttempts: 2, baseDelayS: 2, multiplier: 3,
                                                  maxDelayS: 15, jitterFraction: 0.25)

    /// No retry. For a caller that must fail fast, and for tests pinning "this class is terminal".
    static let none = CloudSyncRetryPolicy(maxAttempts: 1, baseDelayS: 0, multiplier: 1,
                                            maxDelayS: 0, jitterFraction: 0)

    /// The retry COUNTS of `standard`, with no waiting. Tests only — a unit test must be able to prove
    /// a retryable class is retried without spending four real seconds doing it.
    static let immediate = CloudSyncRetryPolicy(maxAttempts: 3, baseDelayS: 0, multiplier: 1,
                                                 maxDelayS: 0, jitterFraction: 0)

    /// Nominal-then-jittered delay before `attempt` (1-based, so `attempt == 2` is the first retry).
    /// `jitterUnit` is the random draw in `0...1`, passed in rather than taken so the whole schedule is
    /// a pure function and testable without sampling a distribution.
    func delayS(beforeAttempt attempt: Int, jitterUnit: Double) -> Double {
        guard attempt > 1 else { return 0 }
        let nominal = min(baseDelayS * pow(multiplier, Double(attempt - 2)), maxDelayS)
        let scale = 1 + jitterFraction * (2 * min(max(jitterUnit, 0), 1) - 1)
        return max(nominal * scale, 0)
    }
}

/// Run `body`, retrying it while it throws a RETRYABLE `CloudSyncError` and attempts remain.
///
/// Only `CloudSyncError.isRetryable` decides. That is the whole reason the error taxonomy exists: a
/// `507` (server has no room — the backup is fine) and a `400 corrupt_sqlite` (these bytes are
/// unreadable, never send them again) are both "an error" and must be handled in opposite directions.
/// Anything that is not a `CloudSyncError` at all propagates untouched on the first throw.
///
/// Cancellation short-circuits: `sleep` is `Task.sleep` in production, which throws on cancellation, and
/// that is surfaced as `CloudSyncError.cancelled` rather than swallowed — a `BGAppRefreshTask` whose
/// expiration handler just fired must stop immediately, not sit out a backoff it will never survive.
///
/// `sleep` and `jitter` are injected so a test can prove the retry COUNT and the terminal-class
/// behaviour without real time and without a real random draw.
func withCloudSyncRetry<T>(
    _ policy: CloudSyncRetryPolicy,
    sleep: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
    jitter: () -> Double = { Double.random(in: 0...1) },
    _ body: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await body()
        } catch let error as CloudSyncError {
            guard error.isRetryable, attempt < policy.maxAttempts else { throw error }
            attempt += 1
            let delay = policy.delayS(beforeAttempt: attempt, jitterUnit: jitter())
            if delay > 0 {
                do { try await sleep(delay) } catch { throw CloudSyncError.cancelled }
            }
            if Task.isCancelled { throw CloudSyncError.cancelled }
        }
    }
}
#endif // CLOUD_SYNC
