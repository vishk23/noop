import Foundation
import SQLite3
import StrandAnalytics
import WhoopProtocol

// livebench — score LiveSleepStager (causal, forward-filter) against every reference this database
// carries, and measure REM-cue latency. Read-only; the DB path is always an argument.

let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let epochS = 30.0
let stageOrder = ["wake", "light", "deep", "rem"]

var dbPath = ""
var device = "my-whoop-noop"
var streamDevice = "my-whoop"
var pad = 3600
var remThreshold = 0.5
var refractoryMin = 20.0
var onlyCausality = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--db": dbPath = it.next() ?? ""
    case "--device": device = it.next() ?? device
    case "--stream-device": streamDevice = it.next() ?? streamDevice
    case "--pad": pad = Int(it.next() ?? "") ?? pad
    case "--rem-threshold": remThreshold = Double(it.next() ?? "") ?? remThreshold
    case "--causality-only": onlyCausality = true
    default: FileHandle.standardError.write(Data("unknown arg \(k)\n".utf8)); exit(2)
    }
}
guard !dbPath.isEmpty else { print("usage: livebench --db <sqlite>"); exit(2) }

// MARK: - Read-only DB

final class RODB {
    var h: OpaquePointer?
    init(path: String) throws {
        let rc = sqlite3_open_v2("file:\(path)?immutable=1", &h,
                                 SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else { throw E("open failed \(rc)") }
    }
    deinit { if let h { sqlite3_close(h) } }
    struct E: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }
    func q(_ sql: String, _ each: (OpaquePointer) -> Void) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &s, nil) == SQLITE_OK else {
            throw E("prepare: \(String(cString: sqlite3_errmsg(h))) [\(sql)]")
        }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { each(s!) }
    }
    static func i(_ s: OpaquePointer, _ c: Int32) -> Int { Int(sqlite3_column_int64(s, c)) }
    static func d(_ s: OpaquePointer, _ c: Int32) -> Double { sqlite3_column_double(s, c) }
    static func null(_ s: OpaquePointer, _ c: Int32) -> Bool { sqlite3_column_type(s, c) == SQLITE_NULL }
    static func t(_ s: OpaquePointer, _ c: Int32) -> String? {
        guard let p = sqlite3_column_text(s, c) else { return nil }
        return String(cString: p)
    }
}

struct Row {
    let startTs: Int, endTs: Int, userEdited: Bool
    let stages: [StageSegment]
}
struct Streams {
    var hr: [HRSample] = [], rr: [RRInterval] = [], grav: [GravitySample] = []
    var resp: [RespSample] = [], band: [(ts: Int, state: Int)] = []
}

let db = try RODB(path: dbPath)
var rows: [Row] = []
try db.q("""
SELECT startTs, endTs, userEdited, stagesJSON FROM sleepSession
WHERE deviceId = '\(device)' ORDER BY startTs
""") { s in
    let js = RODB.t(s, 3) ?? "[]"
    let st = (try? JSONDecoder().decode([StageSegment].self, from: Data(js.utf8))) ?? []
    rows.append(Row(startTs: RODB.i(s, 0), endTs: RODB.i(s, 1),
                    userEdited: RODB.i(s, 2) != 0, stages: st))
}
var stageLocked: Set<Int> = []
let prefix = "stagelock:\(device):"
try db.q("SELECT name FROM cursors WHERE value = 1 AND name LIKE '\(prefix)%'") { s in
    if let n = RODB.t(s, 0), let ts = Int(n.dropFirst(prefix.count)) { stageLocked.insert(ts) }
}

func streams(from: Int, to: Int) throws -> Streams {
    var st = Streams()
    let w = "deviceId = '\(streamDevice)' AND ts >= \(from) AND ts <= \(to)"
    try db.q("SELECT ts, bpm FROM hrSample WHERE \(w) ORDER BY ts") {
        st.hr.append(HRSample(ts: RODB.i($0, 0), bpm: RODB.i($0, 1)))
    }
    try db.q("SELECT ts, rrMs FROM rrInterval WHERE \(w) ORDER BY ts, ord, seq") {
        st.rr.append(RRInterval(ts: RODB.i($0, 0), rrMs: RODB.i($0, 1)))
    }
    try db.q("SELECT ts, x, y, z, dynAccel FROM gravitySample WHERE \(w) ORDER BY ts") {
        st.grav.append(GravitySample(ts: RODB.i($0, 0), x: RODB.d($0, 1), y: RODB.d($0, 2),
                                     z: RODB.d($0, 3), unit: "g",
                                     dynAccel: RODB.null($0, 4) ? nil : RODB.d($0, 4)))
    }
    try db.q("SELECT ts, raw FROM respSample WHERE \(w) ORDER BY ts") {
        st.resp.append(RespSample(ts: RODB.i($0, 0), raw: RODB.i($0, 1)))
    }
    try db.q("SELECT ts, state FROM sleepStateSample WHERE \(w) ORDER BY ts") {
        st.band.append((ts: RODB.i($0, 0), state: RODB.i($0, 1)))
    }
    return st
}

