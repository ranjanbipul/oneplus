import AVFoundation
import AVKit
import CallBridgeCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var m

    var body: some View {
        @Bindable var m = m
        TabView(selection: $m.tab) {
            DialView().tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }.tag(AppModel.Tab.dial)
            RecentsView().tabItem { Label("Recents", systemImage: "clock") }.tag(AppModel.Tab.recents)
            MessagesView().tabItem { Label("Messages", systemImage: "message") }.tag(AppModel.Tab.messages)
            SettingsView().tabItem { Label("Settings", systemImage: "gear") }.tag(AppModel.Tab.settings)
        }
        .overlay(alignment: .bottom) { NoticeBar().padding(.bottom, 60) }
        // Ringing is shown by CallKit; this screen is for calls on this iPhone.
        .fullScreenCover(isPresented: .constant(m.inCall && (m.mine || m.call.bridged))) {
            CallView().environment(m)
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var m

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(m.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(m.status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !m.connected {
                Button("Retry") { m.link.reconnect() }.font(.footnote)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct NoticeBar: View {
    @Environment(AppModel.self) private var m

    var body: some View {
        if let n = m.notice {
            Text(n)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .onTapGesture { m.notice = nil }
                .task(id: n) {
                    try? await Task.sleep(for: .seconds(4))
                    if m.notice == n { m.notice = nil }
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
        Grid(horizontalSpacing: 26, verticalSpacing: 16) {
            ForEach(keys.indices, id: \.self) { r in
                GridRow {
                    ForEach(keys[r], id: \.0) { k in
                        Button { onKey(Character(k.0)) } label: {
                            VStack(spacing: 0) {
                                Text(k.0).font(.system(size: 32))
                                Text(k.1).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(height: 12)
                            }
                            .frame(width: 78, height: 78)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct DialView: View {
    @Environment(AppModel.self) private var m

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 20) {
            Spacer()
            HStack {
                Text(m.dialText.isEmpty ? " " : m.dialText)
                    .font(.system(size: 34, weight: .light))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .contextMenu {
                        Button("Paste") {
                            if let s = UIPasteboard.general.string { m.dialText = dialable(s) }
                        }
                    }
            }
            .padding(.horizontal, 24)
            Keypad { m.dialText.append($0) }
            HStack(spacing: 26) {
                Color.clear.frame(width: 78, height: 78)
                Button { m.dialFromUI(m.dialText) } label: {
                    Image(systemName: "phone.fill").font(.title).foregroundStyle(.white)
                        .frame(width: 78, height: 78).background(Circle().fill(.green))
                }
                .disabled(!m.connected || m.dialText.isEmpty)
                Button { if !m.dialText.isEmpty { m.dialText.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.title2).foregroundStyle(.secondary)
                        .frame(width: 78, height: 78)
                }
                .opacity(m.dialText.isEmpty ? 0 : 1)
            }
            Spacer()
        }
        .safeAreaInset(edge: .top, spacing: 0) { StatusBar() }
    }
}

// MARK: in-call

struct CallView: View {
    @Environment(AppModel.self) private var m
    @State private var showKeypad = false
    @State private var dtmfDigits = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 40)
            Text(m.call.number.isEmpty ? "Unknown" : m.call.number).font(.system(size: 34, weight: .light))
            Text(subtitle).foregroundStyle(.secondary)
            if m.call.state == Proto.active && m.call.bridged {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(ctx.date)).font(.title3.monospacedDigit())
                }
            }
            Spacer()
            if m.call.state == Proto.ringing && m.call.incoming && !m.mine {
                HStack(spacing: 80) {
                    round("phone.down.fill", .red, "Decline") { CallManager.shared.hangupFromUI() }
                    round("phone.fill", .green, "Answer") { CallManager.shared.answerFromUI() }
                }
            } else {
                if showKeypad {
                    Text(dtmfDigits).font(.title2.monospaced()).frame(height: 30)
                    Keypad { d in
                        dtmfDigits.append(d)
                        CallManager.shared.dtmfFromUI(d)
                    }
                } else {
                    HStack(spacing: 50) {
                        toggle(m.muted ? "mic.slash.fill" : "mic.fill", "Mute", on: m.muted) {
                            CallManager.shared.setMutedFromUI(!m.muted)
                        }
                        toggle("circle.grid.3x3.fill", "Keypad", on: false) { showKeypad = true }
                        AudioRoutePicker().frame(width: 72, height: 72)
                    }
                }
                HStack(spacing: 40) {
                    if showKeypad { Button("Hide") { showKeypad = false } }
                    round("phone.down.fill", .red, "End") { CallManager.shared.hangupFromUI() }
                }
            }
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        switch m.call.state {
        case Proto.ringing: return m.call.incoming ? "Incoming call via OnePlus 8" : "Ringing…"
        case Proto.dialing: return "Calling…"
        case Proto.active: return m.call.bridged ? "On this iPhone" : "On another device"
        default: return "Connecting…"
        }
    }

    private func elapsed(_ now: Date) -> String {
        guard let start = m.callStarted else { return "" }
        let t = max(0, Int(now.timeIntervalSince(start)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func round(_ icon: String, _ color: Color, _ label: String, _ action: @escaping () -> Void) -> some View {
        VStack {
            Button(action: action) {
                Image(systemName: icon).font(.title).foregroundStyle(.white)
                    .frame(width: 78, height: 78).background(Circle().fill(color))
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ icon: String, _ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        VStack {
            Button(action: action) {
                Image(systemName: icon).font(.title2).foregroundStyle(on ? Color.black : Color.primary)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(on ? Color.white : Color.primary.opacity(0.12)))
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The system route picker (speaker, earpiece, AirPods).
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = AVRoutePickerViewWrapper()
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class AVRoutePickerViewWrapper: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let p = AVRoutePickerView()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.tintColor = .label
        p.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        p.layer.cornerRadius = 36
        addSubview(p)
        NSLayoutConstraint.activate([
            p.widthAnchor.constraint(equalToConstant: 72), p.heightAnchor.constraint(equalToConstant: 72),
            p.centerXAnchor.constraint(equalTo: centerXAnchor), p.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: recents

struct RecentsView: View {
    @Environment(AppModel.self) private var m

    var body: some View {
        NavigationStack {
            Group {
                if m.callLog.isEmpty {
                    ContentUnavailableView("No calls", systemImage: "phone",
                                           description: Text(m.connected ? "" : "Connect to the gateway to load the call log."))
                } else {
                    List(m.callLog) { item in
                        Button { m.dialFromUI(item.number) } label: {
                            HStack {
                                Image(systemName: icon(item.type))
                                    .foregroundStyle(item.type == "missed" || item.type == "rejected" ? .red : .secondary)
                                    .frame(width: 22)
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
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button {
                                MessagesView.openThread = item.number
                                m.tab = .messages
                            } label: { Label("Message", systemImage: "message") }.tint(.blue)
                        }
                    }
                    .refreshable { m.refresh() }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { StatusBar() }
            .navigationTitle("Recents")
        }
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

struct MessagesView: View {
    @Environment(AppModel.self) private var m
    @State private var path: [String] = []
    @State private var composing = false
    /// Set by other screens to jump to a conversation.
    static var openThread: String?

    var body: some View {
        NavigationStack(path: $path) {
            List(SmsThread.group(m.sms)) { t in
                NavigationLink(value: t.addr) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(t.addr).fontWeight(.semibold).lineLimit(1)
                            Spacer()
                            Text(shortDate(t.items[0].ts)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(t.items[0].body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .refreshable { m.refresh() }
            .safeAreaInset(edge: .top, spacing: 0) { StatusBar() }
            .navigationTitle("Messages")
            .toolbar {
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
            }
            .navigationDestination(for: String.self) { addr in ThreadView(addr: addr) }
            .sheet(isPresented: $composing) {
                ComposeView { to in
                    composing = false
                    path = [to]
                }
            }
        }
        .onAppear {
            if let n = Self.openThread {
                Self.openThread = nil
                path = [n]
            }
        }
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var m
    let addr: String
    @State private var draft = ""

    private var items: [SmsItem] {
        let key = SmsThread.key(addr)
        return m.sms.filter { SmsThread.key($0.addr) == key }.sorted { $0.ts < $1.ts }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { s in
                            HStack {
                                if s.out { Spacer(minLength: 50) }
                                VStack(alignment: s.out ? .trailing : .leading, spacing: 2) {
                                    Text(s.body)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 16).fill(s.out ? Color.accentColor : Color.primary.opacity(0.1)))
                                        .foregroundStyle(s.out ? .white : .primary)
                                    Text(shortDate(s.ts)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                if !s.out { Spacer(minLength: 50) }
                            }
                            .id(s.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear { if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: items.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            HStack {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button {
                    m.sendSms(to: addr, body: draft)
                    draft = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle(addr)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { m.dialFromUI(addr) } label: { Image(systemName: "phone") }
        }
    }
}

struct ComposeView: View {
    @Environment(AppModel.self) private var m
    let onSent: (String) -> Void
    @State private var to = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("To", text: $to).keyboardType(.phonePad)
                TextField("Message", text: $text, axis: .vertical).lineLimit(3...8)
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Send") {
                    m.sendSms(to: to, body: text)
                    onSent(to)
                }
                .disabled(to.isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: settings

struct SettingsView: View {
    @Environment(AppModel.self) private var m
    @State private var key = Settings.key
    @State private var host = Settings.host
    @State private var mic = AVAudioApplication.shared.recordPermission

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pairing key", text: $key)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Address (automatic)", text: $host)
                        .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Save & Reconnect") {
                        Settings.key = key
                        Settings.host = host
                        key = Settings.key
                        m.link.reconnect()
                    }
                } header: {
                    Text("Gateway")
                } footer: {
                    Text("The pairing key is shown in the CallBridge Gateway app on the OnePlus 8. Leave the address empty on the OnePlus 8's hotspot.")
                }
                Section("Status") {
                    LabeledContent("Gateway", value: m.status)
                    LabeledContent("Ringing in background", value: m.pushStatus)
                    LabeledContent("Microphone", value: mic == .granted ? "Allowed" : mic == .denied ? "Denied" : "Not asked yet")
                    LabeledContent("This device", value: Settings.deviceName)
                    if mic == .denied {
                        Button("Open iPhone Settings") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { StatusBar() }
            .navigationTitle("Settings")
            .onAppear { mic = AVAudioApplication.shared.recordPermission }
        }
    }
}
