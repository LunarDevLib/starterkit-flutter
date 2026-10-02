package dev.lunardev.starterkit.platform

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaResultFenceTest {
    @Test
    fun stalePreDetachResultCannotClaimReplacementOperation() {
        val allocator = MediaRequestCodeAllocator(0x5300, 0x5301)
        val oldCode = allocator.allocate()!!
        val old = MediaOperationState(oldCode)
        old.invalidate()
        assertTrue(old.settle())
        val currentCode = allocator.allocate()!!
        val current = MediaOperationState(currentCode)

        assertNotEquals(oldCode, currentCode)
        assertFalse(current.acceptActivityResult(oldCode))
        assertFalse(current.startWork())
        assertTrue(current.acceptActivityResult(currentCode))
        assertTrue(current.startWork())
        assertNull(allocator.allocate())
    }

    @Test
    fun duplicateResultsCannotQueueStartOrCompleteAnotherWorker() {
        val code = 0x5300
        val operation = MediaOperationState(code)
        assertTrue(operation.acceptActivityResult(code))
        assertFalse(operation.acceptActivityResult(code)) // Queued.
        assertTrue(operation.startWork())
        assertFalse(operation.acceptActivityResult(code)) // Running.
        assertFalse(operation.startWork())
        assertTrue(operation.finishWork(keepFile = true))
        assertFalse(operation.acceptActivityResult(code)) // Completion queued for main.
        assertFalse(operation.startWork())
        assertFalse(operation.finishWork(keepFile = true))
        assertTrue(operation.settle())
        assertFalse(operation.acceptActivityResult(code))
    }

    @Test
    fun simultaneousIncomingResultsHaveExactlyOneWinner() {
        val operation = MediaOperationState(0x5300)
        val ready = CountDownLatch(8)
        val start = CountDownLatch(1)
        val winners = AtomicInteger()
        val threads = (1..8).map {
            Thread {
                ready.countDown()
                check(start.await(5, TimeUnit.SECONDS))
                if (operation.acceptActivityResult(0x5300)) winners.incrementAndGet()
            }.apply { start() }
        }
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        start.countDown()
        threads.forEach { it.join(5_000) }
        assertTrue(threads.none { it.isAlive })
        assertEquals(1, winners.get())
        assertTrue(operation.startWork())
        assertTrue(operation.finishWork(keepFile = true))
    }

    @Test
    fun staleCompletedOutputIsRemovedOnceWithoutConsumingCurrentResult() {
        val output = countingOutput()
        try {
            val old = MediaOperationState(0x5300, output)
            assertTrue(old.acceptActivityResult(0x5300))
            assertTrue(old.startWork())
            assertTrue(old.finishWork(keepFile = true))
            val current = MediaOperationState(0x5301)

            // Mirrors the plugin's rejected-completion branch, even for a success outcome.
            old.invalidate()
            old.invalidate()
            assertFalse(old.finishWork(keepFile = true))
            assertFalse(output.exists())
            assertEquals(1, output.deletions.get())
            assertFalse(current.acceptActivityResult(0x5300))
            assertTrue(current.acceptActivityResult(0x5301))
            assertTrue(current.startWork())
        } finally {
            if (output.exists()) output.delete()
        }
    }

    @Test
    fun detachNeverDeletesOrRecreatesOutputWhileWorkerCanStillWrite() {
        val output = countingOutput()
        try {
            val operation = MediaOperationState(0x5300)
            assertTrue(operation.acceptActivityResult(0x5300))
            assertTrue(operation.startWork())
            assertTrue(operation.trackWorkerFile(output))
            operation.invalidate()
            assertTrue(operation.settle())
            operation.invalidate()
            assertEquals(0, output.deletions.get())
            assertTrue(output.exists())
            output.writeText("write finishes after detach")
            assertFalse(operation.finishWork(keepFile = true))
            assertFalse(output.exists())
            assertEquals(1, output.deletions.get())
            operation.invalidate()
            assertFalse(operation.finishWork(keepFile = true))
            assertEquals(1, output.deletions.get())
        } finally {
            if (output.exists()) output.delete()
        }
    }

    @Test
    fun failedWorkerCleansOutputOnceAfterStreamsHaveClosed() {
        val output = countingOutput()
        try {
            val operation = MediaOperationState(0x5300)
            assertTrue(operation.acceptActivityResult(0x5300))
            assertTrue(operation.startWork())
            assertTrue(operation.trackWorkerFile(output))
            output.outputStream().use { it.write(1) }
            assertTrue(operation.finishWork(keepFile = false))
            assertFalse(output.exists())
            operation.invalidate()
            assertTrue(operation.settle())
            assertEquals(1, output.deletions.get())
        } finally {
            if (output.exists()) output.delete()
        }
    }

    @Test
    fun deliveredOutputOwnershipSurvivesLateDuplicateCompletion() {
        val output = countingOutput()
        try {
            val operation = MediaOperationState(0x5300, output)
            assertTrue(operation.acceptActivityResult(0x5300))
            assertTrue(operation.startWork())
            assertTrue(operation.finishWork(keepFile = true))
            assertTrue(operation.settle())
            operation.forgetFile()
            assertFalse(operation.settle())
            operation.invalidate()
            assertTrue(output.exists())
            assertEquals(0, output.deletions.get())
        } finally {
            if (output.exists()) output.delete()
        }
    }

    @Test
    fun allocatorIsBoundedSixteenBitAndNeverWrapsAfterExhaustion() {
        val allocator = MediaRequestCodeAllocator(0xfffe, 0xffff)
        assertEquals(0xfffe, allocator.allocate())
        assertEquals(0xffff, allocator.allocate())
        repeat(10) { assertNull(allocator.allocate()) }
    }

    @Test
    fun concurrentAllocationsDoNotCollideOrReuseCodes() {
        val allocator = MediaRequestCodeAllocator(0x5300, 0x530f)
        val ready = CountDownLatch(16)
        val start = CountDownLatch(1)
        val codes = arrayOfNulls<Int>(16)
        val threads = codes.indices.map { index ->
            Thread {
                ready.countDown()
                check(start.await(5, TimeUnit.SECONDS))
                codes[index] = allocator.allocate()
            }.apply { start() }
        }
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        start.countDown()
        threads.forEach { it.join(5_000) }
        assertTrue(threads.none { it.isAlive })
        assertEquals((0x5300..0x530f).toSet(), codes.toSet())
        assertNull(allocator.allocate())
    }

    @Test
    fun processAllocatorIsSharedAcrossOperationOwners() {
        val first = MediaOperationState(MediaRequestCodes.allocate()!!)
        first.invalidate()
        val second = MediaOperationState(MediaRequestCodes.allocate()!!)
        assertNotEquals(first.requestCode, second.requestCode)
        assertTrue(first.requestCode in 0x5300..0x53ff)
        assertTrue(second.requestCode in 0x5300..0x53ff)
        assertFalse(second.acceptActivityResult(first.requestCode))
        assertTrue(second.acceptActivityResult(second.requestCode))
    }

    private fun countingOutput(): CountingFile =
        CountingFile(Files.createTempFile("starterkit-result-fence", ".tmp").toFile())

    private class CountingFile(file: File) : File(file.path) {
        val deletions = AtomicInteger()

        override fun delete(): Boolean {
            deletions.incrementAndGet()
            return super.delete()
        }
    }
}
