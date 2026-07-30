import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests for the live/streaming stager. The load-bearing one is `testNoLookahead...`: everything else in
/// this file is scaffolding to make that assertion meaningful.
final class LiveSleepStagerTests: XCTestCase {

    // MARK: - Synthetic night

    /// A deterministic 6-hour night with a plausible shape: HR drifts down then up, HR variability rises in
    /// the REM-ish stretches, and the wrist twitches on a fixed schedule. No randomness — every value is a
    /// closed-form function of `t`, so a truncated replay and a full replay see byte-identical inputs.
    struct SyntheticNight {
        let start: Int
        let end: Int
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var grav: [GravitySample] = []

        init(start: Int = 1_700_000_000, hours: Double = 6) {
            self.start = start
            self.end = start + Int(hours * 3600)
            for t in start..<end {
                let u = Double(t - start)
                let phase = u / 5400.0 * 2 * Double.pi           // 90-minute cycle
                let remish = max(0.0, sin(phase))
                let base = 58.0 - 4.0 * cos(u / Double(end - start) * Double.pi)
                let wobble = (1.0 + 5.0 * remish) * sin(u / 11.0)
                let bpm = Int((base + wobble).rounded())
                hr.append(HRSample(ts: t, bpm: max(35, min(120, bpm))))

                // R-R consistent with that HR, modulated by a respiratory sinus term.
                let rrMs = Int(60000.0 / Double(max(35, bpm)) + 40.0 * sin(u / 3.6) * (1.0 + remish))
                rr.append(RRInterval(ts: t, rrMs: max(300, min(2000, rrMs))))

                // Gravity: a slowly rotating wrist plus a periodic twitch every ~7 minutes.
                let twitch = (Int(u) % 420 < 3) ? 0.08 : 0.0
                let ang = u / 900.0
                grav.append(GravitySample(ts: t,
                                          x: 0.10 * sin(ang) + twitch,
                                          y: 0.05 * cos(ang),
                                          z: 0.99 - twitch * 0.5))
            }
        }

        var calibration: PersonalSleepPriors.CalibrationNight {
            .init(start: start, end: end, hr: hr, rr: rr, gravity: grav)
        }
    }

    /// Replay a night through a stager in 30 s ticks, stopping at `stopAt`.
    private func replay(_ n: SyntheticNight, priors: PersonalSleepPriors,
                        config: LiveSleepStager.Config, stopAt: Int) -> [LiveStageDecision] {
        let stager = LiveSleepStager(priors: priors, sessionStart: n.start, config: config)
        var hi = 0, ri = 0, gi = 0
        var t = n.start
        while t < stopAt {
            let next = t + 30
            var hb: [HRSample] = [], rb: [RRInterval] = [], gb: [GravitySample] = []
            while hi < n.hr.count && n.hr[hi].ts < next { hb.append(n.hr[hi]); hi += 1 }
            while ri < n.rr.count && n.rr[ri].ts < next { rb.append(n.rr[ri]); ri += 1 }
            while gi < n.grav.count && n.grav[gi].ts < next { gb.append(n.grav[gi]); gi += 1 }
            stager.ingest(hr: hb); stager.ingest(rr: rb); stager.ingest(gravity: gb)
            stager.advance(to: next)
            t = next
        }
        return stager.decisions
    }

    private func priors(for n: SyntheticNight) -> PersonalSleepPriors {
        PersonalSleepPriors.calibrate(nights: [n.calibration])
    }

    // MARK: - THE no-lookahead test

