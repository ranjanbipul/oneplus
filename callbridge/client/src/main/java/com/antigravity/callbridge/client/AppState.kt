package com.antigravity.callbridge.client

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.antigravity.callbridge.proto.Proto

data class CallInfo(
    val state: String = Proto.STATE_IDLE,
    val number: String = "",
    val incoming: Boolean = false,
    /** True when the gateway is relaying this call's audio to this device. */
    val bridged: Boolean = false,
)

data class LogItem(val number: String, val name: String, val type: String, val ts: Long, val dur: Long)
data class SmsItem(val addr: String, val body: String, val ts: Long, val out: Boolean)

/** UI-observable state. Compose snapshot state is safe to write from any thread. */
object AppState {
    var connected by mutableStateOf(false)
    var status by mutableStateOf("Not connected")
    var call by mutableStateOf(CallInfo())

    /** True when this device answered or placed the current call. */
    var mine by mutableStateOf(false)
    var muted by mutableStateOf(false)
    var speaker by mutableStateOf(false)
    var callLog by mutableStateOf(listOf<LogItem>())
    var sms by mutableStateOf(listOf<SmsItem>())
    var notice by mutableStateOf<String?>(null)
}

object Config {
    private fun sp(ctx: Context) = ctx.getSharedPreferences("callbridge", Context.MODE_PRIVATE)
    fun key(ctx: Context): String = sp(ctx).getString("key", "")!!
    fun host(ctx: Context): String = sp(ctx).getString("host", "")!!

    /** Stable id for this install; lets the gateway hand a call back after a brief disconnect. */
    fun clientId(ctx: Context): String {
        sp(ctx).getString("client_id", null)?.let { return it }
        val id = java.util.UUID.randomUUID().toString()
        sp(ctx).edit().putString("client_id", id).apply()
        return id
    }
    fun save(ctx: Context, key: String, host: String) {
        sp(ctx).edit().putString("key", key.trim().uppercase()).putString("host", host.trim()).apply()
    }
}
