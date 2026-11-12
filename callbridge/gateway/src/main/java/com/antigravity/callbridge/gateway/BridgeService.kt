package com.antigravity.callbridge.gateway

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import com.antigravity.callbridge.proto.Auth
import com.antigravity.callbridge.proto.Proto
import com.antigravity.callbridge.proto.Wire
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * The gateway server. Accepts paired clients on TCP, reports call state, executes call
 * commands, and relays call audio over UDP to the client that answered or placed the call.
 */
class BridgeService : Service() {
    private class Client(val wire: Wire, val addr: InetAddress) {
        var token = 0
        var uport = 0
        var name = ""

        /** Stable per-install id, so a client that reconnects mid-call can reclaim its call. */
        var id = ""

        @Volatile
        var udp: SocketAddress? = null
    }

    private val clients = CopyOnWriteArrayList<Client>()

    /** All call-state transitions and client commands run on this one thread. */
    private val exec = Executors.newSingleThreadScheduledExecutor()
    private var server: ServerSocket? = null
    private var udp: DatagramSocket? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var logcat: Process? = null

    @Volatile
    private var owner: Client? = null

    @Volatile
    private var session: AudioSession? = null

    /** Set while the call's owner is briefly disconnected: its id, and the pending hang-up. */
    private var orphanId: String? = null
    private var orphanHangup: java.util.concurrent.ScheduledFuture<*>? = null

    @Volatile
    private var running = false