// MARK: - Metrics

func epochCount(_ a: Int, _ b: Int) -> Int { max(1, Int(ceil(Double(b - a) / epochS))) }

func epochLabels(_ stages: [StageSegment], start: Int, end: Int) -> [String] {
    let n = epochCount(start, end)
    var out = [String](repeating: "wake", count: n)
    guard !stages.isEmpty else { return out }
    let s = stages.sorted { $0.start < $1.start }
    var si = 0
    for i in 0..<n {
        let t = start + Int(Double(i) * epochS)
        while si + 1 < s.count && s[si].end <= t { si += 1 }
        if s[si].start <= t && t < s[si].end { out[i] = s[si].stage }
        else if let hit = s.first(where: { $0.start <= t && t < $0.end }) { out[i] = hit.stage }
        else if t >= s[s.count - 1].end { out[i] = s[s.count - 1].stage }
    }
    return out
}

func kappa(_ a: [String], _ b: [String], classes: [String]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .nan }
    let k = classes.count
    var idx: [String: Int] = [:]
    for (i, c) in classes.enumerated() { idx[c] = i }
    var m = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
    var n = 0.0
    for i in a.indices {
        guard let x = idx[a[i]], let y = idx[b[i]] else { continue }
        m[x][y] += 1; n += 1
    }
    guard n > 0 else { return .nan }
    var po = 0.0
    for i in 0..<k { po += m[i][i] }
    po /= n
    var pe = 0.0
    for i in 0..<k {
        let r = m[i].reduce(0, +)
        var c = 0.0
        for j in 0..<k { c += m[j][i] }
        pe += (r / n) * (c / n)
    }
    return pe >= 1 ? .nan : (po - pe) / (1 - pe)
}

func accuracy(_ a: [String], _ b: [String]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .nan }
    var hit = 0
    for i in a.indices where a[i] == b[i] { hit += 1 }
    return Double(hit) / Double(a.count)
}

/// F1 for one class: pred = a, ref = b.
func f1(_ a: [String], _ b: [String], cls: String) -> Double {
    var tp = 0.0, fp = 0.0, fn = 0.0
    for i in a.indices {
        let p = a[i] == cls, r = b[i] == cls
        if p && r { tp += 1 } else if p { fp += 1 } else if r { fn += 1 }
    }
    if tp == 0 { return 0 }
    let prec = tp / (tp + fp), rec = tp / (tp + fn)
    return 2 * prec * rec / (prec + rec)
}

func f(_ v: Double, _ d: Int = 3) -> String {
    v.isNaN ? "  n/a" : String(format: "%.\(d)f", v)
}
func pct(_ v: Double) -> String { v.isNaN ? " n/a" : String(format: "%.1f%%", v * 100) }

func nightLabel(_ ts: Int) -> String {
    let d = Date(timeIntervalSince1970: Double(ts - 7 * 3600))
    let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"; fm.timeZone = TimeZone(identifier: "UTC")
    return fm.string(from: d)
}

func median(_ v: [Double]) -> Double {
    if v.isEmpty { return .nan }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
}
func quantile(_ v: [Double], _ q: Double) -> Double {
    if v.isEmpty { return .nan }
    let s = v.sorted()
    let p = q * Double(s.count - 1)
    let lo = Int(p.rounded(.down)), hi = min(s.count - 1, lo + 1)
    return s[lo] + (p - Double(lo)) * (s[hi] - s[lo])
}
func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }

// MARK: - Load every night once

struct Night {
    let row: Row
    let name: String
    let st: Streams
    let v2: [String]
    let stored: [String]
    let bandEpochs: [Int]
    let n: Int
}

FileHandle.standardError.write(Data("loading \(rows.count) sessions…\n".utf8))
var nights: [Night] = []
for r in rows {
    let st = try streams(from: r.startTs - pad, to: r.endTs + pad)
    let v2 = SleepStagerV2.stageSession(start: r.startTs, end: r.endTs, grav: st.grav,
                                        hr: st.hr, rr: st.rr, resp: st.resp)
    let n = epochCount(r.startTs, r.endTs)
    let be = SleepStager.sessionEpochSleepState(start: r.startTs, end: r.endTs, sleepState: st.band)
    nights.append(Night(row: r, name: nightLabel(r.startTs), st: st,
                        v2: epochLabels(v2, start: r.startTs, end: r.endTs),
                        stored: epochLabels(r.stages, start: r.startTs, end: r.endTs),
                        bandEpochs: be.count == n ? be : [], n: n))
}

