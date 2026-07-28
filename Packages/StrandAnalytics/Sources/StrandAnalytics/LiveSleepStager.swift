import Foundation
import WhoopProtocol

// LiveSleepStager.swift — staging a night WHILE it happens.
//
// `SleepStagerV2` decides an epoch's stage with a Viterbi pass over the whole night: the label at 02:00
// depends on what happened at 05:00. That is the last, and the deepest, of its whole-night dependencies —
// the others are normalisation and can be replaced with a personal prior (`PersonalSleepPriors`), but
// Viterbi is non-causal by construction.
//
// The causal analogue is the standard HMM FORWARD FILTER: at each epoch, propagate the previous
// posterior through the same transition matrix, multiply by this epoch's emission, renormalise. That
// yields P(stage | everything so far), which is strictly more useful for cueing than a hard label —
// a haptic policy wants to gate on "P(REM) has held above x for n minutes", not on an argmax that can
// flicker.
//
// Two emission models are provided behind one protocol:
//   * `.recipe`  — V2's hand-written log-emission formula, evaluated on causal features + personal priors.
//                  No training, no labels, and it inherits V2's a-priori coefficients unchanged.
//   * `.learned` — a multinomial logistic regression over the same causal features, trained with the
//                  POST-HOC stager as the label source (teacher/student). Ships as fixed coefficients.
//
// Both feed the same forward filter, so the comparison isolates the emission model.
//
// SCOPE: this file DETECTS. It fires nothing, writes nothing, and touches no BLE path.

/// One live decision: the stage this epoch was called, and the full posterior behind it.
public struct LiveStageDecision: Equatable, Sendable {
    public let epochStart: Int
    /// argmax of `posterior` — the "wake" | "light" | "deep" | "rem" label, canonicalised like V2's output.
    public let stage: String
    /// P(stage | all data through this epoch). Sums to 1 over `SleepStagerV2.stageNames`.
    public let posterior: [String: Double]
    /// Seconds since session start at this epoch's midpoint.
    public let elapsedSec: Int
    /// The causal features this decision was made from.
    public let features: CausalSleepEpoch

    public var remProbability: Double { posterior["rem"] ?? 0 }
}

/// Produces a per-stage log-emission from one normalised causal epoch.
public protocol LiveEmissionModel {
    func logEmissions(_ n: CausalSleepFeatureExtractor.Normalised) -> [String: Double]
}

/// `SleepStagerV2`'s emission recipe, evaluated causally.
///
/// Every coefficient is V2's, read from `SleepStagerV2` rather than copied, so a re-tune there moves both
/// stagers together. The only substitutions are the ones the live setting forces: personal-prior z-scores
/// for within-night z-scores, the personal HR-flatness CDF for the within-night percentile, and the
/// elapsed-fraction clock for the span-normalised one.
public struct RecipeEmissionModel: LiveEmissionModel, Sendable {
    public init() {}

    /// True when the wrist did not move this epoch, on the night-relative scale V2's wake gate uses.
    /// Mirrors `SleepStagerV2.motionQuiescent`, which takes a post-hoc `Epoch` this model never has.
    static func motionQuiescent(_ n: CausalSleepFeatureExtractor.Normalised) -> Bool {
        n.moveFrac <= 0.0 && n.jerkRatio <= SleepStagerV2.jerkFloorGateMult
    }

    public func logEmissions(_ n: CausalSleepFeatureExtractor.Normalised) -> [String: Double] {
        let gate = SleepStagerV2.deepGateSlope * max(0.0, n.flatPercentile - SleepStagerV2.deepGateThresh)
        let awakeCardiac0: Double = 0.8 * n.zHRVar + 0.4 * n.zHR
        let awakeCardiac: Double = Self.motionQuiescent(n) ? min(0.0, awakeCardiac0) : awakeCardiac0

        // Built term-by-term rather than as one dictionary literal: the literal form pushes the Swift
        // type-checker past its expression budget.
        let deep: Double = -1.1 * n.zHRVar - 0.5 * n.zMove - gate + SleepStagerV2.baseLogPrior["deep"]!
        let rem: Double = 0.6 * n.zHRVar - 0.6 * n.zMove + 0.4 * n.zHR + SleepStagerV2.baseLogPrior["rem"]!
        let light: Double = SleepStagerV2.baseLogPrior["light"]!
        let awake: Double = 1.0 * n.zMove + awakeCardiac + SleepStagerV2.baseLogPrior["awake"]!

        var em: [String: Double] = ["deep": deep, "rem": rem, "light": light, "awake": awake]
        let pr = SleepStagerV2.cyclePrior(n.clock)
        for s in SleepStagerV2.stageNames { em[s]! += pr[s]! }
        if n.jerkRatio > SleepStagerV2.jerkFloorGateMult { em["awake"]! += SleepStagerV2.motionGateBoost }
        if n.hasRespReg {
            em["deep"]! += SleepStagerV2.respWeight * n.zRespReg
            em["rem"]! -= SleepStagerV2.respWeight * n.zRespReg
        }
        return em
    }
}

