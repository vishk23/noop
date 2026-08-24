// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation

/// One row of the noop-cloud server's append-only edit journal. Field names match the server's
/// JSON keys exactly (camelCase), so no CodingKeys translation is needed.
struct CloudEdit: Decodable, Equatable {
    let seq: Int
    let editId: String
    let kind: String
    let payloadJSON: String
    let beforeJSON: String?
    let rationale: String?
    let appliedAt: Int
    let undoneBySeq: Int?
    let ackedAt: Int?
}

/// The `GET /edits` response envelope: the page of journal rows since the requested cursor, plus
/// the server's latest known seq (so the caller can detect it's fully caught up).
struct CloudEditsResponse: Decodable {
    let edits: [CloudEdit]
    let latestSeq: Int
}
#endif // CLOUD_SYNC