print("""

================================================================================
0. WHAT THIS HARNESS CAN AND CANNOT MEASURE
================================================================================
sessions \(nights.count)   userEdited \(nights.filter { $0.row.userEdited }.count)   \
stage-locked \(nights.filter { stageLocked.contains($0.row.startTs) }.count)   \
with band sleep_state \(nights.filter { !$0.bandEpochs.isEmpty }.count)
""")

// MARK: - Section 1: contamination of the stage-locked set

print("""

================================================================================
1. IS THERE ANY CLEAN REM REFERENCE?  (stored-vs-V2 agreement, every stage-locked night)
================================================================================
A stage-locked row was authored through the cloud `edit_sleep_stages` path, so its stages are nominally
human. If a row nevertheless agrees with a FRESH V2 replay far above the human inter-scorer ceiling
(kappa 0.76), it cannot be an independent reference for V2 or for anything derived from V2.
  night          epochs   4-class agree   kappa vs V2   REM F1 vs V2
""")
var lockedAgree: [Double] = []
var lockedKappa: [Double] = []
for nt in nights where stageLocked.contains(nt.row.startTs) {
    let a = accuracy(nt.stored, nt.v2)
    let k = kappa(nt.stored, nt.v2, classes: stageOrder)
    lockedAgree.append(a); lockedKappa.append(k)
    print("  \(nt.name)  \(String(format: "%8d", nt.n))   \(String(format: "%12s", ("" as NSString).utf8String!))\(pct(a))        \(f(k))         \(f(f1(nt.stored, nt.v2, cls: "rem")))")
}
print("""
  ------------------------------------------------------------------------------
  n = \(lockedAgree.count)   median agreement \(pct(median(lockedAgree)))   min \(pct(lockedAgree.min() ?? .nan))   \
median kappa-vs-V2 \(f(median(lockedKappa)))
""")

// MARK: - Section 2: causality proof

print("""

================================================================================
2. CAUSALITY — TRUNCATION INVARIANCE
================================================================================
The property that matters: an epoch's decision must be a pure function of samples BEFORE its read window
closes. Test: replay each night truncated at 25%, 50% and 75% of its length and compare every decision the
truncated run produced against the same epoch in the full run. Any difference is a lookahead leak.
""")

/// Leave-one-night-out priors, computed EXACTLY but without re-extracting every night per fold.
///
/// `PersonalSleepPriors.calibrate` is two passes: pass A pools per-night jerk medians into `jerkFloor`,
/// pass B re-extracts every night with the move threshold PINNED to that floor and pools the feature
/// distributions. Pass B is the expensive half and it depends on the fold ONLY through `jerkFloor` — so
/// the same extraction can be reused by every fold that shares a floor. Leaving one of N nights out moves
/// a median between two adjacent order statistics, so there are a handful of distinct floors, not N.
///
/// Everything pooled here is a sufficient statistic (counts/sums/sums-of-squares are additive; the flat
/// quantile knots come from the concatenated sorted values), so the result is MATHEMATICALLY identical to
/// calling `calibrate` on the 35-night subset. It is not BIT-identical: this sums per-night subtotals and
/// then combines them, while `calibrate` runs one accumulator over every epoch, and floating-point addition
/// is not associative. Measured divergence is ~1e-13 relative on the pooled mean/sd — 12 orders of magnitude
/// below anything that could move a label, let alone a kappa. The self-check below reports the actual gap
/// rather than trusting this paragraph.
struct NightStats {
    var hrN = 0, hvN = 0, mvN = 0, rgN = 0
    var hrS = 0.0, hvS = 0.0, mvS = 0.0, rgS = 0.0
    var hrQ = 0.0, hvQ = 0.0, mvQ = 0.0, rgQ = 0.0
    var flat: [Double] = []
    var span = 0
    var epochs = 0
}

func perNightJerkFloor(_ nt: Night) -> Double? {
    let cal = PersonalSleepPriors.CalibrationNight(start: nt.row.startTs, end: nt.row.endTs,
                                                   hr: nt.st.hr, rr: nt.st.rr, gravity: nt.st.grav)
    let p = PersonalSleepPriors.calibrate(nights: [cal])
    return p.nightsUsed == 0 ? nil : p.jerkFloor
}

