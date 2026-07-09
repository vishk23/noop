import Foundation

// MARK: - Neutral models emitted by OuraApiParser (network-free; the app-target writer maps them to WhoopStore).

/// One heart-rate sample (→ hrSample on write). `ts` is unix seconds, `bpm` is positive.
public struct OuraHRPoint: Sendable, Equatable {
    public let ts: Int
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

/// One Oura detailed sleep period: the shared `session` (incl. decoded stages) plus the rich extras the
/// shared model can't hold. `movement30s` → sleepSession.motionJSON; `hr` → hrSample. (HRV samples stay
/// in the raw archive only — there is no rMSSD-per-sample table; the per-night average is on `session`.)
public struct OuraSleepPeriod: Sendable, Equatable {
    public var session: WearableSleepSession
    public var movement30s: [Int]
    public var hr: [OuraHRPoint]
    public init(session: WearableSleepSession, movement30s: [Int], hr: [OuraHRPoint]) {
        self.session = session; self.movement30s = movement30s; self.hr = hr
    }
}
