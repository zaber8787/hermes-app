package dev.hermes.hermes_app

import android.Manifest
import android.os.Build
import android.content.pm.PackageManager
import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var exportResult: MethodChannel.Result? = null
    private var exportFile: File? = null
    private var micResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val keepalive = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hermes/stream-keepalive")
        HermesStreamService.reportError = { keepalive.invokeMethod("error", null) }
        keepalive.setMethodCallHandler { call, result ->
            if (call.method == "setLocale") {
                // Dispatched BEFORE numeric token validation: locale calls
                // carry a map, not a stream id (I18N-PLAN §6.1). Only the
                // two canonical tags are accepted — never free text.
                val tag = (call.arguments as? Map<*, *>)?.get("tag") as? String
                if (tag == "en" || tag == "zh-Hant") {
                    NotificationLocale.set(applicationContext, tag)
                    result.success(null)
                } else result.error("argument", "Unknown locale tag", null)
                return@setMethodCallHandler
            }
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hermes/browser")
            .setMethodCallHandler { call, result ->
                // LINK-EXIT (2026-10-22): our own verified App Links domain
                // resolves ACTION_VIEW back to THIS app — url_launcher cannot
                // dodge that, so resolve an external browser ourselves and
                // pin the package. Our own package is never a candidate.
                if (call.method != "openExternally") { result.notImplemented(); return@setMethodCallHandler }
                val url = (call.arguments as? Map<*, *>)?.get("url") as? String
                if (url == null) { result.error("argument", "Missing url", null); return@setMethodCallHandler }
                try {
                    val view = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                        .addCategory(Intent.CATEGORY_BROWSABLE)
                    val self = packageName
                    var target: android.content.ComponentName? = null
                    val chosen = packageManager.queryIntentActivities(view, 0)
                        .firstOrNull { it.activityInfo.packageName != self }
                    if (chosen != null) {
                        target = android.content.ComponentName(chosen.activityInfo.packageName, chosen.activityInfo.name)
                    } else {
                        val resolved = packageManager.resolveActivity(view, 0)
                        if (resolved != null && resolved.activityInfo.packageName != self) {
                            target = android.content.ComponentName(resolved.activityInfo.packageName, resolved.activityInfo.name)
                        }
                    }
                    if (target == null) { result.success(false); return@setMethodCallHandler }
                    view.component = target
                    view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    view.addFlags(Intent.FLAG_ACTIVITY_MATCH_EXTERNAL)
                    startActivity(view)
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
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
        // Voice call (PLAN-VOICEUI §4.8 row MainActivity.kt): one
        // MethodChannel for control, an EventChannel for capture frames and
        // signals, and a BinaryCodec downlink where a length-0 message is
        // the flush command — play/flush share ONE ordered channel (§4.1).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hermes/voice-call")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "micPermission" -> result.success(micPermissionState())
                    "requestMic" -> requestMicPermission(result)
                    "start" -> {
                        val args = call.arguments as? Map<*, *>
                        val title = args?.get("title") as? String ?: ""
                        val speaker = args?.get("speaker") as? Boolean ?: true
                        try {
                            VoiceCallService.start(applicationContext, title, speaker, result)
                        } catch (_: Exception) {
                            result.error("fgs", "Cannot start call service", null)
                        }
                    }
                    "stop" -> VoiceCallService.stop(applicationContext, result)
                    "setSpeaker" -> {
                        VoiceCallService.setSpeaker(
                            (call.arguments as? Map<*, *>)?.get("on") as? Boolean ?: true)
                        result.success(null)
                    }
                    "openAppSettings" -> {
                        // micPermanentlyDenied → system page (§4.3).
                        try {
                            startActivity(
                                Intent(
                                    android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    android.net.Uri.parse("package:$packageName"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("settings", "Cannot open app settings", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "hermes/voice-call/uplink")
            .setStreamHandler(object : EventChannel.StreamHandler {
                // Remember our own sink so a late onCancel cannot clear a
                // newer listener's sink.
                private var sink: EventChannel.EventSink? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    VoiceCallService.uplink = events
                }

                override fun onCancel(arguments: Any?) {
                    if (VoiceCallService.uplink === sink) VoiceCallService.uplink = null
                    sink = null
                }
            })
        BasicMessageChannel(flutterEngine.dartExecutor.binaryMessenger,
            "hermes/voice-call/downlink", BinaryCodec.INSTANCE)
            .setMessageHandler { message, reply ->
                // Copy out now: the platform buffer is only valid inside
                // this callback.
                val bytes = if (message != null) {
                    ByteArray(message.remaining()).also { message.get(it) }
                } else ByteArray(0)
                if (bytes.isEmpty()) VoiceCallService.flush() else VoiceCallService.play(bytes)
                reply.reply(null)
            }
    }

    /** §4.4: three-state mic answer BEFORE any dialog; anything but
     *  granted makes Dart fire requestMic (the actual dialog path). */
    private fun micPermissionState(): String =
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED) "granted" else "denied"

    private fun requestMicPermission(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        val prefs = getSharedPreferences("voice_permissions", MODE_PRIVATE)
        val askedBefore = prefs.getBoolean("mic_requested", false)
        if (askedBefore && !shouldShowRequestPermissionRationale(
                Manifest.permission.RECORD_AUDIO)) {
            result.success("permanentlyDenied")
            return
        }
        if (micResult != null) {
            result.error("busy", "Permission request already open", null)
            return
        }
        micResult = result
        prefs.edit().putBoolean("mic_requested", true).apply()
        try {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 2404)
        } catch (_: Exception) {
            micResult = null
            result.success("denied")
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 2404) return
        val result = micResult ?: return
        micResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        result.success(when {
            granted -> "granted"
            shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> "denied"
            else -> "permanentlyDenied" // §4.4: rationale false after refusal
        })
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
