// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
#if os(iOS)
import Foundation
import UIKit

/// Owns THE process-wide background `URLSession` that carries the `/ingest` upload, so a whole-DB
/// `.noopbak` (100-300MB on disk, ~80MB deflated) can finish even though the app that started it is
/// suspended or killed partway through.
///
/// WHY THIS EXISTS (found live, 2026-07-14→15): cloud sync had not completed once in 22h despite a
/// foreground app-open AND a delivered APNs push. `CloudSyncClient` used `URLSession.shared` — a
/// DEFAULT, foreground session — and `didReceiveRemoteNotification:fetchCompletionHandler:` grants
/// only ~30s. Zipping the database alone blows past that budget; when the app then suspends, in-flight
/// `URLSession.shared` tasks are killed outright. APNs honestly reported the push as delivered; the
/// work was destroyed mid-flight, before it could even write a failure status. A BACKGROUND session is
/// the only transfer iOS keeps running on the app's behalf across suspension and termination — the OS
/// owns the upload, not this process.
///
/// DELEGATE-BASED BY NECESSITY: background sessions reject every completion-handler and async/await
/// convenience API (`upload(for:fromFile:)` and friends raise "Completion handler blocks are not
/// supported in background sessions"). Only `uploadTask(with:fromFile:)` + a delegate works — hence
/// the continuation bridge below, which restores an `async` shape for `CloudSyncClient` without
/// changing a single caller above it.
///
/// FILE-BODY ONLY: background sessions cannot send an in-memory body, which is why `ingest` already
/// streams from a temp `.noopbak` on disk (`CloudSyncUploader.upload`) — that pre-existing shape is
/// exactly what this migration needed, so the uploader is unchanged.
final class CloudSyncBackgroundSession: NSObject {
    static let shared = CloudSyncBackgroundSession()

    /// MUST be stable across launches: iOS keys the OS-side transfer queue (and the relaunch
    /// `handleEventsForBackgroundURLSession` callback) on this exact string. Changing it orphans any
    /// upload that was in flight across the update.
    static let sessionIdentifier = "com.noopapp.noop.cloudsync.upload"

    /// Guards `pending`, `staged*` and `backgroundEventsCompletion`. An `NSLock` (not an actor, not
    /// `@MainActor`) because `URLSession` invokes the delegate on `delegateQueue` — a plain
    /// `OperationQueue` — and `handleEvents`/`stage` are called from the main actor: the state has to
    /// be reachable synchronously from both without an `await`. Mirrors `BGTaskCompletion`'s reasoning
    /// in `CloudSyncBackgroundRefresh`.
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var backgroundEventsCompletion: (() -> Void)?
    /// The status prefix + content token `CloudSyncModel.performSync` staged for the upload it is
    /// about to start (see `stage`). Read once, when the task is created.
    private var stagedStatusPrefix = ""
    private var stagedContentToken: String?

    /// Per-task state. A class (reference semantics) so the delegate can append to `body` in place.
    /// `fileURL` is optional: on a RELAUNCH the process has no memory of having started the task, so
    /// the first thing it sees may be a `didReceive`/`didComplete` for a task it never created — the
    /// temp file to clean up then comes from the persisted `CloudSyncInFlightUpload` record instead.
    private final class Pending {
        var body = Data()
        var continuation: CheckedContinuation<(Data, Int), Error>?
        let fileURL: URL?
        init(fileURL: URL?) { self.fileURL = fileURL }
    }

