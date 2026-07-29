package com.noop.protocol

/**
 * Kotlin twin of Swift `Whoop5EcgProbe`: formats the WHOOP MG ECG ("Labrador") turn-on attempt into one
 * readable, copyable report — the per-command COMMAND_RESPONSE result codes, whether any ECG-shaped
 * packet actually arrived, and the verdict on the ONE gating question the client cannot answer: whether
 * the strap's firmware returns a device-flag block for this feature.
 *
 * Pure and deterministic, so the JVM unit tests cover it with no strap.
 *
 * The Android client has no ECG app layer to drive this — it takes the decoder ([Whoop5Ecg]) only. It is
 * mirrored anyway because the classification below decides whether a null result gets reported as
 * evidence of a firmware block, which is the claim this probe exists to make; a rule that important is
 * worth two independent implementations and two test suites, and both suites pin the same runs.
 *
 * ## How the block is detected
 *
 * The client-side gates are known and satisfiable, so the remaining unknown is a FIRMWARE gate, which
 * only the strap's own behaviour can answer. Three signals separate the cases, and the report states
 * which one fired:
 *
 *  1. `UNSUPPORTED(3)` — the firmware does not implement the opcode at all. Not a flag block; a
 *     different (and more final) answer.
 *  2. `FAILURE(0)` — the firmware KNOWS the opcode and REFUSES to run it. That is the single-frame
 *     signature most consistent with a device-flag block.
 *  3. `SUCCESS(1)` on every command, but ZERO ECG packets across the capture window — a silent no-op:
 *     acknowledged and then not honoured.
 *
 * A block is never inferred from silence alone: no reply at all is reported as exactly that, because an
 * in-flight sync or a dropped notification produces the same silence.
 *
 * ## What a run has to contain before silence means anything
 *
 * Signal 3 reads SILENCE as evidence. Silence only carries information when the run actually **asked the
 * strap for data**: a wrist selection changes no data path, and the OFF sequence asks for the silence it
 * gets. So every step records whether the command — *with the argument it was sent with* — could have
 * produced realtime ECG data ([Whoop5Ecg.requestsRealtimeData]), and the two verdicts that interpret
 * silence are unreachable without one:
 *
 *  - [Verdict.AcceptedButSilent] needs a data request that came back `SUCCESS`. Requested-but-
 *    unacknowledged is [Verdict.DataRequestNotAccepted]; nothing requested at all is
 *    [Verdict.NoDataRequested].
 *  - [Verdict.BlockedByDeviceFlagsLikely] needs the refused command to be a data request. A `FAILURE` on
 *    a configuration write is [Verdict.CommandRefused] — the firmware refused *that write*, which is a
 *    fact about that opcode and not about whether ECG generation is gated.
 *
 * Both defects were live: a `SELECT_WRIST`-only run on a WHOOP 5 MG rendered "Accepted but SILENT …
 * consistent with a device-flag block" having sent no data-generation command at all, and a second
 * `SELECT_WRIST`-only run that came back `FAILURE` rendered "LIKELY blockedByDeviceFlags". Both
 * manufactured evidence for hypothesis (e) of #891 out of runs that could not speak to it.
 */
object Whoop5EcgProbe {

    /** The 5/MG COMMAND_RESPONSE result code, at `frame[12]`. */
    const val RESULT_CODE_OFFSET = 12

    sealed class CommandOutcome {
        object Success : CommandOutcome()
        object Failure : CommandOutcome()
        object Pending : CommandOutcome()
        object Unsupported : CommandOutcome()
        data class Unmapped(val value: Int) : CommandOutcome()

        /** No COMMAND_RESPONSE arrived inside the probe window. */
        object NoReply : CommandOutcome()

        val token: String
            get() = when (this) {
                is Success -> "SUCCESS(1)"
                is Failure -> "FAILURE(0)"
                is Pending -> "PENDING(2)"
                is Unsupported -> "UNSUPPORTED(3)"
                is Unmapped -> "result$value"
                is NoReply -> "no reply"
            }
    }

