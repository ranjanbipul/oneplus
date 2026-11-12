package com.antigravity.callbridge.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.IBinder
import kotlin.concurrent.thread

object Notifications {
    private const val ID_INCOMING = 2

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("link", "Connection", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(
            NotificationChannel("incoming", "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 800, 600, 800, 600)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
        nm.createNotificationChannel(NotificationChannel("sms", "SMS", NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun activity(ctx: Context, request: Int, action: String?): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (action != null) i.putExtra("action", action)
        return PendingIntent.getActivity(ctx, request, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun link(ctx: Context): Notification =
        Notification.Builder(ctx, "link")
            .setContentTitle("CallBridge")
            .setContentText("Waiting for calls from the gateway phone")
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentIntent(activity(ctx, 0, null))
            .setOngoing(true)
            .build()

    fun showIncoming(ctx: Context, number: String) {
        val decline = PendingIntent.getBroadcast(
            ctx, 3, Intent(ctx, ActionReceiver::class.java).setAction("decline"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val n = Notification.Builder(ctx, "incoming")
            .setContentTitle("Incoming call")
            .setContentText(number.ifEmpty { "Unknown number" })
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(activity(ctx, 1, null))
            .setFullScreenIntent(activity(ctx, 1, null), true)
            .addAction(Notification.Action.Builder(null, "Decline", decline).build())
            .addAction(Notification.Action.Builder(null, "Answer", activity(ctx, 2, "answer")).build())
            .build()
        // Keep ringing until answered, declined, or the caller gives up.
        n.flags = n.flags or Notification.FLAG_INSISTENT
        runCatching { ctx.getSystemService(NotificationManager::class.java).notify(ID_INCOMING, n) }
    }

    fun cancelIncoming(ctx: Context) {
        ctx.getSystemService(NotificationManager::class.java).cancel(ID_INCOMING)
    }

    fun showSms(ctx: Context, item: SmsItem) {
        val n = Notification.Builder(ctx, "sms")
            .setContentTitle(item.addr)
            .setContentText(item.body)
            .setStyle(Notification.BigTextStyle().bigText(item.body))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(activity(ctx, 4, "sms"))
            .setAutoCancel(true)
            .build()
        runCatching {
            ctx.getSystemService(NotificationManager::class.java).notify(1000 + (item.ts % 100000).toInt(), n)
        }
    }
}

/** Keeps the gateway link alive in the background so incoming calls can ring. */
class LinkService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Notifications.ensureChannels(this)
        startForeground(1, Notifications.link(this))
        Tele.register(this)
        thread(name = "cb-link") { Link.run(applicationContext) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Re-asserting foreground while the app is visible renews microphone access for the
        // call, so audio keeps working when the screen turns off against the ear.
        if (intent?.action == ACTION_CALL) runCatching { startForeground(1, Notifications.link(this)) }
        return START_STICKY
    }

    override fun onDestroy() {
        Link.stop()
        super.onDestroy()
    }

    companion object {
        private const val ACTION_CALL = "call"

        fun start(ctx: Context) {
            runCatching { ctx.startForegroundService(Intent(ctx, LinkService::class.java)) }
        }

        fun promoteForCall(ctx: Context) {
            runCatching { ctx.startForegroundService(Intent(ctx, LinkService::class.java).setAction(ACTION_CALL)) }
        }
    }
}

class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == "decline") CallCoordinator.hangup(ctx.applicationContext)
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) = LinkService.start(ctx)
}
