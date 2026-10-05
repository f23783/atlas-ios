import AVFoundation
import SwiftUI
import UIKit

/// Yarım saniyelik ölçüm: o aralıktaki en yüksek ses seviyesi ve uygulamanın önde mi arkada mı olduğu.
struct Sample: Identifiable {
    let id = UUID()
    let time: Date
    let level: Float
    let background: Bool
}

/// İki soruyu cevaplar:
///  1) Ekran kilitliyken mikrofon çalışmaya devam ediyor mu? (UIBackgroundModes: audio, ücretsiz imza)
///  2) Uygulama bir Kestirme'yi çalıştırıp x-callback-url ile geri dönebiliyor mu, dönüşte sonuç geliyor mu?
@MainActor
final class Probe: ObservableObject {
    @Published var running = false
    @Published var status = "Hazır"
    @Published var samples: [Sample] = []
    @Published var callbacks: [String] = []
    @Published var shortcutName = "Atlas Test"

    /// Konuşma eşiği (RMS). Oda gürültüsü ~0,002–0,01; konuşma ~0,03+.
    static let voiceLevel: Float = 0.02

    private let engine = AVAudioEngine()
    private var peak: Float = 0
    private var lastAppend = Date.distantPast

    init() {
        // Kestirmeler öne gelince ya da arama gelince ses oturumu kesilirse kayda düşsün.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            Task { @MainActor in self?.callbacks.insert("\(Probe.stamp()) ⚠︎ ses oturumu kesintisi \(began ? "başladı" : "bitti")", at: 0) }
        }
    }

    var backgroundCount: Int { samples.filter(\.background).count }
    var backgroundVoiceCount: Int { samples.filter { $0.background && $0.level > Self.voiceLevel }.count }

    func start() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                if granted { self.begin() } else { self.status = "Mikrofon izni verilmedi (Ayarlar → AtlasProbe)" }
            }
        }
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let data = buffer.floatChannelData?[0] else { return }
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += data[i] * data[i] }
                let rms = (sum / Float(max(n, 1))).squareRoot()
                Task { @MainActor in self?.record(rms) }
            }
            try engine.start()
            running = true
            status = "Dinliyor. Şimdi ekranı kilitle, 10–20 sn konuş, sonra geri gel."
        } catch {
            status = "Hata: \(error.localizedDescription)"
        }
    }

    private func record(_ rms: Float) {
        peak = max(peak, rms)
        let now = Date()
        guard now.timeIntervalSince(lastAppend) >= 0.5 else { return }
        let background = UIApplication.shared.applicationState != .active
        samples.append(Sample(time: now, level: peak, background: background))
        if samples.count > 4000 { samples.removeFirst(samples.count - 4000) }
        peak = 0
        lastAppend = now
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
        status = "Durdu"
    }

    func reset() {
        samples.removeAll()
        callbacks.removeAll()
    }

    // MARK: - Kestirme testi

    func runShortcut() {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "x-callback-url"
        c.path = "/run-shortcut"
        c.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: "AtlasProbe'dan merhaba"),
            URLQueryItem(name: "x-success", value: "atlasprobe://basarili"),
            URLQueryItem(name: "x-error", value: "atlasprobe://hata"),
            URLQueryItem(name: "x-cancel", value: "atlasprobe://iptal"),
        ]
        guard let url = c.url else { return }
        callbacks.insert("\(Self.stamp()) → \"\(shortcutName)\" çalıştırılıyor", at: 0)
        UIApplication.shared.open(url) { ok in
            Task { @MainActor in
                if !ok { self.callbacks.insert("\(Self.stamp()) ✗ Kestirmeler açılamadı", at: 0) }
            }
        }
    }

    /// Kestirme bitince x-success/x-error/x-cancel ile buraya dönülür; sonuç varsa sorgu parametresinde gelir.
    func handle(_ url: URL) {
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        callbacks.insert("\(Self.stamp()) ← \(text)", at: 0)
    }

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
