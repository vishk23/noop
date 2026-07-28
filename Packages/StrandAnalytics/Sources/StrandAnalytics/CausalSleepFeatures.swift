import Foundation
import WhoopProtocol

// CausalSleepFeatures.swift — the STREAMING half of live sleep staging.
//
// `SleepStagerV2` stages a night AFTER it is over. That is an architectural choice, not a data
// dependency: every input it reads (HR, R-R, gravity) arrives per-second over BLE while the wearer is
// asleep. What actually blocks live staging is that V2 normalises against the WHOLE night — it z-scores
// each feature over the night's own epochs, ranks HR-flatness as a percentile within the night, scales
// motion by the night's median jerk, and reads centred windows that extend up to 390 s into the future.
// At 02:00 none of that exists yet.
//
// This file removes every one of those dependencies. Each is replaced either by a TRAILING window (same
// window LENGTH, shifted to end at the epoch boundary) or by a PERSONAL PRIOR learned from the wearer's
// own completed nights (`PersonalSleepPriors`), optionally blended with what tonight has shown so far.
//
// The load-bearing property, and the one the tests pin: an epoch's features are a pure function of
// samples with `ts < epochEnd + lookaheadSec`. Feeding a truncated night must produce byte-identical
// features for every epoch the truncation still covers. Nothing here may consult the future.

// MARK: - Streaming quantile

/// Deterministic streaming quantile over positive values on a fixed log-spaced bin grid.
///
/// The night's quiescent jerk floor is a MEDIAN, which normally needs the whole sample kept and sorted.
/// Live we need it incrementally and cheaply, and — critically for the no-lookahead test — DETERMINISTICALLY:
/// a reservoir or a randomised sketch would make the same night replay differently. A fixed log-spaced
/// histogram is exact in its bin index and so replays identically. 800 bins over [1e-7, 1e1] is 0.01
/// decades per bin ≈ 2.3 % relative resolution on the recovered quantile — far finer than the ×75 / ×35
/// multipliers the floor feeds, whose thresholds sit decades away from the floor itself.
struct LogHistogram: Equatable, Sendable, Codable {
    static let loLog = -7.0
    static let hiLog = 1.0
    static let bins = 800
    static let step = (hiLog - loLog) / Double(bins)

    private(set) var counts: [Int]
    private(set) var total: Int

    init() { counts = [Int](repeating: 0, count: Self.bins); total = 0 }

    static func binIndex(_ v: Double) -> Int {
        if !(v > 0) { return 0 }
        let l = log10(v)
        if l <= loLog { return 0 }
        if l >= hiLog { return bins - 1 }
        return min(bins - 1, max(0, Int((l - loLog) / step)))
    }

    mutating func add(_ v: Double) { counts[Self.binIndex(v)] += 1; total += 1 }

    /// Value at quantile `q` — the geometric centre of the bin the cumulative count crosses.
    /// Returns nil when nothing has been observed.
    func quantile(_ q: Double) -> Double? {
        if total == 0 { return nil }
        let target = max(0.0, min(1.0, q)) * Double(total)
        var cum = 0
        for b in 0..<Self.bins {
            cum += counts[b]
            if Double(cum) >= target {
                return pow(10.0, Self.loLog + (Double(b) + 0.5) * Self.step)
            }
        }
        return pow(10.0, Self.loLog + (Double(Self.bins) - 0.5) * Self.step)
    }

    /// Fraction of observations at or below `v` — the empirical CDF, i.e. a percentile rank.
    func percentileOf(_ v: Double) -> Double? {
        if total == 0 { return nil }
        let b = Self.binIndex(v)
        var cum = 0
        for i in 0...b { cum += counts[i] }
        return Double(cum) / Double(total)
    }
}

/// Exact O(1) running mean / population std. Used for the "what has tonight looked like so far" half of
/// every adaptive z-score.
struct RunningMoments: Equatable, Sendable, Codable {
    private(set) var n: Int = 0
    private(set) var sum: Double = 0
    private(set) var sumSq: Double = 0

    mutating func add(_ v: Double) { n += 1; sum += v; sumSq += v * v }

    var mean: Double? { n == 0 ? nil : sum / Double(n) }
    /// Population std (÷n), matching `SleepStagerV2.stageEpochs`'s `zfun`. nil below 2 observations.
    var sd: Double? {
        if n < 2 { return nil }
        let m = sum / Double(n)
        let v = sumSq / Double(n) - m * m
        return (v < 0 ? 0 : v).squareRoot()
    }
}