/// A multinomial logistic regression over the causal feature vector.
///
/// Trained offline against post-hoc `SleepStagerV2` labels (teacher/student) and shipped as fixed
/// coefficients — inference is one 4×N dot product per 30 s epoch, so it is far cheaper than the feature
/// extraction that feeds it. The logits are used directly as log-emissions, which is exactly what they
/// are: unnormalised log-probabilities over the four stages.
public struct LogisticEmissionModel: LiveEmissionModel, Equatable, Sendable, Codable {
    /// Row per stage in `SleepStagerV2.stageNames` order; last column is the bias.
    public var weights: [[Double]]
    /// When false, the two time-since-onset features are held at 0 — the model must decide from physiology
    /// alone. Exists so the contribution of the temporal prior can be measured rather than assumed; a model
    /// must be TRAINED with the same setting it is evaluated with.
    public var usesTemporalPrior: Bool

    public init(weights: [[Double]], usesTemporalPrior: Bool = true) {
        self.weights = weights; self.usesTemporalPrior = usesTemporalPrior
    }

    /// Names of the feature vector's entries, for reporting. Index-aligned with `featureVector`.
    public static let featureNames = [
        "zHR", "zHRVar", "zMove", "zRespReg", "hasResp", "flatPct",
        "clock", "earlyNight", "logJerk", "moveFrac", "zHR*zHRV", "zHRV^2",
        "quiescent", "twitchRate", "respRegCV", "bias"]

    /// The causal feature vector, in the order `weights` expects. The last entry is the constant 1 for
    /// the bias term. Kept as a free function so training and inference can never drift apart.
    ///
    /// TIME-SINCE-ONSET IS A PRIOR, NOT A RIVAL. `clock` and `earlyNight` carry P(REM) before any
    /// physiology is read — REM pressure is near zero in the first ~12 % of a night and rises toward
    /// morning. Multiplying that against the physiological likelihood is the whole point: late in the
    /// night weaker feature evidence should suffice, early it should not.
    public static func featureVector(_ n: CausalSleepFeatureExtractor.Normalised,
                                     temporal: Bool = true) -> [Double] {
        let zhr: Double = n.zHR
        let zhv: Double = n.zHRVar
        let zmv: Double = n.zMove
        let zrg: Double = n.zRespReg
        let jerk: Double = min(6.0, log1p(max(0.0, n.jerkRatio)))
        let quiescent: Double = (n.moveFrac <= 0.0 && n.jerkRatio <= SleepStagerV2.jerkFloorGateMult)
            ? 1.0 : 0.0
        var v = [Double]()
        v.reserveCapacity(featureCount)
        v.append(zhr)
        v.append(zhv)
        v.append(zmv)
        v.append(zrg)
        v.append(n.hasRespReg ? 1.0 : 0.0)
        v.append(n.flatPercentile)
        v.append(temporal ? n.clock : 0.0)
        v.append(temporal ? (n.clock < 0.12 ? 1.0 : 0.0) : 0.0)
        v.append(jerk)
        v.append(min(1.0, n.moveFrac))
        v.append(zhr * zhv)          // the REM signature is high HR-variability WITH a raised HR
        v.append(zhv * zhv)          // curvature: both very-flat and very-erratic differ from mid
        v.append(quiescent)          // still wrist — V2's guard against elevated-HR-but-motionless wake
        v.append(min(1.0, n.twitchRate))   // phasic breakthroughs through atonia — REM-specific
        v.append(min(3.0, n.respRegCV))    // erratic breathing — REM; steady RSA — NREM
        v.append(1.0)                // bias
        return v
    }

    public static let featureCount = 16

    public func logEmissions(_ n: CausalSleepFeatureExtractor.Normalised) -> [String: Double] {
        let x = Self.featureVector(n, temporal: usesTemporalPrior)
        var out: [String: Double] = [:]
        for (i, s) in SleepStagerV2.stageNames.enumerated() {
            guard i < weights.count else { out[s] = 0; continue }
            let w = weights[i]
            var acc = 0.0
            for j in 0..<min(x.count, w.count) { acc += x[j] * w[j] }
            out[s] = acc
        }
        return out
    }
}

