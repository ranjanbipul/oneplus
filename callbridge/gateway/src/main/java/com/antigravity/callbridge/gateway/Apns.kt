package com.antigravity.callbridge.gateway

import android.content.Context
import android.util.Base64
import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Apple push for iPhone clients that are not connected (an iOS app is suspended in the
 * background): a VoIP push when a call starts ringing, which wakes the app into CallKit,
 * and an alert push for each new SMS. Sent over the phone's own internet connection.
 *
 * Needs an APNs auth key from the Apple developer account, placed on the phone as
 *   /sdcard/Android/data/<package>/files/apns/key.p8
 *   /sdcard/Android/data/<package>/files/apns/config.json   {"keyId": "...", "teamId": "..."}
 * (install_callbridge.sh apns does this). Without them pushes are off and iPhone clients
 * ring only while their app is open.
 */
object Apns {
    private const val TAG = "CallBridgeGateway"
    private val exec = Executors.newSingleThreadExecutor()
    private val http by lazy {
        OkHttpClient.Builder()
            .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }

    private class Credentials(val keyId: String, val teamId: String, val key: PrivateKey)

    @Volatile
    private var creds: Credentials? = null
    private var credsLoadedFrom = 0L
    private var jwt = ""
    private var jwtAt = 0L

    /** One registered iPhone install. */
    data class Device(val clientId: String, val voip: String, val alert: String, val topic: String, val sandbox: Boolean)

    // ---------------------------------------------------------------- registrations

    private fun sp(ctx: Context) = ctx.getSharedPreferences("apns_devices", Context.MODE_PRIVATE)

    fun register(ctx: Context, d: Device) {
        val o = JSONObject().put("voip", d.voip).put("alert", d.alert).put("topic", d.topic).put("sandbox", d.sandbox)
        sp(ctx).edit().putString(d.clientId, o.toString()).apply()
        Log.i(TAG, "push registered for ${d.clientId} (sandbox=${d.sandbox})")
    }

    fun devices(ctx: Context): List<Device> = sp(ctx).all.mapNotNull { (id, v) ->
        runCatching {
            val o = JSONObject(v as String)
            Device(id, o.optString("voip"), o.optString("alert"), o.optString("topic"), o.optBoolean("sandbox"))
        }.getOrNull()
    }

    private fun forget(ctx: Context, clientId: String, field: String) {
        val v = sp(ctx).getString(clientId, null) ?: return
        val o = JSONObject(v).put(field, "")
        sp(ctx).edit().putString(clientId, o.toString()).apply()
        Log.i(TAG, "push token ($field) for $clientId is no longer valid; dropped")
    }

    // ---------------------------------------------------------------- credentials

    private fun dir(ctx: Context) = File(ctx.getExternalFilesDir(null), "apns")

    /** Null when pushes are configured, else why they are off. */
    fun problem(ctx: Context): String? = if (load(ctx) != null) null else "no APNs key on the gateway"

