package dev.hermes.hermes_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit

/**
 * Voice-call foreground service (PLAN-VOICEUI §4.4/§4.8 row
 * VoiceCallService.kt). Capture AND playback live here so the call keeps
 * running while the Activity is paused; capture uses
 * MediaRecorder.AudioSource.VOICE_COMMUNICATION and playback
 * USAGE_VOICE_COMMUNICATION under MODE_IN_COMMUNICATION so the platform's
 * paired AEC applies to BOTH directions (§4.1 point 1 — a player outside
 * this audio path would silently break echo cancellation).
 *
 * Wire contract with Dart (call_audio_native.dart):
 * * uplink EventSink: ByteArray = one 640-byte capture frame; Map =
 *   {type: focusLost|hangupRequested|stats|drained, input_latency_ms}.
 * * downlink (MainActivity): ByteArray 640 = play, length 0 = flush — ONE
 *   channel, so play/flush order equals wire order (§4.1).
 */
class VoiceCallService : Service() {
    companion object {
        const val ACTION_HANGUP = "dev.hermes.hermes_app.HANGUP"
        private const val CHANNEL = "hermes_call"
        private const val NOTIFICATION = 2401
        private const val FRAME_BYTES = 640 // 20 ms @ 16 kHz mono s16le

        /// Set by MainActivity's EventChannel.onListen; frames and signals
        /// are posted on the main looper before touching it.
        @Volatile
        var uplink: EventChannel.EventSink? = null

        @Volatile
        private var active: VoiceCallService? = null

        private var pendingResult: MethodChannel.Result? = null
        private var pendingStart: Pair<String, Boolean>? = null

        fun start(context: Context, title: String, speaker: Boolean,
                  result: MethodChannel.Result) {
            if (active != null) { // one call at a time (mirrors 4409, D13)
                result.error("busy", "Call already running", null)
                return
            }
            pendingResult = result
            pendingStart = title to speaker
            try {
                val intent = Intent(context, VoiceCallService::class.java)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (_: Exception) {
                pendingResult?.error("fgs", "Cannot start call service", null)
                pendingResult = null
                pendingStart = null
            }
        }

        fun stop(context: Context, result: MethodChannel.Result) {
            context.stopService(Intent(context, VoiceCallService::class.java))
            result.success(null)
        }

        /** Downlink PCM frame; the length-0 flush message never comes here. */
        fun play(bytes: ByteArray) {
            active?.enqueue(bytes)
        }

        fun flush() {
            active?.flushPlayback()
        }

        fun setSpeaker(on: Boolean) {
            active?.applySpeaker(on)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private val queue = LinkedBlockingDeque<ByteArray>()
    private var captureThread: Thread? = null
    private var playbackThread: Thread? = null
    @Volatile private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANGUP) {
            // Notification "hang up" (§4.4): Dart owns the teardown so the
            // gateway still gets {"type":"hangup"} + close(1000) (§3.4).
            main.post { uplink?.success(mapOf("type" to "hangupRequested")) }
            return START_NOT_STICKY
        }
        if (running) {
            pendingResult?.success(null)
            pendingResult = null
            return START_NOT_STICKY
        }
        val (title, speaker) = pendingStart ?: ("" to true)
        var started = false
        try {
            promoteForeground(title)
            startAudio(speaker)
            running = true
            active = this
            started = true
        } catch (_: Exception) {
            releaseAudio()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        val result = pendingResult
        pendingResult = null
        pendingStart = null
        if (started) result?.success(null)
        else result?.error("fgs", "Cannot start call service", null)
        return START_NOT_STICKY
    }

    private fun promoteForeground(title: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL, NotificationLocale.callChannelName(this),
                NotificationManager.IMPORTANCE_LOW))
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        val hangUp = PendingIntent.getService(
            this, 0,
            Intent(this, VoiceCallService::class.java).setAction(ACTION_HANGUP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = builder
            .setSmallIcon(R.drawable.ic_stream_notification)
            .setContentTitle(NotificationLocale.callTitle(this, title))
            .addAction(0, NotificationLocale.callHangUp(this), hangUp)
            .setContentIntent(PendingIntent.getActivity(
                this, 0, Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(Notification.PRIORITY_LOW)
            .build()
        // FOREGROUND_SERVICE_TYPE_MICROPHONE is API 30 (api-versions.xml);
        // on 29 the two-arg form falls back to the manifest type.
        if (Build.VERSION.SDK_INT >= 30) {
            startForeground(NOTIFICATION, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else startForeground(NOTIFICATION, notification)
    }

    private fun startAudio(speaker: Boolean) {
        val am = getSystemService(AudioManager::class.java)
        audioManager = am
        // MODE_IN_COMMUNICATION routes VOICE_COMMUNICATION and arms the
        // paired AEC (§4.1); D9's speaker default is applied at the end.
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        requestFocus(am)

        val minBuf = AudioRecord.getMinBufferSize(
            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf, FRAME_BYTES * 4))
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("AudioRecord unavailable")
        }
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(rec.audioSessionId)?.also { it.setEnabled(true) }
        }
        rec.startRecording()
        record = rec

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val minOut = AudioTrack.getMinBufferSize(
            16000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val trackBuilder = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setTransferMode(AudioTrack.MODE_STREAM)
        if (Build.VERSION.SDK_INT >= 26) { // setPerformanceMode is API 26
            trackBuilder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val trk = trackBuilder
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(16000)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build())
            .setBufferSizeInBytes(maxOf(minOut, FRAME_BYTES * 16))
            .build()
        trk.play()
        track = trk
        applySpeaker(speaker)

        captureThread = Thread({ captureLoop(rec) }, "vg-capture").also {
            it.priority = Thread.MAX_PRIORITY
            it.start()
        }
        playbackThread = Thread({ playbackLoop(trk) }, "vg-playback").also { it.start() }
    }

    private fun requestFocus(am: AudioManager) {
        val loss: (Int) -> Unit = { change ->
            if (change != AudioManager.AUDIOFOCUS_GAIN) {
                // §4.2/D20: any loss auto-mutes in Dart; never auto-unmutes.
                main.post { uplink?.success(mapOf("type" to "focusLost")) }
            }
        }
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs)
                    .setWillPauseWhenDucked(false)
                    .setOnAudioFocusChangeListener { change -> loss(change) }
                    .build()
                focusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    { change -> loss(change) },
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN)
            }
        } catch (_: Exception) {
            // A focus denial must not stop the call; capture/playback work.
        }
    }