    /** Read the result code out of a 5/MG COMMAND_RESPONSE frame. null when the frame is too short. */
    fun outcome(frame: ByteArray): CommandOutcome? {
        if (frame.size <= RESULT_CODE_OFFSET) return null
        return when (val v = frame[RESULT_CODE_OFFSET].toInt() and 0xFF) {
            0 -> CommandOutcome.Failure
            1 -> CommandOutcome.Success
            2 -> CommandOutcome.Pending
            3 -> CommandOutcome.Unsupported
            else -> CommandOutcome.Unmapped(v)
        }
    }

    /**
     * One command in the turn-on sequence and what came back.
     *
     * [requestsRealtimeData] deliberately has NO default: every construction site must state it, because
     * the verdicts that read silence as evidence turn on this flag and a silently-omitted `true` is
     * exactly the bug this field exists to prevent.
     */
    data class Step(
        val label: String,
        val outcome: CommandOutcome,
        val requestsRealtimeData: Boolean,
        val replyHex: String? = null,
    ) {
        /** How the report annotates the step, so a reader can see WHY the verdict is what it is. */
        val roleNote: String
            get() = if (requestsRealtimeData) "asks for realtime ECG data"
                    else "cannot produce ECG data (configuration or OFF)"
    }

    /** The gate verdict, kept separate from the report text so it is assertable in a test. */
    sealed class Verdict {
        /**
         * Frames that PASS THE STRUCTURAL TRIAGE arrived. Not proof: the triage is a shape heuristic run
         * against ordinary live 5/MG traffic, so an unrelated packet can match.
         */
        data class EcgCandidatesArrived(val packets: Int) : Verdict()

        /** At least one command that ASKED FOR DATA came back FAILURE. */
        data class BlockedByDeviceFlagsLikely(val commands: List<String>) : Verdict()

        /**
         * A command that asks for no data came back FAILURE. The firmware refused THAT WRITE, which is a
         * fact about that opcode and says nothing about whether ECG generation is gated.
         */
        data class CommandRefused(val commands: List<String>) : Verdict()

        /** Everything acked SUCCESS, at least one of them a data request, and nothing ever arrived. */
        data class AcceptedButSilent(val windowSeconds: Int) : Verdict()

        /**
         * The run sent nothing that could produce realtime ECG data, so its silence is the expected
         * outcome and is evidence of nothing.
         */
        data class NoDataRequested(val commands: List<String>) : Verdict()

        /**
         * Data WAS requested, but the strap never returned SUCCESS for the request — so the silence
         * cannot be read as "accepted, then not honoured".
         */
        data class DataRequestNotAccepted(val commands: List<String>) : Verdict()

        /** The firmware rejected an opcode as unimplemented. */
        data class OpcodeUnsupported(val commands: List<String>) : Verdict()

        /** Nothing replied at all. */
        object NoReplies : Verdict()

        /** A mixed or unmapped set of codes that none of the above describes. */
        object Inconclusive : Verdict()