func extractStats(_ nt: Night, jerkFloor: Double) -> NightStats {
    var cfg = CausalSleepFeatureExtractor.Config()
    cfg.fixedJerkScale = jerkFloor
    cfg.adaptFullSec = 0
    let boot = PersonalSleepPriors(hr: .neutral, hrVar: .neutral, moveFrac: .neutral, respReg: .neutral,
                                   jerkFloor: jerkFloor, hrFlat11Quantiles: [],
                                   typicalSessionSec: max(1, nt.row.endTs - nt.row.startTs),
                                   nightsUsed: 0, epochsUsed: 0)
    let ex = CausalSleepFeatureExtractor(priors: boot, sessionStart: nt.row.startTs, config: cfg)
    ex.ingest(hr: nt.st.hr.sorted { $0.ts < $1.ts })
    ex.ingest(rr: nt.st.rr.sorted { $0.ts < $1.ts })
    ex.ingest(gravity: nt.st.grav.sorted { $0.ts < $1.ts })
    var s = NightStats()
    for f in ex.advance(to: nt.row.endTs).map({ $0.epoch }) {
        if let v = f.hr { s.hrN += 1; s.hrS += v; s.hrQ += v * v }
        if let v = f.hrVar { s.hvN += 1; s.hvS += v; s.hvQ += v * v }
        s.mvN += 1; s.mvS += f.moveFrac; s.mvQ += f.moveFrac * f.moveFrac
        if let v = f.respReg { s.rgN += 1; s.rgS += v; s.rgQ += v * v }
        if let v = f.hrFlat11 { s.flat.append(v) }
        s.epochs += 1
    }
    s.span = nt.row.endTs - nt.row.startTs
    return s
}

let cold = PersonalSleepPriors.coldStart

func poolPriors(_ parts: [NightStats], jerkFloor: Double) -> PersonalSleepPriors {
    func stat(_ n: Int, _ sum: Double, _ sq: Double, _ fb: NormStat) -> NormStat {
        guard n >= 2 else { return fb }
        let m = sum / Double(n)
        let v = sq / Double(n) - m * m
        let sd = (v < 0 ? 0 : v).squareRoot()
        return sd > 0 ? NormStat(mean: m, sd: sd) : fb
    }
    var hrN = 0, hvN = 0, mvN = 0, rgN = 0, epochs = 0
    var hrS = 0.0, hvS = 0.0, mvS = 0.0, rgS = 0.0, hrQ = 0.0, hvQ = 0.0, mvQ = 0.0, rgQ = 0.0
    var flat: [Double] = []
    var spans: [Int] = []
    for p in parts {
        hrN += p.hrN; hvN += p.hvN; mvN += p.mvN; rgN += p.rgN; epochs += p.epochs
        hrS += p.hrS; hvS += p.hvS; mvS += p.mvS; rgS += p.rgS
        hrQ += p.hrQ; hvQ += p.hvQ; mvQ += p.mvQ; rgQ += p.rgQ
        flat += p.flat; spans.append(p.span)
    }
    var knots: [Double] = []
    if flat.count >= 8 {
        let s = flat.sorted()
        for i in 0...100 {
            let pos = Double(i) / 100.0 * Double(s.count - 1)
            let lo = Int(pos.rounded(.down)), hi = min(s.count - 1, lo + 1)
            knots.append(s[lo] + (pos - Double(lo)) * (s[hi] - s[lo]))
        }
    }
    let typical: Int = {
        if spans.isEmpty { return cold.typicalSessionSec }
        let s = spans.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }()
    return PersonalSleepPriors(
        hr: stat(hrN, hrS, hrQ, cold.hr), hrVar: stat(hvN, hvS, hvQ, cold.hrVar),
        moveFrac: stat(mvN, mvS, mvQ, cold.moveFrac), respReg: stat(rgN, rgS, rgQ, cold.respReg),
        jerkFloor: jerkFloor, hrFlat11Quantiles: knots, typicalSessionSec: typical,
        nightsUsed: parts.count, epochsUsed: epochs)
}

func medianOf(_ v: [Double]) -> Double {
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
}

