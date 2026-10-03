package dev.lunardev.starterkit.qr_barcode

import org.junit.Assert.*
import org.junit.Test

class QrExecutionPolicyTest {
    @Test fun admissionIsExclusiveUntilRealWorkerReleasesIt() {
        assertTrue(QrProcessAdmission.acquire())
        val oldFence = QrOperationFence()
        val old = oldFence.begin()!!
        var worker: Runnable? = null
        val starter = QrWorkerStarter { worker = it }
        starter.submit(Runnable {
            try { assertFalse(oldFence.finish(old)) } // late worker cannot settle detached engine
            finally { QrProcessAdmission.release() }
        })
        assertTrue(oldFence.detach(old))
        assertFalse(QrProcessAdmission.acquire()) // reattached engine sees conflict while old worker runs
        worker!!.run() // lease ends only as the accepted worker unwinds
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        assertTrue(QrProcessAdmission.acquire())
        QrProcessAdmission.release()
    }

    @Test fun fenceRejectsLateAndDuplicateCompletionAndPreservesIncumbent() {
        val fence = QrOperationFence()
        val first = fence.begin()!!
        assertNull(fence.begin())
        assertTrue(fence.finish(first))
        val replacement = fence.begin()!!
        assertFalse(fence.finish(first))
        assertTrue(fence.isCurrent(replacement))
        assertTrue(fence.finish(replacement))
        assertFalse(fence.finish(replacement))
    }

    @Test fun detachInvalidatesOnlyItsOperation() {
        val fence = QrOperationFence()
        val op = fence.begin()!!
        assertTrue(fence.detach(op))
        assertFalse(fence.isCurrent(op))
        val fresh = fence.begin()!!
        assertFalse(fence.finish(op))
        assertTrue(fence.finish(fresh))
    }

    @Test fun workerIsLazyAndSynchronousSchedulerFailureCanBeHandled() {
        var starts = 0
        val starter = QrWorkerStarter { starts++; throw IllegalStateException("scheduler") }
        assertEquals(0, starts)
        try { starter.submit(Runnable { fail("must not run") }) } catch (_: IllegalStateException) { }
        assertEquals(1, starts)
    }

    @Test fun workerSeamRunsOnlySubmittedTaskAndSupportsReentryAfterRelease() {
        var queued: Runnable? = null
        val starter = QrWorkerStarter { check(queued == null); queued = it }
        assertNull(queued)
        starter.submit(Runnable { QrProcessAdmission.release() })
        assertNotNull(queued)
        assertTrue(QrProcessAdmission.acquire())
        val task = queued!!
        queued = null
        task.run()
        assertFalse(QrProcessAdmission.isOccupiedForTest())
        assertTrue(QrProcessAdmission.acquire())
        QrProcessAdmission.release()
    }
}