// MARK: - Personal priors

/// A mean/std pair a z-score can be taken against.
public struct NormStat: Equatable, Sendable, Codable {
    public var mean: Double
    public var sd: Double
    public init(mean: Double, sd: Double) { self.mean = mean; self.sd = max(sd, 1e-9) }
    /// Neutral: everything z-scores to 0, so a channel with no prior never votes.
    public static let neutral = NormStat(mean: 0, sd: 1)
    public func z(_ v: Double?) -> Double { v == nil ? 0.0 : (v! - mean) / sd }
}

/// What `SleepStagerV2` learns from the night it is staging, learned instead from the wearer's own
/// COMPLETED nights. This is the artefact that makes live staging possible: with it, epoch 1 of a new
/// night can be scored against the same distribution V2 would only know by 08:00.
///
/// Calibrate with `PersonalSleepPriors.calibrate` over historical sessions; persist and refresh
/// periodically. Health data never leaves the device — these are summary statistics of the wearer's own
/// nights, computed on-device from the same store the stager already reads.
public struct PersonalSleepPriors: Equatable, Sendable, Codable {
    /// Distribution of epoch-mean HR across the wearer's nights (replaces V2's per-night `zhr`).
    public var hr: NormStat
    /// Distribution of the trailing 5-min HR std (replaces `zhv`).
    public var hrVar: NormStat
    /// Distribution of the per-epoch move fraction (replaces `zmv`).
    public var moveFrac: NormStat
    /// Distribution of RSA respiration regularity (replaces `zrg`).
    public var respReg: NormStat
    /// Quiescent gravity-jerk floor: the median of the wearer's per-night jerk medians. Replaces the
    /// whole-night `jerkScale`, and carries the strap's gravity-decode scale + this wearer's fit.
    public var jerkFloor: Double
    /// 101 quantile knots (q = 0.00 … 1.00) of the trailing 11-min HR-flatness statistic. Replaces V2's
    /// within-night percentile rank that drives the deep gate.
    public var hrFlat11Quantiles: [Double]
    /// Median total time in bed across calibration nights, in seconds. Replaces V2's `clock`, which needs
    /// the night's END to normalise elapsed time into [0, 1].
    public var typicalSessionSec: Int
    public var nightsUsed: Int
    public var epochsUsed: Int

    public init(hr: NormStat, hrVar: NormStat, moveFrac: NormStat, respReg: NormStat,
                jerkFloor: Double, hrFlat11Quantiles: [Double], typicalSessionSec: Int,
                nightsUsed: Int, epochsUsed: Int) {
        self.hr = hr; self.hrVar = hrVar; self.moveFrac = moveFrac; self.respReg = respReg
        self.jerkFloor = jerkFloor; self.hrFlat11Quantiles = hrFlat11Quantiles
        self.typicalSessionSec = typicalSessionSec
        self.nightsUsed = nightsUsed; self.epochsUsed = epochsUsed
    }

    /// A cold-start prior for a wearer with no staged history: population-plausible centres, wide spreads,
    /// and a jerk floor at the middle of the range WHOOP gravity decode produces. Deliberately vague — the
    /// point is that it degrades to "no strong opinion" rather than to a confidently wrong one.
    public static let coldStart = PersonalSleepPriors(
        hr: NormStat(mean: 60, sd: 8),
        hrVar: NormStat(mean: 3.0, sd: 2.0),
        moveFrac: NormStat(mean: 0.05, sd: 0.12),
        respReg: NormStat(mean: 0.25, sd: 0.12),
        jerkFloor: 0.004,
        hrFlat11Quantiles: [],
        typicalSessionSec: 7 * 3600,
        nightsUsed: 0, epochsUsed: 0)

    /// Percentile rank of an 11-min HR-flatness value against the wearer's own history, by linear
    /// interpolation between the stored quantile knots. Neutral 0.5 when there are no knots — the same
    /// "missing → centre" convention V2 uses.
    public func hrFlat11Percentile(_ v: Double?) -> Double {
        guard let v = v, hrFlat11Quantiles.count >= 2 else { return 0.5 }
        let q = hrFlat11Quantiles
        if v <= q.first! { return 0.0 }
        if v >= q.last! { return 1.0 }
        var lo = 0, hi = q.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if q[mid] <= v { lo = mid } else { hi = mid }
        }
        let span = q[hi] - q[lo]
        let frac = span <= 0 ? 0.0 : (v - q[lo]) / span
        return (Double(lo) + frac) / Double(q.count - 1)
    }
}

