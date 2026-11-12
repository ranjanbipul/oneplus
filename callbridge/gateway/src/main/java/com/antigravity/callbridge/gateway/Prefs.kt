package com.antigravity.callbridge.gateway

import android.content.Context
import com.antigravity.callbridge.proto.Auth

object Prefs {
    /** How the OnePlus 8's own microphone is kept out of a bridged call. */
    const val MUTE_TELECOM = "telecom" // InCallService.setMuted (HAL "Voice Tx Mute")
    const val MUTE_DEVICE = "device"   // root: tinymix "Voice Tx Device Mute"
    const val MUTE_NONE = "none"
    val MUTE_MODES = listOf(MUTE_TELECOM, MUTE_DEVICE, MUTE_NONE)

    private fun sp(ctx: Context) = ctx.getSharedPreferences("callbridge", Context.MODE_PRIVATE)

    fun pairingKey(ctx: Context): String {
        val sp = sp(ctx)
        sp.getString("key", null)?.let { return it }
        val k = Auth.newPairingKey()
        sp.edit().putString("key", k).apply()
        return k
    }

    fun resetPairingKey(ctx: Context) {
        sp(ctx).edit().remove("key").apply()
    }

    fun muteMode(ctx: Context): String = sp(ctx).getString("mute_mode", MUTE_TELECOM)!!

    fun setMuteMode(ctx: Context, mode: String) {
        sp(ctx).edit().putString("mute_mode", mode).apply()
    }
}
