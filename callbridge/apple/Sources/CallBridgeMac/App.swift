import AVFoundation
import AppKit
import CallBridgeCore
import SwiftUI

@main
struct CallBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Config.migrate()
        Notify.setup()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { ui { $0.notice = "Microphone access denied: allow it in System Settings > Privacy & Security" } }
        }
        AppWindow.show()
        Link.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindow.show()
        return true
    }

    /// Closing the window keeps the app (and the gateway link) running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The main window, owned by AppKit so it can be brought back from anywhere (notification, ring).
enum AppWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "CallBridge"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 380, height: 520)
            w.contentView = NSHostingView(rootView: ContentView().environment(AppState.shared))
            w.setFrameAutosaveName("CallBridgeMain")
            if !w.setFrameUsingName("CallBridgeMain") { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }

    static func bringToFront() {
        show()
        NSApp.activate(ignoringOtherApps: true)
    }
}