// MARK: - Causal epoch features

/// One 30 s epoch's features, computed from PAST data only. Field-for-field the same set
/// `SleepStagerV2.Epoch` carries, so the same emission recipe can consume either.
public struct CausalSleepEpoch: Equatable, Sendable, Codable {
    public let start: Int
    /// Epoch-mean HR (bpm), nil when the epoch had no HR sample.
    public let hr: Double?
    /// Std of per-second HR over the TRAILING 330 s (V2 reads the same 330 s centred).
    public let hrVar: Double?
    /// Std of per-second HR over the TRAILING 720 s (V2 reads the same 720 s centred).
    public let hrFlat11: Double?
    /// Fraction of in-epoch per-second jerks above the move threshold.
    public let moveFrac: Double
    /// Peak in-epoch per-second jerk (g).
    public let jerkMax: Double
    /// RSA spectral peakedness over the TRAILING 210 s of beats (V2 reads the same 210 s centred).
    public let respReg: Double?
    /// Elapsed fraction of the wearer's TYPICAL session length, clamped to [0, 1]. V2 divides by the
    /// night's actual span, which is unknown until the wearer wakes.
    public let clock: Double
    /// The jerk floor actually used for this epoch (prior, or prior blended with tonight so far).
    public let jerkScale: Double
    /// Seconds elapsed since session start at this epoch's midpoint — lets a caller reason about how far
    /// into the night a decision was made without re-deriving it.
    public let elapsedSec: Int

    /// PHASIC TWITCH RATE. Fraction of in-epoch per-second jerks that land ABOVE the quiescent floor but
    /// BELOW the "gross movement" threshold — brief distal bursts that break through muscle atonia. REM is
    /// the only stage that pairs near-total atonia with these breakthroughs, so this separates REM from
    /// quiet NREM in a way `moveFrac` (which counts only gross movement) cannot.
    public let twitchRate: Double
    /// RESPIRATORY IRREGULARITY. Coefficient of variation of the RSA regularity statistic over the trailing
    /// ~5 min. NREM is parasympathetic-dominant with strong, steady RSA; REM breathing is erratic. Taking
    /// the VARIANCE rather than the level is what makes this a REM marker instead of a depth marker.
    /// nil until enough consecutive epochs have carried a respiration estimate.
    public let respRegCV: Double?

    public init(start: Int, hr: Double?, hrVar: Double?, hrFlat11: Double?, moveFrac: Double,
                jerkMax: Double, respReg: Double?, clock: Double, jerkScale: Double, elapsedSec: Int,
                twitchRate: Double = 0, respRegCV: Double? = nil) {
        self.start = start; self.hr = hr; self.hrVar = hrVar; self.hrFlat11 = hrFlat11
        self.moveFrac = moveFrac; self.jerkMax = jerkMax; self.respReg = respReg
        self.clock = clock; self.jerkScale = jerkScale; self.elapsedSec = elapsedSec
        self.twitchRate = twitchRate; self.respRegCV = respRegCV
    }
}

/// A closed epoch plus the normalised view captured at the instant it closed. The pair travels together
/// so a batched `advance` can never normalise an early epoch against a later one's statistics.
public struct CausalSleepEpochSample: Equatable, Sendable {
    public let epoch: CausalSleepEpoch
    public let normalised: CausalSleepFeatureExtractor.Normalised
}

/// Incremental, strictly-causal producer of `CausalSleepEpoch`s.
///
/// Feed it samples as they arrive (`ingest`), then call `advance(to:)` with the current wall clock; it
/// returns every epoch whose read window has fully closed. It retains only the seconds a future epoch can
/// still read (~13 min of per-second HR, 30 s of gravity, 4 min of beats), so memory is flat over a night
/// regardless of length.
public final class CausalSleepFeatureExtractor {

