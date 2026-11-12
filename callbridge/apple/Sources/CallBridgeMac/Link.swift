import CallBridgeCore
import Foundation

/// The Mac's gateway connection and call audio.
enum Link {
    static let shared: GatewayLink = {
        let l = GatewayLink {
            LinkConfig(key: Config.key, host: Config.host, name: Config.deviceName, clientId: Config.clientId)
        }
        l.onStatus = { s in
            if s == "Not connected to the gateway" { AppState.shared.notice = s } else { AppState.shared.status = s }
        }
        l.onConnected = { up in
            Power.connected(up)
            if up {
                AppState.shared.connected = true
                Calls.refresh()
            } else {
                Calls.onLinkDown()
            }
        }
        l.onMessage = { Calls.onMessage($0) }
        l.willDisconnect = { audio.stopAndWait() }
        return l
    }()

    static let audio: CallAudio = {
        let a = CallAudio()
        a.onError = { AppState.shared.notice = $0 }
        return a
    }()
}

/// Runs a UI-state mutation on the main thread.
func ui(_ f: @escaping (AppState) -> Void) {
    DispatchQueue.main.async { f(AppState.shared) }
}
