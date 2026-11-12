package com.antigravity.callbridge.client

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import com.antigravity.callbridge.proto.Proto

/**
 * Drives the call experience from gateway call-state messages. The app's own screen and
 * notification always work; Android Telecom (self-managed) is mirrored on top when available
 * so the system knows a call is in progress (audio focus, Bluetooth headset, other apps).
 */
object CallCoordinator {
    private const val TAG = "CallBridgeCalls"
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var pendingDial = false
        private set

    fun dial(ctx: Context, number: String) {
        if (!AppState.connected) {
            AppState.notice = "Not connected to the gateway"
            return
        }
        if (number.isBlank()) return
        AppState.mine = true
        AppState.muted = false
        AppState.speaker = false
        pendingDial = true
        LinkService.promoteForCall(ctx)
        Link.send(Proto.msg("dial").put("number", number))
        Tele.outgoing(ctx, number)
        main.postDelayed({
            if (pendingDial && AppState.call.state == Proto.STATE_IDLE) {
                AppState.notice = "The gateway did not start the call"
                abandonDial()
            }
        }, 8000)
    }

    fun answer(ctx: Context) {
        if (AppState.call.state != Proto.STATE_RINGING) return
        AppState.mine = true
        AppState.muted = false
        AppState.speaker = false
        LinkService.promoteForCall(ctx)
        Notifications.cancelIncoming(ctx)
        Link.send(Proto.msg("answer"))
    }

    fun hangup(ctx: Context) {
        Notifications.cancelIncoming(ctx)
        Link.send(Proto.msg("hangup"))
    }

    fun dtmf(digit: Char) {
        Link.send(Proto.msg("dtmf").put("digit", digit.toString()))
    }

    fun toggleMute() {
        AppState.muted = !AppState.muted
    }

    fun toggleSpeaker(ctx: Context) {
        val on = !AppState.speaker
        AppState.speaker = on
        @Suppress("DEPRECATION")
        runCatching { Tele.connection?.setAudioRoute(if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_EARPIECE) }
        AudioEngine.setSpeaker(ctx, on)
    }

    fun onGatewayError(ctx: Context) {
        if (pendingDial) abandonDial()
    }

    private fun abandonDial() {
        pendingDial = false
        AppState.mine = false
        Tele.end(DisconnectCause.ERROR)
    }

    /** Called for every call-state message from the gateway (and with idle when the link drops). */
    fun onCall(ctx: Context, old: CallInfo, new: CallInfo) {
        if (new.state != Proto.STATE_IDLE) pendingDial = false
        when (new.state) {
            Proto.STATE_RINGING -> if (old.state != Proto.STATE_RINGING && new.incoming) {
                // Telecom calls back into onShowIncomingCallUi; fall back to our own notification.
                if (!Tele.incoming(ctx, new.number)) Notifications.showIncoming(ctx, new.number)
            }
            Proto.STATE_ACTIVE -> {
                Notifications.cancelIncoming(ctx)
                if (new.bridged) {
                    Tele.connection?.setActive()
                    main.post { AudioEngine.start(ctx) }
                } else if (!AppState.mine) {
                    // Answered on the phone itself or by another device.
                    Tele.end(DisconnectCause.ANSWERED_ELSEWHERE)
                }
            }
            Proto.STATE_IDLE -> {
                Notifications.cancelIncoming(ctx)
                AudioEngine.stop(ctx)
                Tele.end(if (old.state == Proto.STATE_RINGING) DisconnectCause.MISSED else DisconnectCause.REMOTE)
                AppState.mine = false
                AppState.muted = false
                AppState.speaker = false
            }
        }
        Log.i(TAG, "call ${old.state} -> ${new.state} bridged=${new.bridged} mine=${AppState.mine}")
    }
}

/** Thin wrapper around the self-managed Telecom phone account. Every call is best-effort. */
object Tele {
    private const val TAG = "CallBridgeTele"

    @Volatile
    var connection: BridgeConnection? = null

    private fun handle(ctx: Context) =
        PhoneAccountHandle(ComponentName(ctx, BridgeConnectionService::class.java), "callbridge")

    fun register(ctx: Context) {
        runCatching {
            val account = PhoneAccount.builder(handle(ctx), "CallBridge")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .addSupportedUriScheme(PhoneAccount.SCHEME_TEL)
                .build()
            ctx.getSystemService(TelecomManager::class.java).registerPhoneAccount(account)
        }.onFailure { Log.w(TAG, "phone account registration failed: $it") }
    }

    fun incoming(ctx: Context, number: String): Boolean = try {
        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts("tel", number.ifEmpty { "unknown" }, null))
        }
        ctx.getSystemService(TelecomManager::class.java).addNewIncomingCall(handle(ctx), extras)
        true
    } catch (e: Exception) {
        Log.w(TAG, "addNewIncomingCall failed: $e")
        false
    }

    fun outgoing(ctx: Context, number: String) {
        try {
            val extras = Bundle().apply { putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle(ctx)) }
            ctx.getSystemService(TelecomManager::class.java).placeCall(Uri.fromParts("tel", number, null), extras)
        } catch (e: Exception) {
            Log.w(TAG, "placeCall failed: $e")
        }
    }

    fun end(cause: Int) {
        val c = connection ?: return
        connection = null
        runCatching {
            c.setDisconnected(DisconnectCause(cause))
            c.destroy()
        }
    }
}

class BridgeConnection(private val ctx: Context, private val number: String) : Connection() {
    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        audioModeIsVoip = true
        setAddress(Uri.fromParts("tel", number.ifEmpty { "unknown" }, null), TelecomManager.PRESENTATION_ALLOWED)
    }

    override fun onShowIncomingCallUi() = Notifications.showIncoming(ctx, number)
    override fun onAnswer() = CallCoordinator.answer(ctx)
    override fun onReject() = CallCoordinator.hangup(ctx)
    override fun onDisconnect() = CallCoordinator.hangup(ctx)
    override fun onAbort() = CallCoordinator.hangup(ctx)
    override fun onPlayDtmfTone(c: Char) = CallCoordinator.dtmf(c)
}

class BridgeConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(account: PhoneAccountHandle?, request: ConnectionRequest): Connection {
        if (AppState.call.state != Proto.STATE_RINGING) {
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.MISSED))
        }
        return BridgeConnection(applicationContext, AppState.call.number).also {
            it.setRinging()
            Tele.connection = it
        }
    }

    override fun onCreateIncomingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) {
        // Telecom refused (for example another call is in progress): ring with our own notification.
        if (AppState.call.state == Proto.STATE_RINGING) Notifications.showIncoming(applicationContext, AppState.call.number)
    }

    override fun onCreateOutgoingConnection(account: PhoneAccountHandle?, request: ConnectionRequest): Connection {
        val stillWanted = CallCoordinator.pendingDial || (AppState.mine && AppState.call.state != Proto.STATE_IDLE)
        if (!stillWanted) return Connection.createFailedConnection(DisconnectCause(DisconnectCause.ERROR))
        return BridgeConnection(applicationContext, request.address?.schemeSpecificPart ?: "").also {
            it.setDialing()
            Tele.connection = it
            if (AppState.call.state == Proto.STATE_ACTIVE && AppState.call.bridged) it.setActive()
        }
    }

    override fun onCreateOutgoingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) {
        Log.w("CallBridgeTele", "Telecom declined the outgoing call mirror; continuing without it")
    }
}
