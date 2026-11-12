package com.antigravity.callbridge.gateway

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.Call
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
import com.antigravity.callbridge.proto.Proto

/** Tracks the phone's cellular calls (fed by [BridgeInCallService]) and performs call actions. */
object CallHub {
    private const val TAG = "CallBridgeHub"

    data class Snapshot(val state: String, val number: String, val incoming: Boolean)

    val IDLE = Snapshot(Proto.STATE_IDLE, "", false)

    @Volatile
    var service: InCallService? = null

    @Volatile
    var snapshot: Snapshot = IDLE
        private set

    @Volatile
    var listener: ((Snapshot) -> Unit)? = null

    private val calls = ArrayList<Call>()
    private val main = Handler(Looper.getMainLooper())

    private val callback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) = refresh()
        override fun onDetailsChanged(call: Call, details: Call.Details) = refresh()
    }

    fun add(call: Call) {
        synchronized(calls) { calls.add(call) }
        call.registerCallback(callback)
        refresh()
    }

    fun remove(call: Call) {
        call.unregisterCallback(callback)
        synchronized(calls) { calls.remove(call) }
        refresh()
    }

    private fun stateOf(c: Call): String = when (c.details.state) {
        Call.STATE_RINGING, Call.STATE_SIMULATED_RINGING -> Proto.STATE_RINGING
        Call.STATE_NEW, Call.STATE_DIALING, Call.STATE_CONNECTING,
        Call.STATE_SELECT_PHONE_ACCOUNT, Call.STATE_PULLING_CALL -> Proto.STATE_DIALING
        Call.STATE_ACTIVE, Call.STATE_HOLDING, Call.STATE_AUDIO_PROCESSING -> Proto.STATE_ACTIVE
        else -> Proto.STATE_IDLE
    }

    /** The first call that is not finished; additional (waiting) calls are ignored. */
    private fun primary(): Call? = synchronized(calls) { calls.firstOrNull { stateOf(it) != Proto.STATE_IDLE } }

    private fun refresh() {
        val c = primary()
        val s = if (c == null) IDLE else Snapshot(
            stateOf(c),
            c.details.handle?.schemeSpecificPart ?: "",
            c.details.callDirection == Call.Details.DIRECTION_INCOMING
        )
        if (s != snapshot) {
            snapshot = s
            Log.i(TAG, "call state=${s.state} incoming=${s.incoming}")
            listener?.invoke(s)
        }
    }

    fun dial(ctx: Context, number: String) {
        val tm = ctx.getSystemService(TelecomManager::class.java)
        tm.placeCall(Uri.fromParts("tel", number, null), Bundle())
    }

    fun answer() {
        val c = primary() ?: return
        if (stateOf(c) == Proto.STATE_RINGING) c.answer(VideoProfile.STATE_AUDIO_ONLY)
    }

    fun hangup() {
        val c = primary() ?: return
        if (stateOf(c) == Proto.STATE_RINGING) c.reject(false, null) else c.disconnect()
    }

    fun dtmf(digit: Char) {
        val c = primary() ?: return
        c.playDtmfTone(digit)
        main.postDelayed({ runCatching { c.stopDtmfTone() } }, 250)
    }

    fun setMuted(muted: Boolean) {
        runCatching { service?.setMuted(muted) }
    }
}
