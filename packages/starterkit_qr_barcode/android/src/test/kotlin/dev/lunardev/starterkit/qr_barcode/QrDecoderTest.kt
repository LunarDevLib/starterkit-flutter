package dev.lunardev.starterkit.qr_barcode

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import org.junit.Assert.*
import org.junit.Test

class QrDecoderTest {
    private fun image(text: String, format: BarcodeFormat, hints: Map<EncodeHintType, Any> = emptyMap()): QrDecodeResult {
        val matrix = MultiFormatWriter().encode(text, format, 420, 300, hints)
        val pixels = IntArray(matrix.width * matrix.height) { i -> if (matrix[i % matrix.width, i / matrix.width]) 0xff000000.toInt() else -1 }
        return QrDecoder.decodePixels(matrix.width, matrix.height, pixels)
    }

    @Test fun productionDecoderRoundTripsRequiredFormatsAndUtf8() {
        assertWire("hello", "QR", image("hello", BarcodeFormat.QR_CODE))
        assertWire("5901234123457", "EAN13", image("5901234123457", BarcodeFormat.EAN_13))
        assertWire("Code128-42", "Code128", image("Code128-42", BarcodeFormat.CODE_128))
        val utf8 = image("Zażółć 🌍", BarcodeFormat.QR_CODE, mapOf(EncodeHintType.CHARACTER_SET to "UTF-8"))
        assertWire("Zażółć 🌍", "QR", utf8)
    }

    private fun assertWire(value: String, format: String, result: QrDecodeResult) {
        assertEquals(mapOf(
            "kind" to "success", "code" to "qr.success",
            "codes" to listOf(mapOf("value" to value, "format" to format)),
        ), result.asMap())
    }

    @Test fun nonSuccessWireEnvelopeHasNoPayloadOrExtraKeys() {
        assertEquals(mapOf("kind" to "unsupported", "code" to "qr.unsupported_format"), image("aztec", BarcodeFormat.AZTEC).asMap())
        assertEquals(mapOf("kind" to "noResult", "code" to "qr.no_result"), QrDecoder.decodePixels(40, 40, IntArray(1600) { -1 }).asMap())
        assertEquals(mapOf("kind" to "invalid", "code" to "qr.image_dimensions"), QrDecoder.decodePixels(0, 0, IntArray(0)).asMap())
    }

    @Test fun unsupportedFormatsAreObservedThenRejected() {
        assertEquals("qr.unsupported_format", image("aztec", BarcodeFormat.AZTEC).code)
        assertEquals("qr.unsupported_format", image("123456789012", BarcodeFormat.PDF_417).code)
    }

    @Test fun productionRoundTripPreservesWhitespaceAndUnicodeExactly() {
        val value = "  Zażółć 🌍  "
        assertWire(value, "QR", image(value, BarcodeFormat.QR_CODE, mapOf(EncodeHintType.CHARACTER_SET to "UTF-8")))
    }

    @Test fun productionRoundTripRejectsObservedControlPayloads() {
        for (value in listOf("bad\u0000text", "bad\u0085text")) {
            assertEquals(mapOf("kind" to "invalid", "code" to "qr.invalid_payload"),
                image(value, BarcodeFormat.QR_CODE, mapOf(EncodeHintType.CHARACTER_SET to "UTF-8")).asMap())
        }
    }

    @Test fun productionRoundTripEnforcesUtf8ByteBoundaryWithoutTruncation() {
        val hints = mapOf<EncodeHintType, Any>(EncodeHintType.CHARACTER_SET to "UTF-8")
        assertWire("é".repeat(1024), "QR", image("é".repeat(1024), BarcodeFormat.QR_CODE, hints))
        assertEquals(mapOf("kind" to "invalid", "code" to "qr.invalid_payload"),
            image("é".repeat(1025), BarcodeFormat.QR_CODE, hints).asMap())
    }

    @Test fun blankPixelsAndInvalidShapesFailClosed() {
        assertEquals("qr.no_result", QrDecoder.decodePixels(40, 40, IntArray(1600) { -1 }).code)
        assertEquals("qr.image_dimensions", QrDecoder.decodePixels(0, 2, IntArray(0)).code)
        assertEquals("qr.image_dimensions", QrDecoder.decodePixels(2, 2, IntArray(3)).code)
        assertEquals("qr.image_dimensions", QrDecoder.decodePixels(4097, 1, IntArray(4097)).code)
        assertEquals("qr.image_dimensions", QrDecoder.decodePixels(4096, 2048, IntArray(0)).code)
    }

    @Test fun payloadUnicodeControlsAndUtf8Limits() {
        assertTrue(QrDecoder.validPayload("é".repeat(1024)))
        assertFalse(QrDecoder.validPayload("é".repeat(1025)))
        assertTrue(QrDecoder.validPayload("🌍".repeat(512)))
        assertFalse(QrDecoder.validPayload("🌍".repeat(513)))
        assertFalse(QrDecoder.validPayload("bad\u0000text"))
        assertFalse(QrDecoder.validPayload("bad\u0085text"))
        assertFalse(QrDecoder.validPayload("\ud800"))
        assertFalse(QrDecoder.validPayload(""))
    }

    @Test fun dimensionsUseSafeLongArithmeticAndPixelBudgetSampling() {
        assertEquals(2, QrDecoder.sampleSize(4096, 2048))
        assertEquals(2, QrDecoder.sampleSize(4096, 4096))
        assertTrue(4096L * 4096L > QrDecoder.MAX_PIXELS)
    }
}
