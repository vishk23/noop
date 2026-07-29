package com.noop.analytics

/**
 * RestingHRWatch — the SINGLE-SIGNAL resting-HR tier of the illness heads-up. Pure, deterministic,
 * DB-free. Byte-for-byte mirror of
 * Packages/StrandAnalytics/Sources/StrandAnalytics/RestingHRWatch.swift.
 *
 * WHY THIS EXISTS ALONGSIDE [IllnessSignalEngine]
 *
 * [IllnessSignalEngine] is the CORROBORATED tier: four signals, a >=2-signal corroboration gate, a
 * Winsorized-EWMA personal baseline, a spread-relative z >= 2.0 threshold, and no temporal state. That
 * shape is deliberately conservative and it is kept — but it is measurably slow, and on a short history
 * it is silent. Three properties make it so:
 *
 *   1. It needs a TRUSTED baseline (14 valid nights inside a window that already drops the 3 most
 *      recent days), so ~17 nights of history must accumulate before it may raise at all.
 *   2. Corroboration means a lone, unambiguous signal cannot raise on its own.
 *   3. Its EWMA spread widens as an anomaly folds into it (Baselines.update tracks the spread against
 *      the UNCLAMPED value), so a SUSTAINED multi-day elevation progressively suppresses its own z —
 *      the longer you stay ill, the weaker the evidence looks.
 *
 * This tier is the published NightSignal-shaped complement, and it makes the opposite choice on every
 * axis: ONE signal (overnight resting HR), a STREAMING MEDIAN baseline (immune to (3) — a median does
 * not widen when an outlier lands), an ABSOLUTE bpm threshold rather than a spread-relative one, and
 * explicit TEMPORAL PERSISTENCE (two consecutive elevated nights) doing the false-positive suppression
 * that corroboration does in the other tier. It reaches a verdict on ~9 nights instead of ~17.
 *
 * It NEVER replaces the corroborated tier and never downgrades it: a caller runs both and takes the
 * louder verdict.
 *
 * STRICTLY ONE-SIDED. Only an ELEVATED resting HR can fire. A resting HR well BELOW the personal median
 * is the healthy direction and must never raise.
 *
 * SAME-DEVICE-ERA INPUT IS THE CALLER'S CONTRACT. The absolute bpm threshold is only meaningful within
 * one device's measurement scale; a brand switch shifts resting HR by a device-dependent offset that is
 * indistinguishable from a real elevation (see Baselines.deviceEraEpoch).
 *
 * WELLNESS ONLY — APPROXIMATE, NOT A DIAGNOSIS. Never names a condition.
 */
object RestingHRWatch {

    // ── Tuning constants (pinned by test; mirror the Swift twin exactly) ──

    /** Absolute elevation over the personal streaming median that counts a night as elevated. */
    const val offsetBPM: Double = 4.0

    /** How many prior nights the streaming median is taken over. */
    const val medianWindowNights: Int = 20

    /** Minimum prior nights with a value before a median is trustworthy enough to compare against. */
    const val minHistoryNights: Int = 7

    /** Consecutive elevated nights required to raise. This is the false-positive suppressor. */
    const val persistenceNights: Int = 2

    enum class Level(val raw: String) {
        QUIET("quiet"),
        RAISED("raised"),
    }

    data class Result(
        val level: Level,
        /** Most recent night's bpm over the streaming median (may be negative — reported, never fires). */
        val deltaBPM: Double?,
        /** The streaming median the most recent night was compared against. */
        val medianBPM: Double?,
        /** How many consecutive elevated nights end the series (0 when the last night is not elevated). */
        val consecutiveElevatedNights: Int,
    )

    /**
     * Evaluate the most recent night of [nightlyRHR] (ordered OLDEST->NEWEST; null = a night with no
     * reading, which is skipped rather than treated as zero).
     *
     * A night is ELEVATED when its value is at least [offsetBPM] over the median of the up-to
     * [medianWindowNights] valued nights BEFORE it (that night itself excluded, so an elevation never
     * props up its own baseline). Raises when the last [persistenceNights] valued nights are all
     * elevated.
     */
    fun evaluate(nightlyRHR: List<Double?>): Result {
        // Index the valued nights so missing nights neither break a run nor pad the median window.
        val valued = nightlyRHR.filterNotNull()
        if (valued.isEmpty()) {
            return Result(Level.QUIET, deltaBPM = null, medianBPM = null, consecutiveElevatedNights = 0)
        }

        // Median of the up-to-medianWindowNights valued nights strictly BEFORE position `pos`,
        // or null when there are fewer than minHistoryNights of them.
        fun medianBefore(pos: Int): Double? {
            val lo = maxOf(0, pos - medianWindowNights)
            val window = valued.subList(lo, pos)
            if (window.size < minHistoryNights) return null
            val sorted = window.sorted()
            val mid = sorted.size / 2
            return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2.0
        }

        // ONE-SIDED by construction: a value below the median can never satisfy `>= +offset`.
        fun isElevated(pos: Int): Boolean {
            val med = medianBefore(pos) ?: return false
            return valued[pos] - med >= offsetBPM
        }

        val lastPos = valued.size - 1
        val median = medianBefore(lastPos)
        val delta = median?.let { valued[lastPos] - it }

        var streak = 0
        var pos = lastPos
        while (pos >= 0 && isElevated(pos)) {
            streak += 1
            pos -= 1
        }

        val level = if (streak >= persistenceNights) Level.RAISED else Level.QUIET
        return Result(level, deltaBPM = delta, medianBPM = median, consecutiveElevatedNights = streak)
    }

    /**
     * Non-clinical copy for a raised verdict, matching the corroborated tier's register (never names a
     * condition, always carries the not-a-diagnosis tail). Null unless raised.
     */
    fun copy(result: Result): String? {
        if (result.level != Level.RAISED) return null
        val delta = result.deltaBPM ?: return null
        val rounded = Math.round(delta).toInt()
        return "Heads-up - your resting heart rate has been about $rounded bpm above your usual for " +
            "${result.consecutiveElevatedNights} nights running. Consider taking it easy. " +
            IllnessSignalEngine.disclaimerTail
    }
}