    /// Truncating the night must not change a single epoch the truncation still covers.
    ///
    /// This is the property that separates a live stager from a post-hoc one replayed in a loop. If any
    /// feature, normalisation or smoothing step reached forward — a centred window, a whole-night z-score,
    /// a Viterbi backward pass — the prefix would disagree with the full run, because the full run saw
    /// data the prefix could not.
    func testNoLookaheadTruncatedNightIsAPrefixOfTheFullNight() {
        let night = SyntheticNight()
        let p = priors(for: night)
        let cfg = LiveSleepStager.Config()
        XCTAssertEqual(cfg.extractor.lookaheadSec, 0, "the default config must be strictly causal")

        let full = replay(night, priors: p, config: cfg, stopAt: night.end)
        XCTAssertGreaterThan(full.count, 600, "a 6-hour night should yield >600 30 s epochs")

        for cutHours in [1.0, 2.0, 3.5, 5.0] {
            let cut = night.start + Int(cutHours * 3600)
            let partial = replay(night, priors: p, config: cfg, stopAt: cut)
            XCTAssertFalse(partial.isEmpty, "truncation at \(cutHours) h produced no epochs")
            XCTAssertLessThanOrEqual(partial.count, full.count)

            for (i, d) in partial.enumerated() {
                XCTAssertEqual(d.epochStart, full[i].epochStart,
                               "epoch \(i) start diverged at cut \(cutHours) h")
                XCTAssertEqual(d.stage, full[i].stage,
                               "epoch \(i) (t+\(d.elapsedSec) s) staged '\(d.stage)' on the truncated night "
                               + "but '\(full[i].stage)' on the full night — something read the future")
                for s in SleepStagerV2.stageNames {
                    XCTAssertEqual(d.posterior[s]!, full[i].posterior[s]!, accuracy: 1e-12,
                                   "posterior for \(s) at epoch \(i) diverged under truncation")
                }
                XCTAssertEqual(d.features, full[i].features,
                               "features at epoch \(i) diverged under truncation")
            }
        }
    }

    /// Same property, but with the samples delivered in ONE batch at the end of the night instead of in
    /// 30 s ticks. A caller that reconnects after a BLE gap closes many epochs in a single `advance`; if any
    /// per-epoch normalisation were computed after the batch rather than at each epoch's close, the early
    /// epochs would be normalised against statistics from the late ones.
    func testBatchedDeliveryMatchesIncrementalDelivery() {
        let night = SyntheticNight(hours: 4)
        let p = priors(for: night)
        let cfg = LiveSleepStager.Config()

        let incremental = replay(night, priors: p, config: cfg, stopAt: night.end)

        let batched = LiveSleepStager(priors: p, sessionStart: night.start, config: cfg)
        batched.ingest(hr: night.hr); batched.ingest(rr: night.rr); batched.ingest(gravity: night.grav)
        batched.advance(to: night.end)

        XCTAssertEqual(batched.decisions.count, incremental.count)
        for (i, d) in batched.decisions.enumerated() {
            XCTAssertEqual(d.epochStart, incremental[i].epochStart)
            XCTAssertEqual(d.stage, incremental[i].stage,
                           "epoch \(i) differs between batched and incremental delivery")
            XCTAssertEqual(d.remProbability, incremental[i].remProbability, accuracy: 1e-12)
        }
    }

    /// An epoch must never be influenced by samples that arrive after its window closed. Injecting a violent
    /// motion burst AFTER the cut must leave every already-emitted epoch untouched.
    func testLateArrivingDataCannotChangeAlreadyEmittedEpochs() {
        let night = SyntheticNight(hours: 3)
        let p = priors(for: night)
        let cfg = LiveSleepStager.Config()
        let cut = night.start + 2 * 3600

        let stager = LiveSleepStager(priors: p, sessionStart: night.start, config: cfg)
        stager.ingest(hr: night.hr.filter { $0.ts < cut })
        stager.ingest(rr: night.rr.filter { $0.ts < cut })
        stager.ingest(gravity: night.grav.filter { $0.ts < cut })
        stager.advance(to: cut)
        let before = stager.decisions

        // A large post-cut disturbance.
        let burst = (cut..<(cut + 600)).map {
            GravitySample(ts: $0, x: Double($0 % 2) * 0.9, y: 0.4, z: 0.2)
        }
        stager.ingest(gravity: burst)
        stager.ingest(hr: (cut..<(cut + 600)).map { HRSample(ts: $0, bpm: 110) })
        stager.advance(to: cut + 600)

        XCTAssertGreaterThan(stager.decisions.count, before.count, "the burst should have produced epochs")
        for (i, d) in before.enumerated() {
            XCTAssertEqual(d.stage, stager.decisions[i].stage,
                           "epoch \(i) changed after later data arrived")
            XCTAssertEqual(d.features, stager.decisions[i].features)
        }
    }

