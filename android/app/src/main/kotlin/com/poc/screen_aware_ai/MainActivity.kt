package com.poc.screen_aware_ai

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.poc.screen_aware_ai/screen"
    private val SCREEN_CAPTURE_REQUEST_CODE = 1001
    private val MODEL_PICK_REQUEST_CODE = 1002
    private val TAG = "MainActivity"

    private var pendingResult: MethodChannel.Result? = null
    private var pendingModelResult: MethodChannel.Result? = null
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var methodChannel: MethodChannel? = null

    // Store projection data so we can reinitialize the service if needed.
    // IMPORTANT: Use 0 as sentinel — Activity.RESULT_OK is -1, so -1 can't be the default.
    private var projectionResultCode: Int = 0
    private var projectionData: Intent? = null

    // Broadcast receiver for the stop notification action
    private val forceStopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == OverlayService.ACTION_FORCE_STOP) {
                Log.d(TAG, "Received FORCE_STOP broadcast, forwarding to Flutter")
                methodChannel?.invokeMethod("onForceStop", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        // Register broadcast receiver for the stop notification action
        val filter = IntentFilter(OverlayService.ACTION_FORCE_STOP)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(forceStopReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(forceStopReceiver, filter)
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "selectLocalModel" -> {
                    if (pendingModelResult != null) {
                        result.error("MODEL_PICKER_BUSY", "A model selection is already in progress", null)
                    } else {
                        pendingModelResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/octet-stream", "application/x-gguf"))
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        try {
                            startActivityForResult(intent, MODEL_PICK_REQUEST_CODE)
                        } catch (e: Exception) {
                            pendingModelResult = null
                            result.error("MODEL_PICKER_UNAVAILABLE", "Android could not open the document picker", null)
                        }
                    }
                }
                "requestScreenCapture" -> {
                    pendingResult = result
                    val intent = mediaProjectionManager!!.createScreenCaptureIntent()
                    startActivityForResult(intent, SCREEN_CAPTURE_REQUEST_CODE)
                }
                "captureScreen" -> {
                    val service = ScreenCaptureService.instance
                    if (service == null) {
                        // Service not running at all — try to restart if we have stored data
                        if (projectionResultCode == Activity.RESULT_OK && projectionData != null) {
                            Log.w(TAG, "captureScreen: service is null, restarting with stored projection data")
                            try {
                                startCaptureService(projectionResultCode, projectionData!!)
                                // Return error so Flutter side can retry after service starts
                                result.error("NOT_INITIALIZED", "Service restarting, retry capture", null)
                            } catch (e: Exception) {
                                // On Android 14+ the token may be single-use — need fresh permission
                                Log.e(TAG, "captureScreen: failed to restart service with stored data", e)
                                projectionData = null
                                result.error("NO_SERVICE", "Screen capture token expired, need new permission", null)
                            }
                        } else {
                            result.error("NO_SERVICE", "Screen capture service not running, need permission", null)
                        }
                    } else if (!service.isInitialized) {
                        // Service exists but imageReader is null — try to reinitialize
                        if (projectionResultCode == Activity.RESULT_OK && projectionData != null) {
                            Log.w(TAG, "captureScreen: service not initialized, reinitializing with stored data")
                            try {
                                service.initializeProjection(projectionResultCode, projectionData!!)
                                // If initialization succeeded, capture immediately
                                if (service.isInitialized) {
                                    service.captureScreen { bytes ->
                                        runOnUiThread { result.success(bytes) }
                                    }
                                } else {
                                    result.error("NOT_INITIALIZED", "Failed to reinitialize, need new permission", null)
                                }
                            } catch (e: SecurityException) {
                                // Android 14+: projection token is single-use, can't be reused
                                Log.e(TAG, "captureScreen: SecurityException — token expired, need new permission", e)
                                projectionData = null
                                result.error("NOT_INITIALIZED", "Projection token expired, need new permission", null)
                            } catch (e: Exception) {
                                Log.e(TAG, "captureScreen: reinit failed", e)
                                result.error("NOT_INITIALIZED", "Reinit failed: ${e.message}", null)
                            }
                        } else {
                            result.error("NOT_INITIALIZED", "Service not initialized, need permission", null)
                        }
                    } else {
                        service.captureScreen { bytes ->
                            runOnUiThread { result.success(bytes) }
                        }
                    }
                }
                "isAccessibilityEnabled" -> {
                    result.success(ScreenActionService.instance != null)
                }
                "getScreenSize" -> {
                    val service = ScreenCaptureService.instance
                    if (service != null) {
                        result.success(mapOf("width" to service.screenWidth, "height" to service.screenHeight))
                    } else {
                        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
                        val metrics = android.util.DisplayMetrics()
                        @Suppress("DEPRECATION")
                        wm.defaultDisplay.getRealMetrics(metrics)
                        result.success(mapOf("width" to metrics.widthPixels, "height" to metrics.heightPixels))
                    }
                }
                "performTap" -> {
                    val x = call.argument<Double>("x")?.toFloat() ?: 0f
                    val y = call.argument<Double>("y")?.toFloat() ?: 0f
                    val service = ScreenActionService.instance
                    if (service != null) {
                        service.performTap(x, y) { success -> result.success(success) }
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "performLongPress", "performDoubleTap" -> {
                    val x = call.argument<Double>("x")?.toFloat() ?: 0f
                    val y = call.argument<Double>("y")?.toFloat() ?: 0f
                    val service = ScreenActionService.instance
                    if (service == null) {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    } else {
                        val callback: (Boolean) -> Unit = { success -> result.success(success) }
                        if (call.method == "performLongPress") {
                            service.performLongPress(x, y, callback)
                        } else {
                            service.performDoubleTap(x, y, callback)
                        }
                    }
                }
                "performType" -> {
                    val text = call.argument<String>("text") ?: ""
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.performType(text))
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "pressBack" -> {
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.pressBack())
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "pressHome" -> {
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.pressHome())
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "openApp" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    try {
                        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                        if (launchIntent != null) {
                            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.error("LAUNCH_FAILED", "Could not launch $packageName: ${e.message}", null)
                    }
                }
                "performSwipe" -> {
                    val startX = call.argument<Double>("startX")?.toFloat() ?: 0f
                    val startY = call.argument<Double>("startY")?.toFloat() ?: 0f
                    val endX = call.argument<Double>("endX")?.toFloat() ?: 0f
                    val endY = call.argument<Double>("endY")?.toFloat() ?: 0f
                    val service = ScreenActionService.instance
                    if (service != null) {
                        service.performSwipe(startX, startY, endX, endY) { success ->
                            result.success(success)
                        }
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "getUITree" -> {
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.getUITree())
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "openAccessibilitySettings" -> {
                    val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    startActivity(intent)
                    result.success(true)
                }
                "showStopOverlay" -> {
                    val intent = Intent(this, OverlayService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "hideStopOverlay" -> {
                    val service = OverlayService.instance
                    if (service != null) {
                        service.hideOverlay()
                        stopService(Intent(this, OverlayService::class.java))
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startCaptureService(resultCode: Int, data: Intent) {
        val serviceIntent = Intent(this, ScreenCaptureService::class.java).apply {
            putExtra("resultCode", resultCode)
            putExtra("data", data)
        }
        startForegroundService(serviceIntent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MODEL_PICK_REQUEST_CODE) {
            val result = pendingModelResult
            pendingModelResult = null
            if (result == null) return
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(null)
                return
            }
            Thread({
                try {
                    val imported = importLocalModel(uri)
                    runOnUiThread { result.success(imported) }
                } catch (e: Exception) {
                    val message = when (e) {
                        is IllegalArgumentException -> e.message ?: "Choose a GGUF model file."
                        else -> "Could not import the selected model. Check storage space and choose a readable .gguf file."
                    }
                    runOnUiThread { result.error("MODEL_IMPORT_FAILED", message, null) }
                }
            }, "LucyModelImport").start()
        } else if (requestCode == SCREEN_CAPTURE_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                // Store projection data for potential reinitialization later
                projectionResultCode = resultCode
                projectionData = data.clone() as Intent

                Log.d(TAG, "onActivityResult: permission granted, starting capture service")

                startCaptureService(resultCode, data)

                // Wait for the service to fully initialize before returning success.
                // With the callback fix, onStartCommand should reliably initialize.
                // Do NOT try to reinitialize with stored data here — on Android 14+
                // the projection token is single-use and was already consumed by onStartCommand.
                android.os.Handler(mainLooper).postDelayed({
                    val service = ScreenCaptureService.instance
                    if (service != null && service.isInitialized) {
                        Log.d(TAG, "onActivityResult: service initialized successfully")
                        pendingResult?.success(true)
                    } else {
                        Log.w(TAG, "onActivityResult: service not initialized after 1.5s")
                        pendingResult?.success(false)
                    }
                    pendingResult = null
                }, 1500)
            } else {
                Log.w(TAG, "onActivityResult: permission denied or no data")
                pendingResult?.success(false)
                pendingResult = null
            }
        }
    }

    /** Stream the selected document to private storage without buffering model weights in RAM. */
    private fun importLocalModel(uri: Uri): Map<String, Any> {
        var displayName: String? = null
        var declaredSize: Long? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0) displayName = cursor.getString(nameIndex)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0) {
                    val size = cursor.getLong(sizeIndex)
                    if (size >= 0) declaredSize = size
                }
            }
        }
        val name = displayName?.takeIf { it.isNotBlank() } ?: "selected-model.gguf"
        if (!name.lowercase().endsWith(".gguf")) {
            throw IllegalArgumentException("Choose a .gguf model file.")
        }

        val modelDir = File(filesDir, "models")
        if (!modelDir.exists() && !modelDir.mkdirs()) {
            throw IllegalStateException("Could not create private model storage.")
        }
        if (declaredSize != null && StatFs(modelDir.path).availableBytes < declaredSize!!) {
            throw IllegalStateException("Not enough free storage to copy this model.")
        }

        val temporary = File(modelDir, "lucy-model.gguf.tmp")
        val target = File(modelDir, "lucy-model.gguf")
        val backup = File(modelDir, "lucy-model.gguf.bak")
        var copied = 0L
        try {
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("Android could not read the selected document.")
            input.use { source ->
                FileOutputStream(temporary, false).buffered(1024 * 1024).use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        copied += count
                    }
                    output.flush()
                }
            }
            if (copied < 4) throw IllegalArgumentException("The selected model is incomplete.")
            val header = ByteArray(4)
            val headerRead = temporary.inputStream().use { stream ->
                var offset = 0
                while (offset < header.size) {
                    val count = stream.read(header, offset, header.size - offset)
                    if (count < 0) break
                    offset += count
                }
                offset
            }
            if (headerRead != 4 || String(header, Charsets.US_ASCII) != "GGUF") {
                throw IllegalArgumentException("The selected file does not have a GGUF header.")
            }

            if (backup.exists()) backup.delete()
            val hadPrevious = target.exists()
            if (hadPrevious && !target.renameTo(backup)) {
                throw IllegalStateException("Could not safely replace the previous model file.")
            }
            if (!temporary.renameTo(target)) {
                if (hadPrevious) backup.renameTo(target)
                throw IllegalStateException("Could not finish importing the model file.")
            }
            if (backup.exists()) backup.delete()
            return mapOf(
                "path" to target.absolutePath,
                "name" to name,
                "bytes" to copied,
                "format" to "GGUF",
            )
        } finally {
            if (temporary.exists()) temporary.delete()
            if (backup.exists() && !target.exists()) backup.renameTo(target)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(forceStopReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister forceStopReceiver", e)
        }
        methodChannel = null
        pendingResult = null
        pendingModelResult = null
        super.onDestroy()
    }
}