    val clientCount: Int get() = clients.size

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("bridge", "CallBridge", NotificationManager.IMPORTANCE_LOW))
        startForeground(
            1,
            Notification.Builder(this, "bridge")
                .setContentTitle("CallBridge gateway running")
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setOngoing(true)
                .build()
        )
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "callbridge:call")
        running = true
        instance = this
        // The system log on this phone rotates within seconds, so keep our own lines in a file:
        // /sdcard/Android/data/<package>/files/gateway.log (rotated to gateway.log.1 at 1 MB).
        runCatching {
            val file = java.io.File(getExternalFilesDir(null), "gateway.log")
            val p = ProcessBuilder(
                "logcat", "-v", "time", "-s", "CallBridgeGateway:V", "CallBridgeHub:V", "CallBridgeAudio:V"
            ).start()
            logcat = p
            thread(name = "cb-log", isDaemon = true) {
                runCatching {
                    p.inputStream.bufferedReader().forEachLine { line ->
                        if (file.length() > 1024 * 1024) file.renameTo(java.io.File(file.path + ".1"))
                        file.appendText(line + "\n")
                    }
                }
            }
        }
        CallHub.listener = { s -> exec.execute { onCallState(s) } }
        thread(name = "cb-accept") { acceptLoop() }
        thread(name = "cb-udp") { udpLoop() }
        Log.i(TAG, "gateway started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // adb: am start-foreground-service -n <pkg>/.BridgeService --es mute_mode telecom|device|none
        intent?.getStringExtra("mute_mode")?.let {
            if (it in Prefs.MUTE_MODES) {
                Prefs.setMuteMode(this, it)
                Log.i(TAG, "mute mode set to $it")
                exec.execute { session?.applyMute(it) }
            }
        }
        // adb: am start-foreground-service -n <pkg>/.BridgeService --es test_push sms|call
        // Sends a test push to registered iPhones that are not connected. A test ring shows
        // the incoming-call screen briefly; the app ends it once it sees no call is ringing.
        when (intent?.getStringExtra("test_push")) {
            "sms" -> exec.execute { Apns.sms(this, "CallBridge", "Test notification from the gateway", connectedIds()) }
            "call" -> exec.execute { Apns.ring(this, "CallBridge test", connectedIds()) }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        instance = null
        CallHub.listener = null
        runCatching { server?.close() }
        runCatching { udp?.close() }
        runCatching { logcat?.destroy() }
        exec.execute { stopSession() }
        exec.shutdown()
        clients.forEach { it.wire.close() }
        super.onDestroy()
    }

    // ---------------------------------------------------------------- control channel

    private fun acceptLoop() {
        while (running) {
            try {
                val ss = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(Proto.CONTROL_PORT))
                }
                server = ss
                while (running) {
                    val s = ss.accept()
                    thread(name = "cb-client") { handleClient(s) }
                }
            } catch (e: Exception) {
                if (running) {
                    Log.w(TAG, "accept loop error: $e")
                    Thread.sleep(2000)
                }
            }
        }
    }

    private fun handleClient(socket: Socket) {
        val wire = Wire(socket)
        val client = Client(wire, socket.inetAddress)
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = 10_000
            val nonce = Auth.nonce()
            wire.send(Proto.msg("challenge").put("nonce", nonce))
            val auth = wire.read() ?: return
            val key = Prefs.pairingKey(this)
            val cnonce = auth.optString("cnonce")
            if (auth.optString("t") != "auth" || cnonce.length < 16 ||
                !Auth.same(auth.optString("mac"), Auth.hmac(key, "c", nonce, cnonce))
            ) {
                Log.w(TAG, "rejected client ${socket.inetAddress}: bad pairing key")
                Thread.sleep(1000)
                wire.send(Proto.msg("error").put("msg", "bad pairing key"))
                return
            }
            client.token = Auth.token()
            client.uport = auth.optInt("uport")
            client.name = auth.optString("name")
            client.id = auth.optString("id")
            wire.send(Proto.msg("ok").put("mac", Auth.hmac(key, "s", nonce, cnonce)).put("token", client.token))
            // Clients ping every 5 s; 20 s of silence means the link is dead.
            socket.soTimeout = 20_000
            clients.add(client)
            Log.i(TAG, "client connected: ${client.name} ${client.addr}")
            exec.execute {
                reclaim(client)
                send(client, callMsg(client, CallHub.snapshot))
            }
            while (true) {
                val m = wire.read() ?: break
                exec.execute { runCatching { onMessage(client, m) }.onFailure { Log.w(TAG, "command failed", it) } }
            }
        } catch (e: Exception) {
            Log.i(TAG, "client ${socket.inetAddress} dropped: $e")
        } finally {
            wire.close()
            if (clients.remove(client)) exec.execute { onClientGone(client) }
        }
    }

    private fun onClientGone(client: Client) {
        if (owner !== client) return
        val wasBridged = session != null
        stopSession()
        owner = null
        if (!wasBridged && CallHub.snapshot.state != Proto.STATE_DIALING) return
        // The device on the call vanished. Networks blip, so give it a short window to come
        // back and reclaim the call before hanging up; never leave a call up with nobody on it.
        Log.i(TAG, "call owner ${client.name} lost; waiting ${ORPHAN_GRACE_S}s for it to return")
        orphanId = client.id
        orphanHangup?.cancel(false)
        orphanHangup = exec.schedule({
            if (orphanId != null) {
                Log.i(TAG, "call owner did not return; hanging up")
                orphanId = null
                CallHub.hangup()
            }
        }, ORPHAN_GRACE_S, TimeUnit.SECONDS)
    }

    private fun reclaim(client: Client) {
        if (orphanId == null || client.id.isEmpty() || client.id != orphanId) return
        orphanId = null
        orphanHangup?.cancel(false)
        if (CallHub.snapshot.state == Proto.STATE_IDLE) return
        Log.i(TAG, "call owner ${client.name} is back; resuming")
        owner = client
        if (CallHub.snapshot.state == Proto.STATE_ACTIVE) startSession(client)
    }

    private fun onMessage(c: Client, m: JSONObject) {
        when (m.optString("t")) {
            "ping" -> send(c, Proto.msg("pong"))
            "dial" -> {
                val number = m.optString("number").filter { it.isDigit() || it in "+*#" }
                if (number.isEmpty()) return send(c, Proto.msg("error").put("msg", "empty number"))
                if (CallHub.snapshot.state != Proto.STATE_IDLE) return send(c, Proto.msg("error").put("msg", "line busy"))
                owner = c
                try {
                    CallHub.dial(this, number)
                } catch (e: Exception) {
                    owner = null
                    send(c, Proto.msg("error").put("msg", "dial failed: ${e.message}"))
                }
            }
            "answer" -> {
                if (CallHub.snapshot.state == Proto.STATE_RINGING) {
                    owner = c
                    CallHub.answer()
                }
            }
            "reject", "hangup" -> CallHub.hangup()
            "dtmf" -> m.optString("digit").firstOrNull()?.let { if (it in "0123456789*#") CallHub.dtmf(it) }
            "calllog_get" -> send(c, Proto.msg("calllog").put("items", CallLogSync.query(this, m.optInt("limit", 100).coerceIn(1, 500))))
            "push_register" -> {
                if (c.id.isEmpty()) return
                Apns.register(
                    this,
                    Apns.Device(c.id, m.optString("voip"), m.optString("alert"), m.optString("topic"), m.optBoolean("sandbox"))
                )
                val problem = Apns.problem(this)
                send(c, Proto.msg("push_status").put("ok", problem == null).put("msg", problem ?: ""))
            }
            "sms_get" -> send(c, Proto.msg("sms").put("items", SmsBridge.query(this, m.optInt("limit", 100).coerceIn(1, 500))))
            "sms_send" -> {
                val reply = Proto.msg("sms_sent").put("id", m.optString("id"))
                try {
                    SmsBridge.send(this, m.getString("to"), m.getString("body"))
                    reply.put("ok", true)
                } catch (e: Exception) {
                    reply.put("ok", false).put("error", e.message ?: e.toString())
                }
                send(c, reply)
            }
        }
    }

    private fun callMsg(c: Client, s: CallHub.Snapshot): JSONObject =
        Proto.msg("call")
            .put("state", s.state)
            .put("number", s.number)
            .put("incoming", s.incoming)
            .put("bridged", session != null && owner === c)

    private fun send(c: Client, m: JSONObject) {
        try {
            c.wire.send(m)
        } catch (e: Exception) {
            c.wire.close()
        }
    }

    private fun broadcast(build: (Client) -> JSONObject) = clients.forEach { send(it, build(it)) }

    fun onSmsReceived(from: String, body: String, ts: Long) {
        exec.execute {
            broadcast { Proto.msg("sms_in").put("from", from).put("body", body).put("ts", ts) }
            Apns.sms(this, from, body, connectedIds())
        }
    }

    // ---------------------------------------------------------------- call state

    private var lastState = Proto.STATE_IDLE

    private fun connectedIds(): Set<String> = clients.map { it.id }.toSet()

    private fun onCallState(s: CallHub.Snapshot) {
        if (s.state == Proto.STATE_RINGING && s.incoming && lastState != Proto.STATE_RINGING) {
            Apns.ring(this, s.number, connectedIds())
        }
        lastState = s.state
        when (s.state) {
            Proto.STATE_ACTIVE -> if (session == null) owner?.let { startSession(it) }
            Proto.STATE_IDLE -> {
                stopSession()
                owner = null
                orphanId = null
                orphanHangup?.cancel(false)
                // The call log row is written shortly after the call ends.
                exec.schedule({
                    val items = CallLogSync.query(this, 100)
                    broadcast { Proto.msg("calllog").put("items", items) }
                }, 1500, TimeUnit.MILLISECONDS)
            }
        }
        broadcast { callMsg(it, s) }
    }

    private fun startSession(c: Client) {
        val s = AudioSession(c)
        try {
            s.start()
            session = s
        } catch (e: Exception) {
            Log.e(TAG, "audio session failed", e)
            send(c, Proto.msg("error").put("msg", "call audio unavailable: ${e.message}"))
        }
    }

    private fun stopSession() {
        session?.stop()
        session = null
    }

    // ---------------------------------------------------------------- audio

    private fun udpLoop() {
        val buf = ByteArray(2048)
        while (running) {
            try {
                val sock = DatagramSocket(null).apply {
                    reuseAddress = true
                    bind(InetSocketAddress(Proto.AUDIO_PORT))
                }
                udp = sock
                val pkt = DatagramPacket(buf, buf.size)
                val pcm = ShortArray(Proto.FRAME_SAMPLES)
                while (running) {
                    pkt.length = buf.size
                    sock.receive(pkt)
                    val o = owner ?: continue
                    Proto.unpackAudio(buf, pkt.length, o.token, pcm) ?: continue
                    // Reply to wherever the client's packets actually come from (handles NAT).
                    o.udp = pkt.socketAddress
                    session?.offerUplink(pcm.copyOf())
                }
            } catch (e: Exception) {
                if (running) {
                    Log.w(TAG, "udp loop error: $e")
                    Thread.sleep(2000)
                }
            }
        }
    }

    private inner class AudioSession(val client: Client) {
        private val bridge = HybridAudioBridge(this@BridgeService)
        private val queue = ArrayBlockingQueue<ShortArray>(8)
        private var muteMode = Prefs.muteMode(this@BridgeService)

        /** Switches how the phone's own mic is silenced, also in the middle of a call. */
        fun applyMute(mode: String) {
            CallHub.setMuted(mode == Prefs.MUTE_TELECOM)
            if (mode == Prefs.MUTE_DEVICE || muteMode == Prefs.MUTE_DEVICE) {
                HybridAudioBridge.rootDeviceMute(mode == Prefs.MUTE_DEVICE)
            }
            muteMode = mode
        }

        @Volatile
        private var live = true

        fun start() {
            bridge.start()
            wakeLock?.acquire(4 * 60 * 60 * 1000L)
            when (muteMode) {
                Prefs.MUTE_TELECOM -> CallHub.setMuted(true)
                Prefs.MUTE_DEVICE -> HybridAudioBridge.rootDeviceMute(true)
            }
            thread(name = "cb-downlink") { downlink() }
            thread(name = "cb-uplink") { uplink() }
            Log.i(TAG, "audio session started for ${client.name} (mute=$muteMode)")
        }

        fun offerUplink(frame: ShortArray) {
            while (!queue.offer(frame)) queue.poll() // drop oldest when the client runs ahead
        }

        private fun downlink() {
            val pcm = ShortArray(Proto.FRAME_SAMPLES)
            val out = ByteArray(Proto.AUDIO_PACKET)
            var seq = 0
            while (live) {
                // AudioRecord.read in blocking mode fills the whole frame or reports an error.
                if (bridge.readDownlink(pcm, pcm.size) != pcm.size) return
                Proto.packAudio(out, client.token, seq++, pcm)
                val dest = client.udp ?: InetSocketAddress(client.addr, client.uport)
                runCatching { udp?.send(DatagramPacket(out, out.size, dest)) }
            }
        }

        /** Clock-paced so the injector always has a continuous stream (silence when the client is quiet). */
        private fun uplink() {
            val silence = ShortArray(Proto.FRAME_SAMPLES)
            val frameNs = 20_000_000L
            var next = System.nanoTime()
            while (live) {
                val frame = queue.poll() ?: silence
                if (!bridge.writeUplink(frame, Proto.FRAME_SAMPLES)) return
                next += frameNs
                val wait = next - System.nanoTime()
                if (wait > 0) Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
                else if (wait < -100_000_000L) next = System.nanoTime()
            }
        }

        fun stop() {
            live = false
            bridge.stop()
            when (muteMode) {
                Prefs.MUTE_TELECOM -> CallHub.setMuted(false)
                Prefs.MUTE_DEVICE -> HybridAudioBridge.rootDeviceMute(false)
            }
            runCatching { if (wakeLock?.isHeld == true) wakeLock?.release() }
            Log.i(TAG, "audio session stopped")
        }
    }

    companion object {
        private const val TAG = "CallBridgeGateway"
        private const val ORPHAN_GRACE_S = 20L

        @Volatile
        var instance: BridgeService? = null
    }
}
