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

    fun ownedPath(root: File, candidate: File): Boolean =
        runCatching {
            val rootPath = root.canonicalFile.path
            val candidatePath = candidate.canonicalFile.path
            candidatePath.startsWith(rootPath + File.separator)
        }.getOrDefault(false)
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
