import SwiftUI
import UIKit
import UserNotifications

/// Uygulama öndeyken de zamanlayıcı bildirimi görünsün.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct AtlasApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var assistant: Assistant

    private let notifications = NotificationDelegate()

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _assistant = StateObject(wrappedValue: Assistant(settings: s))
        UNUserNotificationCenter.current().delegate = notifications
        Log.i("Atlas açıldı · iOS \(UIDevice.current.systemVersion)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(assistant)
                // atlas://dinle → açılır açılmaz bağlan (Kestirme / "Hey Siri, Atlas'ı aç" + Arkaya Dokun için)
                .onOpenURL { url in
                    if ShortcutRunner.shared.handle(url) { return } // atlas://kestirme/... dönüşü
                    if url.host == "dinle", assistant.conn == .idle { assistant.start() }
                }
        }
    }
}
