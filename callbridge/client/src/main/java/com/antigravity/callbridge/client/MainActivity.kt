package com.antigravity.callbridge.client

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.text.format.DateUtils
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.antigravity.callbridge.proto.Proto

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            // Incoming calls must be able to light up a locked phone.
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        Notifications.ensureChannels(this)
        LinkService.start(this)
        val wanted = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (wanted.isNotEmpty()) requestPermissions(wanted.toTypedArray(), 1)
        handleIntent(intent)
        setContent { MaterialTheme { Surface(Modifier.fillMaxSize()) { App() } } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        when (intent?.getStringExtra("action")) {
            "answer" -> CallCoordinator.answer(applicationContext)
            "sms" -> startTab = 2
        }
        intent?.removeExtra("action")
    }

    companion object {
        var startTab by mutableIntStateOf(0)
    }
}

@Composable
private fun App() {
    val call = AppState.call
    val showCall = call.state != Proto.STATE_IDLE &&
        ((call.state == Proto.STATE_RINGING && call.incoming) || AppState.mine || call.bridged)
    if (showCall) InCallScreen(call) else MainTabs()
}

@Composable
private fun MainTabs() {
    var number by rememberSaveable { mutableStateOf("") }
    val tab = MainActivity.startTab
    Scaffold(
        bottomBar = {
            NavigationBar {
                val tabs = listOf("Dial" to Icons.Filled.Call, "Calls" to Icons.Filled.List, "SMS" to Icons.Filled.Email, "Settings" to Icons.Filled.Settings)
                tabs.forEachIndexed { i, (label, icon) ->
                    NavigationBarItem(
                        selected = tab == i,
                        onClick = { MainActivity.startTab = i },
                        icon = { Icon(icon, contentDescription = label) },
                        label = { Text(label) }
                    )
                }
            }
        }
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            StatusLine()
            when (tab) {
                0 -> DialTab(number) { number = it }
                1 -> CallsTab { number = it; MainActivity.startTab = 0 }
                2 -> SmsTab()
                else -> SettingsTab()
            }
        }
    }
}

@Composable
private fun StatusLine() {
    val call = AppState.call
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(
            AppState.status,
            color = if (AppState.connected) Color(0xFF1B7F3B) else MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodyMedium
        )
        if (call.state != Proto.STATE_IDLE) {
            Text("Line in use on the gateway phone (${call.number.ifEmpty { "unknown" }})", style = MaterialTheme.typography.bodyMedium)
        }
        AppState.notice?.let { msg ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(msg, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = { AppState.notice = null }) { Text("Dismiss") }
            }
        }
    }
    HorizontalDivider()
}

@Composable
private fun Keypad(onKey: (Char) -> Unit) {
    val rows = listOf("123", "456", "789", "*0#")
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        rows.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { ch ->
                    FilledTonalButton(onClick = { onKey(ch) }, modifier = Modifier.weight(1f).height(60.dp)) {
                        Text(ch.toString(), fontSize = 24.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun DialTab(number: String, onChange: (String) -> Unit) {
    val ctx = LocalContext.current.applicationContext
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.Bottom) {
        Text(
            number.ifEmpty { "Enter a number" },
            Modifier.fillMaxWidth().padding(vertical = 24.dp),
            fontSize = 32.sp,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = if (number.isEmpty()) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface
        )
        Keypad { onChange(number + it) }
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { onChange(if (number.isEmpty()) "+" else number + "+") }, modifier = Modifier.weight(1f).height(56.dp)) { Text("+") }
            Button(
                onClick = { CallCoordinator.dial(ctx, number) },
                enabled = number.isNotEmpty() && AppState.connected && AppState.call.state == Proto.STATE_IDLE,
                modifier = Modifier.weight(2f).height(56.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1B7F3B))
            ) { Text("Call") }
            OutlinedButton(onClick = { onChange(number.dropLast(1)) }, modifier = Modifier.weight(1f).height(56.dp)) { Text("⌫") }
        }
    }
}