func runLive(_ nt: Night, priors: PersonalSleepPriors, until: Int? = nil,
             lookahead: Int = 0) -> [LiveStageDecision] {
    var cfg = LiveSleepStager.Config()
    cfg.extractor.lookaheadSec = lookahead
    let s = LiveSleepStager(priors: priors, sessionStart: nt.row.startTs, config: cfg)
    let end = until ?? nt.row.endTs
    // Feed in wall-clock order, one epoch's worth at a time, exactly as BLE would deliver it.
    var t = nt.row.startTs
    var hi = 0, ri = 0, gi = 0
    let hrS = nt.st.hr, rrS = nt.st.rr, gvS = nt.st.grav
    while t < end + 30 {
        let bound = t + 30
        var h: [HRSample] = []; while hi < hrS.count && hrS[hi].ts < bound { h.append(hrS[hi]); hi += 1 }
        var r: [RRInterval] = []; while ri < rrS.count && rrS[ri].ts < bound { r.append(rrS[ri]); ri += 1 }
        var g: [GravitySample] = []; while gi < gvS.count && gvS[gi].ts < bound { g.append(gvS[gi]); gi += 1 }
        if !h.isEmpty { s.ingest(hr: h) }
        if !r.isEmpty { s.ingest(rr: r) }
        if !g.isEmpty { s.ingest(gravity: g) }
        s.advance(to: bound)
        t = bound
    }
    return s.decisions
}

// Per-night jerk floors — pass A, computed once. Every fold's floor is a median over a subset of these.
FileHandle.standardError.write(Data("pass A: per-night jerk floors…\n".utf8))
var nightFloor: [Int: Double] = [:]
for nt in nights { if let f = perNightJerkFloor(nt) { nightFloor[nt.row.startTs] = f } }

func looFloor(excluding skip: Int?) -> Double {
    let v = nights.compactMap { $0.row.startTs == skip ? nil : nightFloor[$0.row.startTs] }
    return v.isEmpty ? cold.jerkFloor : medianOf(v)
}

// Pass B, cached by floor: every fold sharing a floor reuses one extraction of all 36 nights.
var statsCache: [Double: [Int: NightStats]] = [:]
func statsFor(floor: Double) -> [Int: NightStats] {
    if let c = statsCache[floor] { return c }
    FileHandle.standardError.write(Data("pass B: extracting all nights at jerkFloor \(floor)…\n".utf8))
    var m: [Int: NightStats] = [:]
    for nt in nights { m[nt.row.startTs] = extractStats(nt, jerkFloor: floor) }
    statsCache[floor] = m
    return m
}

func makePriors(excluding skip: Int?) -> PersonalSleepPriors {
    let floor = looFloor(excluding: skip)
    let all = statsFor(floor: floor)
    let parts = nights.compactMap { $0.row.startTs == skip ? nil : all[$0.row.startTs] }
    return poolPriors(parts, jerkFloor: floor)
}

let distinctFloors = Set(nights.map { looFloor(excluding: $0.row.startTs) }).count
FileHandle.standardError.write(Data("\(nights.count) folds share \(distinctFloors) distinct jerk floor(s)\n".utf8))

// Global priors for the causality check (the check is about the extractor, not the priors).
let globalPriors = makePriors(excluding: nil)

// The cache above claims to be a caching strategy and not an approximation. Check it rather than assert
// it: the pooled all-nights prior must equal what `calibrate` produces directly on the same nights.
let direct = PersonalSleepPriors.calibrate(nights: nights.map {
    PersonalSleepPriors.CalibrationNight(start: $0.row.startTs, end: $0.row.endTs,
                                         hr: $0.st.hr, rr: $0.st.rr, gravity: $0.st.grav)
})
func relGap(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b), s = max(abs(a), abs(b))
    return s == 0 ? d : d / s
}
let gaps = [relGap(globalPriors.hr.mean, direct.hr.mean), relGap(globalPriors.hr.sd, direct.hr.sd),
            relGap(globalPriors.hrVar.mean, direct.hrVar.mean),
            relGap(globalPriors.moveFrac.mean, direct.moveFrac.mean),
            relGap(globalPriors.jerkFloor, direct.jerkFloor)]
let worst = gaps.max() ?? 0
print("""
  PRIOR-CACHE SELF-CHECK (the LOO cache must not change the prior, only its cost)
    epochsUsed pooled \(globalPriors.epochsUsed) vs direct \(direct.epochsUsed)  \
\(globalPriors.epochsUsed == direct.epochsUsed ? "MATCH" : "DIFFER")
    jerkFloor  \(globalPriors.jerkFloor == direct.jerkFloor ? "exact match" : "differs")
    worst relative gap across pooled mean/sd/floor: \(String(format: "%.2e", worst))  \
\(worst < 1e-9 ? "— float summation order only, not a methodological difference" : "— TOO LARGE, investigate")
""")
var leaks = 0, comparedEpochs = 0, checkedNights = 0
for nt in nights.prefix(12) {
    let full = runLive(nt, priors: globalPriors)
    var byStart: [Int: LiveStageDecision] = [:]
    for d in full { byStart[d.epochStart] = d }
    checkedNights += 1
    for frac in [0.25, 0.5, 0.75] {
        let cut = nt.row.startTs + Int(Double(nt.row.endTs - nt.row.startTs) * frac)
        let part = runLive(nt, priors: globalPriors, until: cut)
        for d in part {
            guard let ref = byStart[d.epochStart] else { continue }
            comparedEpochs += 1
            if ref.stage != d.stage || abs(ref.remProbability - d.remProbability) > 1e-12 { leaks += 1 }
        }
    }
}
print("""
  nights checked \(checkedNights)   epochs re-decided from truncated input \(comparedEpochs)   MISMATCHES \(leaks)
  \(leaks == 0 ? "PASS — no epoch's decision changed when the future was removed." : "FAIL — the stager reads the future.")
""")

