package com.antigravity.callbridge.gateway

import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.util.Log
import com.antigravity.callbridge.proto.Proto
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Two-way tap into the active cellular call. PCM is 16 kHz mono 16-bit.
 *
 * Downlink (far party -> us): Android 13 system API
 *   AudioManager.getCallDownlinkExtractionAudioRecord (needs CALL_AUDIO_INTERCEPTION).
 * Uplink (us -> far party): root. The matching system API routes to a "voice_tx" output that
 *   this ROM's audio HAL never connects to the modem, so we instead enable the modem's
 *   in-call music mixer and stream 48 kHz stereo into ALSA device MultiMedia2 with tinyplay.
 *   Both Incall_Music (SIM slot 1) and Incall_Music_2 (SIM slot 2) are enabled.
 *   Verified on IN2011 / OxygenOS 13.1 with the SIM in slot 2.
 */
class HybridAudioBridge(context: Context) {
    private val am = context.getSystemService(AudioManager::class.java)
    private var record: AudioRecord? = null
    private var proc: Process? = null
    private var sink: OutputStream? = null
    private var prev = 0
    private var injectorStarted = 0L

    @Volatile
    private var stopped = false
    private val out = ByteBuffer.allocate(Proto.FRAME_SAMPLES * 3 * 4).order(ByteOrder.LITTLE_ENDIAN)

    fun start() {
        try {
            val fmt = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(Proto.SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            record = AudioManager::class.java
                .getMethod("getCallDownlinkExtractionAudioRecord", AudioFormat::class.java)
                .invoke(am, fmt) as AudioRecord
            record!!.startRecording()

            startInjector()
            Log.i(TAG, "started: mode=${am.mode} routedIn=${record!!.routedDevice?.type}")
        } catch (e: Throwable) {
            stop()
            val cause = if (e is java.lang.reflect.InvocationTargetException && e.cause != null) e.cause!! else e
            throw IllegalStateException("call audio unavailable: $cause", cause)
        }
    }

    /**
     * Starts tinyplay reading a WAV stream from its stdin. tinyplay does not recover from a
     * buffer underrun (it prints "Error playing sample" and exits), so:
     *  - the ALSA buffer is 4 x 480 frames (40 ms) rather than the minimum,
     *  - the pipe is pre-filled with silence so tinyplay always has a chunk waiting, and
     *  - [writeUplink] restarts it if it ever exits.
     */
    private fun startInjector() {
        val p = ProcessBuilder("su", "-c", "$MIXER_ON; exec tinyplay /proc/self/fd/0 -D 0 -d $PCM_DEVICE -p 480 -n 4")
            .redirectErrorStream(true)
            .start()
        proc = p
        // The stream is closed under this reader when the injector stops; that must not crash the app.
        Thread({ runCatching { p.inputStream.bufferedReader().forEachLine { Log.i(TAG, "tinyplay: $it") } } }, "cb-tinyplay-log")
            .apply { isDaemon = true }.start()
        val o = p.outputStream
        o.write(wavHeader())
        o.write(ByteArray(PREFILL_FRAMES * Proto.FRAME_SAMPLES * 3 * 4))
        o.flush()
        sink = o
        injectorStarted = System.nanoTime()
    }

    private fun restartInjector(why: String): Boolean {
        if (stopped) return false
        // Do not spin if the injector cannot start at all (for example root was revoked).
        if (System.nanoTime() - injectorStarted < 300_000_000L) return true
        Log.w(TAG, "injector stopped ($why); restarting")
        runCatching { sink?.close() }
        runCatching { proc?.destroy() }
        sink = null
        return try {
            startInjector()
            true
        } catch (e: Exception) {
            Log.e(TAG, "injector restart failed: $e")
            false
        }
    }

    /** Blocking read of far-party audio. Returns samples read, or <= 0 on error. */
    fun readDownlink(buf: ShortArray, len: Int): Int = record?.read(buf, 0, len) ?: -1

    /** Sends [len] mono 16 kHz samples towards the far party. Returns false once the bridge is stopped. */
    fun writeUplink(buf: ShortArray, len: Int): Boolean {
        if (stopped) return false
        if (proc?.isAlive != true) return restartInjector("process exited")
        val s = sink ?: return restartInjector("no stream")
        out.clear()
        for (i in 0 until len) {
            val cur = buf[i].toInt()
            // 16 kHz -> 48 kHz by linear interpolation, duplicated to stereo.
            for (k in 1..3) {
                val v = (prev + (cur - prev) * k / 3).toShort()
                out.putShort(v).putShort(v)
            }
            prev = cur
        }
        return try {
            s.write(out.array(), 0, out.position())
            s.flush()
            true
        } catch (e: java.io.IOException) {
            restartInjector("write failed: ${e.message}")
        }
    }

    fun stop() {
        stopped = true
        runCatching { record?.stop() }
        runCatching { record?.release() }
        record = null
        runCatching { sink?.close() }
        sink = null
        proc?.let { p ->
            runCatching { p.destroy() }
            runCatching { Runtime.getRuntime().exec(arrayOf("su", "-c", MIXER_OFF)).waitFor() }
        }
        proc = null
    }

    /** WAV header with an effectively endless data chunk so tinyplay keeps reading the pipe. */
    private fun wavHeader(): ByteArray {
        val rate = 48000
        val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray()).putInt(0x7ffffff0).put("WAVE".toByteArray())
        h.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(2)
        h.putInt(rate).putInt(rate * 4).putShort(4).putShort(16)
        h.put("data".toByteArray()).putInt(0x7fffff00)
        return h.array()
    }

    companion object {
        private const val TAG = "CallBridgeAudio"
        private const val PCM_DEVICE = 1 // MultiMedia2
        private const val PREFILL_FRAMES = 5 // 100 ms of silence queued ahead of live audio
        private const val MIXER_ON =
            "tinymix 'Incall_Music Audio Mixer MultiMedia2' 1; tinymix 'Incall_Music_2 Audio Mixer MultiMedia2' 1"
        private const val MIXER_OFF =
            "tinymix 'Incall_Music Audio Mixer MultiMedia2' 0; tinymix 'Incall_Music_2 Audio Mixer MultiMedia2' 0"

        // Voice session ids for SIM slot 1 and 2 (VoiceMMode1 / VoiceMMode2).
        private const val DEVICE_MUTE =
            "tinymix 'Voice Tx Device Mute' %d 297816064 0; tinymix 'Voice Tx Device Mute' %d 299651072 0"

        fun rootDeviceMute(muted: Boolean) {
            val v = if (muted) 1 else 0
            runCatching {
                Runtime.getRuntime().exec(arrayOf("su", "-c", DEVICE_MUTE.format(v, v))).waitFor()
            }
        }
    }
}
