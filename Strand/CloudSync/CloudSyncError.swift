// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation

/// User-facing failure reasons for the cloud-sync lane.
///
/// SPLIT OUT OF ONE `badResponse(Int, String)` CASE, which is the shape that turned a partial server
/// outage into a ten-day blackout. The noop-cloud server is deliberately expressive about *which kind
/// of "no"* it is answering — its `/ingest` handler comments say so in as many words — and the client
/// threw all of it away:
///
/// | Server says | Means | Old client | Now |
/// |---|---|---|---|
/// | `507 insufficient_space` | backup is fine, no room right now, retry later | "error (507)" | `serverOutOfSpace`, RETRYABLE |
/// | `400 corrupt_sqlite` | these exact bytes are unreadable, don't resend | "error (400)" | `rejected`, terminal |
/// | `503 storage_not_configured` | an OPTIONAL lane is switched off — not a failure at all | "error (503)" | `featureNotConfigured`, skip |
/// | `401 unauthorized` | the token is wrong; no amount of retrying fixes it | "error (401)" | `unauthorized`, terminal |
/// | `500`/`502`/`504` | server-side fault, almost always transient | "error (500)" | `serverFault`, RETRYABLE |
///
/// Two things depend on this distinction. `isRetryable` is what `CloudSyncRetry` consults, so only the
/// transient classes cost the user a backoff wait and only they get a second chance inside one sync.
/// And `errorDescription` is what lands in `UserDefaults["cloudsync.lastStatus"]` and on the Data
/// Sources card, so the sentence a human reads now says what to do about it rather than restating a
/// three-digit number.
enum CloudSyncError: LocalizedError, Equatable {
    /// 401/403. The token this build is using is not accepted. TERMINAL — retrying sends the same
    /// rejected credential, and only re-entering it (or re-signing the build) can help.
    case unauthorized(status: Int, detail: String)

    /// A 4xx the server refused on the merits: `400 corrupt_sqlite`, `400 bad_zip`, `413 too_large`,
    /// `400 bad_since`/`bad_seqs`/`bad_token`, `404 not_found`. TERMINAL — the same request produces
    /// the same refusal, so resending is pure cost. `code` is the server's own `error` string (it names
    /// exactly one failure mode; the phone should surface it verbatim rather than paraphrase).
    case rejected(status: Int, code: String, detail: String)

    /// 507 Insufficient Storage — `insufficient_space` or `storage_unavailable`. The single most
    /// important case to get right: the upload was PERFECTLY VALID and nothing local is wrong or lost.
    /// The server's own comment on this ("the phone reads them as 'server has no room, keep the backup
    /// and retry later' rather than 'this upload is malformed, discard it'") is the contract. RETRYABLE.
    case serverOutOfSpace(code: String, detail: String)

    /// 503 with `storage_not_configured` — an OPTIONAL server-side lane this build asked for is simply
    /// not switched on (today: the `/deepbuf` object-storage archive). NOT A FAILURE, and callers must
    /// treat it as "skip this lane" rather than "the sync failed": a deliberately-unconfigured optional
    /// feature sitting next to a real error in the same status line is exactly what made one outage
    /// look like two, and made the real one harder to find.
    case featureNotConfigured(feature: String, detail: String)

    /// Any other 5xx — the server tried and faulted. RETRYABLE: these are transient in practice
    /// (restart, deploy, upstream blip) and the next attempt seconds later usually lands.
    case serverFault(status: Int, code: String, detail: String)

    /// Transport-level: no route, TLS failure, DNS, connection dropped, or one of
    /// `CloudSyncClient.syncSession`'s timeouts firing. RETRYABLE.
    case network(String)

    /// The request was cancelled — the `BGAppRefreshTask` expiration handler calling `work.cancel()`,
    /// or the app tearing the sync down. NOT retryable: something deliberately asked this to stop, and
    /// retrying inside the same doomed scope just burns the remaining budget. Kept distinct from
    /// `network` so a cancelled background wake never reads as a server problem.
    case cancelled

    /// A 2xx whose body doesn't match the contract. Terminal: re-running the same parse over the same
    /// endpoint is not a fault that time fixes, it is a version mismatch between phone and server.
    case decode

    // MARK: - Classification

    /// Whether trying again — after a backoff — could plausibly succeed with no user action and no
    /// change to what is being sent. This is the ONLY input to `CloudSyncRetry`'s decision.
    var isRetryable: Bool {
        switch self {
        case .serverOutOfSpace, .serverFault, .network:
            return true
        case .unauthorized, .rejected, .featureNotConfigured, .cancelled, .decode:
            return false
        }
    }

    /// True for the one case that is not an error at all — an optional lane the server has switched
    /// off. Callers use this to skip a lane silently instead of reporting a failure.
    var isFeatureNotConfigured: Bool {
        if case .featureNotConfigured = self { return true }
        return false
    }

    /// True when the server has no such endpoint (404). `CloudSyncAppDelegate` treats that as benign
    /// for `/register-device`, which ships in parallel with this client.
    var isEndpointMissing: Bool {
        if case .rejected(404, _, _) = self { return true }
        return false
    }

    /// The HTTP status this came from, or nil for the non-HTTP cases.
    var httpStatus: Int? {
        switch self {
        case .unauthorized(let s, _): return s
        case .rejected(let s, _, _): return s
        case .serverOutOfSpace: return 507
        case .featureNotConfigured: return 503
        case .serverFault(let s, _, _): return s
        case .network, .cancelled, .decode: return nil
        }
    }