        val headline: String
            get() = when (this) {
                is EcgCandidatesArrived ->
                    "$packets frame(s) matched the ECG structural triage. That is a CANDIDATE, not proof: " +
                        "the triage is a shape heuristic and unrelated traffic can match it. Confirm against " +
                        "the raw bytes below before concluding anything about whether the feature is blocked."
                is BlockedByDeviceFlagsLikely ->
                    "LIKELY blockedByDeviceFlags — the firmware returned FAILURE for " +
                        "${commands.joinToString(", ")}, which asked it to produce ECG data: it knows the " +
                        "opcode and refused to run it."
                is CommandRefused ->
                    "REFUSED — the firmware returned FAILURE for ${commands.joinToString(", ")}. " +
                        "That command asks for no ECG data, so this is a fact about that write and NOT " +
                        "evidence that ECG generation is blocked. Nothing here speaks to the block question."
                is AcceptedButSilent ->
                    "Accepted but SILENT — a command that asks for realtime ECG data returned SUCCESS, every " +
                        "other command did too, yet no ECG packet arrived in ${windowSeconds}s. " +
                        "Consistent with a device-flag block applied as a silent no-op."
                is NoDataRequested ->
                    "NOT A TEST of whether ECG is blocked — this run sent no command that could produce " +
                        "realtime ECG data (${commands.joinToString(", ")}), so zero packets is the EXPECTED " +
                        "outcome and says nothing either way. Run the turn-on sequence to test the block question."
                is DataRequestNotAccepted ->
                    "INCONCLUSIVE — data was requested (${commands.joinToString(", ")}) but the strap never " +
                        "returned SUCCESS for it, so the silence cannot be read as 'accepted, then not " +
                        "honoured'. Retry idle."
                is OpcodeUnsupported ->
                    "Opcode UNSUPPORTED on this firmware for ${commands.joinToString(", ")} — " +
                        "not a device-flag block, the command is not implemented."
                is NoReplies ->
                    "No COMMAND_RESPONSE at all — the strap answered nothing. Silence is not evidence of a " +
                        "block (a mid-flight sync or a missed notification looks identical); retry idle."
                is Inconclusive ->
                    "INCONCLUSIVE — the result codes do not match a known pattern. The raw replies below are " +
                        "the record."
            }
    }

    /**
     * Classify the run.
     *
     * Order matters, and it puts the ATTESTED signals first: the COMMAND_RESPONSE result codes are real
     * wire semantics, whereas the packet count comes from a shape heuristic that unrelated traffic can
     * trip. So an explicit FAILURE or UNSUPPORTED from the firmware outranks a candidate count.
     *
     * The SECOND rule the order encodes is SCOPE: a claim about "is the ECG feature blocked" is only made
     * when the run exercised the ECG data path. A `FAILURE` on a command that asks for no data is a
     * refusal of that write; silence after a run that asked for no data is the expected outcome. Both get
     * their own verdict rather than being folded into the block case.
     */
    fun verdict(steps: List<Step>, ecgPacketsSeen: Int, windowSeconds: Int): Verdict {
        val failures = steps.filter { it.outcome is CommandOutcome.Failure }
        if (failures.isNotEmpty()) {
            // A refusal is only evidence about the BLOCK question when what was refused asked for data.
            val dataFailures = failures.filter { it.requestsRealtimeData }.map { it.label }
            if (dataFailures.isNotEmpty()) return Verdict.BlockedByDeviceFlagsLikely(dataFailures)
            return Verdict.CommandRefused(failures.map { it.label })
        }
        val unsupported = steps.filter { it.outcome is CommandOutcome.Unsupported }.map { it.label }
        if (unsupported.isNotEmpty()) return Verdict.OpcodeUnsupported(unsupported)
        if (ecgPacketsSeen > 0) return Verdict.EcgCandidatesArrived(ecgPacketsSeen)
        if (steps.isEmpty()) return Verdict.NoReplies
        if (steps.all { it.outcome is CommandOutcome.NoReply }) return Verdict.NoReplies
        // Past this point the verdict INTERPRETS SILENCE, which only carries information about the ECG
        // data path when the run asked that path for something and the strap said yes.
        val requests = steps.filter { it.requestsRealtimeData }
        if (requests.isEmpty()) return Verdict.NoDataRequested(steps.map { it.label })
        if (requests.none { it.outcome is CommandOutcome.Success }) {
            return Verdict.DataRequestNotAccepted(requests.map { it.label })
        }
        if (steps.all { it.outcome is CommandOutcome.Success }) {
            return Verdict.AcceptedButSilent(windowSeconds)
        }
        return Verdict.Inconclusive
    }

