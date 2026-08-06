package com.noop.analytics

import com.noop.data.EventRow
import com.noop.data.HrSample

/**
 * Three-state strap liveness read off the strap's own STRAP_CONDITION_REPORT(29) heartbeat, crossed with HR
 * coverage. INSTRUMENTATION ONLY — nothing scores this, and it never writes a stored metric.
 *
 * Byte-parity twin of Swift `StrapLiveness`.
 *
 * WHY IT EXISTS. "No data for this window" currently collapses three different facts into one:
 *
 *   1. the strap was worn and collecting,
 *   2. the strap was alive but OFF THE WRIST (so there is genuinely nothing to collect),
 *   3. the strap was dead, out of range, or its buffer was never offloaded (data may still exist).
 *
 * Only (3) is a reason to go looking for missing data; (2) is the correct absence of it. The heartbeat
 * separates them because it keeps beating when HR stops: across the 2026-08-01T22:53:30Z→08-02T01:40:18Z
 * off-wrist episode (167 min) the strap logged 16 reports and 1 HR sample, while across the
 * 2026-07-05→07-09 dead span (114 h 52 m) it logged 10 reports where the ~600 s cadence predicts ~689.
 *
 * THE CADENCE IS ~600 s, NOT EXACTLY 600 s. Over a 39-day corpus (5,079 reports, 5,078 inter-arrivals)
 * 5,056 fell in 595–605 s, but only 1,766 were exactly 600. [DEFAULT_BIN_SECONDS] is therefore 1.5× the
 * cadence rather than 1×, so ordinary jitter cannot make a live strap look silent: measured against that
 * corpus, 900 s bins misclassify 0.13 % of bins as [State.SILENT] while HR is flowing, against 0.40 % at
 * 600 s.
 */
object StrapLiveness {

    /** The strap's own liveness report. Name matched by prefix — kinds are formatted "NAME(n)". */
    const val HEARTBEAT_KIND_PREFIX = "STRAP_CONDITION_REPORT"

    /** Nominal heartbeat cadence in seconds, as observed on a WHOOP 5/MG. */
    const val HEARTBEAT_CADENCE_SECONDS = 600L

    /** Default bin width: 1.5× the cadence. See the type doc for the measurement behind the 1.5. */
    const val DEFAULT_BIN_SECONDS = 900L

    /**
     * A bin counts as worn when HR covers at least this fraction of it. HR is nominally 1 Hz, so a worn bin
     * carries ~binSeconds samples and coverage sits at ~1.0.
     *
     * WHY A FRACTION AND NOT "ANY HR AT ALL". Presence is far too weak a test. Across the real 167-minute
     * off-wrist episode of 2026-08-01 the strap emitted exactly ONE HR sample in 10,008 s — under a presence
     * rule that single stray sample flips the whole episode to [State.COLLECTING] and the state is worthless.
     *
     * WHY 0.10. Measured over the 39-day corpus, per-bin HR coverage is sharply bimodal: of 3,396 bins
     * carrying a heartbeat, 3,370 (99.2 %) sit at >=90 % coverage and 17 sit at <5 %, with NOT ONE BIN
     * anywhere between 5 % and 20 %. 0.10 is the middle of that empty gap, so the classification is
     * insensitive to the exact value — any threshold in [0.05, 0.20) yields identical output on the corpus.
     */
    const val WORN_HR_COVERAGE = 0.10

    enum class State {
        /** Heartbeat present AND HR covering at least [WORN_HR_COVERAGE] of the bin — worn and collecting. */
        COLLECTING,

        /**
         * Heartbeat present, HR essentially absent — the strap is alive and simply not on a wrist. An honest
         * absence, not a gap to go hunting for.
         */
        ALIVE_NOT_WORN,

        /** No heartbeat — dead, out of range, or never offloaded. The only state worth investigating. */
        SILENT,
    }

    data class Bin(
        val start: Long,
        val end: Long,
        val state: State,
        val heartbeats: Int,
        val hrSamples: Int,
    )