    // MARK: - What a human reads

    /// Written to be ACTIONABLE, because this exact string is what `CloudSyncModel.persistLastStatus`
    /// puts in `cloudsync.lastStatus` and what the Data Sources card shows. "The cloud sync server
    /// returned an error (507)" told the one person who could act on it nothing at all; every sentence
    /// below ends with what happens next or what to do.
    var errorDescription: String? {
        switch self {
        case .unauthorized(let status, _):
            return "Cloud sync rejected this device's token (\(status)). Re-enter the server token in "
                 + "Data Sources — retrying won't help."
        case .rejected(let status, let code, let detail):
            return "The server refused this upload: \(code) (\(status))."
                 + Self.suffix(for: code, detail: detail)
        case .serverOutOfSpace(let code, let detail):
            return "The server has no room for the backup right now (\(code)). Nothing was lost — your "
                 + "data is safe on this device and the next sync will try again."
                 + Self.detailSuffix(detail)
        case .featureNotConfigured(let feature, _):
            return "The optional \(feature) lane isn't switched on for this server — skipped, nothing "
                 + "to fix."
        case .serverFault(let status, let code, let detail):
            return "The cloud sync server hit an error (\(status) \(code)). It will be retried."
                 + Self.detailSuffix(detail)
        case .network(let d):
            return "Couldn't reach the cloud sync server: \(d)"
        case .cancelled:
            return "Sync was cancelled before it finished — it will resume on the next sync."
        case .decode:
            return "Couldn't read the cloud sync server's response (the phone and server may be on "
                 + "different versions)."
        }
    }

    /// Advice attached to the terminal `rejected` codes worth explaining. `corrupt_sqlite` in
    /// particular is the one where "don't resend these bytes" is the whole point — the phone re-exports
    /// from scratch every sync, so the next attempt is already sending different bytes.
    private static func suffix(for code: String, detail: String) -> String {
        switch code {
        case "corrupt_sqlite":
            return " The uploaded database couldn't be read, so it was discarded rather than replacing "
                 + "the good copy. The next sync exports a fresh backup." + detailSuffix(detail)
        case "bad_zip":
            return " The backup archive was malformed in transit; the next sync exports a fresh one."
                 + detailSuffix(detail)
        case "too_large":
            return " The backup is bigger than this server accepts — raise its ingest limit."
                 + detailSuffix(detail)
        default:
            return detailSuffix(detail)
        }
    }

    private static func detailSuffix(_ detail: String) -> String {
        detail.isEmpty ? "" : " \(detail)"
    }

    // MARK: - Building one from a response

    /// Map a non-2xx `(status, body)` onto exactly one case.
    ///
    /// The body is JSON (`{"error": "...", "detail": "..."}`) on every noop-cloud error path, so the
    /// server's own machine-readable code drives the classification and only falls back to the raw body
    /// prefix when the body isn't the expected shape (a proxy's HTML 502, say). `lane` names the
    /// optional feature for `featureNotConfigured` — it is only consulted when the server says
    /// `storage_not_configured`, so a caller passing a lane name never changes how a real error reads.
    static func from(status: Int, body: Data, lane: String) -> CloudSyncError {
        let parsed = ServerErrorBody.parse(body)
        let code = parsed.error ?? ""
        let detail = parsed.detail ?? (parsed.error == nil ? bodyPrefix(body) : "")

        switch status {
        case 401, 403:
            return .unauthorized(status: status, detail: detail)
        case 503 where code == "storage_not_configured":
            return .featureNotConfigured(feature: parsed.feature ?? lane, detail: detail)
        case 507:
            return .serverOutOfSpace(code: code.isEmpty ? "insufficient_space" : code, detail: detail)
        case 500...599:
            return .serverFault(status: status, code: code.isEmpty ? "server_error" : code, detail: detail)
        default:
            return .rejected(status: status, code: code.isEmpty ? "http_\(status)" : code, detail: detail)
        }
    }

    /// Map a thrown `URLSession`/structured-concurrency error onto `cancelled` or `network`. Cancellation
    /// arrives in two shapes depending on where it was observed — `CancellationError` from the
    /// concurrency runtime, `URLError.cancelled` from the transport — and both must land on `.cancelled`
    /// so a cancelled background wake is never retried or reported as a server problem.
    static func from(transport error: any Error) -> CloudSyncError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .network(error.localizedDescription)
    }

    /// Truncates a response body to a bounded prefix for error messages (never surface an unbounded
    /// server body through an error description).
    static func bodyPrefix(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.count > 200 ? String(s.prefix(200)) : s
    }
}

/// The JSON shape every noop-cloud error path answers with. All fields optional: a 502 from a proxy in
/// front of the server is not JSON at all, and `configured`/`feature` are only present on the
/// deep-buffer not-configured reply.
struct ServerErrorBody: Decodable {
    let error: String?
    let detail: String?
    let feature: String?
    let configured: Bool?

    static func parse(_ data: Data) -> ServerErrorBody {
        (try? JSONDecoder().decode(ServerErrorBody.self, from: data))
            ?? ServerErrorBody(error: nil, detail: nil, feature: nil, configured: nil)
    }
}
#endif // CLOUD_SYNC
