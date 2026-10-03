package dev.lunardev.starterkit.platform

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal fun interface AndroidShareChooser {
    fun present(activity: Activity, spec: ShareIntentSpec)
}

/** Explicit-call-only ACTION_SEND adapter; registration itself performs no provider or UI work. */
internal class AndroidNativeShareHandler(
    private val context: Context,
    private val main: Handler = Handler(Looper.getMainLooper()),
    private val chooser: AndroidShareChooser? = null,
) : MethodChannel.MethodCallHandler {
    private var activityBinding: ActivityPluginBinding? = null
    private var engineGeneration = 0L
    private var engineAttached = true

    fun onAttachedToActivity(binding: ActivityPluginBinding) { activityBinding = binding }

    fun onActivityDetached() { activityBinding = null }

    fun onEngineDetached() {
        activityBinding = null
        engineAttached = false
        engineGeneration++
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "share") { result.notImplemented(); return }
        if (Looper.myLooper() != main.looper) {
            val generation = engineGeneration
            if (!main.post {
                    if (engineAttached && generation == engineGeneration) share(call.arguments, result)
                    else result.success(SharePolicy.response("cancelled", "share.engine_detached"))
                }
            ) result.success(SharePolicy.response("failure", "share.platform_failure"))
        } else {
            share(call.arguments, result)
        }
    }

    private fun share(arguments: Any?, result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        val currentActivity = activity?.takeUnless { it.isFinishing || it.isDestroyed }
        val outcome = SharePolicy.execute(
            arguments = arguments,
            hostAvailable = currentActivity != null,
            fileAvailable = ::fileIsAvailable,
        ) { spec ->
            try {
                (chooser ?: AndroidShareChooser { host, shareSpec -> showSystemChooser(host, shareSpec) })
                    .present(requireNotNull(currentActivity), spec)
            } catch (_: ActivityNotFoundException) {
                throw ShareLaunchFailure(ShareLaunchFailureKind.UNAVAILABLE)
            } catch (_: SecurityException) {
                throw ShareLaunchFailure(
                    if (spec.streamUri != null) ShareLaunchFailureKind.FILE_UNAVAILABLE
                    else ShareLaunchFailureKind.FAILURE,
                )
            } catch (_: Throwable) {
                throw ShareLaunchFailure(ShareLaunchFailureKind.FAILURE)
            }
        }
        result.success(outcome)
    }

    private fun fileIsAvailable(value: String): Boolean {
        return try {
        val uri = Uri.parse(value)
        if (uri.scheme != "content" || uri.query != null || uri.fragment != null) false else {
        val mimeType = context.contentResolver.getType(uri)
        var declaredSize: Long? = null
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (column >= 0 && !cursor.isNull(column)) declaredSize = cursor.getLong(column)
            }
        }
        context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
            val size = declaredSize?.takeIf { it >= 0 } ?: descriptor.length.takeIf { it >= 0 }
            SharePolicy.isReadableImageSize(mimeType, size)
        } ?: false
        }
    } catch (_: Throwable) {
        false
    }
    }

    private fun showSystemChooser(activity: Activity, spec: ShareIntentSpec) {
        val send = Intent(spec.action).apply {
            type = spec.mimeType
            spec.extraText?.let { putExtra(Intent.EXTRA_TEXT, it) }
            spec.streamUri?.let { rawUri ->
                val uri = Uri.parse(rawUri)
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newUri(context.contentResolver, "shared image", uri)
                if (spec.grantReadUriPermission) addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
        activity.startActivity(Intent.createChooser(send, null))
    }
}
