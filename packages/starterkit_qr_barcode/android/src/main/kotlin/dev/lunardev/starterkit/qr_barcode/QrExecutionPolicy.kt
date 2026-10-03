package dev.lunardev.starterkit.qr_barcode

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Process-wide admission deliberately stores no engine, callback, payload, or result. */
internal object QrProcessAdmission {
    private val occupied = AtomicBoolean(false)
    fun acquire(): Boolean = occupied.compareAndSet(false, true)
    fun release() { check(occupied.compareAndSet(true, false)) }
    internal fun isOccupiedForTest(): Boolean = occupied.get()
}

internal data class QrOperationToken(val generation: Long, val identity: Any)

/** Engine-local identity fence used by the real method-channel adapter. */
internal class QrOperationFence {
    private var generation = 0L
    private var current: QrOperationToken? = null

    @Synchronized fun begin(): QrOperationToken? {
        if (current != null) return null
        generation += 1
        return QrOperationToken(generation, Any()).also { current = it }
    }

    @Synchronized fun isCurrent(token: QrOperationToken): Boolean = current === token

    @Synchronized fun finish(token: QrOperationToken): Boolean {
        if (current !== token || token.generation != generation) return false
        current = null
        return true
    }

    @Synchronized fun detach(token: QrOperationToken): Boolean = finish(token)
}

/** Thin scheduling seam: constructing/registering the plugin never starts a thread. */
internal class QrWorkerStarter(private val start: (Runnable) -> Unit) {
    fun submit(task: Runnable) = start(task)

    /** Either the worker owns cleanup, or rejection prevents it from ever running. */
    fun submitOwned(task: Runnable, rejected: () -> Unit) {
        val state = AtomicInteger(0) // queued, running, finished, rejected
        val guarded = Runnable {
            if (state.compareAndSet(0, 1)) {
                try { task.run() } finally { state.set(2) }
            }
        }
        try { start(guarded) } catch (_: Throwable) {
            // A scheduler may throw after starting/enqueuing. Never release a running lease.
            if (state.compareAndSet(0, 3)) rejected()
        }
    }
}