    // MARK: - Extractor properties

    func testFeaturesAreOnTheSame30sGridAsSleepStagerV2() {
        let night = SyntheticNight(hours: 2)
        let p = priors(for: night)
        let v2 = SleepStagerV2.features(start: night.start, end: night.end,
                                        grav: night.grav, hr: night.hr, rr: night.rr).map { $0.start }

        // Advanced past the end of the session, the live grid is EXACTLY V2's.
        let ex = CausalSleepFeatureExtractor(priors: p, sessionStart: night.start)
        ex.ingest(hr: night.hr); ex.ingest(rr: night.rr); ex.ingest(gravity: night.grav)
        XCTAssertEqual(ex.advance(to: night.end + 30).map { $0.epoch.start }, v2,
                       "the live extractor must tile the same epoch grid V2 stages")

        // Advanced only TO the end, it is a strict prefix: V2's final epoch is a partial one that ends
        // after the session does, and live cannot close an epoch whose 30 s have not elapsed. That is a
        // real property of streaming, not a bug — pin it so nobody "fixes" it by peeking.
        let live = CausalSleepFeatureExtractor(priors: p, sessionStart: night.start)
        live.ingest(hr: night.hr); live.ingest(rr: night.rr); live.ingest(gravity: night.grav)
        let atEnd = live.advance(to: night.end).map { $0.epoch.start }
        XCTAssertEqual(atEnd, Array(v2.prefix(atEnd.count)))
        XCTAssertEqual(atEnd.count, v2.count - 1)
    }

    /// The trailing windows must be the same LENGTH as V2's centred ones — that is what makes the two
    /// statistics comparable at all.
    func testTrailingWindowLengthsMatchV2Spans() {
        XCTAssertEqual(CausalSleepFeatureExtractor.hrVarWindow, 330)   // V2: [e-150, e+180)
        XCTAssertEqual(CausalSleepFeatureExtractor.hrFlatWindow, 720)  // V2: [e-330, e+390)
        XCTAssertEqual(CausalSleepFeatureExtractor.rsaWindow, 210)     // V2: [e-90,  e+120)
        XCTAssertEqual(CausalSleepFeatureExtractor.hrFlatWindow,
                       SleepStagerV2.padLo + 30 + (SleepStagerV2.padHi - 30),
                       "the 11-min window must equal V2's declared total reach")
    }

    func testEpochWithNoCoverageIsSkipped() {
        let start = 1_700_000_010          // already 30 s-aligned, so the grid starts exactly here
        XCTAssertEqual(start % 30, 0)
        let ex = CausalSleepFeatureExtractor(priors: .coldStart, sessionStart: start)
        // Cover the first and third epochs; leave the second entirely blank.
        ex.ingest(hr: (start..<(start + 30)).map { HRSample(ts: $0, bpm: 60) })
        ex.ingest(hr: ((start + 60)..<(start + 90)).map { HRSample(ts: $0, bpm: 61) })
        let out = ex.advance(to: start + 120)
        XCTAssertEqual(out.map { $0.epoch.start }, [start, start + 60],
                       "an epoch with neither HR nor gravity must be skipped, as V2 skips it")
    }

    func testMemoryStaysBoundedOverALongNight() {
        let night = SyntheticNight(hours: 10)
        let ex = CausalSleepFeatureExtractor(priors: .coldStart, sessionStart: night.start)
        var t = night.start
        var hi = 0, gi = 0
        while t < night.end {
            let next = t + 30
            var hb: [HRSample] = [], gb: [GravitySample] = []
            while hi < night.hr.count && night.hr[hi].ts < next { hb.append(night.hr[hi]); hi += 1 }
            while gi < night.grav.count && night.grav[gi].ts < next { gb.append(night.grav[gi]); gi += 1 }
            ex.ingest(hr: hb); ex.ingest(gravity: gb)
            ex.advance(to: next)
            t = next
        }
        // 10 hours ingested; retention must be a function of the window sizes, not of night length.
        XCTAssertLessThanOrEqual(ex.retainedSecondCountForTesting, 900,
                                 "per-second buffers must not grow with the length of the night")
    }