    public struct Config: Equatable, Sendable, Codable {
        /// Seconds of *bounded* lookahead the caller is willing to wait before an epoch is scored. 0 is
        /// strictly causal — the epoch is scored the instant it closes. A live cueing system can afford
        /// some latency (REM periods run 10–30 min), and every window recentres by this much, so this
        /// trades decision latency directly against agreement with the centred-window post-hoc stager.
        public var lookaheadSec: Int = 0
        /// How much of tonight's own data is blended into the priors, and how fast. At `t` seconds into
        /// the session the weight on tonight is `min(1, t / adaptFullSec)`; the remainder stays on the
        /// personal prior. 0 disables adaptation (pure prior). This partially recovers V2's per-night
        /// re-centring — which is what protects it when a night sits uniformly off the wearer's baseline.
        public var adaptFullSec: Int = 3 * 3600
        /// When set, the jerk floor is FIXED to this value instead of blended. Used by calibration's
        /// second pass, so the pooled `moveFrac` statistics are taken against the same threshold live
        /// inference will use.
        public var fixedJerkScale: Double? = nil

        public init(lookaheadSec: Int = 0, adaptFullSec: Int = 3 * 3600,
                    fixedJerkScale: Double? = nil) {
            self.lookaheadSec = lookaheadSec
            self.adaptFullSec = adaptFullSec
            self.fixedJerkScale = fixedJerkScale
        }
    }

    /// Trailing window LENGTHS, in seconds — identical to the spans `SleepStagerV2.features` reads,
    /// only shifted to end at the epoch boundary instead of straddling it.
    static let hrVarWindow = 330    // V2: [e-150, e+180)
    static let hrFlatWindow = 720   // V2: [e-330, e+390)
    static let rsaWindow = 210      // V2: [e-90,  e+120)
    static let epochSec = 30
    /// Lower edge of the phasic-twitch band, as a multiple of the quiescent jerk floor. Sits well clear of
    /// the decode noise floor and well below `jerkFloorMoveMult` (gross movement), so the band captures
    /// breakthroughs rather than either noise or postural shifts.
    static let twitchFloorMult = 8.0
    /// Epochs of history behind the respiratory-irregularity CV (~5 min).
    static let respCVWindow = 10

    public let config: Config
    private let priors: PersonalSleepPriors
    private let sessionStart: Int

    // Per-second aggregation buffers, pruned to what a not-yet-emitted epoch can still read.
    private var hrSum: [Int: Double] = [:]
    private var hrCnt: [Int: Int] = [:]
    private var gSum: [Int: (Double, Double, Double)] = [:]
    private var gCnt: [Int: Int] = [:]
    private var rrBy: [Int: [Double]] = [:]

    // Tonight-so-far state. All of it is a function of already-observed seconds.
    private var jerkHist = LogHistogram()
    private var hrMoments = RunningMoments()
    private var hrVarMoments = RunningMoments()
    private var moveFracMoments = RunningMoments()
    private var respRegMoments = RunningMoments()
    private var hrFlatHist = LogHistogram()
    private var respRegRing: [Double] = []

    private var nextEpoch: Int

    public init(priors: PersonalSleepPriors, sessionStart: Int, config: Config = Config()) {
        self.priors = priors
        self.sessionStart = sessionStart
        self.config = config
        // First 30 s-aligned epoch at or after the session start — the same grid V2 tiles.
        self.nextEpoch = ((sessionStart + Self.epochSec - 1) / Self.epochSec) * Self.epochSec
    }

    /// Oldest second any epoch still to be emitted can read. Everything before it is unreachable and gets
    /// dropped. Derived from `nextEpoch`, never from the wall clock, so pruning can never race emission.
    private var oldestReadableSecond: Int {
        nextEpoch + Self.epochSec + config.lookaheadSec - Self.hrFlatWindow
    }

    public func ingest(hr samples: [HRSample]) {
        let floor = oldestReadableSecond
        for s in samples where s.ts >= floor {
            hrSum[s.ts, default: 0] += Double(s.bpm)
            hrCnt[s.ts, default: 0] += 1
        }
    }

    public func ingest(gravity samples: [GravitySample]) {
        let floor = oldestReadableSecond
        for g in samples where g.ts >= floor {
            var acc = gSum[g.ts] ?? (0, 0, 0)
            acc.0 += g.x; acc.1 += g.y; acc.2 += g.z
            gSum[g.ts] = acc
            gCnt[g.ts, default: 0] += 1
        }
    }

    public func ingest(rr samples: [RRInterval]) {
        let floor = oldestReadableSecond
        for r in samples where r.ts >= floor {
            rrBy[r.ts, default: []].append(Double(r.rrMs))
        }
    }

