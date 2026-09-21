package dev.hermes.hermes_app

import android.Manifest
import android.os.Build
import android.content.pm.PackageManager
import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var exportResult: MethodChannel.Result? = null
    private var exportFile: File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val keepalive = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hermes/stream-keepalive")
        HermesStreamService.reportError = { keepalive.invokeMethod("error", null) }
        keepalive.setMethodCallHandler { call, result ->
            val id = (call.arguments as? Number)?.toInt()
            if (id == null) result.error("argument", "Missing stream token", null)
            else when (call.method) {
                "start" -> HermesStreamService.start(applicationContext, id, result)
                "stop" -> {
                    try {
                        HermesStreamService.stop(applicationContext, id, result)
                    } catch (_: Exception) { result.error("fgs", "Cannot stop service", null) }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hermes/diagnostics")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(mapOf("version" to "${info.versionName}+${info.versionCode}",
                            "directory" to File(filesDir, "diagnostics").absolutePath))
                    }
                    "export" -> {
                        if (exportResult != null) {
                            result.error("busy", "Export already open", null)
                        } else {
                            exportResult = result
                            exportFile = File(call.arguments as String)
                            try {
                                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "application/octet-stream"
                                    putExtra(Intent.EXTRA_TITLE, "hermes-diagnostics.jsonl")
                                }, 2202)
                            } catch (_: Exception) {
                                exportResult = null
                                exportFile = null
                                result.error("export", "Cannot open document picker", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onPostResume() {
        super.onPostResume()
        val prefs = getSharedPreferences("stream_permissions", MODE_PRIVATE)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean("notification_requested", false)) {
            prefs.edit().putBoolean("notification_requested", true).apply()
            try {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2303)
            } catch (_: Exception) { HermesStreamService.reportError?.invoke() }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 2202) return
        val result = exportResult ?: return
        try {
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) result.success(false)
            else {
                val output = contentResolver.openOutputStream(uri) ?: error("No output stream")
                output.use { out -> exportFile!!.inputStream().use { it.copyTo(out) } }
                result.success(true)
            }
        } catch (_: Exception) {
            result.error("export", "Cannot save diagnostics", null)
        } finally {
            exportResult = null
            exportFile = null
        }
    }
}