    // MARK: - Priors

    func testCalibrationLearnsFromHistoryAndBeatsColdStart() {
        let n1 = SyntheticNight(start: 1_700_000_000, hours: 6)
        let n2 = SyntheticNight(start: 1_700_100_000, hours: 7)
        let p = PersonalSleepPriors.calibrate(nights: [n1.calibration, n2.calibration])
        XCTAssertEqual(p.nightsUsed, 2)
        XCTAssertGreaterThan(p.epochsUsed, 1000)
        XCTAssertEqual(p.hrFlat11Quantiles.count, 101)
        XCTAssertGreaterThan(p.jerkFloor, 0)
        XCTAssertNotEqual(p.hr.mean, PersonalSleepPriors.coldStart.hr.mean,
                          "calibration must move the HR centre off the cold-start default")
        // Typical session length is a median of the calibration windows, so it sits between them.
        XCTAssertGreaterThanOrEqual(p.typicalSessionSec, 6 * 3600)
        XCTAssertLessThanOrEqual(p.typicalSessionSec, 7 * 3600)
    }

    func testCalibrationWithNoNightsFallsBackToColdStart() {
        XCTAssertEqual(PersonalSleepPriors.calibrate(nights: []), .coldStart)
    }

    func testHRFlatPercentileIsMonotonicAndBounded() {
        let n = SyntheticNight(hours: 5)
        let p = PersonalSleepPriors.calibrate(nights: [n.calibration])
        var last = -1.0
        for v in stride(from: 0.0, through: 20.0, by: 0.25) {
            let pct = p.hrFlat11Percentile(v)
            XCTAssertGreaterThanOrEqual(pct, 0.0)
            XCTAssertLessThanOrEqual(pct, 1.0)
            XCTAssertGreaterThanOrEqual(pct, last - 1e-12, "percentile must be non-decreasing")
            last = pct
        }
        XCTAssertEqual(p.hrFlat11Percentile(nil), 0.5, "a missing value must read as the neutral centre")
    }

    // MARK: - Forward filter

    func testPosteriorIsANormalisedDistribution() {
        let night = SyntheticNight(hours: 3)
        let p = priors(for: night)
        for d in replay(night, priors: p, config: .init(), stopAt: night.end) {
            let total = SleepStagerV2.stageNames.reduce(0.0) { $0 + (d.posterior[$1] ?? 0) }
            XCTAssertEqual(total, 1.0, accuracy: 1e-9, "posterior must sum to 1")
            for s in SleepStagerV2.stageNames {
                XCTAssertGreaterThanOrEqual(d.posterior[s]!, 0.0)
                XCTAssertLessThanOrEqual(d.posterior[s]!, 1.0)
            }
            XCTAssertEqual(d.remProbability, d.posterior["rem"]!)
        }
    }

    func testArgmaxMatchesThePosteriorAndUsesCanonicalStageNames() {
        let night = SyntheticNight(hours: 3)
        let p = priors(for: night)
        for d in replay(night, priors: p, config: .init(), stopAt: night.end) {
            XCTAssertTrue(["wake", "light", "deep", "rem"].contains(d.stage),
                          "stage '\(d.stage)' is not one of the canonical StageSegment labels")
            let key = d.stage == "wake" ? "awake" : d.stage
            let best = SleepStagerV2.stageNames.max { d.posterior[$0]! < d.posterior[$1]! }!
            XCTAssertEqual(key, best, "the reported stage must be the posterior argmax")
        }
    }