    /// Emit every epoch whose read window has closed by `now`. Epochs come out in time order; an epoch is
    /// emitted at most once. An epoch with neither an HR nor a gravity sample is SKIPPED, matching V2.
    ///
    /// The normalised view is captured AT CLOSE, not derived afterwards. That distinction is load-bearing:
    /// a caller that advances past several epochs in one go (a BLE gap, a resumed connection) would
    /// otherwise normalise the first of them against running statistics that already include the last —
    /// a lookahead leak of exactly the kind this class exists to prevent.
    @discardableResult
    public func advance(to now: Int) -> [CausalSleepEpochSample] {
        var out: [CausalSleepEpochSample] = []
        while nextEpoch + Self.epochSec + config.lookaheadSec <= now {
            if let f = closeEpoch(nextEpoch) { out.append(f) }
            nextEpoch += Self.epochSec
            prune()
        }
        return out
    }

    /// Build the features for `[e, e+30)`. Reads only seconds `< e + 30 + lookaheadSec`.
    private func closeEpoch(_ e: Int) -> CausalSleepEpochSample? {
        let readEnd = e + Self.epochSec + config.lookaheadSec

        // In-epoch per-second HR and gravity, exactly V2's [e, e+30) scan.
        var hrs: [Double] = []
        var gseq: [(Double, Double, Double)] = []
        for s in e..<(e + Self.epochSec) {
            if let sum = hrSum[s], let c = hrCnt[s] { hrs.append(sum / Double(c)) }
            if let sum = gSum[s], let c = gCnt[s] {
                let d = Double(c); gseq.append((sum.0 / d, sum.1 / d, sum.2 / d))
            }
        }
        if hrs.isEmpty && gseq.isEmpty { return nil }   // no coverage → skip, as V2 does

        // Movement: L2 distance between consecutive present per-second gravity vectors, within the epoch.
        var jerks: [Double] = []
        if gseq.count >= 2 {
            for i in 1..<gseq.count {
                let a = gseq[i - 1], b = gseq[i]
                let dx = a.0 - b.0, dy = a.1 - b.1, dz = a.2 - b.2
                jerks.append((dx * dx + dy * dy + dz * dz).squareRoot())
            }
        }
        // This epoch's jerks are PAST data by the time the epoch closes, so folding them in before
        // thresholding is causal — and it matches V2, which pools every jerk in the night.
        for j in jerks { jerkHist.add(j) }
        let jerkMax = jerks.max() ?? 0.0

        let elapsed = e + Self.epochSec / 2 - sessionStart
        let w = adaptWeight(elapsedSec: elapsed)

        let jerkScale = resolvedJerkScale(blend: w)
        let moveThr = jerkScale * SleepStagerV2.jerkFloorMoveMult
        let moves = jerks.reduce(0) { $0 + ($1 > moveThr ? 1 : 0) }
        let moveFrac = Double(moves) / Double(max(1, gseq.count - 1))
        // Phasic band: clearly above the strap's own noise floor, but not gross movement.
        let twitchLo = jerkScale * Self.twitchFloorMult
        let twitches = jerks.reduce(0) { $0 + (($1 > twitchLo && $1 <= moveThr) ? 1 : 0) }
        let twitchRate = Double(twitches) / Double(max(1, gseq.count - 1))

        let hrMean = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
        let hrVar = trailingHRStd(endExclusive: readEnd, length: Self.hrVarWindow)
        let hrFlat11 = trailingHRStd(endExclusive: readEnd, length: Self.hrFlatWindow)

        var beats: [(Double, Double)] = []
        for s in (readEnd - Self.rsaWindow)..<readEnd {
            if let vs = rrBy[s] { for v in vs { beats.append((Double(s), min(max(v, 300), 2000))) } }
        }
        beats.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let respReg = SleepStagerV2.respRegularity(beats)

        // Fold this epoch into tonight's running distributions. V2's within-night z-scores and percentile
        // rank are taken over EVERY epoch of the night including the one being scored, so including it
        // here is the faithful causal analogue — and it is still strictly causal, because by the time the
        // epoch closes its own data is in the past.
        if let v = hrMean { hrMoments.add(v) }
        if let v = hrVar { hrVarMoments.add(v) }
        moveFracMoments.add(moveFrac)
        if let v = respReg { respRegMoments.add(v) }
        if let v = hrFlat11 { hrFlatHist.add(v) }

        // Trailing coefficient of variation of the RSA statistic. Ring holds the last `respCVWindow`
        // epochs, so it is a strictly backward-looking measure of how erratic breathing has just been.
        if let v = respReg {
            respRegRing.append(v)
            if respRegRing.count > Self.respCVWindow { respRegRing.removeFirst() }
        }
        var respRegCV: Double? = nil
        if respRegRing.count >= 4 {
            let m = respRegRing.reduce(0, +) / Double(respRegRing.count)
            if m > 1e-9 {
                let sd = (respRegRing.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
                          / Double(respRegRing.count)).squareRoot()
                respRegCV = sd / m
            }
        }

        let clock = min(1.0, max(0.0, Double(elapsed) / Double(max(1, priors.typicalSessionSec))))

        let epoch = CausalSleepEpoch(start: e, hr: hrMean, hrVar: hrVar, hrFlat11: hrFlat11,
                                     moveFrac: moveFrac, jerkMax: jerkMax, respReg: respReg,
                                     clock: clock, jerkScale: jerkScale, elapsedSec: elapsed,
                                     twitchRate: twitchRate, respRegCV: respRegCV)
        return CausalSleepEpochSample(epoch: epoch, normalised: normalise(epoch, adaptWeight: w))
    }

