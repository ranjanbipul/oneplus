package com.antigravity.callbridge.client

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.PowerManager
import android.util.Log
import com.antigravity.callbridge.proto.Proto
import java.net.DatagramPacket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import kotlin.concurrent.thread

/** Microphone -> gateway and gateway -> earpiece/speaker, 16 kHz mono PCM over UDP. */
object AudioEngine {
    private const val TAG = "CallBridgeAudio"

    @Volatile
    var running = false
        private set

    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var proximity: PowerManager.WakeLock? = null

    @Synchronized
    fun start(ctx: Context) {
        if (running) return
        val sock = Link.udp ?: return
        val gw = Link.gateway ?: return
        val token = Link.token
        val am = ctx.getSystemService(AudioManager::class.java)
        try {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            val minRec = AudioRecord.getMinBufferSize(Proto.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            @Suppress("MissingPermission")
            val rec = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, Proto.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minRec, Proto.FRAME_SAMPLES * 2 * 5)
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("microphone unavailable")
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(rec.audioSessionId)?.enabled = true
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(rec.audioSessionId)?.enabled = true
            val minPlay = AudioTrack.getMinBufferSize(Proto.SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val trk = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(Proto.SAMPLE_RATE)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                // ~120 ms: the track's own buffer doubles as the jitter buffer.
                .setBufferSizeInBytes(maxOf(minPlay, Proto.FRAME_SAMPLES * 2 * 6))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            record = rec
            track = trk
            rec.startRecording()
            trk.play()
        } catch (e: Exception) {
            Log.e(TAG, "audio start failed", e)
            AppState.notice = "Audio failed: ${e.message}"
            release(ctx)
            return
        }
        running = true
        setSpeaker(ctx, AppState.speaker)
        val dest = InetSocketAddress(gw, Proto.AUDIO_PORT)

        thread(name = "cb-mic") {
            val pcm = ShortArray(Proto.FRAME_SAMPLES)
            val silence = ShortArray(Proto.FRAME_SAMPLES)
            val out = ByteArray(Proto.AUDIO_PACKET)
            var seq = 0
            while (running) {
                val r = record?.read(pcm, 0, pcm.size) ?: break
                if (r != pcm.size) break
                Proto.packAudio(out, token, seq++, if (AppState.muted) silence else pcm)
                runCatching { sock.send(DatagramPacket(out, out.size, dest)) }
            }
        }
        thread(name = "cb-play") {
            val buf = ByteArray(2048)
            val pkt = DatagramPacket(buf, buf.size)
            val pcm = ShortArray(Proto.FRAME_SAMPLES)
            var last = -1
            runCatching { sock.soTimeout = 500 }
            while (running) {
                try {
                    pkt.length = buf.size
                    sock.receive(pkt)
                } catch (e: SocketTimeoutException) {
                    continue
                } catch (e: Exception) {
                    break
                }
                val seq = Proto.unpackAudio(buf, pkt.length, token, pcm) ?: continue
                // Drop late or duplicated packets; accept a restart of the sequence.
                if (seq <= last && last - seq < 500) continue
                last = seq
                track?.write(pcm, 0, pcm.size, AudioTrack.WRITE_NON_BLOCKING)
            }
        }
    }

    @Synchronized
    fun stop(ctx: Context) {
        if (!running && record == null) return
        running = false
        release(ctx)
    }

    private fun release(ctx: Context) {
        runCatching { record?.stop() }
        runCatching { record?.release() }
        runCatching { track?.stop() }
        runCatching { track?.release() }
        record = null
        track = null
        runCatching { if (proximity?.isHeld == true) proximity?.release() }
        val am = ctx.getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 31) runCatching { am.clearCommunicationDevice() }
        else @Suppress("DEPRECATION") runCatching { am.isSpeakerphoneOn = false }
        runCatching { am.mode = AudioManager.MODE_NORMAL }
    }

    fun setSpeaker(ctx: Context, on: Boolean) {
        val am = ctx.getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            val want = if (on) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            val dev = am.availableCommunicationDevices.firstOrNull { it.type == want }
            runCatching { if (dev != null) am.setCommunicationDevice(dev) else am.clearCommunicationDevice() }
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = on
        }
        // Screen off against the ear, like a normal call.
        runCatching {
            if (proximity == null) {
                proximity = ctx.getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "callbridge:proximity")
            }
            if (on || !running) {
                if (proximity?.isHeld == true) proximity?.release()
            } else if (proximity?.isHeld == false) proximity?.acquire(4 * 60 * 60 * 1000L)
        }
    }
}
