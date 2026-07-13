// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation
import WhoopStore

/// Abstracts the raw-bytes ingest POST so `CloudSyncUploader` is testable without a live network —
/// mirrors `CloudSyncCoordinator`'s `CloudEditFetching` seam. `CloudSyncClient` conforms below.
protocol CloudIngesting {
    func ingest(fileURL: URL) async throws -> (bytes: Int, latestDay: String?)
}
extension CloudSyncClient: CloudIngesting {}

/// The export half's user-facing failure. The network half of an upload throws `CloudSyncError` (same
/// typed error every other CloudSync network call throws); this covers only "never got as far as
/// having bytes to send".
enum CloudSyncUploadError: LocalizedError, Equatable {
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let detail):
            return "Couldn't prepare the backup to upload. \(detail)"
        }
    }
}

/// Produces this device's own checkpointed, integrity-verified `.noopbak` and POSTs it to the
/// noop-cloud server's `/ingest` endpoint — the "upload" half of Phase 3.5's zero-touch sync (the
/// "pull" half is `CloudSyncCoordinator`). A pure coordination step with no state of its own, like
/// `CloudSyncCoordinator`, so it's a namespace of static functions rather than an instance.
enum CloudSyncUploader {
    /// Produces a `.noopbak` at `dest` from `store`, returning `DataBackup.BackupResult` so a real
    /// export failure's message survives. Injectable so a test can supply canned bytes without
    /// touching the app's real on-disk database: `WhoopStore.inMemory()` test stores have no backing
    /// file at all (see `WhoopStore.inMemory()`'s doc comment — a `DatabaseQueue`, not a file-backed
    /// `DatabasePool`), and the production default below is hardcoded to
    /// `StorePaths.defaultDatabasePath()` regardless of which `WhoopStore` instance is passed in. That
    /// fixed path is correct for production — there is only ever one real on-disk database, and
    /// `FolderBackup.backupNow`/`DataBackup.runExport` resolve it the exact same way — but it makes the
    /// default exporter untestable against a throwaway store, hence the seam.
    typealias Exporter = (WhoopStore, URL) async -> DataBackup.BackupResult

    /// The real export: checkpoint `store`'s WAL (so the single `.sqlite` file is whole), then reuse
    /// the SAME checkpointed, `PRAGMA quick_check`-verified export `BackupSync`/`FolderBackup` use — an
    /// auto-uploaded snapshot is byte-identical to a manual "Export backup".
    static let defaultExporter: Exporter = { store, dest in
        await DataBackup.writeBackup(checkpoint: { (try? await store.checkpointWAL()) != nil }, to: dest)
    }

    /// Export the live store to a disposable temp file in Caches (never Documents — nothing here is
    /// meant to persist or be user-visible) and POST it to `<base>/ingest`. The temp file is removed in
    /// `defer`, whatever happens: success, an export failure, or a network failure. The DB can be
    /// 100-300MB, so `CloudSyncClient.ingest` streams it from this file via
    /// `URLSession.upload(for:fromFile:)` rather than loading it into memory.
    static func upload(store: WhoopStore, client: any CloudIngesting,
                        exporter: Exporter = defaultExporter) async throws -> (bytes: Int, latestDay: String?) {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let tempURL = cachesDir.appendingPathComponent("cloudsync-upload-\(UUID().uuidString).noopbak")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        switch await exporter(store, tempURL) {
        case .exported:
            return try await client.ingest(fileURL: tempURL)
        case .failure(let message):
            throw CloudSyncUploadError.exportFailed(message)
        case .cancelled, .imported:
            // The checkpointed export path (no picker, no import flow) never actually returns these —
            // handled explicitly so the switch stays exhaustive without a silently-wrong `default`.
            throw CloudSyncUploadError.exportFailed("The export step returned an unexpected result.")
        }
    }
}
#endif // CLOUD_SYNC