if onlyCausality { exit(0) }

// MARK: - Section 3: live vs references

print("""

================================================================================
3. LIVE STAGER vs EVERY AVAILABLE REFERENCE   (priors calibrated LEAVE-ONE-NIGHT-OUT)
================================================================================
The prior is recalibrated for every night with THAT night held out, so no night is scored against a prior
that has seen it.
""")

struct Res {
    var name = ""
    var n = 0
    var kV2 = Double.nan, accV2 = Double.nan, remF1V2 = Double.nan
    var kStored = Double.nan, remF1Stored = Double.nan
    var kBand = Double.nan
    var v2RemPct = Double.nan, liveRemPct = Double.nan
    var locked = false
    var hasBand = false
}
var results: [Res] = []
var liveAll: [String] = [], v2All: [String] = []
var liveLocked: [String] = [], storedLocked: [String] = []
var liveBand: [String] = [], bandAll: [String] = []
// REM-latency records
struct Lat { let night: String; let bout: Int; let delayMin: Double?; let boutMin: Double }
var lats: [Lat] = []
var decisionsByNight: [String: [LiveStageDecision]] = [:]

for nt in nights {
    FileHandle.standardError.write(Data("scoring \(nt.name)…\n".utf8))
    let pri = makePriors(excluding: nt.row.startTs)
    let dec = runLive(nt, priors: pri)
    guard !dec.isEmpty else { continue }
    decisionsByNight[nt.name + "@\(nt.row.startTs)"] = dec

    // Align decisions onto the same epoch grid the references use.
    var live = [String](repeating: "wake", count: nt.n)
    var remP = [Double](repeating: 0, count: nt.n)
    for d in dec {
        let i = Int((Double(d.epochStart - nt.row.startTs) / epochS).rounded(.down))
        if i >= 0 && i < nt.n { live[i] = d.stage; remP[i] = d.remProbability }
    }

    var r = Res()
    r.name = nt.name; r.n = nt.n
    r.locked = stageLocked.contains(nt.row.startTs)
    r.kV2 = kappa(live, nt.v2, classes: stageOrder)
    r.accV2 = accuracy(live, nt.v2)
    r.remF1V2 = f1(live, nt.v2, cls: "rem")
    r.v2RemPct = Double(nt.v2.filter { $0 == "rem" }.count) / Double(nt.n)
    r.liveRemPct = Double(live.filter { $0 == "rem" }.count) / Double(nt.n)
    liveAll += live; v2All += nt.v2

    if r.locked {
        r.kStored = kappa(live, nt.stored, classes: stageOrder)
        r.remF1Stored = f1(live, nt.stored, cls: "rem")
        liveLocked += live; storedLocked += nt.stored
    }
    if !nt.bandEpochs.isEmpty {
        r.hasBand = true
        // Band: 0 wake / 1 still / 2 asleep / 3 up. Only 2 is unambiguously "asleep"; 0 and 3 are
        // unambiguously "not asleep". 1 ("still") is NOT a sleep claim, so those epochs are dropped
        // rather than guessed.
        var lb: [String] = [], rb: [String] = []
        for i in 0..<nt.n {
            let b = nt.bandEpochs[i]
            guard b == 0 || b == 2 || b == 3 else { continue }
            rb.append(b == 2 ? "sleep" : "wake")
            lb.append(live[i] == "wake" ? "wake" : "sleep")
        }
        if !lb.isEmpty {
            r.kBand = kappa(lb, rb, classes: ["wake", "sleep"])
            liveBand += lb; bandAll += rb
        }
    }
    results.append(r)

    // REM-cue latency against V2's REM bouts (the only per-epoch REM signal that exists).
    var i = 0
    var bout = 0
    while i < nt.n {
        guard nt.v2[i] == "rem" else { i += 1; continue }
        var j = i
        while j < nt.n && nt.v2[j] == "rem" { j += 1 }
        let lenMin = Double(j - i) * epochS / 60.0
        if lenMin >= 3.0 {   // ignore 1-2 epoch specks; a cue would never target them
            bout += 1
            var fired: Double? = nil
            for k in i..<min(nt.n, j + 20) where remP[k] >= remThreshold {
                fired = Double(k - i) * epochS / 60.0; break
            }
            lats.append(Lat(night: nt.name, bout: bout, delayMin: fired, boutMin: lenMin))
        }
        i = j
    }
}

