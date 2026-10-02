package dev.lunardev.starterkit.preferences

internal interface PreferencesStorage {
    fun read(key: String): Any?
    fun write(key: String, value: String): Boolean
    fun remove(key: String): Boolean
}

internal interface PreferencesWorker {
    fun post(task: () -> Unit): Boolean
    fun clear()
    fun quit()
}

/** Flutter-independent method policy; the plugin supplies Android storage and worker adapters. */
internal class PreferencesHandlerPolicy(
    private val dispatchCompletion: (() -> Unit) -> Unit,
) {
    private val lock = Any()
    private var storageFactory: (() -> PreferencesStorage)? = null
    private var workerFactory: (() -> PreferencesWorker)? = null
    private var worker: PreferencesWorker? = null
    private var attached = false
    private var generation = 0L
    private val pending = mutableSetOf<PendingResult>()

    fun attach(
        storageFactory: () -> PreferencesStorage,
        workerFactory: () -> PreferencesWorker,
    ) {
        synchronized(lock) {
            generation++
            attached = true
            this.storageFactory = storageFactory
            this.workerFactory = workerFactory
        }
    }

    fun onMethodCall(
        operation: String,
        arguments: Any?,
        complete: (Any?, String?) -> Unit,
    ) {
        val expected = when (operation) {
            "read", "remove" -> setOf("key")
            "write" -> setOf("key", "value")
            else -> return complete(null, INVALID_ARGUMENTS)
        }
        val args = arguments as? Map<*, *> ?: return complete(null, INVALID_ARGUMENTS)
        if (args.keys != expected) return complete(null, INVALID_ARGUMENTS)
        val key = PreferencesValidation.key(args["key"])
            ?: return complete(null, INVALID_KEY)
        val value = if (operation == "write") PreferencesValidation.value(args["value"]) else null
        if (operation == "write" && value == null) return complete(null, INVALID_VALUE)

        synchronized(lock) {
            if (!attached) return complete(null, UNAVAILABLE)
            val request = PendingResult(complete, generation)
            pending.add(request)
            val activeWorker = worker ?: try {
                val created = workerFactory?.invoke() ?: throw IllegalStateException()
                worker = created
                created
            } catch (_: RuntimeException) {
                finishLocked(request, error = UNAVAILABLE)
                return
            }
            val accepted = try {
                activeWorker.post { execute(request, operation, key, value) }
            } catch (_: RuntimeException) {
                false
            }
            if (!accepted) {
                if (worker === activeWorker) {
                    worker = null
                    val failedGeneration = generation
                    generation++
                    closeWorker(activeWorker)
                    pending.toList()
                        .filter { it.generation == failedGeneration }
                        .forEach { finishLocked(it, error = UNAVAILABLE) }
                } else {
                    finishLocked(request, error = UNAVAILABLE)
                }
            }
        }
    }

    private fun execute(request: PendingResult, operation: String, key: String, value: String?) {
        try {
            val storage = synchronized(lock) {
                if (!isCurrentLocked(request)) {
                    finishLocked(request, error = UNAVAILABLE)
                    return
                }
                val factory = storageFactory
                    ?: return finishLocked(request, error = UNAVAILABLE)
                factory()
            }
            when (operation) {
                "read" -> {
                    val stored = storage.read(key)
                    if (stored != null && stored !is String) {
                        finish(request, error = OPERATION_FAILED)
                    } else if (stored is String && PreferencesValidation.value(stored) == null) {
                        finish(request, error = OPERATION_FAILED)
                    } else finish(request, value = stored)
                }
                "write" -> if (storage.write(key, value!!)) finish(request)
                    else finish(request, error = OPERATION_FAILED)
                "remove" -> if (storage.remove(key)) finish(request)
                    else finish(request, error = OPERATION_FAILED)
            }
        } catch (_: RuntimeException) {
            finish(request, error = OPERATION_FAILED)
        }
    }

    fun detach() {
        synchronized(lock) {
            attached = false
            generation++
            storageFactory = null
            workerFactory = null
            worker?.let(::closeWorker)
            worker = null
            pending.toList().forEach { finishLocked(it, error = UNAVAILABLE) }
        }
    }

    private fun isCurrentLocked(request: PendingResult): Boolean =
        attached && request.generation == generation && !request.completed

    private fun closeWorker(worker: PreferencesWorker) {
        try { worker.clear() } catch (_: RuntimeException) { }
        try { worker.quit() } catch (_: RuntimeException) { }
    }

    private fun finish(request: PendingResult, value: Any? = null, error: String? = null) {
        synchronized(lock) { finishLocked(request, value, error) }
    }

    private fun finishLocked(request: PendingResult, value: Any? = null, error: String? = null) {
        if (request.completed) return
        request.completed = true
        pending.remove(request)
        dispatchCompletion { request.complete(value, error) }
    }

    private class PendingResult(
        val complete: (Any?, String?) -> Unit,
        val generation: Long,
    ) {
        var completed = false
    }

    private companion object {
        const val INVALID_ARGUMENTS = "preference.invalid_arguments"
        const val INVALID_KEY = "preference.invalid_key"
        const val INVALID_VALUE = "preference.invalid_value"
        const val UNAVAILABLE = "preference.unavailable"
        const val OPERATION_FAILED = "preference.operation_failed"
    }
}
