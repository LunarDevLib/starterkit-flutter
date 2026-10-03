package dev.lunardev.starterkit.qr_barcode

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class QrOperationRunnerTest {
    private val args = mapOf("bytes" to byteArrayOf(1, 2, 3))
    private val success = QrDecodeResult("success", "qr.success", listOf(QrCode("hello", "QR")))
    private fun envelope(kind: String, code: String) = mapOf("kind" to kind, "code" to code)

    private class Harness {
        val workers = mutableListOf<Runnable>()
        val main = mutableListOf<Runnable>()
        val replies = mutableListOf<Map<String, Any>>()
        var copies = 0
        var decodes = 0
        var snapshot: ByteArray? = null
        var posting: (Runnable) -> Boolean = { main.add(it); true }
        var decoding: (ByteArray) -> QrDecodeResult = { QrDecodeResult("noResult", "qr.no_result") }
        var copying: (ByteArray) -> ByteArray = { it.clone() }
        val runner = QrOperationRunner(
            post = { posting(it) },
            decode = { decodes++; decoding(it) },
            copy = { copies++; copying(it).also { snapshot = it } },
        ).also { it.workerStarter = QrWorkerStarter { task -> workers.add(task) } }
        fun call(arguments: Any? = mapOf("bytes" to byteArrayOf(1, 2, 3))) {
            runner.decode(arguments) { replies.add(it) }
        }
    }

    @After fun noLeakedProcessLease() { assertFalse(QrProcessAdmission.isOccupiedForTest()) }

    @Test fun registrationAndDetachedCallsDoNotCopyDispatchOrAcquire() {
        val h = Harness()
        h.call()
        assertEquals(listOf(envelope("unavailable", "qr.unavailable")), h.replies)
        assertEquals(0, h.copies)
        assertTrue(h.workers.isEmpty())
        h.runner.attach()
        assertEquals(0, h.copies)
        assertTrue(h.workers.isEmpty())
        h.runner.detach()
        h.call()
        assertEquals(2, h.replies.size)
        assertFalse(h.runner.hasPendingForTest())
    }

    @Test fun invalidArgumentsAndByteBoundsRejectBeforeCopyOrDispatch() {
        val h = Harness()
        h.runner.attach()
        h.call(null)
        h.call(mapOf("bytes" to "bad"))
        h.call(mapOf("bytes" to byteArrayOf(1), "extra" to true))
        h.call(mapOf("bytes" to byteArrayOf()))
        h.call(mapOf("bytes" to ByteArray(QrDecoder.MAX_BYTES + 1)))
        assertEquals(listOf(
            envelope("invalid", "qr.invalid_request"), envelope("invalid", "qr.invalid_request"),
            envelope("invalid", "qr.invalid_request"), envelope("invalid", "qr.invalid_image"),
            envelope("invalid", "qr.image_too_large"),
        ), h.replies)
        assertEquals(0, h.copies)
        assertTrue(h.workers.isEmpty())
    }

    @Test fun acceptedInputIsSnapshottedAndSettledExactlyOnceOnMain() {
        val h = Harness()
        h.runner.attach()
        val input = byteArrayOf(1, 2, 3)
        h.decoding = { assertArrayEquals(byteArrayOf(1, 2, 3), it); success }
        h.call(mapOf("bytes" to input))
        input.fill(9)
        assertTrue(QrProcessAdmission.isOccupiedForTest())
        h.workers.single().run()
        h.workers.single().run() // a misbehaving scheduler cannot run the decode twice
        assertEquals(1, h.decodes)
        assertArrayEquals(byteArrayOf(0, 0, 0), h.snapshot)
        assertTrue(h.replies.isEmpty())
        assertTrue(h.runner.hasPendingForTest())
        h.main.single().run()
        h.main.single().run()
        assertEquals(listOf(success.asMap()), h.replies)
        assertFalse(h.runner.hasPendingForTest())
    }

    @Test fun conflictingEngineAndSameEngineNeverCopyOrDisturbIncumbent() {
        val incumbent = Harness()
        val other = Harness()
        incumbent.runner.attach()
        other.runner.attach()
        incumbent.call()
        incumbent.call()
        other.call()
        assertEquals(1, incumbent.copies)
        assertEquals(0, other.copies)
        assertEquals(listOf(envelope("conflict", "qr.operation_in_progress")), other.replies)
        assertTrue(incumbent.runner.hasPendingForTest())
        incumbent.workers.single().run()
        incumbent.main.single().run()
        assertEquals(envelope("noResult", "qr.no_result"), incumbent.replies.last())
    }

    @Test fun detachCancelsOnceKeepsLeaseAndFencesLateResultAfterReattach() {
        val old = Harness()
        val other = Harness()
        old.runner.attach()
        other.runner.attach()
        old.call()
        old.runner.detach()
        old.runner.detach()
        assertEquals(listOf(envelope("cancelled", "qr.engine_detached")), old.replies)
        assertFalse(old.runner.hasPendingForTest())
        assertTrue(QrProcessAdmission.isOccupiedForTest())
        old.runner.attach()
        other.call()
        assertEquals(0, other.copies)
        old.workers.single().run()
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        old.call() // replacement starts before the stale main completion is delivered
        old.main.single().run()
        assertTrue(old.runner.hasPendingForTest())
        assertEquals(1, old.replies.size)
        old.workers.last().run()
        old.main.last().run()
        assertEquals(envelope("noResult", "qr.no_result"), old.replies.last())
    }

    @Test fun detachAfterDecodeBeforeMainDeliveryDropsQueuedSuccess() {
        val h = Harness()
        h.runner.attach()
        h.call()
        h.workers.single().run()
        h.runner.detach()
        h.runner.attach()
        h.main.single().run()
        assertEquals(listOf(envelope("cancelled", "qr.engine_detached")), h.replies)
        assertFalse(h.runner.hasPendingForTest())
    }

    @Test fun falseMainPostClearsOperationWithoutOffMainSettlementAndAllowsReentry() {
        assertFailedPostCleanup(throws = false)
    }

    @Test fun throwingMainPostClearsOperationWithoutOffMainSettlementAndAllowsReentry() {
        assertFailedPostCleanup(throws = true)
    }

    private fun assertFailedPostCleanup(throws: Boolean) {
        val h = Harness()
        h.runner.attach()
        h.posting = {
            h.main.add(it) // even a retained/enqueued callback must no longer contain a reply
            if (throws) throw IllegalStateException("post") else false
        }
        h.call()
        h.workers.single().run()
        assertTrue(h.replies.isEmpty())
        assertFalse(h.runner.hasPendingForTest())
        assertArrayEquals(byteArrayOf(0, 0, 0), h.snapshot)
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        h.posting = { h.main.add(it); true }
        h.call()
        h.main.first().run()
        assertTrue(h.runner.hasPendingForTest())
        assertTrue(h.replies.isEmpty())
        h.workers.last().run()
        h.main.last().run()
        assertEquals(listOf(envelope("noResult", "qr.no_result")), h.replies)
    }

    @Test fun schedulerThrowBeforeStartSettlesOnceCleansSnapshotAndAllowsRetry() {
        val h = Harness()
        h.runner.attach()
        h.runner.workerStarter = QrWorkerStarter { throw IllegalStateException("scheduler") }
        h.call()
        assertEquals(listOf(envelope("failure", "qr.decode_error")), h.replies)
        assertFalse(h.runner.hasPendingForTest())
        assertArrayEquals(byteArrayOf(0, 0, 0), h.snapshot)
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        h.runner.workerStarter = QrWorkerStarter { h.workers.add(it) }
        h.call()
        h.workers.single().run()
        h.main.single().run()
        assertEquals(2, h.replies.size)
    }

    @Test fun enqueueThenThrowRevokesQueuedWorkerSoItCannotDecodeOrReleaseAgain() {
        val h = Harness()
        h.runner.attach()
        h.runner.workerStarter = QrWorkerStarter { h.workers.add(it); throw IllegalStateException("queued") }
        h.call()
        val rejected = h.workers.single()
        assertEquals(listOf(envelope("failure", "qr.decode_error")), h.replies)
        val replacement = Harness()
        replacement.runner.attach()
        replacement.call()
        rejected.run()
        assertEquals(0, h.decodes)
        assertTrue(QrProcessAdmission.isOccupiedForTest())
        assertTrue(h.main.isEmpty())
        replacement.workers.single().run()
        replacement.main.single().run()
    }

    @Test fun throwAfterRealWorkerStartsCannotReleaseOrWipeItsLeaseEarly() {
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val h = Harness()
        var thread: Thread? = null
        var observedInput: ByteArray? = null
        var workerFailure: Throwable? = null
        h.decoding = {
            entered.countDown()
            check(finish.await(5, TimeUnit.SECONDS))
            observedInput = it.clone()
            success
        }
        h.runner.workerStarter = QrWorkerStarter {
            thread = Thread(it).also { worker ->
                worker.setUncaughtExceptionHandler { _, error -> workerFailure = error }
                worker.start()
            }
            check(entered.await(5, TimeUnit.SECONDS))
            throw IllegalStateException("already started")
        }
        h.runner.attach()
        try {
            h.call()
            assertTrue(QrProcessAdmission.isOccupiedForTest())
            assertArrayEquals(byteArrayOf(1, 2, 3), h.snapshot)
            assertTrue(h.replies.isEmpty())
            h.runner.detach()
            h.runner.attach()
            h.call()
            assertEquals(1, h.copies)
            assertEquals(listOf(envelope("cancelled", "qr.engine_detached"), envelope("conflict", "qr.operation_in_progress")), h.replies)
            assertTrue(QrProcessAdmission.isOccupiedForTest())
        } finally {
            finish.countDown()
            thread?.join(5000)
        }
        assertFalse(thread!!.isAlive)
        assertNull(workerFailure)
        assertArrayEquals(byteArrayOf(1, 2, 3), observedInput)
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        assertArrayEquals(byteArrayOf(0, 0, 0), h.snapshot)
        h.main.single().run()
        assertEquals(2, h.replies.size)
    }

    @Test fun throwAfterSynchronousWorkerFinishesDoesNotReleaseTwiceOrSettleAgain() {
        val h = Harness()
        h.runner.attach()
        h.runner.workerStarter = QrWorkerStarter { it.run(); throw IllegalStateException("finished") }
        h.call()
        assertTrue(h.replies.isEmpty())
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        h.main.single().run()
        assertEquals(listOf(envelope("noResult", "qr.no_result")), h.replies)
    }

    @Test fun decoderThrowableProducesFixedFailureAndAlwaysWipesAndReleases() {
        val h = Harness()
        h.runner.attach()
        h.decoding = { throw OutOfMemoryError("not exposed") }
        h.call()
        h.workers.single().run()
        assertArrayEquals(byteArrayOf(0, 0, 0), h.snapshot)
        h.main.single().run()
        assertEquals(listOf(envelope("failure", "qr.decode_error")), h.replies)
        assertFalse(h.runner.hasPendingForTest())
    }

    @Test fun snapshotOomUsesImageTooLargeAndReleasesBeforeRetry() {
        assertSnapshotFailure(OutOfMemoryError("not exposed"), envelope("invalid", "qr.image_too_large"))
    }

    @Test fun snapshotExceptionUsesFixedFailureAndReleasesBeforeRetry() {
        assertSnapshotFailure(IllegalStateException("not exposed"), envelope("failure", "qr.decode_error"))
    }

    private fun assertSnapshotFailure(error: Throwable, expected: Map<String, String>) {
        val h = Harness()
        h.runner.attach()
        h.copying = { throw error }
        h.call()
        assertEquals(listOf(expected), h.replies)
        assertFalse(h.runner.hasPendingForTest())
        assertTrue(h.workers.isEmpty())
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        h.copying = { it.clone() }
        h.call()
        h.workers.single().run()
        h.main.single().run()
        assertEquals(2, h.replies.size)
    }

    @Test fun throwingReplyCannotRetainOperationOnMainCompletionOrDetach() {
        for (detach in listOf(false, true)) {
            val h = Harness()
            h.runner.attach()
            h.runner.decode(args) { throw IllegalStateException("reply") }
            if (!detach) h.workers.single().run()
            try {
                if (detach) h.runner.detach() else h.main.single().run()
                fail("reply must throw")
            } catch (_: IllegalStateException) { }
            assertFalse(h.runner.hasPendingForTest())
            if (detach) {
                assertTrue(QrProcessAdmission.isOccupiedForTest())
                h.workers.single().run()
                h.main.single().run()
            }
        }
    }

    @Test fun throwingRejectionReplyStillReleasesLeaseAndClearsOperation() {
        val h = Harness()
        h.runner.attach()
        h.runner.workerStarter = QrWorkerStarter { throw IllegalStateException("schedule") }
        try {
            h.runner.decode(args) { throw IllegalStateException("reply") }
            fail("reply must throw")
        } catch (_: IllegalStateException) { }
        assertFalse(h.runner.hasPendingForTest())
        assertArrayEquals(byteArrayOf(0, 0, 0), h.snapshot)
    }
}