    /// Weight on tonight-so-far versus the personal prior.
    private func adaptWeight(elapsedSec: Int) -> Double {
        if config.adaptFullSec <= 0 { return 0.0 }
        return min(1.0, max(0.0, Double(elapsedSec) / Double(config.adaptFullSec)))
    }

    private func resolvedJerkScale(blend w: Double) -> Double {
        if let fixed = config.fixedJerkScale { return max(fixed, 1e-9) }
        let prior = max(priors.jerkFloor, 1e-9)
        guard let tonight = jerkHist.quantile(0.5), tonight > 0 else { return prior }
        return max(1e-9, (1 - w) * prior + w * tonight)
    }

    /// Population std of the per-second HR present in `[endExclusive - length, endExclusive)`.
    /// nil below 2 present seconds — the same semantics as V2's `stdOfSeconds`.
    private func trailingHRStd(endExclusive: Int, length: Int) -> Double? {
        var n = 0
        var sum = 0.0
        var sumSq = 0.0
        for s in (endExclusive - length)..<endExclusive {
            guard let acc = hrSum[s], let c = hrCnt[s] else { continue }
            let v = acc / Double(c)
            n += 1; sum += v; sumSq += v * v
        }
        if n < 2 { return nil }
        let dn = Double(n)
        let m = sum / dn
        let v = sumSq / dn - m * m
        return (v < 0 ? 0 : v).squareRoot()
    }

    private func prune() {
        let floor = oldestReadableSecond
        hrSum = hrSum.filter { $0.key >= floor }
        hrCnt = hrCnt.filter { $0.key >= floor }
        let gFloor = nextEpoch   // gravity is only ever read inside the epoch itself
        gSum = gSum.filter { $0.key >= gFloor }
        gCnt = gCnt.filter { $0.key >= gFloor }
        let rrFloor = nextEpoch + Self.epochSec + config.lookaheadSec - Self.rsaWindow
        rrBy = rrBy.filter { $0.key >= rrFloor }
    }

    // MARK: - Adaptive normalisation, exposed for the stager

    /// z-score of a feature against the personal prior blended with tonight so far. `w` is the adapt
    /// weight at this epoch; the blended mean/sd is `(1-w)·prior + w·tonight`, falling back to the prior
    /// alone until tonight has two observations of that channel.
    func blendedZ(_ v: Double?, prior: NormStat, tonight: RunningMoments, w: Double) -> Double {
        guard let v = v else { return 0.0 }
        guard w > 0, let tm = tonight.mean, let ts = tonight.sd, ts > 0 else { return prior.z(v) }
        let mean = (1 - w) * prior.mean + w * tm
        let sd = max(1e-9, (1 - w) * prior.sd + w * ts)
        return (v - mean) / sd
    }

    /// The normalised view of an epoch the emission recipe consumes. Bundled so `LiveSleepStager` and the
    /// learned model see exactly the same numbers.
    public struct Normalised: Equatable, Sendable {
        public var zHR: Double
        public var zHRVar: Double
        public var zMove: Double
        public var zRespReg: Double
        public var hasRespReg: Bool
        public var flatPercentile: Double
        public var clock: Double
        public var jerkRatio: Double     // jerkMax / jerkScale — what V2's wake gate thresholds
        public var moveFrac: Double
        public var adaptWeight: Double
        /// Phasic-twitch rate (already a fraction; self-normalising, so no prior is needed).
        public var twitchRate: Double
        /// Trailing respiratory-irregularity CV; 0 when not yet estimable.
        public var respRegCV: Double