private fun ago(ts: Long): String =
    DateUtils.getRelativeTimeSpanString(ts, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

@Composable
private fun CallsTab(onPick: (String) -> Unit) {
    if (AppState.callLog.isEmpty()) {
        Text("No calls yet.", Modifier.padding(16.dp))
        return
    }
    LazyColumn(Modifier.fillMaxSize()) {
        items(AppState.callLog) { item ->
            val (label, color) = when (item.type) {
                "in" -> "Incoming" to MaterialTheme.colorScheme.onSurfaceVariant
                "out" -> "Outgoing" to MaterialTheme.colorScheme.onSurfaceVariant
                "missed" -> "Missed" to MaterialTheme.colorScheme.error
                "rejected" -> "Declined" to MaterialTheme.colorScheme.error
                else -> "Call" to MaterialTheme.colorScheme.onSurfaceVariant
            }
            Column(Modifier.fillMaxWidth().clickable { onPick(item.number) }.padding(horizontal = 16.dp, vertical = 10.dp)) {
                Text(item.name.ifEmpty { item.number.ifEmpty { "Unknown" } }, fontWeight = FontWeight.Medium)
                val dur = if (item.dur > 0) " · ${item.dur / 60}m ${item.dur % 60}s" else ""
                Text("$label · ${ago(item.ts)}$dur", color = color, style = MaterialTheme.typography.bodySmall)
            }
            HorizontalDivider()
        }
    }
}

@Composable
private fun SmsTab() {
    var to by rememberSaveable { mutableStateOf("") }
    var body by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                to, { to = it }, Modifier.fillMaxWidth(), label = { Text("To") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone)
            )
            OutlinedTextField(body, { body = it }, Modifier.fillMaxWidth(), label = { Text("Message") }, maxLines = 4)
            Button(
                onClick = {
                    Link.send(Proto.msg("sms_send").put("id", System.currentTimeMillis().toString()).put("to", to.trim()).put("body", body))
                    body = ""
                },
                enabled = AppState.connected && to.isNotBlank() && body.isNotBlank()
            ) { Text("Send SMS") }
        }
        HorizontalDivider()
        LazyColumn(Modifier.fillMaxSize()) {
            items(AppState.sms) { item ->
                Column(Modifier.fillMaxWidth().clickable { to = item.addr }.padding(horizontal = 16.dp, vertical = 10.dp)) {
                    Text("${if (item.out) "To" else "From"} ${item.addr} · ${ago(item.ts)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(item.body)
                }
                HorizontalDivider()
            }
        }
    }
}

@Composable
private fun SettingsTab() {
    val ctx = LocalContext.current.applicationContext
    var key by rememberSaveable { mutableStateOf(Config.key(ctx)) }
    var host by rememberSaveable { mutableStateOf(Config.host(ctx)) }
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(key, { key = it }, Modifier.fillMaxWidth(), label = { Text("Pairing key") }, singleLine = true,
            supportingText = { Text("Shown in the CallBridge Gateway app on the OnePlus 8") })
        OutlinedTextField(host, { host = it }, Modifier.fillMaxWidth(), label = { Text("Gateway address (optional)") }, singleLine = true,
            supportingText = { Text("Leave empty to use this network's router, which is the gateway phone") })
        Button(onClick = {
            Config.save(ctx, key, host)
            AppState.status = "Reconnecting…"
            Link.reconnect()
        }) { Text("Save and connect") }
    }
}

@Composable
private fun InCallScreen(call: CallInfo) {
    val ctx = LocalContext.current.applicationContext
    var keypad by rememberSaveable { mutableStateOf(false) }
    val ringing = call.state == Proto.STATE_RINGING
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(top = 48.dp)) {
            Text(call.number.ifEmpty { "Unknown number" }, fontSize = 32.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(8.dp))
            Text(
                when {
                    ringing -> "Incoming call"
                    call.state == Proto.STATE_DIALING -> "Calling…"
                    call.bridged -> "In call"
                    else -> "Connecting audio…"
                },
                style = MaterialTheme.typography.titleMedium
            )
            AppState.notice?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
        }
        if (keypad && !ringing) Keypad { CallCoordinator.dtmf(it) }
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (ringing) {
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Button(
                        onClick = { CallCoordinator.hangup(ctx) }, modifier = Modifier.weight(1f).height(64.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                    ) { Text("Decline") }
                    Button(
                        onClick = { CallCoordinator.answer(ctx) }, modifier = Modifier.weight(1f).height(64.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1B7F3B))
                    ) { Text("Answer") }
                }
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Toggle("Mute", AppState.muted, Modifier.weight(1f)) { CallCoordinator.toggleMute() }
                    Toggle("Speaker", AppState.speaker, Modifier.weight(1f)) { CallCoordinator.toggleSpeaker(ctx) }
                    Toggle("Keypad", keypad, Modifier.weight(1f)) { keypad = !keypad }
                }
                Button(
                    onClick = { CallCoordinator.hangup(ctx) }, modifier = Modifier.fillMaxWidth().height(64.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) { Text("Hang up") }
            }
        }
    }
}

@Composable
private fun Toggle(label: String, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    if (on) Button(onClick = onClick, modifier = modifier.height(56.dp)) { Text(label) }
    else OutlinedButton(onClick = onClick, modifier = modifier.height(56.dp)) { Text(label) }
}