    /**
     * A tally of every CRC-valid live frame that reached the probe during the window, keyed by the
     * packet type byte and a coarse length bucket. Twin of Swift `Whoop5EcgProbe.FrameCensus`.
     *
     * ## Why this exists
     *
     * `ecgPacketsSeen` is incremented only after [Whoop5Ecg.plausibleFilteredFrame] passes, and that
     * triage assumes a fixed payload start ([Whoop5Ecg.PUFFIN_PAYLOAD_START]), a 17-byte header, four
     * bytes at `payload[2..5]` that are all <= 1, and a tight length agreement. An ECG record arriving
     * under a different packet type or a different header layout fails it silently. The probe kept no
     * tally of frames that arrived and failed, so a 30-second window in which many unrecognised frames
     * arrived rendered **identically** to one in which nothing arrived at all — and a run's zero could
     * not separate "acknowledged, then not honoured" from "this was the wrong transport to watch".
     *
     * ## What it is not
     *
     * An OBSERVATION, and nothing else. It is deliberately **not** a parameter of [verdict], so no
     * census can reach the classification — the report prints it beside the verdict, never inside it.
     * The table states what arrived and stops there.
     *
     * Unlike the Swift twin this takes no schema argument: Kotlin's [Framing.canonicalTypeName] reads
     * the [PacketType] table directly, where Swift threads a loaded `Schema`. The rendered text matches.
     */
    class FrameCensus {

        /** One census key: a packet type plus the length bucket the frame fell in. */
        data class Kind(val type: Int, val lengthBucket: Int) {
            /** The bucket as a closed range, e.g. "224-255". */
            val lengthRange: String get() = "$lengthBucket-${lengthBucket + FrameCensus.BUCKET_WIDTH - 1}"

            companion object {
                fun of(type: Int, length: Int): Kind =
                    Kind(type, maxOf(0, length) / FrameCensus.BUCKET_WIDTH * FrameCensus.BUCKET_WIDTH)
            }
        }

        private val tally = LinkedHashMap<Kind, Int>()

        val counts: Map<Kind, Int> get() = tally

        /**
         * Frames whose kind did not fit under [MAX_KINDS]. Counted, never itemised: tracking which
         * distinct kinds were dropped would need an unbounded set, which is the exact growth the cap
         * exists to prevent. A count is bounded and still says "the table below is not the whole story".
         */
        var framesBeyondCap = 0
            private set

        val isEmpty: Boolean get() = tally.isEmpty() && framesBeyondCap == 0
        val kindsRecorded: Int get() = tally.size
        val totalFramesObserved: Int get() = tally.values.sum() + framesBeyondCap

        /**
         * Count one frame. A kind already in the table keeps counting after the cap is reached; only a
         * NEW kind arriving at cap is diverted to [framesBeyondCap].
         */
        fun record(type: Int, length: Int) {
            val kind = Kind.of(type, length)
            val existing = tally[kind]
            when {
                existing != null -> tally[kind] = existing + 1
                tally.size < MAX_KINDS -> tally[kind] = 1
                else -> framesBeyondCap += 1
            }
        }

        /**
         * Count one whole 5/MG frame, reading its type byte at [TYPE_OFFSET].
         *
         * A frame too short to carry that byte cannot be keyed and is not counted. Unreachable for real
         * traffic — a CRC-valid 5/MG frame is longer than its own envelope — but stated rather than
         * hidden, since an uncounted frame is the failure mode this whole type exists to remove.
         */
        fun record(frame: ByteArray) {
            if (frame.size <= TYPE_OFFSET) return
            record(frame[TYPE_OFFSET].toInt() and 0xFF, frame.size)
        }

        fun count(type: Int, length: Int): Int = tally[Kind.of(type, length)] ?: 0

