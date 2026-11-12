import AVFoundation
import SwiftUI
import UserNotifications

@main
struct CallBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                AppModel.shared.start()
            } else if p == .background {
                AppModel.shared.enterBackground()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Setup from a Mac: `devicectl device process launch ... -key KEY [-host IP]` saves them.
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let k = args["key"] as? String { Settings.key = k }
        if let h = args["host"] as? String { Settings.host = h }
        _ = CallManager.shared
        AppModel.shared.start()
        PushRegistry.shared.start()
        let n = UNUserNotificationCenter.current()
        n.delegate = self
        n.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        AVAudioApplication.requestRecordPermission { _ in }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistry.shared.setAlertToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("CallBridge: remote notifications unavailable: \(error)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let addr = response.notification.request.content.userInfo["sms"] as? String {
            DispatchQueue.main.async {
                AppModel.shared.tab = .messages
                MessagesView.openThread = addr
            }
        }
        completionHandler()
    }
}
