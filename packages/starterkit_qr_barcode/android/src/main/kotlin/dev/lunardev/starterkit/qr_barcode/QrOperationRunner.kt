package dev.lunardev.starterkit.qr_barcode

/** Engine-local lifecycle/cleanup used by the channel adapter; contains no Android APIs. */
internal class QrOperationRunner(
    private val post: (Runnable) -> Boolean,
    private val decode: (ByteArray) -> QrDecodeResult = { QrDecoder.decodeImage(it) },
    private val copy: (ByteArray) -> ByteArray = { it.clone() },
) {
    var workerStarter = QrWorkerStarter { task ->
        Thread(task, "starterkit-qr-decode").apply { isDaemon = true; start() }
    }
    private val fence = QrOperationFence()
    private var attached = false
    private var operation: Pending? = null
    private class Pending(val token: QrOperationToken, var reply: ((Map<String, Any>) -> Unit)?)

    @Synchronized fun attach() { attached = true }

    fun detach() {
        val reply = synchronized(this) {
            attached = false
            operation?.let { take(it) }
        }
        reply?.invoke(QrDecodeResult("cancelled", "qr.engine_detached").asMap())
    }

    fun decode(arguments: Any?, reply: (Map<String, Any>) -> Unit) {
        val input: ByteArray
        val pending: Pending
        synchronized(this) {
            // Detached native calls must never acquire admission, copy, or start workers.
            if (!attached) { reply(QrDecodeResult("unavailable", "qr.unavailable").asMap()); return }
            val args = arguments as? Map<*, *>
            if (args == null || args.keys != setOf("bytes") || args["bytes"] !is ByteArray) {
                reply(QrDecodeResult("invalid", "qr.invalid_request").asMap()); return
            }
            input = args["bytes"] as ByteArray
            if (input.isEmpty()) { reply(QrDecodeResult("invalid", "qr.invalid_image").asMap()); return }
            if (input.size > QrDecoder.MAX_BYTES) { reply(QrDecodeResult("invalid", "qr.image_too_large").asMap()); return }
            if (!QrProcessAdmission.acquire()) {
                reply(QrDecodeResult("conflict", "qr.operation_in_progress").asMap()); return
            }
            val token = fence.begin()
            if (token == null) {
                QrProcessAdmission.release()
                reply(QrDecodeResult("conflict", "qr.operation_in_progress").asMap()); return
            }
            pending = Pending(token, reply)
            operation = pending
        }
        val snapshot = try { copy(input) } catch (_: OutOfMemoryError) {
            try { complete(pending, QrDecodeResult("invalid", "qr.image_too_large")) }
            finally { QrProcessAdmission.release() }
            return
        } catch (_: Throwable) {
            try { complete(pending, QrDecodeResult("failure", "qr.decode_error")) }
            finally { QrProcessAdmission.release() }
            return
        }
        workerStarter.submitOwned(Runnable {
            try {
                val decoded = try { decode(snapshot) }
                catch (_: Throwable) { QrDecodeResult("failure", "qr.decode_error") }
                try {
                    if (!post(Runnable { complete(pending, decoded) })) abandon(pending)
                } catch (_: Throwable) {
                    // No valid main boundary remains. Drop callbacks rather than call Flutter off-main.
                    abandon(pending)
                }
            } catch (_: Throwable) {
                abandon(pending)
            } finally {
                snapshot.fill(0)
                QrProcessAdmission.release()
            }
        }, rejected = {
            try {
                snapshot.fill(0)
                complete(pending, QrDecodeResult("failure", "qr.decode_error"))
            } finally { QrProcessAdmission.release() }
        })
    }

    private fun complete(pending: Pending, decoded: QrDecodeResult) {
        val reply = synchronized(this) { if (attached) take(pending) else null }
        reply?.invoke(decoded.asMap())
    }

    private fun abandon(pending: Pending) { synchronized(this) { take(pending) } }

    /** Called only under the engine lock; clear retained callback before invoking external code. */
    private fun take(pending: Pending): ((Map<String, Any>) -> Unit)? {
        if (operation !== pending || !fence.finish(pending.token)) return null
        operation = null
        return pending.reply.also { pending.reply = null }
    }

    @Synchronized internal fun hasPendingForTest(): Boolean = operation != null
}