        public init(zHR: Double, zHRVar: Double, zMove: Double, zRespReg: Double, hasRespReg: Bool,
                    flatPercentile: Double, clock: Double, jerkRatio: Double, moveFrac: Double,
                    adaptWeight: Double, twitchRate: Double = 0, respRegCV: Double = 0) {
            self.zHR = zHR; self.zHRVar = zHRVar; self.zMove = zMove; self.zRespReg = zRespReg
            self.hasRespReg = hasRespReg; self.flatPercentile = flatPercentile; self.clock = clock
            self.jerkRatio = jerkRatio; self.moveFrac = moveFrac; self.adaptWeight = adaptWeight
            self.twitchRate = twitchRate; self.respRegCV = respRegCV
        }
    }

    /// Total per-second entries currently retained across all buffers. Exposed so a test can pin that
    /// memory is a function of the window sizes and not of how long the night has run.
    var retainedSecondCountForTesting: Int { hrSum.count + gSum.count + rrBy.count }

    /// Normalise an epoch against the running state as it stands right now. PRIVATE by construction: the
    /// only correct moment to call it is the instant the epoch closes, which `closeEpoch` does.
    private func normalise(_ f: CausalSleepEpoch, adaptWeight w: Double) -> Normalised {
        let pFlat = priors.hrFlat11Quantiles.count >= 2 ? priors.hrFlat11Percentile(f.hrFlat11) : 0.5
        let tFlat = f.hrFlat11.flatMap { hrFlatHist.percentileOf($0) }
        let flatPct: Double = {
            guard w > 0, let t = tFlat, hrFlatHist.total >= 8 else { return pFlat }
            return (1 - w) * pFlat + w * t
        }()
        return Normalised(
            zHR: blendedZ(f.hr, prior: priors.hr, tonight: hrMoments, w: w),
            zHRVar: blendedZ(f.hrVar, prior: priors.hrVar, tonight: hrVarMoments, w: w),
            zMove: blendedZ(f.moveFrac, prior: priors.moveFrac, tonight: moveFracMoments, w: w),
            zRespReg: blendedZ(f.respReg, prior: priors.respReg, tonight: respRegMoments, w: w),
            hasRespReg: f.respReg != nil,
            flatPercentile: flatPct,
            clock: f.clock,
            jerkRatio: f.jerkMax / max(f.jerkScale, 1e-9),
            moveFrac: f.moveFrac,
            adaptWeight: w,
            twitchRate: f.twitchRate,
            respRegCV: f.respRegCV ?? 0)
    }
}

// MARK: - Calibration

public extension PersonalSleepPriors {

    /// One completed night handed to calibration. Streams are the same shapes `SleepStagerV2.stageSession`
    /// takes; `[start, end]` is the locked in-bed window.
    struct CalibrationNight {
        public let start: Int
        public let end: Int
        public let hr: [HRSample]
        public let rr: [RRInterval]
        public let gravity: [GravitySample]
        public init(start: Int, end: Int, hr: [HRSample], rr: [RRInterval], gravity: [GravitySample]) {
            self.start = start; self.end = end; self.hr = hr; self.rr = rr; self.gravity = gravity
        }
    }

