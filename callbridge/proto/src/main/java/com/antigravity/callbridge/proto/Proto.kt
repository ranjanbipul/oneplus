package com.antigravity.callbridge.proto

import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * CallBridge wire protocol.
 *
 * Control: TCP [CONTROL_PORT], one JSON object per line, field "t" is the message type.
 *   handshake   gw->cl  {t:challenge, nonce}
 *               cl->gw  {t:auth, cnonce, mac=HMAC(key,"c",nonce,cnonce), name, uport}
 *               gw->cl  {t:ok, mac=HMAC(key,"s",nonce,cnonce), token}
 *   cl->gw      dial{number} answer reject hangup dtmf{digit} calllog_get{limit}
 *               sms_get{limit} sms_send{id,to,body} ping
 *               push_register{voip,alert,topic,sandbox}   (iPhone: APNs tokens, see gateway Apns.kt)
 *   gw->cl      call{state,number,incoming,bridged} calllog{items[]} sms{items[]}
 *               sms_in{from,body,ts} sms_sent{id,ok,error} error{msg} pong push_status{ok,msg}
 *
 * Audio: UDP [AUDIO_PORT], packets of [token:int][seq:int][FRAME_SAMPLES x pcm16le], mono.
 */
object Proto {
    const val CONTROL_PORT = 8765
    const val AUDIO_PORT = 8766
    const val SAMPLE_RATE = 16000
    const val FRAME_SAMPLES = SAMPLE_RATE / 50 // 20 ms
    const val AUDIO_HEADER = 8
    const val AUDIO_PACKET = AUDIO_HEADER + FRAME_SAMPLES * 2
    const val MAX_LINE = 256 * 1024

    const val STATE_IDLE = "idle"
    const val STATE_RINGING = "ringing"
    const val STATE_DIALING = "dialing"
    const val STATE_ACTIVE = "active"

    fun msg(type: String): JSONObject = JSONObject().put("t", type)

    fun packAudio(out: ByteArray, token: Int, seq: Int, pcm: ShortArray) {
        val b = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(token).putInt(seq)
        for (i in 0 until FRAME_SAMPLES) b.putShort(pcm[i])
    }

    /** Returns the sequence number, or null if the packet is malformed or the token is wrong. */
    fun unpackAudio(data: ByteArray, len: Int, token: Int, pcm: ShortArray): Int? {
        if (len != AUDIO_PACKET) return null
        val b = ByteBuffer.wrap(data, 0, len).order(ByteOrder.LITTLE_ENDIAN)
        if (b.int != token) return null
        val seq = b.int
        for (i in 0 until FRAME_SAMPLES) pcm[i] = b.short
        return seq
    }
}

object Auth {
    private val rng = SecureRandom()

    fun nonce(): String = ByteArray(16).also { rng.nextBytes(it) }.joinToString("") { "%02x".format(it) }

    fun token(): Int = rng.nextInt()

    /** Human-typable pairing key (no ambiguous characters). */
    fun newPairingKey(): String {
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return (1..10).map { alphabet[rng.nextInt(alphabet.length)] }.joinToString("")
    }

    fun hmac(key: String, vararg parts: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key.trim().uppercase().toByteArray(), "HmacSHA256"))
        for (p in parts) {
            mac.update(p.toByteArray())
            mac.update(0)
        }
        return mac.doFinal().joinToString("") { "%02x".format(it) }
    }

    fun same(a: String, b: String): Boolean = MessageDigest.isEqual(a.toByteArray(), b.toByteArray())
}

/** Line-delimited JSON over a socket. Reads are single-threaded; sends are synchronized. */
class Wire(private val socket: Socket) {
    private val input: InputStream = socket.getInputStream().buffered()
    private val output: OutputStream = socket.getOutputStream()

    /** Returns null on end of stream. Throws on oversized or malformed input. */
    fun read(): JSONObject? {
        val buf = java.io.ByteArrayOutputStream()
        while (true) {
            val c = input.read()
            if (c < 0) return null
            if (c == '\n'.code) break
            buf.write(c)
            if (buf.size() > Proto.MAX_LINE) throw java.io.IOException("line too long")
        }
        return JSONObject(buf.toString("UTF-8"))
    }

    fun send(o: JSONObject) {
        val bytes = (o.toString() + "\n").toByteArray()
        synchronized(output) {
            output.write(bytes)
            output.flush()
        }
    }

    fun close() {
        runCatching { socket.close() }
    }
}
