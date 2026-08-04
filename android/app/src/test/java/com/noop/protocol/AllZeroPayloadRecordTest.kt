package com.noop.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [isAllZeroPayloadRecord] — the gate that keeps the Backfiller's reject hex dump (#91 / #30) from
 * full-frame-dumping records whose payload is entirely zero. Observed shape: structurally valid
 * 1584 B frames (21-byte header + 1,559 zero bytes + 4-byte CRC32 trailer), banked once per second
 * by a WHOOP 5/MG after a raw-data config-flag write. These mirror the Swift
 * `AllZeroPayloadRecordTests` 1:1 — SAME bounds, SAME behavior.
 */
class AllZeroPayloadRecordTest {

    /** A frame in the observed shape: nonzero header bytes, all-zero payload, nonzero CRC trailer. */
    private fun zeroPayloadFrame(size: Int = 1584): ByteArray {
        val f = ByteArray(size)
        for (i in 0 until 21) f[i] = ((i * 7 + 1) and 0xFF).toByte() // arbitrary nonzero header
        f[0] = 0xAA.toByte() // observed magic
        for (i in size - 4 until size) f[i] = 0xCD.toByte() // nonzero CRC32 trailer
        return f
    }

    @Test
    fun observedShapeIsAllZeroPayload() {
        assertTrue(isAllZeroPayloadRecord(zeroPayloadFrame()))
    }

    @Test
    fun singleNonzeroPayloadByteDefeatsIt() {
        // One nonzero byte anywhere in the payload region means there IS something to map — dump it.
        for (offset in intArrayOf(21, 800, 1579)) {
            val f = zeroPayloadFrame()
            f[offset] = 0x01
            assertFalse("nonzero byte at $offset must defeat the check", isAllZeroPayloadRecord(f))
        }
    }

    @Test
    fun nonzeroHeaderAndTrailerAreIgnored() {
        // The header and CRC trailer are ALWAYS nonzero on a real frame; only the payload matters.
        val f = zeroPayloadFrame()
        for (i in 0 until 21) f[i] = 0xFF.toByte()
        for (i in f.size - 4 until f.size) f[i] = 0xFF.toByte()
        assertTrue(isAllZeroPayloadRecord(f))
    }

    @Test
    fun tooShortFrameIsNeverAllZeroPayload() {
        // A frame with no payload region at all (≤ header + trailer) must be dumped, not summarized —
        // there is nothing to classify, and short frames are exactly the unfamiliar ones worth seeing.
        assertFalse(isAllZeroPayloadRecord(ByteArray(25)))
        assertFalse(isAllZeroPayloadRecord(ByteArray(24)))
        assertFalse(isAllZeroPayloadRecord(ByteArray(0)))
    }

    @Test
    fun minimalOneBytePayload() {
        // 26 B = 21 header + 1 payload byte + 4 trailer: the smallest frame the check can classify.
        val f = ByteArray(26)
        f[0] = 0xAA.toByte()
        assertTrue(isAllZeroPayloadRecord(f))
        f[21] = 0x01
        assertFalse(isAllZeroPayloadRecord(f))
    }

    @Test
    fun smallUnmappedRecordsStayDumpable() {
        // v25/v26-sized records (~84 B) with real payload bytes — the frames #91's dump exists for —
        // must never be classified as zero-payload.
        val f = ByteArray(84)
        f[0] = 0xAA.toByte()
        f[40] = 0x5A
        assertFalse(isAllZeroPayloadRecord(f))
    }
}