    /// Derive the personal priors from completed nights.
    ///
    /// TWO PASSES, and the second one matters. Pass A takes each night's own quiescent jerk median — the
    /// exact quantity V2 computes — and pools them into `jerkFloor`. Pass B then re-extracts every night
    /// with the move threshold PINNED to that pooled floor, so the `moveFrac` distribution the priors
    /// carry is taken against the same threshold live inference will use. Calibrating `moveFrac` in pass A
    /// would measure it against a per-night threshold that live never sees, and the z-scores would be
    /// biased from the first epoch.
    ///
    /// Features are extracted with TRAILING windows (`CausalSleepFeatureExtractor`), not V2's centred
    /// ones, for the same reason: the prior must describe the distribution live actually observes.
    static func calibrate(nights: [CalibrationNight],
                          config: CausalSleepFeatureExtractor.Config
                              = CausalSleepFeatureExtractor.Config()) -> PersonalSleepPriors {
        let usable = nights.filter { $0.end > $0.start && (!$0.hr.isEmpty || !$0.gravity.isEmpty) }
        if usable.isEmpty { return .coldStart }

        // PASS A — per-night quiescent jerk median, pooled.
        var nightFloors: [Double] = []
        for n in usable {
            var hist = LogHistogram()
            let g = n.gravity.filter { $0.ts >= n.start && $0.ts < n.end }.sorted { $0.ts < $1.ts }
            var perSec: [Int: (Double, Double, Double, Int)] = [:]
            for s in g {
                var a = perSec[s.ts] ?? (0, 0, 0, 0)
                a.0 += s.x; a.1 += s.y; a.2 += s.z; a.3 += 1
                perSec[s.ts] = a
            }
            // Epoch-local consecutive-second jerks, matching how the extractor pools them.
            var e = ((n.start + 29) / 30) * 30
            while e < n.end {
                var seq: [(Double, Double, Double)] = []
                for s in e..<(e + 30) {
                    if let a = perSec[s] {
                        let d = Double(a.3); seq.append((a.0 / d, a.1 / d, a.2 / d))
                    }
                }
                if seq.count >= 2 {
                    for i in 1..<seq.count {
                        let a = seq[i - 1], b = seq[i]
                        let dx = a.0 - b.0, dy = a.1 - b.1, dz = a.2 - b.2
                        hist.add((dx * dx + dy * dy + dz * dz).squareRoot())
                    }
                }
                e += 30
            }
            if let m = hist.quantile(0.5), m > 0 { nightFloors.append(m) }
        }
        let jerkFloor: Double = {
            if nightFloors.isEmpty { return PersonalSleepPriors.coldStart.jerkFloor }
            let s = nightFloors.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
        }()

        // PASS B — pooled feature distributions at the pinned floor, with adaptation OFF so the pooled
        // statistics describe the raw feature and not a partly self-normalised one.
        var pinned = config
        pinned.fixedJerkScale = jerkFloor
        pinned.adaptFullSec = 0

        var hrM = RunningMoments(), hvM = RunningMoments(), mvM = RunningMoments(), rgM = RunningMoments()
        var flat: [Double] = []
        var spans: [Int] = []
        var epochs = 0
        for n in usable {
            let boot = PersonalSleepPriors(hr: .neutral, hrVar: .neutral, moveFrac: .neutral,
                                           respReg: .neutral, jerkFloor: jerkFloor,
                                           hrFlat11Quantiles: [], typicalSessionSec: max(1, n.end - n.start),
                                           nightsUsed: 0, epochsUsed: 0)
            let ex = CausalSleepFeatureExtractor(priors: boot, sessionStart: n.start, config: pinned)
            ex.ingest(hr: n.hr.sorted { $0.ts < $1.ts })
            ex.ingest(rr: n.rr.sorted { $0.ts < $1.ts })
            ex.ingest(gravity: n.gravity.sorted { $0.ts < $1.ts })
            let feats = ex.advance(to: n.end + pinned.lookaheadSec).map { $0.epoch }
            for f in feats {
                if let v = f.hr { hrM.add(v) }
                if let v = f.hrVar { hvM.add(v) }
                mvM.add(f.moveFrac)
                if let v = f.respReg { rgM.add(v) }
                if let v = f.hrFlat11 { flat.append(v) }
            }
            epochs += feats.count
            spans.append(n.end - n.start)
        }

        func stat(_ m: RunningMoments, fallback: NormStat) -> NormStat {
            guard let mean = m.mean, let sd = m.sd, sd > 0 else { return fallback }
            return NormStat(mean: mean, sd: sd)
        }
        let cold = PersonalSleepPriors.coldStart

        // 101 quantile knots of the trailing 11-min HR-flatness statistic.
        var knots: [Double] = []
        if flat.count >= 8 {
            let s = flat.sorted()
            knots.reserveCapacity(101)
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
            hr: stat(hrM, fallback: cold.hr),
            hrVar: stat(hvM, fallback: cold.hrVar),
            moveFrac: stat(mvM, fallback: cold.moveFrac),
            respReg: stat(rgM, fallback: cold.respReg),
            jerkFloor: jerkFloor,
            hrFlat11Quantiles: knots,
            typicalSessionSec: typical,
            nightsUsed: usable.count,
            epochsUsed: epochs)
    }
}