    /// `isDiscretionary = false` asks iOS to run the transfer promptly rather than waiting for a
    /// "good" moment (Wi-Fi + power). IMPORTANT CAVEAT: iOS treats a background session created while
    /// the app is ALREADY backgrounded as discretionary regardless of this flag — which is exactly the
    /// push-triggered case this whole change exists to serve. `prewarm()` (called from the AppDelegate's
    /// `didFinishLaunching`) constructs the session while the app is still foreground so the flag
    /// actually sticks for later background wakes.
    ///
    /// `sessionSendsLaunchEvents = true` is what makes iOS relaunch the app to deliver this session's
    /// completion events — the other half of `handleEventsForBackgroundURLSession`.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.noopapp.noop.cloudsync.upload.delegate"
        return URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }()

    /// Construct the session NOW, while the caller is (presumably) foreground, so `isDiscretionary`
    /// takes effect — see the `session` property's doc comment. Also the point at which iOS starts
    /// replaying any events queued for this identifier while the app was dead. Idempotent: `lazy`
    /// makes every call after the first a no-op, which matters because constructing a SECOND session
    /// with the same identifier is a hard error.
    func prewarm() {
        _ = session
    }

    /// Publish the status prefix (`"Applied 0 · skipped 0"`) and content token that the upload about to
    /// start belongs to, so that a completion arriving with NO in-process awaiter — the app was
    /// suspended or relaunched mid-transfer — can still write a truthful `lastStatus` and the
    /// `lastUploadToken`. In-memory only: `upload` folds these into the persisted
    /// `CloudSyncInFlightUpload` record microseconds later, in the same process.
    func stage(statusPrefix: String, contentToken: String?) {
        lock.lock()
        stagedStatusPrefix = statusPrefix
        stagedContentToken = contentToken
        lock.unlock()
    }

    /// The `CloudSyncClient.FileUploading` seam: hands `ingest`'s fully-formed, Bearer-authed request
    /// (headers and all — this only changes WHICH session carries it) to the background session.
    var uploader: CloudSyncClient.FileUploading {
        { [unowned self] request, fileURL in
            try await self.upload(request, fromFile: fileURL)
        }
    }

    /// Start the background upload and suspend until the delegate reports completion.
    ///
    /// If iOS suspends the app first, this continuation simply never resumes IN THIS PROCESS — and
    /// that is the whole point: the transfer belongs to iOS now and keeps going. The awaiting
    /// `performSync` is frozen with the process (or dies with it), and the completion is honoured by
    /// `urlSession(_:task:didCompleteWithError:)`'s detached branch on the next launch instead.
    private func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { continuation in
            // `uploadTask` assigns `taskIdentifier` at creation and nothing is delivered before
            // `resume()`, so registering here is race-free.
            let task = session.uploadTask(with: request, fromFile: fileURL)
            let record: CloudSyncInFlightUpload
            lock.lock()
            let entry = Pending(fileURL: fileURL)
            entry.continuation = continuation
            pending[task.taskIdentifier] = entry
            record = CloudSyncInFlightUpload(filePath: fileURL.path,
                                             statusPrefix: stagedStatusPrefix,
                                             contentToken: stagedContentToken,
                                             startedAt: Date().timeIntervalSince1970)
            lock.unlock()
            // Persisted BEFORE `resume()`: once the task is running, this process may be suspended at
            // any instant, and the record is the only thing a future launch has to work from.
            CloudSyncModel.saveInFlightUpload(record)
            task.resume()
        }
    }

    /// Stash the relaunch completion handler and bring the session back up so iOS starts replaying the
    /// events it queued while the app was dead. The handler is called from
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`, once those events are drained.
    func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundEventsCompletion = completionHandler
        lock.unlock()
        prewarm()
    }

    /// Minimum age before `reconcileInFlight` will declare a record dead. `allTasks.isEmpty` is the
    /// real proof; this is the belt to its braces, ruling out the one race that matters — a relaunch
    /// where reconcile runs in the milliseconds BEFORE the session replays its queued completion, sees
    /// no live task, and tears down the record that completion is about to need. No legitimate
    /// transfer resolves and reports in under 15 minutes' wall time from a cold launch.
    private static let reconcileMinimumAgeS: TimeInterval = 15 * 60

    /// Recover from the one exit iOS never tells us about: a user force-quit. Force-quitting cancels
    /// every background transfer AND suppresses the relaunch, so no delegate callback ever fires —
    /// the record and its temp `.noopbak` would otherwise sit there forever, the card would claim an
    /// upload is still running, and `lastStatus` would stay frozen at the pre-upload line (exactly the
    /// symptom this change set out to kill).
    ///
    /// Both conditions must hold to declare death: the session has NO outstanding tasks, and the
    /// record is old enough that no in-flight transfer could plausibly own it.
    func reconcileInFlight() async {
        guard let record = CloudSyncModel.loadInFlightUpload() else { return }
        guard Date().timeIntervalSince1970 - record.startedAt >= Self.reconcileMinimumAgeS else { return }
        // A background session re-associates its outstanding tasks when it is recreated, so this is
        // the authoritative "is iOS still carrying my upload?" question.
        guard await session.allTasks.isEmpty else { return }
        cleanUpTempFile(URL(fileURLWithPath: record.filePath))
        CloudSyncModel.clearInFlightUpload()
        CloudSyncModel.recordDetachedUploadCompletion(
            statusPrefix: record.statusPrefix,
            outcome: .failure("Upload interrupted — the app was force-quit mid-upload. It will retry."),
            // No token: nothing was confirmed uploaded, so `lastUploadToken` must NOT advance or the
            // next sync would skip re-sending this content as "unchanged".
            contentToken: nil
        )
    }

    /// Delete a finished upload's temp `.noopbak`. The file MUST outlive the transfer — iOS reads the
    /// body from it (`CloudSyncUploader.upload`'s own `defer` cleanup is a harmless no-op by the time
    /// it runs in-process, and never runs at all when the process is suspended mid-upload, which is
    /// precisely why the file is still here for us).
    private func cleanUpTempFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - URLSessionDataDelegate

/// An upload task IS a `URLSessionDataTask`, so the `/ingest` JSON reply (`{ok,bytes,latestDay}`)
/// arrives through the DATA delegate — background sessions forbid bare data TASKS, not the data
/// delegate callbacks of an upload task.
extension CloudSyncBackgroundSession: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        // Create-if-missing, not `pending[id]?.body.append`: after a relaunch this process never
        // created the task, so there is no entry — and dropping the body here would throw away the
        // `bytes` count the "Uploaded 81.5 MB" line is built from.
        let entry = pending[dataTask.taskIdentifier] ?? Pending(fileURL: nil)
        entry.body.append(data)
        pending[dataTask.taskIdentifier] = entry
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let body = entry?.body ?? Data()
        // The record is the relaunch case's only source of truth for the temp path / status prefix /
        // content token. Read it BEFORE clearing.
        let record = CloudSyncModel.loadInFlightUpload()
        cleanUpTempFile(entry?.fileURL ?? record.map { URL(fileURLWithPath: $0.filePath) })
        CloudSyncModel.clearInFlightUpload()

        if let continuation = entry?.continuation {
            // IN-PROCESS: `performSync` is still awaiting and owns the lastStatus/lastAutoSync
            // contract exactly as it always has. Resume it and write nothing here.
            if let error {
                continuation.resume(throwing: CloudSyncError.network(error.localizedDescription))
            } else {
                continuation.resume(returning: (body, status))
            }
            return
        }
        // DETACHED: nobody is awaiting — the app was suspended or relaunched mid-transfer, so the
        // `performSync` that started this upload will never write its status line. Honour the same
        // contract on its behalf.
        CloudSyncModel.recordDetachedUploadCompletion(
            statusPrefix: record?.statusPrefix ?? "",
            outcome: Self.outcome(status: status, error: error, body: body),
            contentToken: record?.contentToken
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        lock.unlock()
        // UIKit requires its relaunch completion handler on the main thread; the delegate queue is not.
        DispatchQueue.main.async { handler?() }
    }

    /// Classify a finished transfer into the outcome `recordDetachedUploadCompletion` records. Mirrors
    /// `CloudSyncClient.ingest`'s own checks (2xx, then decode) so a detached completion reports the
    /// same thing the in-process path would have.
    private static func outcome(status: Int, error: Error?, body: Data) -> CloudSyncDetachedUploadOutcome {
        if let error {
            return .failure(CloudSyncError.network(error.localizedDescription).errorDescription
                            ?? error.localizedDescription)
        }
        guard (200..<300).contains(status) else {
            let prefix = String(decoding: body.prefix(200), as: UTF8.self)
            return .failure(CloudSyncError.badResponse(status, prefix).errorDescription
                            ?? "Upload failed (\(status))")
        }
        guard let decoded = try? JSONDecoder().decode(IngestResponse.self, from: body) else {
            return .failure(CloudSyncError.decode.errorDescription ?? "Upload response unreadable.")
        }
        return .success(bytes: decoded.bytes)
    }
}
#endif // os(iOS)
#endif // CLOUD_SYNC