print("""
  night          epochs   vs V2: acc   kappa   REM F1  |  vs BAND sleep/wake kappa  |  vs STORED kappa  REM F1
""")
for r in results {
    let bandS = r.hasBand ? String(format: "%22s", (f(r.kBand) as NSString).utf8String!) : "                   n/a"
    let stS = r.locked ? "        \(f(r.kStored))   \(f(r.remF1Stored))" : "            n/a      n/a"
    print("  \(r.name)  \(String(format: "%8d", r.n))      \(pct(r.accV2))   \(f(r.kV2))   \(f(r.remF1V2))  |\(bandS)  |\(stS)")
}

print("""

  POOLED (all epochs, every night)
    vs V2 (teacher, NOT truth) 4-class acc \(pct(accuracy(liveAll, v2All)))  kappa \(f(kappa(liveAll, v2All, classes: stageOrder)))  \
REM F1 \(f(f1(liveAll, v2All, cls: "rem")))   epochs \(liveAll.count)
    vs BAND sleep_state        sleep/wake kappa \(f(kappa(liveBand, bandAll, classes: ["wake", "sleep"])))   \
acc \(pct(accuracy(liveBand, bandAll)))   epochs \(liveBand.count)
    vs STORED stage-locked     4-class kappa \(f(kappa(liveLocked, storedLocked, classes: stageOrder)))  \
REM F1 \(f(f1(liveLocked, storedLocked, cls: "rem")))   epochs \(liveLocked.count)
      ^ contaminated — see section 1. Reported for completeness only.
""")

// Also: V2 vs band, as the incumbent's own score on the ONE uncontaminated reference.
var v2Band: [String] = [], bandRef2: [String] = []
for nt in nights where !nt.bandEpochs.isEmpty {
    for i in 0..<nt.n {
        let b = nt.bandEpochs[i]
        guard b == 0 || b == 2 || b == 3 else { continue }
        bandRef2.append(b == 2 ? "sleep" : "wake")
        v2Band.append(nt.v2[i] == "wake" ? "wake" : "sleep")
    }
}
print("""
  INCUMBENT ON THE SAME UNCONTAMINATED REFERENCE
    V2 (non-causal)  vs BAND sleep/wake kappa \(f(kappa(v2Band, bandRef2, classes: ["wake", "sleep"])))   \
acc \(pct(accuracy(v2Band, bandRef2)))   epochs \(v2Band.count)
""")

// MARK: - Section 4: REM cue latency

print("""

================================================================================
4. REM-CUE LATENCY — minutes after a REM period starts before P(REM) crosses \(f(remThreshold, 2))
================================================================================
For a lucid-dream cue this is the number that matters. The reference REM bouts are V2's, which is a
TEACHER and not truth: this measures how far the causal filter LAGS the non-causal one, not how far it
lags physiology. Bouts shorter than 3 min are ignored. A bout is a MISS when P(REM) never crosses inside
the bout or the 10 min after it.
""")
let hit = lats.compactMap { $0.delayMin }
let missCount = lats.filter { $0.delayMin == nil }.count
print("""
  REM bouts (>= 3 min, V2)  \(lats.count)   fired \(hit.count)   missed \(missCount)   \
hit rate \(pct(lats.isEmpty ? .nan : Double(hit.count) / Double(lats.count)))
  delay (min)   median \(f(median(hit), 1))   mean \(f(mean(hit), 1))   p10 \(f(quantile(hit, 0.1), 1))   \
p90 \(f(quantile(hit, 0.9), 1))   max \(f(hit.max() ?? .nan, 1))
  bout length (min)  median \(f(median(lats.map { $0.boutMin }), 1))   \
p10 \(f(quantile(lats.map { $0.boutMin }, 0.1), 1))
""")
// How much of the bout is left when the cue fires — the usable-window question.
var usable: [Double] = []
for l in lats { if let d = l.delayMin, d < l.boutMin { usable.append(l.boutMin - d) } }
print("""
  REM remaining at cue time (min)   median \(f(median(usable), 1))   p10 \(f(quantile(usable, 0.1), 1))   \
bouts with >= 5 min left \(usable.filter { $0 >= 5 }.count) of \(lats.count)
""")

