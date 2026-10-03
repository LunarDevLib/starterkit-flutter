package dev.lunardev.starterkit.platform

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class StarterkitPlatformPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var locationChannel: MethodChannel
    private lateinit var biometricChannel: MethodChannel
    private lateinit var shareChannel: MethodChannel
    private lateinit var locationHandler: AndroidLocationHandler
    private lateinit var biometricHandler: AndroidBiometricHandler
    private lateinit var shareHandler: AndroidNativeShareHandler
    private var activityBinding: ActivityPluginBinding? = null
    private var pending: PendingOperation? = null
    private var activityResultListenerRegistered = false
    private var worker: ExecutorService? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        locationHandler = AndroidLocationHandler(context, main)
        locationChannel = MethodChannel(binding.binaryMessenger, LOCATION_CHANNEL)
        locationChannel.setMethodCallHandler(locationHandler)
        biometricHandler = AndroidBiometricHandler(context, main)
        biometricChannel = MethodChannel(binding.binaryMessenger, BIOMETRIC_CHANNEL)
        biometricChannel.setMethodCallHandler(biometricHandler)
        shareHandler = AndroidNativeShareHandler(context, main)
        shareChannel = MethodChannel(binding.binaryMessenger, SHARE_CHANNEL)
        shareChannel.setMethodCallHandler(shareHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        biometricHandler.onEngineDetached()
        biometricChannel.setMethodCallHandler(null)
        shareHandler.onEngineDetached()
        shareChannel.setMethodCallHandler(null)
        locationHandler.onEngineDetached()
        locationChannel.setMethodCallHandler(null)
        settlePending(mediaOutcome("failure", "media.engine_detached"), deleteFile = true)
        channel.setMethodCallHandler(null)
        worker?.shutdownNow()
        worker = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        locationHandler.onAttachedToActivity(binding)
        biometricHandler.onAttachedToActivity(binding)
        shareHandler.onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        shareHandler.onActivityDetached()
        biometricHandler.onActivityDetached()
        locationHandler.onActivityDetached()
        if (activityResultListenerRegistered) {
            activityBinding?.removeActivityResultListener(this)
            activityResultListenerRegistered = false
        }
        activityBinding = null
        settlePending(mediaOutcome("failure", "media.activity_detached"), deleteFile = true)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cameraAvailability" ->
                result.success(
                    context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY),
                )
            "cameraPermissionStatus" -> result.success("notRequired")
            "requestCameraPermission" -> result.success("notRequired")
            "galleryAvailability" -> result.success(true)
            "captureCamera" -> captureCamera(call.arguments as? Map<*, *>, result)
            "pickGalleryImage" -> pickGallery(call.arguments as? Map<*, *>, result)
            "cleanupMedia" -> {
                val path = (call.arguments as? Map<*, *>)?.get("path") as? String
                result.success(path != null && cleanupOwned(File(path)))
            }
            else -> result.notImplemented()
        }
    }

    private fun captureCamera(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (pending != null) {
            result.success(mediaOutcome("failure", "media.operation_in_progress"))
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(mediaOutcome("unavailable", "camera.activity_unavailable"))
            return
        }
        val limits = MediaLimits.parse(arguments)
        if (limits == null) {
            result.success(mediaOutcome("invalid", "media.invalid_limits"))
            return
        }
        val authority = arguments?.get("fileProviderAuthority") as? String
        if (authority != context.packageName + ".fileprovider") {
            result.success(mediaOutcome("unavailable", "camera.fileprovider_not_configured"))
            return
        }
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            result.success(mediaOutcome("unavailable", "camera.unavailable"))
            return
        }
        val requestCode = MediaRequestCodes.allocate()
        if (requestCode == null) {
            result.success(mediaOutcome("failure", "media.request_codes_exhausted"))
            return
        }
        val intent = cameraIntent()

        val file = newTempFile("camera", ".jpg")
        val uri =
            runCatching { FileProvider.getUriForFile(context, authority, file) }
                .getOrElse {
                    file.delete()
                    result.success(mediaOutcome("unavailable", "camera.fileprovider_not_configured"))
                    return
                }

        intent.putExtra(MediaStore.EXTRA_OUTPUT, uri)
        intent.clipData = ClipData.newRawUri("starterkit-camera-output", uri)
        intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        ensureActivityResultListener()
        pending =
            PendingOperation(
                requestCode = requestCode,
                kind = MediaOperationKind.CAMERA,
                result = result,
                limits = limits,
                file = file,
                grantedUri = uri,
            )
        try {
            activity.startActivityForResult(intent, requestCode)
        } catch (_: ActivityNotFoundException) {
            revoke(uri)
            settlePending(mediaOutcome("unavailable", "camera.unavailable"), deleteFile = true)
        } catch (_: Throwable) {
            revoke(uri)
            settlePending(mediaOutcome("failure", "camera.launch_failed"), deleteFile = true)
        }
    }

    private fun pickGallery(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (pending != null) {
            result.success(mediaOutcome("failure", "media.operation_in_progress"))
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(mediaOutcome("unavailable", "gallery.activity_unavailable"))
            return
        }
        val limits = MediaLimits.parse(arguments)
        if (limits == null) {
            result.success(mediaOutcome("invalid", "media.invalid_limits"))
            return
        }
        val requestCode = MediaRequestCodes.allocate()
        if (requestCode == null) {
            result.success(mediaOutcome("failure", "media.request_codes_exhausted"))
            return
        }
        val intent = galleryIntent()
        ensureActivityResultListener()
        pending =
            PendingOperation(
                requestCode = requestCode,
                kind = MediaOperationKind.GALLERY,
                result = result,
                limits = limits,
            )
        try {
            activity.startActivityForResult(intent, requestCode)
        } catch (_: ActivityNotFoundException) {
            settlePending(mediaOutcome("unavailable", "gallery.unavailable"), deleteFile = false)
        } catch (_: Throwable) {
            settlePending(mediaOutcome("failure", "gallery.launch_failed"), deleteFile = false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val operation = pending ?: return false
        if (operation.requestCode != requestCode) return false
        // A duplicate belonging to us is consumed, but must never start another worker.
        if (!operation.state.acceptActivityResult(requestCode)) return true

        if (operation.kind == MediaOperationKind.CAMERA) {
            operation.grantedUri?.let(::revoke)
            if (resultCode != Activity.RESULT_OK) {
                complete(
                    operation,
                    MediaPolicy.activityResultFailure(
                        resultCode,
                        Activity.RESULT_CANCELED,
                        "camera.cancelled",
                        "camera.capture_failed",
                    ),
                    deleteFile = true,
                )
                return true
            }
            val file = operation.file
            if (file == null) {
                complete(operation, mediaOutcome("failure", "camera.output_missing"), deleteFile = true)
                return true
            }
            work {
                if (!operation.state.startWork()) return@work
                val outcome = runCatching { validateFile(file, operation.limits, "camera") }
                    .getOrElse { mediaOutcome("failure", "camera.read_failed") }
                if (operation.state.finishWork(keepFile = outcome["kind"] == "success")) {
                    main.post {
                        complete(operation, outcome, deleteFile = outcome["kind"] != "success")
                    }
                }
            }
            return true
        }

        if (resultCode != Activity.RESULT_OK) {
            complete(
                operation,
                MediaPolicy.activityResultFailure(
                    resultCode,
                    Activity.RESULT_CANCELED,
                    "gallery.cancelled",
                    "gallery.pick_failed",
                ),
                deleteFile = true,
            )
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") {
            complete(operation, mediaOutcome("invalid", "gallery.invalid_uri"), deleteFile = true)
            return true
        }
        work {
            if (!operation.state.startWork()) return@work
            val outcome = copyAndValidateGallery(uri, operation)
            if (operation.state.finishWork(keepFile = outcome["kind"] == "success")) {
                main.post { complete(operation, outcome, deleteFile = outcome["kind"] != "success") }
            }
        }
        return true
    }

    private fun copyAndValidateGallery(uri: Uri, operation: PendingOperation): Map<String, Any> {
        val limits = operation.limits
        return try {
            if (!operation.state.isActive()) return mediaOutcome("failure", "media.activity_detached")
            val resolver = context.contentResolver
            val declaredMime = resolver.getType(uri)
            if (declaredMime != null && !declaredMime.startsWith("image/")) {
                return mediaOutcome("invalid", "gallery.invalid_type")
            }
            val tempFile = newTempFile("gallery", ".image")
            if (!operation.state.trackWorkerFile(tempFile)) {
                return mediaOutcome("failure", "media.activity_detached")
            }
            val copied = resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(tempFile).use { output ->
                    val buffer = ByteArray(16 * 1024)
                    var total = 0L
                    while (true) {
                        if (!operation.state.isActive()) throw IllegalStateException("operation detached")
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > limits.maxBytes) throw MediaTooLargeException()
                        output.write(buffer, 0, count)
                    }
                    total
                }
            } ?: throw IllegalStateException("missing input")
            if (copied <= 0) throw IllegalStateException("empty input")
            if (!operation.state.isActive()) return mediaOutcome("failure", "media.activity_detached")
            validateFile(tempFile, limits, "gallery")
        } catch (error: Throwable) {
            MediaPolicy.galleryFailure(error)
        }
    }

    private fun validateFile(
        file: File,
        limits: MediaLimits,
        prefix: String,
    ): Map<String, Any> {
        if (!MediaPolicy.ownedPath(mediaRoot(), file) || !file.isFile) {
            return mediaOutcome("invalid", "$prefix.invalid_file")
        }
        val bytes = file.length()
        if (bytes !in 1..limits.maxBytes) {
            return mediaOutcome("invalid", "media.too_large")
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, options)
        if (!MediaPolicy.validDimensions(options.outWidth, options.outHeight, limits)) {
            return mediaOutcome("invalid", "media.invalid_dimensions")
        }
        val mime = options.outMimeType
        if (mime == null || !mime.startsWith("image/") || mime.length > 128) {
            return mediaOutcome("invalid", "media.invalid_type")
        }
        val sample = MediaPolicy.sampleSize(options.outWidth, options.outHeight, limits.maxPixels)
        val decoded =
            BitmapFactory.decodeFile(
                file.path,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = android.graphics.Bitmap.Config.RGB_565
                },
            ) ?: return mediaOutcome("invalid", "media.invalid_content")
        try {
            if (!MediaPolicy.validDecodedContent(decoded.width, decoded.height)) {
                return mediaOutcome("invalid", "media.invalid_content")
            }
        } finally {
            decoded.recycle()
        }
        return mediaOutcome(
            "success",
            "media.success",
            MediaMetadata(
                path = file.absolutePath,
                byteLength = bytes,
                width = options.outWidth,
                height = options.outHeight,
                mimeType = mime,
            ),
        )
    }

    private fun cameraIntent(): Intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)

    private fun galleryIntent(): Intent =
        if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "image/*" }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
            }
        }

    private fun mediaRoot(): File =
        File(context.cacheDir, "starterkit_media").apply { mkdirs() }

    private fun newTempFile(prefix: String, suffix: String): File =
        File(mediaRoot(), prefix + "-" + UUID.randomUUID().toString() + suffix)

    private fun cleanupOwned(file: File): Boolean =
        MediaPolicy.ownedPath(mediaRoot(), file) && (!file.exists() || file.delete())

    private fun revoke(uri: Uri) {
        runCatching {
            context.revokeUriPermission(
                uri,
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
    }

    private fun ensureActivityResultListener() {
        val binding = activityBinding ?: return
        if (activityResultListenerRegistered) return
        binding.addActivityResultListener(this)
        activityResultListenerRegistered = true
    }

    private fun work(block: () -> Unit) {
        val executor = worker ?: Executors.newSingleThreadExecutor().also { worker = it }
        executor.execute(block)
    }

    private fun settlePending(outcome: Map<String, Any>, deleteFile: Boolean) {
        val operation = pending ?: return
        operation.grantedUri?.let(::revoke)
        if (deleteFile) operation.state.invalidate()
        complete(operation, outcome, deleteFile)
    }

    private fun complete(operation: PendingOperation, outcome: Map<String, Any>, deleteFile: Boolean) {
        if (pending !== operation || !operation.state.settle()) {
            // Rejected success owns a completed output too; never key cleanup to its outcome.
            operation.state.invalidate()
            return
        }
        pending = null
        if (deleteFile) operation.state.invalidate() else operation.state.forgetFile()
        operation.result.success(outcome)
    }

    private data class PendingOperation(
        val requestCode: Int,
        val kind: MediaOperationKind,
        val result: MethodChannel.Result,
        val limits: MediaLimits,
        val file: File? = null,
        val grantedUri: Uri? = null,
        val state: MediaOperationState = MediaOperationState(requestCode, file),
    )

    companion object {
        private const val CHANNEL = "starterkit/platform/media"
        private const val LOCATION_CHANNEL = "starterkit/platform/location"
        private const val BIOMETRIC_CHANNEL = "starterkit/platform/biometric"
        private const val SHARE_CHANNEL = "starterkit/platform/share"
    }
}