    /** Capture thread: blocking 640-byte reads posted to Dart (§4.1),
     *  plus one §5.3 input-latency sample per second. */
    private fun captureLoop(rec: AudioRecord) {
        val frame = ByteArray(FRAME_BYTES)
        var offset = 0
        var lastStats = 0L
        var framesRead = 0L // PCM frames (2 bytes each) handed to Dart
        try {
            while (running) {
                val read = rec.read(frame, offset, FRAME_BYTES - offset)
                if (read < 0) break // released mid-read on teardown
                if (read == 0) continue
                offset += read
                if (offset == FRAME_BYTES) {
                    offset = 0
                    framesRead += FRAME_BYTES / 2
                    val copy = frame.copyOf()
                    main.post { uplink?.success(copy) }
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastStats >= 1000) {
                        lastStats = now
                        var latency: Double? = null
                        try {
                            val ts = AudioTimestamp()
                            if (rec.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) ==
                                AudioRecord.SUCCESS && ts.nanoTime > 0) {
                                // TIMEBASE_MONOTONIC shares System.nanoTime's
                                // timebase. ts pins framePosition to its
                                // capture time; extrapolate at 16 kHz to the
                                // last frame we just read and measure how
                                // long ago it was captured. Missing → honest
                                // null (§5.3).
                                val capturedAt = ts.nanoTime +
                                    (framesRead - ts.framePosition) * 1_000_000_000L / 16000
                                latency = ((System.nanoTime() - capturedAt) / 1e6)
                                    .coerceIn(0.0, 1000.0)
                            }
                        } catch (_: Exception) {
                            latency = null
                        }
                        val sample = latency
                        main.post {
                            uplink?.success(
                                mapOf("type" to "stats", "input_latency_ms" to sample))
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // Record released mid-read during teardown: normal exit.
        }
    }

    /** Playback thread: deque → blocking AudioTrack.write; queue
     *  non-empty → empty is the `drained` edge — the UI's speech indicator
     *  follows the LOCAL buffer, not audio_end (§4.7). */
    private fun playbackLoop(trk: AudioTrack) {
        try {
            while (running) {
                val frame = queue.poll(20, TimeUnit.MILLISECONDS) ?: continue
                trk.write(frame, 0, frame.size)
                if (queue.isEmpty()) {
                    main.post { uplink?.success(mapOf("type" to "drained")) }
                }
            }
        } catch (_: Exception) {
            // Track released mid-write during teardown: normal exit.
        }
    }

    private fun enqueue(bytes: ByteArray) {
        if (running) queue.add(bytes)
    }

    private fun flushPlayback() {
        queue.clear()
        try {
            track?.let { it.pause(); it.flush(); it.play() }
        } catch (_: Exception) {
            // Idempotent (§3.1): a dead track has nothing left to flush.
        }
    }

    private fun applySpeaker(on: Boolean) {
        val am = audioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                if (on) {
                    val speaker = am.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    }
                    if (speaker != null) am.setCommunicationDevice(speaker)
                } else {
                    am.clearCommunicationDevice()
                }
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = on
            }
        } catch (_: Exception) {
            // Route switch is best-effort (D9: speaker default for calls).
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // §4.4: swiped from recents → release audio; the Dart engine dies
        // with it and the gateway sees the abnormal-disconnect path (§3.4).
        releaseAudio()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseAudio()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun releaseAudio() {
        running = false
        active = null
        queue.clear()
        try { captureThread?.join(500) } catch (_: Exception) {}
        try { playbackThread?.join(500) } catch (_: Exception) {}
        captureThread = null
        playbackThread = null
        try { aec?.release() } catch (_: Exception) {}
        aec = null
        try { record?.stop() } catch (_: Exception) {}
        try { record?.release() } catch (_: Exception) {}
        record = null
        try { track?.pause() } catch (_: Exception) {}
        try { track?.release() } catch (_: Exception) {}
        track = null
        val am = audioManager
        if (am != null) {
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    focusRequest?.let { am.abandonAudioFocusRequest(it) }
                } else {
                    @Suppress("DEPRECATION")
                    am.abandonAudioFocus(null)
                }
            } catch (_: Exception) {}
            if (Build.VERSION.SDK_INT >= 31) {
                try { am.clearCommunicationDevice() } catch (_: Exception) {}
            }
            focusRequest = null
            try { am.mode = AudioManager.MODE_NORMAL } catch (_: Exception) {}
        }
        audioManager = null
    }
}