/// Online sleep stager: ingest samples as they arrive, get a stage + posterior per closed epoch.
///
/// Cost, stated plainly so an opt-in can be informed: the extractor keeps ~13 min of per-second HR, 30 s
/// of gravity and 4 min of R-R (a few tens of kB), and each epoch costs one pass over those windows plus
/// a ~50-bin band-limited DFT for the RSA term — microseconds of CPU once per 30 s. The expensive part of
/// this feature is not the maths, it is holding a BLE connection open all night with the deeper streams
/// enabled; that is a radio and duty-cycle cost, not a compute one.
public final class LiveSleepStager {

    public struct Config: Equatable, Sendable {
        public var extractor: CausalSleepFeatureExtractor.Config
        /// Emission-model selector. `.recipe` needs no training data.
        public var model: Model
        public enum Model: Equatable, Sendable {
            case recipe
            case learned(LogisticEmissionModel)
        }
        public init(extractor: CausalSleepFeatureExtractor.Config = .init(), model: Model = .recipe) {
            self.extractor = extractor; self.model = model
        }
    }

    private let extractor: CausalSleepFeatureExtractor
    private let emission: LiveEmissionModel
    private let logTransition: [String: [String: Double]]
    /// Running log-posterior over stages. nil before the first epoch (the filter starts uniform).
    private var logAlpha: [String: Double]?

    public private(set) var decisions: [LiveStageDecision] = []

    public init(priors: PersonalSleepPriors, sessionStart: Int, config: Config = Config()) {
        self.extractor = CausalSleepFeatureExtractor(priors: priors, sessionStart: sessionStart,
                                                     config: config.extractor)
        switch config.model {
        case .recipe: self.emission = RecipeEmissionModel()
        case .learned(let m): self.emission = m
        }
        self.logTransition = SleepStagerV2.transition.mapValues { row in
            row.mapValues { Foundation.log(max($0, 1e-9)) }
        }
    }

    public func ingest(hr: [HRSample]) { extractor.ingest(hr: hr) }
    public func ingest(rr: [RRInterval]) { extractor.ingest(rr: rr) }
    public func ingest(gravity: [GravitySample]) { extractor.ingest(gravity: gravity) }

    /// Close every epoch whose window has ended by `now` and return the decisions made for them.
    @discardableResult
    public func advance(to now: Int) -> [LiveStageDecision] {
        var out: [LiveStageDecision] = []
        for s in extractor.advance(to: now) {
            let f = s.epoch
            let em = emission.logEmissions(s.normalised)
            let post = step(emission: em)
            var best = SleepStagerV2.stageNames[0]
            var bestP = post[best] ?? 0
            for s in SleepStagerV2.stageNames.dropFirst() where (post[s] ?? 0) > bestP {
                bestP = post[s] ?? 0; best = s
            }
            let d = LiveStageDecision(epochStart: f.start,
                                      stage: best == "awake" ? "wake" : best,
                                      posterior: post, elapsedSec: f.elapsedSec, features: f)
            out.append(d)
            decisions.append(d)
        }
        return out
    }

    /// One forward-filter step. `alpha_t(s) ∝ em_t(s) · Σ_p alpha_{t-1}(p)·T[p][s]`, in log space with a
    /// log-sum-exp so a long quiet stretch cannot underflow. Returns the normalised posterior.
    private func step(emission em: [String: Double]) -> [String: Double] {
        var newLog: [String: Double] = [:]
        if let prev = logAlpha {
            for s in SleepStagerV2.stageNames {
                var terms: [Double] = []
                terms.reserveCapacity(SleepStagerV2.stageNames.count)
                for p in SleepStagerV2.stageNames {
                    terms.append(prev[p]! + logTransition[p]![s]!)
                }
                newLog[s] = logSumExp(terms) + (em[s] ?? 0)
            }
        } else {
            // Uniform start — the same convention V2's Viterbi uses for its first epoch.
            for s in SleepStagerV2.stageNames { newLog[s] = em[s] ?? 0 }
        }
        let norm = logSumExp(SleepStagerV2.stageNames.map { newLog[$0]! })
        for s in SleepStagerV2.stageNames { newLog[s]! -= norm }
        logAlpha = newLog
        var post: [String: Double] = [:]
        for s in SleepStagerV2.stageNames { post[s] = Foundation.exp(newLog[s]!) }
        return post
    }

    private func logSumExp(_ xs: [Double]) -> Double {
        guard let m = xs.max(), m.isFinite else { return -Double.infinity }
        var acc = 0.0
        for x in xs { acc += Foundation.exp(x - m) }
        return m + Foundation.log(acc)
    }

