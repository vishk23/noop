// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation
import WhoopStore
#if os(iOS)
import UIKit
#endif

/// Process-wide reentrancy guard for the cloud-sync lane. `busy` on a `CloudSyncModel` INSTANCE only
/// guards within that one instance — but `autoSyncIfDue` runs on a throwaway `CloudSyncModel()`
/// created fresh in `RootView`/`RootTabView`'s launch `.task` (a new instance every launch), while
/// `DataSourcesView` holds its OWN long-lived `@StateObject` instance. Two different instances means
/// two different `busy` flags: a manual "Sync now" tap on the Data Sources card can't see that the
/// launch-time auto-sync (on its own throwaway instance) is already mid-upload, and vice versa — both
/// would happily run `CloudSyncUploader.upload` concurrently against the same on-disk store and the
/// same server. An `actor` serializes access to its own state automatically, making it the natural
/// process-wide singleton shape here — `shared` is the one gate for the whole process.
actor CloudSyncGate {
    static let shared = CloudSyncGate()
    private var inFlight = false

    /// Claims the gate if it's free. Returns false (and claims nothing) if a sync is already running.
    func begin() -> Bool {
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Releases the gate. Must be called exactly once for every `begin()` that returned true.
    func end() {
        inFlight = false
    }
}

/// Drives the Data Sources "Cloud Sync" card: save the noop-cloud server URL + token → pull confirmed
/// edits → apply them locally → (iOS) re-export whatever changed into Apple Health. @MainActor so every
/// `@Published` mutation is main-thread; the network/apply/write-back work hops off-main.
///
/// `repo: Repository` is taken as a call-time PARAMETER (not stored at construction), for the same
/// reason as `OuraConnectModel`: `Repository` only reaches `DataSourcesView` via `@EnvironmentObject`,
/// which SwiftUI populates after `init()` runs.
@MainActor
final class CloudSyncModel: ObservableObject {
    @Published var busy = false
    @Published var statusText: String?
    /// True once both a server URL and a token are stored in the Keychain (`CloudSyncSettings`).
    @Published var isConfigured = CloudSyncSettings.isConfigured

    /// Recompute-and-refresh hook the wiring point supplies (IntelligenceEngine.analyzeRecent +
    /// Repository.refresh). Cloud edits rewrite stored sessions/workouts, but the daily rollups the
    /// UI headlines read (`dailyMetric.totalSleepMin`, efficiency, Rest/Charge) are only rebuilt by
    /// the analyze cycle — which a pull does NOT trigger, so applied edits left the Sleep/Today
    /// numbers stale until the next strap-data analysis (found live: 14 restaged nights applied while
    /// the headline kept the pre-edit total). `performSync` invokes this whenever the applied-edits
    /// cursor is ahead of `recomputedCursorName`.
    var postApplyRefresh: (() async -> Void)?

    /// Cursor (same `cursors` table as `CloudSyncCoordinator.cursorName`) recording the highest
    /// journal seq the rollups were recomputed for. Cursor-vs-cursor — not `summary.applied > 0` —
    /// so a build that gains this hook AFTER edits were already applied still heals on its first sync.
    static let recomputedCursorName = "cloud_edits_recomputed"

    /// Validates `url` parses as an absolute URL (scheme + host) via `URLComponents` before saving.
    /// `CloudSyncClient.url(path:query:)` force-unwraps its `URLComponents`-built request URL, so a
    /// garbage base URL saved here would crash later at the first pull instead of failing this save
    /// with a clear, recoverable message (flagged in the Task-3 review of `CloudSyncClient`).
    func saveSettings(url: String, token: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedToken.isEmpty else {
            statusText = "Enter both a server URL and a token."
            return
        }
        guard let comps = URLComponents(string: trimmedURL), let scheme = comps.scheme, !scheme.isEmpty,
              let host = comps.host, !host.isEmpty else {
            statusText = "That doesn't look like a valid server URL (needs e.g. https://host)."
            return
        }
        CloudSyncSettings.serverURL = trimmedURL
        CloudSyncSettings.token = trimmedToken
        isConfigured = CloudSyncSettings.isConfigured
        statusText = "Saved."
    }

    /// Pull confirmed edits since this device's cursor, apply them, and — on iOS — re-export whatever
    /// changed into Apple Health. `repo.refresh()` runs unconditionally at the end (not just on
    /// success): `CloudEditApplier` writes land in the local store BEFORE `ack`, so even a pull that
    /// ultimately throws (e.g. the ack call itself failing) can leave real local changes the UI needs
    /// to pick up. Uses the EFFECTIVE credentials (`CloudSyncSettings.effectiveURL`/`effectiveToken`)
    /// so a bundle-only configuration (Phase 3.5, no Keychain save) works here too, not just in
    /// `syncNow`.
    func pullNow(repo: Repository) {
        guard let urlString = CloudSyncSettings.effectiveURL, let token = CloudSyncSettings.effectiveToken,
              let url = URL(string: urlString) else {
            statusText = "Add your noop-cloud server URL and token first."
            return
        }
        setBusy(true); statusText = "Pulling edits…"
        Task {
            var line: String
            if let store = await repo.storeHandle() {
                let client = CloudSyncClient(baseURL: url, token: token)
                do {
                    let summary = try await CloudSyncCoordinator.pull(store: store, client: client)
                    line = "Applied \(summary.applied) · skipped \(summary.skipped) · \(summary.needsAttention) need attention"
                    #if os(iOS) && canImport(HealthKit)
                    line += await reExportToAppleHealthIfNeeded(repo: repo, store: store, summary: summary)
                    #endif
                } catch {
                    line = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } else {
                line = "No local store."
            }
            statusText = line
            await repo.refresh()
            setBusy(false)
        }
    }

    /// Upload this device's own `.noopbak` to the noop-cloud server, then pull + apply any confirmed
    /// edits — the two halves of "zero-touch" in one round trip: this device's own data reaches the
    /// server, and any edits confirmed elsewhere reach this device. Stamps
    /// `UserDefaults["cloudsync.lastAutoSync"]` on SUCCESS ONLY, so a failed attempt (server
    /// unreachable, network down) never blocks the next 20h-gated retry. Used by the user-initiated
    /// "Sync now" button; `autoSyncIfDue`'s on-launch catch-up runs the identical `performSync` body
    /// under its own gated `Task` rather than calling this (see `runGatedSync`'s doc comment) — but a
    /// manual tap still resets the SAME on-launch catch-up clock (`Self.lastAutoSyncKey`, written
    /// inside `performSync`), so it doesn't immediately re-fire on the next launch.
    func syncNow(repo: Repository) {
        guard let urlString = CloudSyncSettings.effectiveURL, let token = CloudSyncSettings.effectiveToken,
              let url = URL(string: urlString) else {
            statusText = "Add your noop-cloud server URL and token first."
            return
        }
        Task { await runGatedSync(repo: repo, url: url, token: token) }
    }

    /// Acquires the process-wide `CloudSyncGate`, runs `performSync`, and always releases it —
    /// written out as one linear sequence rather than `defer` (which can't `await`). This is safe
    /// specifically because `performSync` never throws and never returns early once it starts: every
    /// internal failure is caught inside it and folded into its own status-line string (see its
    /// body), so falling off the end of this function really does mean "released on every exit path."
    /// Shared by `syncNow` and `autoSyncIfDue` — each spawns its own `Task` calling this — rather than
    /// having `autoSyncIfDue` acquire the gate and then call `syncNow` (which would try to acquire it
    /// again and immediately see it as already held by the very call chain it's part of, bailing with
    /// "Sync already in progress" on every auto-sync).
    private func runGatedSync(repo: Repository, url: URL, token: String) async {
        guard await CloudSyncGate.shared.begin() else {
            statusText = "Sync already in progress"
            return
        }
        await performSync(repo: repo, url: url, token: token)
        await CloudSyncGate.shared.end()
    }

    /// The actual upload + pull work, gated by `runGatedSync` — never called directly. Byte-identical
    /// to `syncNow`'s pre-gate Task body, plus persisting the outcome for the Data Sources card to
    /// read back (Finding 2: `CloudSyncModel.persistLastStatus`, below).
    private func performSync(repo: Repository, url: URL, token: String) async {
        setBusy(true); statusText = "Uploading…"
        var line: String
        var succeeded = false
        if let store = await repo.storeHandle() {
            let client = CloudSyncClient(baseURL: url, token: token)
            do {
                let uploaded = try await CloudSyncUploader.upload(store: store, client: client)
                let mb = Double(uploaded.bytes) / 1_048_576.0
                statusText = String(format: "Uploaded %.1f MB · pulling edits…", mb)

                let summary = try await CloudSyncCoordinator.pull(store: store, client: client)
                var parts = [String(format: "Uploaded %.1f MB", mb),
                             "Applied \(summary.applied)", "skipped \(summary.skipped)"]
                if summary.needsAttention > 0 { parts.append("\(summary.needsAttention) attention") }
                line = parts.joined(separator: " · ")
                succeeded = true
                // Rebuild the daily rollups before the Apple Health re-export, so the vitals it
                // exports (which read dailyMetric) reflect the just-applied edits too.
                var didRecompute = false
                if let refresh = postApplyRefresh {
                    let applied = (try? await store.cursor(CloudSyncCoordinator.cursorName)) ?? 0
                    let recomputed = (try? await store.cursor(Self.recomputedCursorName)) ?? 0
                    if applied > recomputed {
                        statusText = "Recomputing days touched by edits…"
                        await refresh()
                        try? await store.setCursor(Self.recomputedCursorName, applied)
                        didRecompute = true
                        parts.append("recomputed")
                        line = parts.joined(separator: " · ")
                    }
                }
                #if os(iOS) && canImport(HealthKit)
                // force after a recompute: the vitals the write-back exports read dailyMetric, so a
                // rollup rebuild needs a re-export even when THIS pull itself applied nothing.
                line += await reExportToAppleHealthIfNeeded(repo: repo, store: store, summary: summary,
                                                            force: didRecompute)
                #endif
            } catch {
                line = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            line = "No local store."
        }
        statusText = line
        if succeeded {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAutoSyncKey)
        }
        Self.persistLastStatus(line)
        await repo.refresh()
        setBusy(false)
    }

    /// UserDefaults key for the last successful `syncNow` (manual or automatic) — read by
    /// `autoSyncIfDue`, written by `performSync` on success only.
    private static let lastAutoSyncKey = "cloudsync.lastAutoSync"

    /// UserDefaults key for the outcome of the last sync attempt, success OR failure, persisted by
    /// `performSync` on EVERY completion (Finding 2). Read directly by the Data Sources card so an
    /// auto-sync that ran on a throwaway `CloudSyncModel` instance (see `CloudSyncGate`'s doc comment)
    /// is still visible on the card's own instance, whose `statusText` never saw it happen.
    private static let lastStatusKey = "cloudsync.lastStatus"

    /// The last sync's outcome, formatted for display ("<line> · <short time>"), or nil if no sync
    /// has ever completed on this device. A plain synchronous UserDefaults read — deliberately not
    /// reactive/`@Published`: `performSync` always ends with a `repo.refresh()`, which already
    /// re-renders the screens that observe `repo`, so the next render picks up a fresh value with no
    /// extra observation machinery.
    static var lastPersistedStatus: String? {
        UserDefaults.standard.string(forKey: lastStatusKey)
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Persist `line` (the human-readable outcome `performSync` just computed) plus a short local
    /// time, so a later launch's Data Sources card can show "Last sync: …" even when ITS OWN
    /// `statusText` is nil — e.g. right after launch, before that screen's own `CloudSyncModel`
    /// `@StateObject` has run a sync itself.
    private static func persistLastStatus(_ line: String) {
        UserDefaults.standard.set("\(line) · \(shortTimeFormatter.string(from: Date()))", forKey: lastStatusKey)
    }

    /// Pure 20h gate, `(lastRun, now) -> Bool`, so the threshold is unit-testable without UserDefaults,
    /// a store, or a network (see `CloudSyncModelAutoSyncGateTests`). `lastRun == 0` (never synced) is
    /// always due — a fresh install syncs on its very first launch, matching "zero manual taps".
    /// `nonisolated`: touches no actor-isolated state, so it's callable synchronously from a plain
    /// (non-`@MainActor`, non-`async`) XCTest method — without this, it inherits the enclosing class's
    /// `@MainActor` and a test would need `await MainActor.run { … }` just to call a pure function.
    nonisolated static func isAutoSyncDue(lastRun: TimeInterval, now: TimeInterval,
                                           intervalS: TimeInterval = 20 * 3600) -> Bool {
        now - lastRun >= intervalS
    }

    /// True when this process is running inside an XCTest test runner. Guards `autoSyncIfDue` against
    /// the incident where the macOS TEST HOST — `StrandTests` runs inside the full `Staging.app` via
    /// `TEST_HOST`, not a bare test bundle — executed `RootView`'s launch `.task` for real during a
    /// test run. Bundle credentials were present, so `CloudSyncModel().autoSyncIfDue(...)` fired and
    /// auto-uploaded the Mac's (empty) test database, replacing the production mirror. Two checks,
    /// either sufficient on its own: `XCTestConfigurationFilePath` is set by Xcode/`xcodebuild test`
    /// for the process actually running the tests; `NSClassFromString("XCTestCase") != nil` is
    /// belt-and-suspenders for the TEST_HOST shape, where XCTest is merely linked into the process.
    /// Only checked in `autoSyncIfDue` — a manual "Sync now" tap (`syncNow`) stays allowed under test,
    /// same as in production, because a human (or an explicit UI-driven test) triggered it on purpose.
    /// `nonisolated`, same reason as `isAutoSyncDue`: `CloudSyncModel` is `@MainActor`, and that
    /// isolation applies to `static` members by default — without this a plain synchronous XCTest
    /// method couldn't call it directly.
    nonisolated static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// On-launch daily catch-up (Phase 3.5: zero-touch): silently no-ops when the lane isn't configured
    /// — `CloudSyncSettings.isConfigured` already covers both a bundle-injected build and a manual
    /// Keychain save — otherwise runs the same gated sync as `syncNow` when it's been >20h since the
    /// last success. Call-time `repo:` parameter, same reason as every other method here (see the
    /// `@StateObject` declaration's note). A plain (non-`async`) MainActor call, mirroring
    /// `pullNow`/`syncNow`'s own shape: it spawns its OWN `Task` internally and returns immediately, so
    /// a caller on the launch-critical path (`RootView`/`RootTabView`'s `.task`) is never blocked
    /// waiting on the network. Deliberately does NOT call `syncNow(repo:)` — see `runGatedSync`'s doc
    /// comment for why that would self-deadlock the gate.
    func autoSyncIfDue(repo: Repository) {
        guard !Self.isRunningUnderXCTest else { return }
        guard CloudSyncSettings.isConfigured else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastAutoSyncKey)
        guard Self.isAutoSyncDue(lastRun: last, now: Date().timeIntervalSince1970) else { return }
        guard let urlString = CloudSyncSettings.effectiveURL, let token = CloudSyncSettings.effectiveToken,
              let url = URL(string: urlString) else { return }
        Task { await runGatedSync(repo: repo, url: url, token: token) }
    }

    #if os(iOS) && canImport(HealthKit)
    /// Re-export into Apple Health when a pulled batch touched sleep/workouts/HR — shared by `pullNow`
    /// and `syncNow` so both surface the same "Apple Health re-export failed" note. Only re-exports
    /// what could plausibly have changed on Health's side. A fresh bridge starts at auth == .unknown
    /// (it isn't the app's long-lived HealthKitBridge instance), so prime it from the existing grant —
    /// `refreshAuthIfPreviouslyGranted` only READS share status, it never prompts — before attempting
    /// the write-back. Returns a status-line SUFFIX: empty when nothing ran or it succeeded.
    private func reExportToAppleHealthIfNeeded(repo: Repository, store: WhoopStore,
                                                summary: CloudApplySummary,
                                                force: Bool = false) async -> String {
        guard force || summary.touchedSleep || summary.touchedWorkouts || summary.touchedHr else { return "" }
        do {
            let bridge = HealthKitBridge(repo: repo, appleDeviceId: "apple-health", noopDeviceId: "my-whoop")
            bridge.refreshAuthIfPreviouslyGranted()
            try await bridge.rerunWriteBack(whoopStore: store, days: 30)
            return ""
        } catch {
            return " · Apple Health re-export failed: \(error.localizedDescription)"
        }
    }
    #endif

    /// Busy also pins the screen awake on iOS, mirroring `OuraConnectModel.setBusy`: the pull +
    /// Apple Health re-export is a foreground async flow, and an auto-lock mid-run suspends the app
    /// and freezes it with no error. Always reset on exit.
    private func setBusy(_ b: Bool) {
        busy = b
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = b
        #endif
    }
}
#endif // CLOUD_SYNC
