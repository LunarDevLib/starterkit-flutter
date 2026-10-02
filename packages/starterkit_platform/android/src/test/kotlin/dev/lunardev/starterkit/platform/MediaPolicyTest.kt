package dev.lunardev.starterkit.platform

import java.io.File
import java.nio.file.Files
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
}
