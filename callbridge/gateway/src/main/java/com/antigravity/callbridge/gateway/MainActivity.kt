package com.antigravity.callbridge.gateway

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.antigravity.callbridge.proto.Proto
import java.net.Inet4Address
import java.net.NetworkInterface

/** Minimal status screen: pairing key, addresses, connected clients, microphone-mute mode. */
class MainActivity : Activity() {
    private lateinit var status: TextView
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            render()
            handler.postDelayed(this, 2000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()
        status = TextView(this).apply { textSize = 16f; setTextIsSelectable(true) }
        val mute = Button(this).apply {
            setOnClickListener {
                val modes = Prefs.MUTE_MODES
                val next = modes[(modes.indexOf(Prefs.muteMode(this@MainActivity)) + 1) % modes.size]
                Prefs.setMuteMode(this@MainActivity, next)
                render()
            }
        }
        val rekey = Button(this).apply {
            text = "New pairing key (unpairs clients)"
            setOnClickListener {
                Prefs.resetPairingKey(this@MainActivity)
                render()
            }
        }
        muteButton = mute
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.TOP
            setPadding(pad, pad * 3, pad, pad)
            addView(status)
            addView(mute)
            addView(rekey)
        })

        val wanted = arrayOf(
            "android.permission.RECORD_AUDIO", "android.permission.READ_PHONE_STATE",
            "android.permission.CALL_PHONE", "android.permission.ANSWER_PHONE_CALLS",
            "android.permission.READ_CALL_LOG", "android.permission.READ_SMS",
            "android.permission.RECEIVE_SMS", "android.permission.SEND_SMS",
            "android.permission.POST_NOTIFICATIONS"
        ).filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (wanted.isNotEmpty()) requestPermissions(wanted.toTypedArray(), 1)
        startForegroundService(Intent(this, BridgeService::class.java))
    }

    private var muteButton: Button? = null

    override fun onResume() {
        super.onResume()
        handler.post(tick)
    }

    override fun onPause() {
        handler.removeCallbacks(tick)
        super.onPause()
    }

    private fun render() {
        val ips = runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback && !it.name.startsWith("rmnet") }
                .flatMap { ni -> ni.inetAddresses.toList().filterIsInstance<Inet4Address>().map { "${it.hostAddress} (${ni.name})" } }
        }.getOrDefault(emptyList())
        val svc = BridgeService.instance
        status.text = buildString {
            append("CallBridge Gateway\n\n")
            append("Pairing key:  ${Prefs.pairingKey(this@MainActivity)}\n\n")
            append("Service: ${if (svc != null) "running" else "stopped"}\n")
            append("Clients connected: ${svc?.clientCount ?: 0}\n")
            append("Call: ${CallHub.snapshot.state}\n")
            append("Call control: ${if (CallHub.service != null) "bound" else "idle (binds during calls)"}\n\n")
            append("LAN addresses (port ${Proto.CONTROL_PORT}):\n")
            append(if (ips.isEmpty()) "  none\n" else ips.joinToString("\n") { "  $it" } + "\n")
        }
        muteButton?.text = "Phone mic during bridged calls: ${Prefs.muteMode(this)}"
    }
}
