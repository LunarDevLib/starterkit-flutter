package dev.lunardev.starterkit.platform

import java.io.File

internal data class MediaLimits(val maxBytes: Long, val maxPixels: Long) {
    companion object {
        const val MAX_BYTES = 20L * 1024L * 1024L
        const val MAX_PIXELS = 50L * 1000L * 1000L

        fun parse(arguments: Map<*, *>?): MediaLimits? {
            val bytes = (arguments?.get("maxBytes") as? Number)?.toLong() ?: return null
            val pixels = (arguments["maxPixels"] as? Number)?.toLong() ?: return null
            if (bytes !in 1..MAX_BYTES || pixels !in 1..MAX_PIXELS) return null
            return MediaLimits(bytes, pixels)
        }
    }
}

internal object MediaPolicy {
    fun validDimensions(width: Int, height: Int, limits: MediaLimits): Boolean {
        if (width <= 0 || height <= 0) return false
        val pixels = width.toLong() * height.toLong()
        return pixels in 1..limits.maxPixels
    }

    fun sampleSize(width: Int, height: Int, maxPixels: Long): Int {
        var sample = 1
        while (
            (width.toLong() + sample - 1) / sample *
                ((height.toLong() + sample - 1) / sample) > maxPixels
        ) {
            if (sample > (1 shl 29)) return sample
            sample *= 2
        }
        return sample
    }

    fun validDecodedContent(width: Int?, height: Int?): Boolean =
        width != null && height != null && width > 0 && height > 0

    fun activityResultFailure(
        resultCode: Int,
        canceledCode: Int,
        canceledCodeName: String,
        failureCodeName: String,
    ): Map<String, Any> =
        if (resultCode == canceledCode) {
            mediaOutcome("cancelled", canceledCodeName)
        } else {
            mediaOutcome("failure", failureCodeName)
        }

    fun ownedPath(root: File, candidate: File): Boolean =
        runCatching {
            val rootPath = root.canonicalFile.path
            val candidatePath = candidate.canonicalFile.path
            candidatePath.startsWith(rootPath + File.separator)
        }.getOrDefault(false)

    fun galleryFailure(error: Throwable): Map<String, Any> =
        when (error) {
            is SecurityException -> mediaOutcome("denied", "gallery.access_denied")
            is MediaTooLargeException -> mediaOutcome("invalid", "media.too_large")
            else -> mediaOutcome("failure", "gallery.read_failed")
        }
}

internal class MediaTooLargeException : RuntimeException()

/** Never reuse a result identity, including after detach or a failed launch. */
internal class MediaRequestCodeAllocator(private val firstCode: Int, private val lastCode: Int) {
    private var nextCode = firstCode

    init {
        require(firstCode in 0..0xffff && lastCode in firstCode..0xffff)
    }

    @Synchronized
    fun allocate(): Int? = if (nextCode <= lastCode) nextCode++ else null
}

/** Process-wide across plugin instances; leave all other plugins' request ranges alone. */
internal object MediaRequestCodes {
    // Reserve only Starterkit Media's 0x53xx prefix (including its former 0x5341/42).
    // Exhaustion fails closed: neither detachment nor creating a new plugin resets it.
    private val allocator = MediaRequestCodeAllocator(0x5300, 0x53ff)

    fun allocate(): Int? = allocator.allocate()
}

internal enum class MediaOperationKind { CAMERA, GALLERY }

/** Thread-safe incoming-result claim and file ownership for one media operation. */
internal class MediaOperationState(val requestCode: Int, initialFile: File? = null) {
    private enum class Phase { SELECTING, QUEUED, RUNNING, COMPLETED }

    private var phase = Phase.SELECTING
    private var invalid = false
    private var settled = false
    private var ownedFile = initialFile

    @Synchronized
    fun isActive(): Boolean = !invalid && !settled

    @Synchronized
    fun acceptActivityResult(incomingCode: Int): Boolean {
        if (incomingCode != requestCode || invalid || settled || phase != Phase.SELECTING) return false
        phase = Phase.QUEUED
        return true
    }

    @Synchronized
    fun startWork(): Boolean {
        if (invalid || settled || phase != Phase.QUEUED) return false
        phase = Phase.RUNNING
        return true
    }

    /** The sole running worker records output before writing, even if detach just won. */
    @Synchronized
    fun trackWorkerFile(file: File): Boolean {
        check(phase == Phase.RUNNING && ownedFile == null)
        ownedFile = file
        return !invalid && !settled
    }

    /** Call only after streams close and validation stops using the file. */
    fun finishWork(keepFile: Boolean): Boolean {
        val (deliver, discarded) = synchronized(this) {
            if (phase != Phase.RUNNING) return false
            phase = Phase.COMPLETED
            val active = !invalid && !settled
            val rejected = if (!active || !keepFile) takeFile() else null
            active to rejected
        }
        discarded?.delete()
        return deliver
    }

    fun invalidate() {
        val discarded = synchronized(this) {
            invalid = true
            // Never unlink running-worker output: finishWork owns its eventual cleanup.
            if (phase == Phase.RUNNING) null else takeFile()
        }
        discarded?.delete()
    }

    @Synchronized
    fun settle(): Boolean {
        if (settled) return false
        settled = true
        return true
    }

    @Synchronized
    fun forgetFile() {
        check(phase != Phase.RUNNING)
        ownedFile = null
    }

    // Called only while holding this operation's monitor.
    private fun takeFile(): File? = ownedFile.also { ownedFile = null }
}

internal data class MediaMetadata(
    val path: String,
    val byteLength: Long,
    val width: Int,
    val height: Int,
    val mimeType: String,
) {
    fun toMap(): Map<String, Any> =
        mapOf(
            "path" to path,
            "byteLength" to byteLength,
            "width" to width,
            "height" to height,
            "mimeType" to mimeType,
        )
}

internal fun mediaOutcome(kind: String, code: String, image: MediaMetadata? = null): Map<String, Any> =
    buildMap {
        put("kind", kind)
        put("code", code)
        if (image != null) put("image", image.toMap())
    }
