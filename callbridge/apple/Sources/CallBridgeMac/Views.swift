import AppKit
import AVFoundation
import SwiftUI

// MARK: root

struct ContentView: View {
    @Environment(AppState.self) private var s

    var body: some View {
        @Bindable var s = s
        VStack(spacing: 0) {
            StatusBar()
            Divider()
            if s.inCall {
                CallView()
            } else {
                TabView(selection: $s.selectedTab) {
                    DialView().tabItem { Text("Keypad") }.tag(AppState.Tab.dial)
                    RecentsView().tabItem { Text("Recents") }.tag(AppState.Tab.recents)
                    MessagesView().tabItem { Text("Messages") }.tag(AppState.Tab.messages)
                    SettingsView().tabItem { Text("Settings") }.tag(AppState.Tab.settings)
                }
                .padding(8)
            }
            NoticeBar()
        }
        .frame(minWidth: 380, minHeight: 520)
    }
}

struct StatusBar: View {
    @Environment(AppState.self) private var s

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(s.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(s.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !s.connected {
                Button("Retry") { Link.shared.reconnect() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct NoticeBar: View {
    @Environment(AppState.self) private var s

    var body: some View {
        if let n = s.notice {
            HStack {
                Text(n).font(.callout)
                Spacer()
                Button { s.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(8)
            .background(.yellow.opacity(0.2))
            .task(id: n) {
                try? await Task.sleep(for: .seconds(5))
                if s.notice == n { s.notice = nil }
            }
        }
    }
}

// MARK: keypad

private let keys: [[(String, String)]] = [
    [("1", ""), ("2", "ABC"), ("3", "DEF")],
    [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
    [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
    [("*", ""), ("0", "+"), ("#", "")],
]

struct Keypad: View {
    let onKey: (Character) -> Void

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 12) {
            ForEach(keys.indices, id: \.self) { r in
                GridRow {
                    ForEach(keys[r], id: \.0) { k in
                        Button { onKey(Character(k.0)) } label: {
                            VStack(spacing: 0) {
                                Text(k.0).font(.system(size: 24, weight: .regular))
                                Text(k.1).font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 10)
                            }
                            .frame(width: 64, height: 56)
                            .contentShape(Circle())
                        }
                        .buttonStyle(KeyStyle())
                    }
                }
            }
        }
    }
}

struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.25 : 0.08)))
    }
}

struct DialView: View {
    @Environment(AppState.self) private var s
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var s = s
        VStack(spacing: 16) {
            Spacer(minLength: 4)
            HStack {
                TextField("Number", text: $s.dialText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .light))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { Calls.dial(s.dialText) }
                if !s.dialText.isEmpty {
                    Button { s.dialText.removeLast() } label: { Image(systemName: "delete.left") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.delete, modifiers: [])
                }
            }
            .padding(.horizontal, 24)
            Keypad { s.dialText.append($0) }
            Button { Calls.dial(s.dialText) } label: {
                Image(systemName: "phone.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Circle().fill(.green))
            }
            .buttonStyle(.plain)
            .disabled(!s.connected || s.dialText.isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            Spacer(minLength: 4)
        }
        .onAppear { focused = true }
    }
}

// MARK: in-call

struct CallView: View {
    @Environment(AppState.self) private var s
    @State private var showKeypad = false
    @State private var dtmfDigits = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(s.call.number.isEmpty ? "Unknown" : s.call.number).font(.system(size: 30, weight: .light))
            Text(subtitle).foregroundStyle(.secondary)
            if s.call.state == Proto.active && s.call.bridged {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(ctx.date)).font(.title3.monospacedDigit())
                }
            }
            Spacer()
            if s.call.state == Proto.ringing && s.call.incoming {
                HStack(spacing: 60) {
                    roundButton("phone.down.fill", .red, "Decline") { Calls.hangup() }
                    roundButton("phone.fill", .green, "Answer") { Calls.answer() }
                        .keyboardShortcut(.return, modifiers: [])
                }
            } else if s.call.state == Proto.active && !s.call.bridged {
                Text("This call is on another device.").foregroundStyle(.secondary)
                roundButton("phone.down.fill", .red, "End call") { Calls.hangup() }
            } else {
                if showKeypad {
                    Text(dtmfDigits).font(.title3.monospaced()).frame(height: 24)
                    Keypad { d in
                        dtmfDigits.append(d)
                        Calls.dtmf(d)
                    }
                } else {
                    HStack(spacing: 40) {
                        toggleButton(s.muted ? "mic.slash.fill" : "mic.fill", "Mute", on: s.muted) { Calls.toggleMute() }
                        toggleButton("circle.grid.3x3.fill", "Keypad", on: false) { showKeypad = true }
                    }
                }
                HStack(spacing: 40) {
                    if showKeypad {
                        Button("Hide") { showKeypad = false }.buttonStyle(.borderless)
                    }
                    roundButton("phone.down.fill", .red, "End") { Calls.hangup() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var subtitle: String {
        switch s.call.state {
        case Proto.ringing: return s.call.incoming ? "Incoming call via OnePlus 8" : "Ringing…"
        case Proto.dialing: return "Calling…"
        case Proto.active: return s.call.bridged ? "On this Mac" : "Active"
        default: return ""
        }
    }

    private func elapsed(_ now: Date) -> String {
        guard let start = s.callStarted else { return "" }
        let t = max(0, Int(now.timeIntervalSince(start)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func roundButton(_ icon: String, _ color: Color, _ label: String, _ action: @escaping () -> Void) -> some View {
        VStack {
            Button(action: action) {
                Image(systemName: icon).font(.title2).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Circle().fill(color))
            }
            .buttonStyle(.plain)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggleButton(_ icon: String, _ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        VStack {
            Button(action: action) {
                Image(systemName: icon).font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(on ? Color.primary.opacity(0.35) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: recents

struct RecentsView: View {
    @Environment(AppState.self) private var s

    var body: some View {
        Group {
            if s.callLog.isEmpty {
                ContentUnavailableView("No calls", systemImage: "phone", description: Text(s.connected ? "" : "Connect to the gateway to load the call log."))
            } else {
                List(s.callLog) { item in
                    HStack {
                        Image(systemName: icon(item.type)).foregroundStyle(item.type == "missed" || item.type == "rejected" ? .red : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(item.name.isEmpty ? item.number : item.name)
                                .foregroundStyle(item.type == "missed" ? .red : .primary)
                            if !item.name.isEmpty { Text(item.number).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(shortDate(item.ts)).font(.caption).foregroundStyle(.secondary)
                            if item.dur > 0 { Text(duration(item.dur)).font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Button { Calls.dial(item.number) } label: { Image(systemName: "phone") }
                            .buttonStyle(.borderless).disabled(!s.connected || s.inCall)
                        Button {
                            s.selectedTab = .messages
                            MessagesView.openThread = item.number
                        } label: { Image(systemName: "message") }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { Calls.dial(item.number) }
                }
            }
        }
        .toolbar { Button("Refresh") { Calls.refresh() } }
    }

    private func icon(_ type: String) -> String {
        switch type {
        case "in": return "phone.arrow.down.left"
        case "out": return "phone.arrow.up.right"
        case "missed": return "phone.down"
        case "rejected": return "phone.down.circle"
        default: return "phone"
        }
    }

    private func duration(_ s: Int64) -> String { s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s" }
}

// MARK: messages

struct SmsThread: Identifiable, Hashable {
    let key: String
    let addr: String
    let items: [SmsItem] // newest first
    var id: String { key }
}

/// Groups numbers that differ only in country prefix or formatting.
func threadKey(_ addr: String) -> String {
    let digits = addr.filter(\.isNumber)
    return digits.count >= 10 ? String(digits.suffix(10)) : (digits.isEmpty ? addr : digits)
}

struct MessagesView: View {
    @Environment(AppState.self) private var s
    @State private var selection: String?
    @State private var composing = false
    /// Set by other screens to jump to a conversation.
    static var openThread: String?

    var threads: [SmsThread] {
        var order = [String]()
        var groups = [String: [SmsItem]]()
        for m in s.sms.sorted(by: { $0.ts > $1.ts }) {
            let k = threadKey(m.addr)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(m)
        }
        return order.map { SmsThread(key: $0, addr: groups[$0]!.first!.addr, items: groups[$0]!) }
    }

    var body: some View {
        NavigationSplitView {
            List(threads, selection: $selection) { t in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(t.addr).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(shortDate(t.items[0].ts)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(t.items[0].body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(t.key)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
            .toolbar {
                Button { composing = true; selection = nil } label: { Image(systemName: "square.and.pencil") }
            }
        } detail: {
            if composing {
                ComposeView(initialTo: pendingTo) { to in
                    pendingTo = ""
                    composing = false
                    selection = threadKey(to)
                }
            } else if let sel = selection, let t = threads.first(where: { $0.key == sel }) {
                ThreadView(thread: t)
            } else if let sel = selection {
                ThreadView(thread: SmsThread(key: sel, addr: sel, items: []))
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "message")
            }
        }
        .onAppear {
            if let n = Self.openThread {
                selection = threadKey(n)
                Self.openThread = nil
                if !threads.contains(where: { $0.key == selection }) {
                    composing = true
                    pendingTo = n
                }
            }
        }
    }

    @State private var pendingTo = ""
}

struct ThreadView: View {
    let thread: SmsThread
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(thread.items.reversed()) { m in
                            HStack {
                                if m.out { Spacer(minLength: 40) }
                                VStack(alignment: m.out ? .trailing : .leading, spacing: 2) {
                                    Text(m.body)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 12).fill(m.out ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.1)))
                                        .foregroundStyle(m.out ? .white : .primary)
                                    Text(shortDate(m.ts)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                if !m.out { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding(10)
                }
                .onAppear { if let last = thread.items.first { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: thread.items.first?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider()
            HStack {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
        .navigationTitle(thread.addr)
        .toolbar {
            Button { Calls.dial(thread.addr) } label: { Image(systemName: "phone") }
        }
    }

    private func send() {
        Calls.sendSms(to: thread.addr, body: draft)
        draft = ""
    }
}

struct ComposeView: View {
    var initialTo = ""
    let onSent: (String) -> Void
    @State private var to = ""
    @State private var body_ = ""

    var body: some View {
        Form {
            TextField("To", text: $to)
            TextField("Message", text: $body_, axis: .vertical).lineLimit(3...8)
            HStack {
                Spacer()
                Button("Send") {
                    Calls.sendSms(to: to, body: body_)
                    onSent(to)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(to.isEmpty || body_.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .onAppear { if to.isEmpty { to = initialTo } }
    }
}

// MARK: settings

struct SettingsView: View {
    @Environment(AppState.self) private var s
    @State private var key = Config.key
    @State private var host = Config.host
    @State private var keepAwake = Config.keepAwake
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section("Gateway") {
                TextField("Pairing key", text: $key, prompt: Text("Shown in the gateway app on the OnePlus 8"))
                TextField("Address", text: $host, prompt: Text("Automatic (default gateway)"))
                HStack {
                    Spacer()
                    Button("Save & Reconnect") {
                        Config.key = key
                        Config.host = host
                        key = Config.key
                        Link.shared.reconnect()
                    }
                }
                LabeledContent("Status", value: s.status)
                LabeledContent("This device", value: Config.deviceName)
            }
            Section("Mac") {
                Toggle("Keep Mac awake while connected so calls can ring", isOn: $keepAwake)
                    .onChange(of: keepAwake) { _, v in
                        Config.keepAwake = v
                        Power.connected(s.connected)
                    }
                LabeledContent("Microphone") {
                    HStack {
                        Text(micText)
                        if mic != .authorized {
                            Button("Open Privacy Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { mic = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    private var micText: String {
        switch mic {
        case .authorized: return "Allowed"
        case .denied, .restricted: return "Denied"
        default: return "Not asked yet"
        }
    }
}

// MARK: menu bar

struct MenuBarIcon: View {
    var body: some View {
        let st = AppState.shared
        Image(systemName: st.call.state == Proto.ringing ? "phone.badge.waveform.fill"
              : st.inCall ? "phone.fill"
              : st.connected ? "phone" : "phone.badge.exclamationmark")
    }
}

struct MenuBarContent: View {
    private var s: AppState { AppState.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(s.status, systemImage: s.connected ? "checkmark.circle" : "exclamationmark.circle")
                .font(.callout)
            if s.inCall {
                Divider()
                Text(s.call.number.isEmpty ? "Unknown" : s.call.number).font(.headline)
                if s.call.state == Proto.ringing && s.call.incoming {
                    HStack {
                        Button("Answer") { Calls.answer() }.tint(.green)
                        Button("Decline") { Calls.hangup() }.tint(.red)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text(s.call.bridged ? "On this Mac" : s.call.state == Proto.active ? "On another device" : "Calling…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("End call") { Calls.hangup() }.buttonStyle(.borderedProminent).tint(.red)
                }
            }
            Divider()
            Button("Open CallBridge") { AppWindow.bringToFront() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }
}

// MARK: helpers

func shortDate(_ ms: Int64) -> String {
    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(date: .numeric, time: .omitted)
}
