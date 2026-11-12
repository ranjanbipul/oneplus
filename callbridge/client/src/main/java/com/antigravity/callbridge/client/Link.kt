package com.antigravity.callbridge.client

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.util.Log
import com.antigravity.callbridge.proto.Auth
import com.antigravity.callbridge.proto.Proto
import com.antigravity.callbridge.proto.Wire
import org.json.JSONArray
import org.json.JSONObject
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Control connection to the gateway. [run] is driven by [LinkService]; sends are off the UI thread. */
object Link {
    private const val TAG = "CallBridgeLink"
    private val sender = Executors.newSingleThreadScheduledExecutor()

    @Volatile
    private var wire: Wire? = null

    @Volatile
    private var socket: Socket? = null

    @Volatile
    var token = 0
        private set

    @Volatile
    var gateway: InetAddress? = null
        private set

    @Volatile
    var udp: DatagramSocket? = null
        private set

    @Volatile
    private var running = false

    fun send(m: JSONObject) {
        sender.execute {
            try {
                wire?.send(m) ?: run { AppState.notice = "Not connected to the gateway" }
            } catch (e: Exception) {
                socket?.let { runCatching { it.close() } }
            }
        }
    }

    /** Drops the current connection so [run] reconnects with fresh settings. */
    fun reconnect() {
        sender.execute { socket?.let { runCatching { it.close() } } }
    }

    fun stop() {
        running = false
        reconnect()
    }

    fun run(ctx: Context) {
        running = true
        while (running) {
            try {
                connectOnce(ctx)
            } catch (e: Exception) {
                Log.i(TAG, "link error: $e")
                if (!AppState.status.startsWith("Pairing")) AppState.status = "Not connected (${e.message ?: e.javaClass.simpleName})"
            }
            onDisconnected(ctx)
            if (running) Thread.sleep(1500)
        }
    }

    private fun defaultGateway(ctx: Context): InetAddress? {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val lp = cm.getLinkProperties(cm.activeNetwork ?: return null) ?: return null
        return lp.routes.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway
    }

    private fun connectOnce(ctx: Context) {
        val key = Config.key(ctx)
        if (key.isEmpty()) {
            AppState.status = "Pairing key not set (see Settings)"
            Thread.sleep(2000)
            return
        }
        val host = Config.host(ctx)
        val addr = if (host.isNotEmpty()) InetAddress.getByName(host)
        else defaultGateway(ctx) ?: throw IllegalStateException("no network gateway found")
        AppState.status = "Connecting to ${addr.hostAddress}…"

        val s = Socket()
        socket = s
        val u = DatagramSocket()
        udp = u
        var ping: ScheduledFuture<*>? = null
        try {
            s.connect(InetSocketAddress(addr, Proto.CONTROL_PORT), 4000)
            s.tcpNoDelay = true
            s.soTimeout = 10_000
            val w = Wire(s)
            val challenge = w.read() ?: throw IllegalStateException("gateway closed the connection")
            val nonce = challenge.getString("nonce")
            val cnonce = Auth.nonce()
            w.send(
                Proto.msg("auth")
                    .put("cnonce", cnonce)
                    .put("mac", Auth.hmac(key, "c", nonce, cnonce))
                    .put("name", Build.MODEL ?: "android")
                    .put("id", Config.clientId(ctx))
                    .put("uport", u.localPort)
            )
            val ok = w.read() ?: throw IllegalStateException("gateway closed the connection")
            if (ok.optString("t") != "ok" || !Auth.same(ok.optString("mac"), Auth.hmac(key, "s", nonce, cnonce))) {
                AppState.status = "Pairing key rejected by gateway"
                Thread.sleep(5000)
                return
            }
            token = ok.getInt("token")
            gateway = addr
            wire = w
            s.soTimeout = 20_000
            AppState.connected = true
            AppState.status = "Connected to ${addr.hostAddress}"
            send(Proto.msg("calllog_get").put("limit", 100))
            send(Proto.msg("sms_get").put("limit", 100))
            ping = sender.scheduleWithFixedDelay({ runCatching { w.send(Proto.msg("ping")) } }, 5, 5, TimeUnit.SECONDS)
            while (true) {
                val m = w.read() ?: break
                onMessage(ctx, m)
            }
        } finally {
            ping?.cancel(false)
            wire = null
            runCatching { s.close() }
        }
    }

    private fun onDisconnected(ctx: Context) {
        val wasConnected = AppState.connected
        AppState.connected = false
        if (wasConnected) AppState.status = "Disconnected, retrying…"
        val old = AppState.call
        if (old.state != Proto.STATE_IDLE) {
            AppState.call = CallInfo()
            CallCoordinator.onCall(ctx, old, AppState.call)
        }
        udp?.close()
        udp = null
    }

    private fun onMessage(ctx: Context, m: JSONObject) {
        when (m.optString("t")) {
            "call" -> {
                val old = AppState.call
                val new = CallInfo(m.optString("state"), m.optString("number"), m.optBoolean("incoming"), m.optBoolean("bridged"))
                AppState.call = new
                CallCoordinator.onCall(ctx, old, new)
            }
            "calllog" -> AppState.callLog = m.optJSONArray("items").map {
                LogItem(it.optString("number"), it.optString("name"), it.optString("type"), it.optLong("ts"), it.optLong("dur"))
            }
            "sms" -> AppState.sms = m.optJSONArray("items").map {
                SmsItem(it.optString("addr"), it.optString("body"), it.optLong("ts"), it.optBoolean("out"))
            }
            "sms_in" -> {
                val item = SmsItem(m.optString("from"), m.optString("body"), m.optLong("ts"), false)
                AppState.sms = listOf(item) + AppState.sms
                Notifications.showSms(ctx, item)
            }
            "sms_sent" -> {
                if (m.optBoolean("ok")) {
                    AppState.notice = "SMS sent"
                    // The phone stores the sent message a moment after accepting it.
                    sender.schedule({ send(Proto.msg("sms_get").put("limit", 100)) }, 2, TimeUnit.SECONDS)
                } else AppState.notice = "SMS failed: ${m.optString("error")}"
            }
            "error" -> {
                AppState.notice = m.optString("msg")
                CallCoordinator.onGatewayError(ctx)
            }
        }
    }

    private fun <T> JSONArray?.map(f: (JSONObject) -> T): List<T> {
        if (this == null) return emptyList()
        return (0 until length()).map { f(getJSONObject(it)) }
    }
}