        /**
         * Render as a plain table.
         *
         * Type names come from [Framing.canonicalTypeName], so the puffin aliases fold onto the base
         * names and an unrecognised type renders with the shared `typeN` fallback rather than a name
         * invented here. The raw byte is always printed beside the name, so the table stays lossless if
         * the [PacketType] table is missing an entry.
         */
        fun table(): String {
            if (isEmpty) return "Live frame census: no live frames observed in the window.\n"
            val sb = StringBuilder()
            sb.append("Live frame census — every CRC-valid frame that reached the probe, counted by packet ")
            sb.append("type and length, whether or not it passed the ECG triage:\n")
            sb.append("  count  type                             length\n")
            // Deterministic order: busiest first, then by type and bucket, so a tie never reshuffles the
            // table between two runs of the same capture.
            val rows = tally.entries.sortedWith(
                compareByDescending<Map.Entry<Kind, Int>> { it.value }
                    .thenBy { it.key.type }
                    .thenBy { it.key.lengthBucket }
            )
            for ((kind, n) in rows) {
                val name = String.format("0x%02x ", kind.type) + Framing.canonicalTypeName(kind.type)
                sb.append("  ")
                sb.append(n.toString().padStart(5))
                sb.append("  ")
                sb.append(name.padEnd(31))
                sb.append("  ")
                sb.append(kind.lengthRange)
                sb.append("\n")
            }
            if (framesBeyondCap > 0) {
                sb.append("  + $framesBeyondCap further frame(s) in kinds past the ")
                sb.append("$MAX_KINDS-kind cap (counted, not itemised).\n")
            }
            return sb.toString()
        }

        companion object {
            /**
             * Lengths are bucketed rather than counted exactly: a live stream varies its payload length
             * frame to frame, and an exact-length key would pack the cap with near-duplicates of a
             * single kind and crowd out the distinct packet types the census exists to reveal.
             */
            const val BUCKET_WIDTH = 32

            /**
             * Distinct (type, length-bucket) kinds the table will hold, matching the probe's other caps
             * on the Apple side (`ecgProbeMaxCandidates` and `ecgProbeMaxSteps` are both 12): a chatty
             * stream must not be able to grow a report section without bound.
             */
            const val MAX_KINDS = 12

            /** The 5/MG packet type byte offset. */
            const val TYPE_OFFSET = 8
        }
    }

    /**
     * The full report: verdict, per-command outcomes, the ECG-packet tally, the live frame census, and
     * the raw replies.
     *
     * [candidateFrames] are the type/length lines for frames that passed the structural triage in
     * [Whoop5Ecg.plausibleFilteredPayload].
     *
     * [census] has NO default. An omitted census would render "no live frames observed" — manufacturing
     * the exact reassurance the census exists to remove — so, like [Step.requestsRealtimeData], every
     * call site is made to state it.
     */
    fun report(
        steps: List<Step>,
        ecgPacketsSeen: Int,
        candidateFrames: List<String>,
        census: FrameCensus,
        windowSeconds: Int,
    ): String {
        val sb = StringBuilder()
        sb.append("WHOOP MG ECG (Labrador) TURN-ON PROBE\n")
        sb.append("Verdict: ${verdict(steps, ecgPacketsSeen, windowSeconds).headline}\n")
        sb.append("\nCommands sent:\n")
        if (steps.isEmpty()) {
            sb.append("  (none)\n")
        } else {
            // Each step carries WHY it does or does not bear on the block question, so the verdict above
            // can be checked against its own inputs without reading the source.
            for (step in steps) sb.append("  ${step.label}: ${step.outcome.token} — ${step.roleNote}\n")
        }
        sb.append("\nECG-shaped packets seen in ${windowSeconds}s: $ecgPacketsSeen\n")
        if (steps.isNotEmpty() && steps.none { it.requestsRealtimeData }) {
            sb.append(
                "Zero is the EXPECTED result here: nothing in this run asked the strap for realtime ECG data.\n"
            )
        }
        if (candidateFrames.isEmpty()) {
            sb.append("Candidate packet types: none — no frame passed the structural triage.\n")
        } else {
            sb.append("Candidate packet types (structural triage only, NOT a confirmed mapping):\n")
            for (line in candidateFrames) sb.append("  $line\n")
        }
        // Printed BESIDE the verdict, never folded into it: `verdict` above takes no census argument.
        sb.append("\n").append(census.table())
        val replies = steps.mapNotNull { step -> step.replyHex?.let { "  ${step.label}: $it" } }
        if (replies.isNotEmpty()) {
            sb.append("\nRaw replies:\n")
            sb.append(replies.joinToString("\n") + "\n")
        }
        sb.append("\nThis is unvalidated instrumentation, not a medical measurement or a diagnosis.\n")
        return sb.toString()
    }
}
