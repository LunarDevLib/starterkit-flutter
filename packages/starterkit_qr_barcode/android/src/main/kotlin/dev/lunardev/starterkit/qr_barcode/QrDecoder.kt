package dev.lunardev.starterkit.qr_barcode

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.multi.GenericMultipleBarcodeReader

internal data class QrCode(val value: String, val format: String)
internal data class QrDecodeResult(val kind: String, val code: String, val codes: List<QrCode> = emptyList()) {
    fun asMap(): Map<String, Any> {
        val map = linkedMapOf<String, Any>("kind" to kind, "code" to code)
        if (kind == "success") map["codes"] = codes.map { mapOf("value" to it.value, "format" to it.format) }
        return map
    }
}

internal object QrDecoder {
    const val MAX_BYTES = 10 * 1024 * 1024
    const val MAX_DIMENSION = 4096
    const val MAX_PIXELS = 8_000_000
    const val MAX_PAYLOAD_BYTES = 2048
    const val MAX_CODES = 16
    const val MAX_AGGREGATE_BYTES = 32768

    fun decodeImage(bytes: ByteArray): QrDecodeResult {
        if (bytes.isEmpty()) return invalid("qr.invalid_image")
        if (bytes.size > MAX_BYTES) return invalid("qr.image_too_large")
        var bitmap: Bitmap? = null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val width = bounds.outWidth
            val height = bounds.outHeight
            if (width <= 0 || height <= 0) return invalid("qr.invalid_image")
            if (width > MAX_DIMENSION || height > MAX_DIMENSION) return invalid("qr.image_dimensions")
            val pixels = width.toLong() * height.toLong()
            if (pixels > Int.MAX_VALUE) return invalid("qr.image_dimensions")
            val sample = sampleSize(width, height)
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                ?: return invalid("qr.invalid_image")
            val w = bitmap.width
            val h = bitmap.height
            if (w <= 0 || h <= 0 || w.toLong() * h.toLong() > MAX_PIXELS) return invalid("qr.image_dimensions")
            val argb = IntArray(w * h)
            bitmap.getPixels(argb, 0, w, 0, 0, w, h)
            val rgb = IntArray(argb.size) { argb[it] and 0x00ffffff }
            decodePixels(w, h, rgb)
        } catch (_: OutOfMemoryError) {
            invalid("qr.image_too_large")
        } catch (_: RuntimeException) {
            invalid("qr.invalid_image")
        } finally {
            bitmap?.recycle()
        }
    }

    internal fun sampleSize(width: Int, height: Int): Int {
        val count = width.toLong() * height.toLong()
        var sample = 1
        while (count / (sample.toLong() * sample.toLong()) > MAX_PIXELS && sample <= (1 shl 29)) sample *= 2
        return sample
    }

    fun decodePixels(width: Int, height: Int, pixels: IntArray): QrDecodeResult {
        if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION ||
            width.toLong() * height.toLong() > MAX_PIXELS || width.toLong() * height.toLong() != pixels.size.toLong()
        ) return invalid("qr.image_dimensions")
        val reader = MultiFormatReader()
        reader.setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to BarcodeFormat.entries))
        val bitmap = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(width, height, pixels)))
        val observed = try {
            GenericMultipleBarcodeReader(reader).decodeMultiple(bitmap).toList()
        } catch (_: NotFoundException) {
            try { listOf(reader.decode(bitmap)) } catch (_: NotFoundException) { emptyList() }
        } finally {
            reader.reset()
        }
        if (observed.isEmpty()) return QrDecodeResult("noResult", "qr.no_result")
        if (observed.size > MAX_CODES) return invalid("qr.invalid_payload")
        val normalized = ArrayList<QrCode>(observed.size)
        var aggregate = 0
        for (result in observed) {
            val format = when (result.barcodeFormat) {
                BarcodeFormat.QR_CODE -> "QR"
                BarcodeFormat.EAN_13 -> "EAN13"
                BarcodeFormat.CODE_128 -> "Code128"
                else -> return QrDecodeResult("unsupported", "qr.unsupported_format")
            }
            val text = result.text ?: return invalid("qr.invalid_payload")
            if (!validPayload(text)) return invalid("qr.invalid_payload")
            val size = text.toByteArray(Charsets.UTF_8).size
            if (size == 0 || size > MAX_PAYLOAD_BYTES) return invalid("qr.invalid_payload")
            aggregate += size
            if (aggregate > MAX_AGGREGATE_BYTES) return invalid("qr.invalid_payload")
            normalized.add(QrCode(text, format))
        }
        return QrDecodeResult("success", "qr.success", normalized)
    }

    internal fun validPayload(value: String): Boolean {
        if (!validUnicode(value)) return false
        val size = value.toByteArray(Charsets.UTF_8).size
        return size in 1..MAX_PAYLOAD_BYTES
    }

    private fun validUnicode(value: String): Boolean {
        var i = 0
        while (i < value.length) {
            val c = value[i]
            val cp = when {
                c.isHighSurrogate() -> {
                    if (i + 1 >= value.length || !value[i + 1].isLowSurrogate()) return false
                    Character.toCodePoint(c, value[++i])
                }
                c.isLowSurrogate() -> return false
                else -> c.code
            }
            if (cp in 0..0x1f || cp in 0x7f..0x9f) return false
            i++
        }
        return true
    }

    private fun invalid(code: String) = QrDecodeResult("invalid", code)
}
