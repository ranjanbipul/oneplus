package com.antigravity.callbridge.gateway

import android.content.Intent
import android.os.IBinder
import android.telecom.Call
import android.telecom.InCallService

/**
 * Non-UI InCallService. Telecom binds it for every call because the app holds
 * CONTROL_INCALL_EXPERIENCE; the stock dialer stays the visible call UI on the phone.
 */
class BridgeInCallService : InCallService() {
    override fun onBind(intent: Intent): IBinder? {
        CallHub.service = this
        return super.onBind(intent)
    }

    override fun onUnbind(intent: Intent): Boolean {
        CallHub.service = null
        return super.onUnbind(intent)
    }

    override fun onCallAdded(call: Call) = CallHub.add(call)

    override fun onCallRemoved(call: Call) = CallHub.remove(call)
}
