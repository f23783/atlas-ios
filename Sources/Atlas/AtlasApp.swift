import SwiftUI

@main
struct AtlasApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var assistant: Assistant

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _assistant = StateObject(wrappedValue: Assistant(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(assistant)
                // atlas://dinle → açılır açılmaz bağlan (Kestirme / "Hey Siri, Atlas'ı aç" + Arkaya Dokun için)
                .onOpenURL { url in
                    if url.host == "dinle", assistant.conn == .idle { assistant.start() }
                }
        }
    }
}
