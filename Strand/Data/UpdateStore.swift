import Foundation
import Combine

// MARK: - UpdateItem
//
// One entry in the "Updates inbox" — the bell in the Today header collects these. An item is either
// purely informational (a What's New note, a "new data" reading) or actionable (a deep link to a
// screen, or a dismissed Today card the user can restore). Everything stays on-device; nothing here
// is medical, identifying, or a verdict — just a calm log of what's new in the app and the data.

struct UpdateItem: Identifiable, Codable, Equatable {
    /// The flavour of update — drives the row's tinted SF Symbol and behaviour.
    enum Kind: String, Codable {
        case dismissedCard   // a Today info-card the user swiped into the inbox (restorable)
        case whatsNew        // a release note (seeded from AppChangelog on first run after an update)
        case reading         // new data arrived (e.g. "N days backfilled") — links to Trends
        case strapAlert      // a strap-side heads-up (low battery, sync) — informational
    }

    let id: UUID
    var kind: Kind
    var title: String
    var message: String
    var date: Date
    var read: Bool
    /// Optional route key the inbox can navigate to when tapped (nil = purely informational). Matches a
    /// `NavRouter.Destination.rawValue` (e.g. "trends", "labBook"); unknown keys just dismiss the sheet.
    var deepLink: String?
    /// For `.dismissedCard` only: the Today card id to restore (the `@AppStorage` dismissed-flag key's
    /// stable suffix). Tapping "Restore to Today" in the inbox flips that flag back so the card reappears.
    var restorePayload: String?

    init(id: UUID = UUID(), kind: Kind, title: String, message: String,
         date: Date = Date(), read: Bool = false,
         deepLink: String? = nil, restorePayload: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.date = date
        self.read = read
        self.deepLink = deepLink
        self.restorePayload = restorePayload
    }
}

// MARK: - UpdateStore
//
// The bell's backing store: a single-user, on-device inbox of `UpdateItem`s persisted as JSON in
// UserDefaults — the same lightweight `@Published`-with-`didSet` persistence ProfileStore/BehaviorStore
// use, just over an array instead of scalars (Codable round-trips the whole list under one key on every
// mutation). A shared singleton like the other stores so any surface (Today cards, the import path) can
// `UpdateStore.shared.post(...)` without threading an instance through.
//
// First-run seeding: posts the current What's New (AppChangelog.releases.first) once, tracking
// `lastSeededVersion` so the same version is never double-posted across launches.
@MainActor
final class UpdateStore: ObservableObject {

    /// The app-wide instance (injected as an `@EnvironmentObject` at both app roots, alongside the other
    /// stores). A singleton so non-View code (an import-complete path) can post to the SAME inbox the UI
    /// observes.
    static let shared = UpdateStore()

    /// Newest-first is computed at read time (`sortedItems`); the stored array preserves insertion order.
    @Published private(set) var items: [UpdateItem] {
        didSet { persist() }
    }

    /// A restore signal TodayView observes: set to a card id when "Restore to Today" is tapped, so the
    /// Today screen (which owns the `@AppStorage` dismissed flags) can flip the matching flag back to
    /// false. Cleared by the observer once handled. (The inbox also clears the flag directly via the
    /// shared key, so this is belt-and-braces for an already-mounted Today.)
    @Published var restoreRequest: String?

    private let d = UserDefaults.standard
    private enum K {
        static let items = "updates.items"
        static let lastSeededVersion = "updates.lastSeededWhatsNewVersion"
    }

    private init() {
        if let data = d.data(forKey: K.items),
           let decoded = try? JSONDecoder().decode([UpdateItem].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    // MARK: Derived

    /// Items newest-first (the inbox list order).
    var sortedItems: [UpdateItem] { items.sorted { $0.date > $1.date } }

    /// How many unread — drives the bell badge.
    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    // MARK: Mutations

    /// Add a new item to the inbox (unread). No dedupe beyond the caller's own checks — callers that
    /// must be idempotent (What's New seeding) guard before calling.
    func post(_ item: UpdateItem) {
        items.append(item)
    }

    /// Mark one item read (no-op if already read / not found).
    func markRead(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].read else { return }
        items[i].read = true
    }

    /// Mark every item read.
    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        for i in items.indices { items[i].read = true }
    }

    /// Remove one item (e.g. after restoring a dismissed card).
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Empty the inbox.
    func clearAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
    }

    /// Ask Today to restore a dismissed card (flips its `@AppStorage` flag). Also removes the inbox item.
    func requestRestore(_ item: UpdateItem) {
        if let payload = item.restorePayload {
            restoreRequest = payload
        }
        remove(item.id)
    }

    // MARK: Seeding

    /// Post the current What's New as a `.whatsNew` item ONCE per version. Idempotent: tracks the last
    /// version it seeded in UserDefaults, so a relaunch on the same version never double-posts. Call on
    /// app appear (both shells), after the changelog version is known. `current` defaults to the live
    /// `AppChangelog`, but is injectable for tests.
    func seedWhatsNewIfNeeded(version: String = AppChangelog.currentVersion,
                              title: String = AppChangelog.releases.first?.title ?? "",
                              summary: String? = nil) {
        guard !version.isEmpty else { return }
        guard d.string(forKey: K.lastSeededVersion) != version else { return }
        // Mark seeded first so a re-entrant call (or a crash mid-post) can't double-post this version.
        d.set(version, forKey: K.lastSeededVersion)

        let message = summary ?? "NOOP \(version) is here — tap to read what's new."
        post(UpdateItem(
            kind: .whatsNew,
            title: title.isEmpty ? "What's new in NOOP \(version)" : title,
            message: message
        ))
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        d.set(data, forKey: K.items)
    }
}
