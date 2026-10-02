package dev.lunardev.starterkit.platform

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaPolicyTest {
    @Test
    fun limitsFailClosedOutsideBoundedRange() {
        assertNotNull(MediaLimits.parse(mapOf("maxBytes" to 1024, "maxPixels" to 4000)))
        assertNull(MediaLimits.parse(mapOf("maxBytes" to 0, "maxPixels" to 4000)))
        assertNull(
            MediaLimits.parse(
                mapOf("maxBytes" to MediaLimits.MAX_BYTES + 1, "maxPixels" to 4000),
            ),
        )
    }

    @Test
    fun dimensionsAreBoundedBeforeDecode() {
        val limits = MediaLimits(maxBytes = 1024, maxPixels = 100)
        assertTrue(MediaPolicy.validDimensions(10, 10, limits))
        assertFalse(MediaPolicy.validDimensions(11, 10, limits))
        assertFalse(MediaPolicy.validDimensions(0, 10, limits))
    }

    @Test
    fun cleanupOwnershipRejectsSiblingPaths() {
        val root = Files.createTempDirectory("starterkit-media").toFile()
        val child = File(root, "child.jpg")
        val sibling = File(root.parentFile, "sibling.jpg")
        try {
            assertTrue(MediaPolicy.ownedPath(root, child))
            assertFalse(MediaPolicy.ownedPath(root, sibling))
        } finally {
            root.deleteRecursively()
            sibling.delete()
        }
    }

    @Test
    fun operationInvalidationCleansAlreadyTrackedAndLateFiles() {
        val first = Files.createTempFile("starterkit-media", ".tmp").toFile()
        val late = Files.createTempFile("starterkit-media", ".tmp").toFile()
        val operation = MediaOperationState(1, first)
        operation.invalidate()
        assertFalse(first.exists())
        val running = MediaOperationState(2)
        assertTrue(running.acceptActivityResult(2))
        assertTrue(running.startWork())
        running.invalidate()
        assertFalse(running.trackWorkerFile(late))
        assertTrue(late.exists()) // Only the worker knows when its writes have stopped.
        assertFalse(running.finishWork(keepFile = true))
        assertFalse(late.exists())
        assertFalse(operation.isActive())
    }

    @Test
    fun queuedWorkCannotSettleAfterDetach() {
        val output = Files.createTempFile("starterkit-media", ".tmp").toFile()
        val operation = MediaOperationState(1, output)
        assertTrue(operation.acceptActivityResult(1))
        operation.invalidate() // Detach wins before queued work begins.
        assertFalse(operation.startWork())
        assertTrue(operation.settle())
        assertFalse(operation.isActive())
        assertFalse(output.exists())
        assertFalse(operation.settle())
    }

    @Test
    fun runningWorkCannotRetainOutputOrSettleAfterDetach() {
        val ready = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val output = Files.createTempFile("starterkit-media", ".tmp").toFile()
        val operation = MediaOperationState(1, output)
        assertTrue(operation.acceptActivityResult(1))
        var workerFinished = true
        val worker = Thread {
            assertTrue(operation.startWork())
            ready.countDown()
            resume.await()
            output.writeText("late worker write")
            workerFinished = operation.finishWork(keepFile = true)
        }.apply { start() }

        ready.await()
        operation.invalidate()
        assertTrue(operation.settle())
        assertTrue(output.exists())
        resume.countDown()
        worker.join()
        assertFalse(output.exists())
        assertFalse(workerFinished)
    }

    @Test
    fun completionQueuedBeforeDetachCannotPublishLateSuccess() {
        val validatedOutput = Files.createTempFile("starterkit-media", ".tmp").toFile()
        val operation = MediaOperationState(1, validatedOutput)
        assertTrue(operation.acceptActivityResult(1))
        assertTrue(operation.startWork())
        assertTrue(operation.finishWork(keepFile = true))
        val ready = CountDownLatch(1)
        val publish = CountDownLatch(1)
        var published = false
        val callback = Thread {
            ready.countDown()
            publish.await()
            published = operation.settle()
        }.apply { start() }

        ready.await()
        operation.invalidate()
        assertTrue(operation.settle())
        publish.countDown()
        callback.join()
        assertFalse(validatedOutput.exists())
        assertFalse(published)
    }

    @Test
    fun operationCanSettleOnlyOnceAcrossConcurrentCompletionAttempts() {
        val operation = MediaOperationState(1)
        val ready = CountDownLatch(8)
        val start = CountDownLatch(1)
        val winners = AtomicInteger()
        val threads = (1..8).map {
            Thread {
                ready.countDown()
                start.await()
                if (operation.settle()) winners.incrementAndGet()
            }.apply { start() }
        }
        ready.await()
        start.countDown()
        threads.forEach { it.join() }
        assertTrue(winners.get() == 1)
    }

    @Test
    fun providerFailuresAreClassifiedWithoutExposingExceptionDetails() {
        assertEquals(
            "denied",
            MediaPolicy.galleryFailure(SecurityException("private")).getValue("kind"),
        )
        assertEquals(
            "invalid",
            MediaPolicy.galleryFailure(MediaTooLargeException()).getValue("kind"),
        )
        assertEquals(
            "failure",
            MediaPolicy.galleryFailure(IllegalStateException("private")).getValue("kind"),
        )
        assertFalse(
            MediaPolicy.galleryFailure(IllegalStateException("private")).containsKey("message"),
        )
    }

    @Test
    fun sampledDecodeSizingStaysWithinPixelBudget() {
        val sample = MediaPolicy.sampleSize(10_000, 10_000, 400_000)
        val sampledPixels = ((10_000L + sample - 1) / sample) * ((10_000L + sample - 1) / sample)
        assertTrue(sampledPixels <= 400_000)
    }

    @Test
    fun decodeMustProduceAValidBitmap() {
        assertFalse(MediaPolicy.validDecodedContent(null, null))
        assertFalse(MediaPolicy.validDecodedContent(0, 10))
        assertTrue(MediaPolicy.validDecodedContent(10, 10))
    }

    @Test
    fun onlyExplicitCancellationIsReportedAsCancelled() {
        assertEquals(
            "cancelled",
            MediaPolicy.activityResultFailure(-1, -1, "gallery.cancelled", "gallery.pick_failed").getValue("kind"),
        )
        assertEquals(
            "failure",
            MediaPolicy.activityResultFailure(0, -1, "gallery.cancelled", "gallery.pick_failed").getValue("kind"),
        )
    }
}