// First-REM-of-night latency: the cue a lucid-dream protocol actually targets is late-night REM.
var firstRem: [Double] = []
for l in lats where l.bout == 1 { if let d = l.delayMin { firstRem.append(d) } }
print("  first REM bout of the night: fired on \(firstRem.count) nights, median delay \(f(median(firstRem), 1)) min")

print("""

================================================================================
5. FALSE-POSITIVE RATE — how often P(REM) crosses when V2 says NOT REM
================================================================================
A haptic cue that fires in NREM wakes the sleeper for nothing. Measured per epoch over all nights.
""")
var fpEpochs = 0, nonRemEpochs = 0, tpEpochs = 0, remEpochs = 0
for nt in nights {
    guard let dec = decisionsByNight[nt.name + "@\(nt.row.startTs)"] else { continue }
    var remP = [Double](repeating: 0, count: nt.n)
    for d in dec {
        let i = Int((Double(d.epochStart - nt.row.startTs) / epochS).rounded(.down))
        if i >= 0 && i < nt.n { remP[i] = d.remProbability }
    }
    for i in 0..<nt.n {
        if nt.v2[i] == "rem" { remEpochs += 1; if remP[i] >= remThreshold { tpEpochs += 1 } }
        else { nonRemEpochs += 1; if remP[i] >= remThreshold { fpEpochs += 1 } }
    }
}
print("""
  P(REM) >= \(f(remThreshold, 2)) on \(fpEpochs) of \(nonRemEpochs) non-REM epochs   \
false-positive rate \(pct(Double(fpEpochs) / Double(max(1, nonRemEpochs))))
  P(REM) >= \(f(remThreshold, 2)) on \(tpEpochs) of \(remEpochs) REM epochs   \
recall \(pct(Double(tpEpochs) / Double(max(1, remEpochs))))
""")

// MARK: - Section 6: an actual cue POLICY, not a bare threshold

print("""

================================================================================
6. CUE POLICY SWEEP — what a real haptic trigger would do
================================================================================
A bare per-epoch threshold is not a policy. A cue fires at most once per REFRACTORY window and only after
P(REM) has held above the threshold for `sustain` consecutive epochs. Scored per NIGHT, the way the wearer
would experience it: how many buzzes land in V2-REM, how many land outside it, and how long after the REM
period began. `\(Int(refractoryMin))` min refractory. Bouts >= 3 min only, as above.
  thr  sustain   cues/night   in-REM   outside-REM   precision   bouts hit   median delay
""")
for thr in [0.50, 0.60, 0.70, 0.80] {
    for sustain in [1, 2, 4, 6] {
        var inRem = 0, outRem = 0, delays: [Double] = []
        var boutsTotal = 0, boutsHit = 0
        for nt in nights {
            guard let dec = decisionsByNight[nt.name + "@\(nt.row.startTs)"] else { continue }
            var remP = [Double](repeating: 0, count: nt.n)
            for d in dec {
                let i = Int((Double(d.epochStart - nt.row.startTs) / epochS).rounded(.down))
                if i >= 0 && i < nt.n { remP[i] = d.remProbability }
            }
            // Fire the policy across the night.
            var run = 0
            var lastFire = -99999
            var fires: [Int] = []
            for i in 0..<nt.n {
                run = remP[i] >= thr ? run + 1 : 0
                if run >= sustain && (i - lastFire) * Int(epochS) >= Int(refractoryMin * 60) {
                    fires.append(i); lastFire = i
                }
            }
            for i in fires { if nt.v2[i] == "rem" { inRem += 1 } else { outRem += 1 } }
            // Bout coverage + delay.
            var i = 0
            while i < nt.n {
                guard nt.v2[i] == "rem" else { i += 1; continue }
                var j = i
                while j < nt.n && nt.v2[j] == "rem" { j += 1 }
                if Double(j - i) * epochS / 60.0 >= 3.0 {
                    boutsTotal += 1
                    if let hitIdx = fires.first(where: { $0 >= i && $0 < j }) {
                        boutsHit += 1
                        delays.append(Double(hitIdx - i) * epochS / 60.0)
                    }
                }
                i = j
            }
        }
        let total = inRem + outRem
        let prec = total == 0 ? Double.nan : Double(inRem) / Double(total)
        print("  \(f(thr, 2))   \(String(format: "%5d", sustain))   \(String(format: "%10.1f", Double(total) / Double(nights.count)))   \(String(format: "%6d", inRem))   \(String(format: "%11d", outRem))   \(String(format: "%9s", (pct(prec) as NSString).utf8String!))   \(String(format: "%4d", boutsHit))/\(String(format: "%-4d", boutsTotal))   \(f(median(delays), 1)) min")
    }
}