    /// Collapse the per-epoch decisions into the same `StageSegment` tiling `SleepStagerV2.stageSession`
    /// returns, so a caller can render a live hypnogram with the existing components.
    public func segments(sessionStart: Int, through end: Int) -> [StageSegment] {
        guard !decisions.isEmpty else { return [] }
        var out: [StageSegment] = []
        for (i, d) in decisions.enumerated() {
            let segStart = i == 0 ? sessionStart : d.epochStart
            let segEnd = i == decisions.count - 1 ? end : decisions[i + 1].epochStart
            if segEnd <= segStart { continue }
            if let last = out.last, last.stage == d.stage {
                out[out.count - 1].end = segEnd
            } else {
                out.append(StageSegment(start: segStart, end: segEnd, stage: d.stage))
            }
        }
        return out
    }
}

// MARK: - Training the student

/// Batch trainer for `LogisticEmissionModel`. Lives beside the model so the feature vector cannot drift
/// between training and inference, and so the fit is reproducible from the repo rather than from a
/// notebook that no longer exists.
///
/// Plain multinomial logistic regression, full-batch gradient descent with L2. The dataset this targets is
/// one wearer's own nights (tens of thousands of epochs, 14 features), where a convex model with a closed
/// training story is worth more than a percent of accuracy from something unauditable.
public enum LiveStagerTrainer {

    public struct Sample {
        public let features: [Double]
        /// Index into `SleepStagerV2.stageNames`.
        public let label: Int
        public init(features: [Double], label: Int) { self.features = features; self.label = label }
    }

    public struct Options {
        public var iterations: Int = 400
        public var learningRate: Double = 0.5
        public var l2: Double = 1e-4
        /// Re-weight classes by inverse frequency. REM is ~20 % of epochs; without this the fit spends its
        /// capacity on light and under-calls the class the whole feature exists to find.
        public var balanceClasses: Bool = true
        public init() {}
    }

    public static func train(_ samples: [Sample], featureCount: Int,
                             options: Options = Options(),
                             usesTemporalPrior: Bool = true) -> LogisticEmissionModel {
        let k = SleepStagerV2.stageNames.count
        var w = [[Double]](repeating: [Double](repeating: 0, count: featureCount), count: k)
        guard !samples.isEmpty else {
            return LogisticEmissionModel(weights: w, usesTemporalPrior: usesTemporalPrior)
        }

        var classWeight = [Double](repeating: 1, count: k)
        if options.balanceClasses {
            var counts = [Double](repeating: 0, count: k)
            for s in samples where s.label >= 0 && s.label < k { counts[s.label] += 1 }
            let present = counts.filter { $0 > 0 }
            let mean = present.isEmpty ? 1 : present.reduce(0, +) / Double(present.count)
            for c in 0..<k { classWeight[c] = counts[c] > 0 ? mean / counts[c] : 0 }
        }
        var totalWeight = 0.0
        for s in samples where s.label >= 0 && s.label < k { totalWeight += classWeight[s.label] }
        if totalWeight <= 0 {
            return LogisticEmissionModel(weights: w, usesTemporalPrior: usesTemporalPrior)
        }

        for _ in 0..<options.iterations {
            var grad = [[Double]](repeating: [Double](repeating: 0, count: featureCount), count: k)
            for s in samples {
                guard s.label >= 0 && s.label < k else { continue }
                let cw = classWeight[s.label]
                if cw == 0 { continue }
                var logits = [Double](repeating: 0, count: k)
                for c in 0..<k {
                    var acc = 0.0
                    for j in 0..<min(featureCount, s.features.count) { acc += w[c][j] * s.features[j] }
                    logits[c] = acc
                }
                let m = logits.max() ?? 0
                var denom = 0.0
                for c in 0..<k { logits[c] = Foundation.exp(logits[c] - m); denom += logits[c] }
                for c in 0..<k {
                    let p = logits[c] / denom
                    let err = (p - (c == s.label ? 1.0 : 0.0)) * cw
                    if err == 0 { continue }
                    for j in 0..<min(featureCount, s.features.count) {
                        grad[c][j] += err * s.features[j]
                    }
                }
            }
            for c in 0..<k {
                for j in 0..<featureCount {
                    let g = grad[c][j] / totalWeight + options.l2 * w[c][j]
                    w[c][j] -= options.learningRate * g
                }
            }
        }
        return LogisticEmissionModel(weights: w, usesTemporalPrior: usesTemporalPrior)
    }
}
