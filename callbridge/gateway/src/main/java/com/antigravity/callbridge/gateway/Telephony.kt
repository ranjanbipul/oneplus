package com.antigravity.callbridge.gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.CallLog
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import org.json.JSONArray
import org.json.JSONObject

object CallLogSync {
    fun query(ctx: Context, limit: Int): JSONArray {
        val items = JSONArray()
        val cols = arrayOf(
            CallLog.Calls.NUMBER, CallLog.Calls.TYPE, CallLog.Calls.DATE,
            CallLog.Calls.DURATION, CallLog.Calls.CACHED_NAME
        )
        ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, cols, null, null, "${CallLog.Calls.DATE} DESC")?.use { c ->
            while (c.moveToNext() && items.length() < limit) {
                val type = when (c.getInt(1)) {
                    CallLog.Calls.INCOMING_TYPE -> "in"
                    CallLog.Calls.OUTGOING_TYPE -> "out"
                    CallLog.Calls.MISSED_TYPE -> "missed"
                    CallLog.Calls.REJECTED_TYPE -> "rejected"
                    else -> "other"
                }
                items.put(
                    JSONObject()
                        .put("number", c.getString(0) ?: "")
                        .put("type", type)
                        .put("ts", c.getLong(2))
                        .put("dur", c.getLong(3))
                        .put("name", c.getString(4) ?: "")
                )
            }
        }
        return items
    }
}

object SmsBridge {
    fun query(ctx: Context, limit: Int): JSONArray {
        val items = JSONArray()
        val cols = arrayOf("address", "body", "date", "type")
        ctx.contentResolver.query(Uri.parse("content://sms"), cols, null, null, "date DESC")?.use { c ->
            while (c.moveToNext() && items.length() < limit) {
                items.put(
                    JSONObject()
                        .put("addr", c.getString(0) ?: "")
                        .put("body", c.getString(1) ?: "")
                        .put("ts", c.getLong(2))
                        .put("out", c.getInt(3) != Telephony.Sms.MESSAGE_TYPE_INBOX)
                )
            }
        }
        return items
    }

    fun send(ctx: Context, to: String, body: String) {
        var sub = SubscriptionManager.getDefaultSmsSubscriptionId()
        if (sub == SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
            sub = ctx.getSystemService(SubscriptionManager::class.java)
                .activeSubscriptionInfoList?.firstOrNull()?.subscriptionId
                ?: throw IllegalStateException("no active SIM for SMS")
        }
        val sm = ctx.getSystemService(SmsManager::class.java).createForSubscriptionId(sub)
        sm.sendMultipartTextMessage(to, null, sm.divideMessage(body), null, null)
    }
}

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return
        val from = parts[0].originatingAddress ?: ""
        val body = parts.joinToString("") { it.messageBody ?: "" }
        BridgeService.instance?.onSmsReceived(from, body, parts[0].timestampMillis)
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        ctx.startForegroundService(Intent(ctx, BridgeService::class.java))
    }
}