    private fun load(ctx: Context): Credentials? {
        val keyFile = File(dir(ctx), "key.p8")
        val confFile = File(dir(ctx), "config.json")
        if (!keyFile.exists() || !confFile.exists()) return null
        val stamp = keyFile.lastModified() + confFile.lastModified()
        creds?.let { if (stamp == credsLoadedFrom) return it }
        return try {
            val conf = JSONObject(confFile.readText())
            val pem = keyFile.readText()
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replace("\\s".toRegex(), "")
            val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(Base64.decode(pem, Base64.DEFAULT)))
            Credentials(conf.getString("keyId"), conf.getString("teamId"), key).also {
                creds = it
                credsLoadedFrom = stamp
                jwt = ""
            }
        } catch (e: Exception) {
            Log.w(TAG, "APNs key unusable: $e")
            null
        }
    }

    /** Provider token (ES256 JWT); Apple accepts one for an hour, so refresh every 50 minutes. */
    private fun token(c: Credentials): String {
        val now = System.currentTimeMillis() / 1000
        if (jwt.isNotEmpty() && now - jwtAt < 50 * 60) return jwt
        val b64 = { b: ByteArray -> Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP) }
        val header = b64(JSONObject().put("alg", "ES256").put("kid", c.keyId).toString().toByteArray())
        val claims = b64(JSONObject().put("iss", c.teamId).put("iat", now).toString().toByteArray())
        val input = "$header.$claims"
        val der = Signature.getInstance("SHA256withECDSA").run {
            initSign(c.key)
            update(input.toByteArray())
            sign()
        }
        jwt = "$input.${b64(derToRaw(der))}"
        jwtAt = now
        return jwt
    }

    /** JWS wants the ECDSA signature as raw r||s (32 bytes each), Java produces DER. */
    private fun derToRaw(der: ByteArray): ByteArray {
        var i = 2
        if (der[1].toInt() and 0x80 != 0) i += der[1].toInt() and 0x7f
        fun int(): ByteArray {
            require(der[i].toInt() == 0x02)
            val len = der[i + 1].toInt()
            val v = der.copyOfRange(i + 2, i + 2 + len)
            i += 2 + len
            val trimmed = v.dropWhile { it.toInt() == 0 }.toByteArray()
            return ByteArray(32 - trimmed.size) + trimmed
        }
        return int() + int()
    }

    // ---------------------------------------------------------------- sending

    /** Rings every registered iPhone that is not connected right now. */
    fun ring(ctx: Context, number: String, connectedIds: Set<String>) {
        val payload = JSONObject().put("number", number).put("ts", System.currentTimeMillis())
        for (d in devices(ctx)) {
            if (d.voip.isEmpty() || d.clientId in connectedIds) continue
            send(ctx, d, "voip", d.voip, "${d.topic}.voip", payload, expiration = 0)
        }
    }

    /** Posts an SMS notification on every registered iPhone that is not connected right now. */
    fun sms(ctx: Context, from: String, body: String, connectedIds: Set<String>) {
        val aps = JSONObject()
            .put("alert", JSONObject().put("title", from).put("body", body))
            .put("sound", "default")
            .put("thread-id", from.filter { it.isDigit() }.takeLast(10).ifEmpty { from })
        val payload = JSONObject().put("aps", aps).put("sms", from)
        val expire = System.currentTimeMillis() / 1000 + 24 * 3600
        for (d in devices(ctx)) {
            if (d.alert.isEmpty() || d.clientId in connectedIds) continue
            send(ctx, d, "alert", d.alert, d.topic, payload, expiration = expire)
        }
    }

    private fun send(ctx: Context, d: Device, type: String, deviceToken: String, topic: String, payload: JSONObject, expiration: Long) {
        exec.execute {
            val c = load(ctx)
            if (c == null) {
                Log.i(TAG, "push skipped: no APNs key on the gateway")
                return@execute
            }
            val host = if (d.sandbox) "api.sandbox.push.apple.com" else "api.push.apple.com"
            val req = Request.Builder()
                .url("https://$host/3/device/$deviceToken")
                .header("authorization", "bearer ${token(c)}")
                .header("apns-topic", topic)
                .header("apns-push-type", type)
                .header("apns-priority", "10")
                .header("apns-expiration", expiration.toString())
                .post(payload.toString().toRequestBody("application/json".toMediaType()))
                .build()
            try {
                http.newCall(req).execute().use { r ->
                    val body = r.body?.string().orEmpty()
                    if (r.isSuccessful) {
                        Log.i(TAG, "push ($type) sent to ${d.clientId}")
                    } else {
                        Log.w(TAG, "push ($type) to ${d.clientId} failed: ${r.code} $body")
                        if (r.code == 410 || body.contains("BadDeviceToken") || body.contains("DeviceTokenNotForTopic")) {
                            forget(ctx, d.clientId, type)
                        }
                        if (r.code == 403) jwt = "" // expired or rejected provider token: make a new one
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "push ($type) to ${d.clientId} failed: $e")
            }
        }
    }
}