    /// A long quiet stretch must not underflow the filter into NaN.
    func testFilterSurvivesAVeryLongMonotonousNight() {
        let start = 1_700_000_000
        let stager = LiveSleepStager(priors: .coldStart, sessionStart: start)
        let end = start + 12 * 3600
        stager.ingest(hr: (start..<end).map { HRSample(ts: $0, bpm: 55) })
        stager.ingest(gravity: (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) })
        stager.advance(to: end)
        XCTAssertGreaterThan(stager.decisions.count, 1000)
        for d in stager.decisions {
            for s in SleepStagerV2.stageNames {
                XCTAssertFalse(d.posterior[s]!.isNaN, "posterior went NaN")
                XCTAssertFalse(d.posterior[s]!.isInfinite, "posterior went infinite")
            }
        }
    }

    func testSegmentsTileTheSessionContiguously() {
        let night = SyntheticNight(hours: 4)
        let p = priors(for: night)
        let stager = LiveSleepStager(priors: p, sessionStart: night.start)
        stager.ingest(hr: night.hr); stager.ingest(rr: night.rr); stager.ingest(gravity: night.grav)
        stager.advance(to: night.end)
        let segs = stager.segments(sessionStart: night.start, through: night.end)
        XCTAssertFalse(segs.isEmpty)
        XCTAssertEqual(segs.first!.start, night.start)
        XCTAssertEqual(segs.last!.end, night.end)
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i - 1].end, segs[i].start, "segments must tile without gaps or overlap")
            XCTAssertNotEqual(segs[i - 1].stage, segs[i].stage, "adjacent same-stage segments must merge")
        }
    }

    // MARK: - Recipe parity with V2's constants

    /// The live recipe must read V2's coefficients rather than carry copies, so a re-tune of the post-hoc
    /// stager moves the live one with it. This pins the shared-constant wiring, not the values.
    func testRecipeEmissionUsesV2Coefficients() {
        let m = RecipeEmissionModel()
        // A fully neutral epoch: every z at 0, mid-percentile, mid-night, no motion, no respiration term.
        let n = CausalSleepFeatureExtractor.Normalised(
            zHR: 0, zHRVar: 0, zMove: 0, zRespReg: 0, hasRespReg: false,
            flatPercentile: SleepStagerV2.deepGateThresh, clock: 0.5,
            jerkRatio: 0, moveFrac: 0, adaptWeight: 1)
        // Onset an hour back, so `remLatencyGuard` is fully spent and the neutral emission is base + cycle.
        let em = m.logEmissions(n, minutesSinceOnset: SleepStagerV2.remLatencyMinutes)
        let pr = SleepStagerV2.cyclePrior(0.5, SleepStagerV2.remLatencyMinutes)
        // With every z at 0 and the gate exactly at threshold, each emission is base prior + cycle prior.
        // `awake` additionally keeps its motion-quiescent clamp, which cannot lower a zero cardiac term.
        for s in SleepStagerV2.stageNames {
            XCTAssertEqual(em[s]!, SleepStagerV2.baseLogPrior[s]! + pr[s]!, accuracy: 1e-12,
                           "neutral emission for \(s) drifted from V2's own constants")
        }
    }

    /// The motion-quiescent clamp must hold a still epoch with an elevated HR out of wake — the same
    /// correction V2 applies post-hoc.
    func testMotionQuiescentClampSuppressesWakeOnAStillElevatedHREpoch() {
        let m = RecipeEmissionModel()
        func em(moveFrac: Double, jerkRatio: Double) -> Double {
            m.logEmissions(.init(zHR: 2.0, zHRVar: 2.0, zMove: 0, zRespReg: 0, hasRespReg: false,
                                 flatPercentile: 0.5, clock: 0.5,
                                 jerkRatio: jerkRatio, moveFrac: moveFrac, adaptWeight: 1),
                           minutesSinceOnset: SleepStagerV2.remLatencyMinutes)["awake"]!
        }
        let still = em(moveFrac: 0, jerkRatio: 1)
        let moved = em(moveFrac: 0.3, jerkRatio: 1)
        XCTAssertLessThan(still, moved,
                          "a motionless epoch with a raised HR must score lower on wake than a moving one")
    }

    // MARK: - Causal sleep onset (the REM-latency guard's clock, #930)

    /// V2 finds sleep onset by staging the whole night with the guard off and re-running Viterbi. The live
    /// stager has to latch it forward, from labels it has already emitted. Onset must appear, and must be
    /// stamped at the START of the sustained run rather than at the epoch that completed it.
    func testOnsetLatchesAtTheStartOfTheSustainedRun() {
        let n = SyntheticNight(hours: 6)
        let s = LiveSleepStager(priors: .coldStart, sessionStart: n.start)
        s.ingest(hr: n.hr); s.ingest(rr: n.rr); s.ingest(gravity: n.grav)
        s.advance(to: n.end)
        guard let onset = s.onsetMinutes else {
            return XCTFail("a 6-hour night must establish sleep onset")
        }
        // The run that establishes onset is `onsetSustainedEpochs` long, so onset can never be later than
        // the first non-wake decision, and must coincide with one.
        let firstSleep = s.decisions.first { $0.stage != "wake" }
        XCTAssertNotNil(firstSleep)
        XCTAssertGreaterThanOrEqual(onset, Double(firstSleep!.elapsedSec) / 60.0 - 1e-9,
                                    "onset cannot precede the first non-wake decision")
        let atOnset = s.decisions.first { abs(Double($0.elapsedSec) / 60.0 - onset) < 1e-9 }
        XCTAssertNotNil(atOnset, "onset must land on an epoch the stager actually emitted")
        XCTAssertNotEqual(atOnset?.stage, "wake", "onset must be stamped on a non-wake epoch")
    }

    /// Onset latches ONCE. A later awakening must not re-date it, or the REM-latency guard would come back
    /// and suppress REM in the second half of the night.
    func testOnsetNeverMovesOnceEstablished() {
        let n = SyntheticNight(hours: 6)
        let s = LiveSleepStager(priors: .coldStart, sessionStart: n.start)
        var seen: [Double] = []
        var t = n.start
        while t < n.end {
            let bound = min(n.end, t + 1800)
            s.ingest(hr: n.hr.filter { $0.ts >= t && $0.ts < bound })
            s.ingest(rr: n.rr.filter { $0.ts >= t && $0.ts < bound })
            s.ingest(gravity: n.grav.filter { $0.ts >= t && $0.ts < bound })
            s.advance(to: bound)
            if let o = s.onsetMinutes { seen.append(o) }
            t = bound
        }
        XCTAssertFalse(seen.isEmpty, "onset must be established at some point")
        XCTAssertEqual(Set(seen).count, 1, "onset moved after being established: \(Set(seen).sorted())")
    }

    /// Before onset is established the guard runs at FULL penalty, so REM must be strictly less likely than
    /// it would be with onset an hour in the past. This pins the direction of the substitution rather than a
    /// value, so a re-tune of `remLatencyPenalty` moves the test with the recipe.
    func testPreOnsetSuppressesREMRelativeToAnEstablishedOnset() {
        let m = RecipeEmissionModel()
        let n = CausalSleepFeatureExtractor.Normalised(
            zHR: 0.5, zHRVar: 1.5, zMove: -0.5, zRespReg: 0, hasRespReg: false,
            flatPercentile: 0.5, clock: 0.5, jerkRatio: 0, moveFrac: 0, adaptWeight: 1)
        let preOnset = m.logEmissions(n, minutesSinceOnset: 0)["rem"]!
        let settled = m.logEmissions(n, minutesSinceOnset: SleepStagerV2.remLatencyMinutes)["rem"]!
        XCTAssertLessThan(preOnset, settled,
                          "an unconfirmed onset must suppress REM, not licence it")
        XCTAssertEqual(settled - preOnset, SleepStagerV2.remLatencyPenalty, accuracy: 1e-12,
                       "the gap must be exactly V2's own penalty, not a copy of it")
    }

    // MARK: - Learned model

    func testFeatureVectorMatchesDeclaredWidth() {
        let n = CausalSleepFeatureExtractor.Normalised(
            zHR: 0.3, zHRVar: -0.2, zMove: 1.1, zRespReg: 0.4, hasRespReg: true,
            flatPercentile: 0.7, clock: 0.4, jerkRatio: 12, moveFrac: 0.2, adaptWeight: 0.5)
        XCTAssertEqual(LogisticEmissionModel.featureVector(n).count, LogisticEmissionModel.featureCount)
        XCTAssertEqual(LogisticEmissionModel.featureVector(n).last, 1.0, "the last entry must be the bias")
    }

    /// The trainer must actually separate classes it can see. A trivially separable problem should reach
    /// near-perfect training accuracy — if it does not, the gradient step is wrong.
    func testTrainerLearnsASeparableProblem() {
        var samples: [LiveStagerTrainer.Sample] = []
        for i in 0..<400 {
            let c = i % 4
            var f = [Double](repeating: 0, count: LogisticEmissionModel.featureCount)
            f[c] = 1.0                                    // one-hot marker per class
            f[LogisticEmissionModel.featureCount - 1] = 1 // bias
            samples.append(.init(features: f, label: c))
        }
        var o = LiveStagerTrainer.Options()
        o.iterations = 800
        o.learningRate = 1.0
        o.l2 = 0
        let model = LiveStagerTrainer.train(samples, featureCount: LogisticEmissionModel.featureCount,
                                            options: o)
        var correct = 0
        for s in samples {
            var logits = [Double](repeating: 0, count: 4)
            for c in 0..<4 {
                for j in 0..<s.features.count { logits[c] += model.weights[c][j] * s.features[j] }
            }
            let best = (0..<4).max { logits[$0] < logits[$1] }!
            if best == s.label { correct += 1 }
        }
        XCTAssertEqual(correct, samples.count, "the trainer failed a linearly separable problem")
    }

    func testTrainerHandlesEmptyInput() {
        let m = LiveStagerTrainer.train([], featureCount: LogisticEmissionModel.featureCount)
        XCTAssertEqual(m.weights.count, 4)
        XCTAssertTrue(m.weights.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    // MARK: - Streaming primitives

    func testLogHistogramRecoversAKnownMedian() {
        var h = LogHistogram()
        for i in 1...1000 { h.add(Double(i) * 1e-4) }   // 1e-4 … 1e-1, median ≈ 0.05005
        let m = h.quantile(0.5)!
        XCTAssertEqual(m, 0.05, accuracy: 0.05 * 0.05, "median off by more than the bin resolution")
        XCTAssertEqual(h.percentileOf(0.05)!, 0.5, accuracy: 0.02)
    }

    func testLogHistogramIsEmptyUntilFed() {
        let h = LogHistogram()
        XCTAssertNil(h.quantile(0.5))
        XCTAssertNil(h.percentileOf(1.0))
    }

    func testRunningMomentsMatchABatchComputation() {
        let vals = (1...500).map { Double($0) * 0.37 }
        var m = RunningMoments()
        for v in vals { m.add(v) }
        let mean = vals.reduce(0, +) / Double(vals.count)
        let sd = (vals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)).squareRoot()
        XCTAssertEqual(m.mean!, mean, accuracy: 1e-6)
        XCTAssertEqual(m.sd!, sd, accuracy: 1e-6)
        XCTAssertNil(RunningMoments().sd, "std is undefined below two observations")
    }

    // MARK: - Lookahead knob

    /// The bounded-lookahead setting must genuinely shift the read window, and must still be a prefix
    /// property at its own latency.
    func testBoundedLookaheadStillProducesAPrefixUnderTruncation() {
        let night = SyntheticNight(hours: 4)
        let p = priors(for: night)
        var cfg = LiveSleepStager.Config()
        cfg.extractor.lookaheadSec = 180

        let full = replay(night, priors: p, config: cfg, stopAt: night.end)
        let cut = night.start + 2 * 3600
        let partial = replay(night, priors: p, config: cfg, stopAt: cut)
        XCTAssertFalse(partial.isEmpty)
        for (i, d) in partial.enumerated() {
            XCTAssertEqual(d.stage, full[i].stage, "epoch \(i) diverged with 180 s lookahead")
        }
        // The last epoch emitted by `cut` must have closed at least `lookaheadSec` before it.
        XCTAssertLessThanOrEqual(partial.last!.epochStart + 30 + 180, cut)
    }
}