    /**
     * Bin `[windowStart, windowEnd)` and classify each bin. Bins are half-open, contiguous, and tile the
     * window exactly, so their durations always sum to it.
     *
     * THE LAST BIN ABSORBS THE REMAINDER rather than being clipped short. A window is rarely a whole
     * multiple of [binSeconds], and a clipped tail bin is biased toward [State.SILENT] for a purely
     * arithmetic reason: a 108 s tail cannot be expected to contain a beat that arrives every ~600 s, so it
     * reports a dead strap at the end of every otherwise-healthy window. Absorbing keeps every bin at least
     * [binSeconds] wide, which is the property the 1.5×-cadence choice rests on. The final bin is therefore
     * in `[binSeconds, 2 × binSeconds)`, and a window shorter than [binSeconds] is a single bin.
     *
     * Pure + deterministic. Inputs need not be sorted. Empty when the window is empty or inverted.
     */
    fun timeline(
        events: List<EventRow>,
        hr: List<HrSample>,
        windowStart: Long,
        windowEnd: Long,
        binSeconds: Long = DEFAULT_BIN_SECONDS,
    ): List<Bin> {
        if (windowEnd <= windowStart || binSeconds <= 0L) return emptyList()
        val beats = events.filter { it.kind.startsWith(HEARTBEAT_KIND_PREFIX) }.map { it.ts }.sorted()
        // HR presence, not HR plausibility: this asks "did the strap emit anything here", which is a
        // different question from "is this beat usable". A bpm gate belongs in the analytics that score HR,
        // not in a liveness read — gating here would report a strap as not-worn during a stretch of
        // implausible-but-real emission, which is exactly the confusion this type exists to remove.
        val hrTs = hr.map { it.ts }.sorted()

        val out = ArrayList<Bin>()
        var t = windowStart
        while (t < windowEnd) {
            // Absorb the remainder into this bin when what would follow is shorter than a full bin.
            val e = if ((windowEnd - (t + binSeconds)) < binSeconds) windowEnd else t + binSeconds
            val h = countInRange(beats, t, e)
            val r = countInRange(hrTs, t, e)
            val coverage = r.toDouble() / (e - t).toDouble()
            val state = when {
                h == 0 -> State.SILENT
                coverage < WORN_HR_COVERAGE -> State.ALIVE_NOT_WORN
                else -> State.COLLECTING
            }
            out.add(Bin(t, e, state, h, r))
            t = e
        }
        return out
    }

    /** Count of [sorted] in the half-open range `[from, to)`, by binary search on both edges. */
    internal fun countInRange(sorted: List<Long>, from: Long, to: Long): Int {
        if (to <= from) return 0
        fun lowerBound(v: Long): Int {
            var lo = 0
            var hi = sorted.size
            while (lo < hi) {
                val mid = (lo + hi) / 2
                if (sorted[mid] < v) lo = mid + 1 else hi = mid
            }
            return lo
        }
        return lowerBound(to) - lowerBound(from)
    }

    /** Rolled-up seconds per state over a timeline, plus the counts behind them, for a diagnostic line. */
    data class Summary(
        val collectingSeconds: Long,
        val aliveNotWornSeconds: Long,
        val silentSeconds: Long,
        val heartbeats: Int,
        val bins: Int,
        val binSeconds: Long,
    ) {
        val totalSeconds: Long get() = collectingSeconds + aliveNotWornSeconds + silentSeconds

        /**
         * Expected heartbeats if the strap had beaten at its nominal cadence for the whole window. The
         * observed/expected ratio is what makes a dead span legible: the 114 h span read 10 vs ~689.
         */
        val expectedHeartbeats: Long get() = totalSeconds / HEARTBEAT_CADENCE_SECONDS

        val summary: String
            get() {
                fun hm(s: Long) = "${s / 3600}h${((s % 3600) / 60).toString().padStart(2, '0')}m"
                return "strap-liveness: bins=${bins}x${binSeconds}s " +
                    "collecting=${hm(collectingSeconds)} aliveNotWorn=${hm(aliveNotWornSeconds)} " +
                    "silent=${hm(silentSeconds)}; heartbeats=$heartbeats/$expectedHeartbeats expected " +
                    "(~${HEARTBEAT_CADENCE_SECONDS}s cadence). Diagnostic only — nothing is scored from this."
            }
    }

    fun summarize(bins: List<Bin>, binSeconds: Long = DEFAULT_BIN_SECONDS): Summary {
        var c = 0L
        var a = 0L
        var s = 0L
        var beats = 0
        for (b in bins) {
            val d = b.end - b.start
            when (b.state) {
                State.COLLECTING -> c += d
                State.ALIVE_NOT_WORN -> a += d
                State.SILENT -> s += d
            }
            beats += b.heartbeats
        }
        return Summary(c, a, s, beats, bins.size, binSeconds)
    }
}
