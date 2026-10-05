import Foundation

/// Paralel canlı döküm (gemini-3.5-transcribe-live). Ön-seçim kipinde sırayı istemci tutar:
/// ajanın kendi dökümü ancak sıra kapanınca geliyor, Jev'e yetişmiyor (masaüstü deneyi, 2026-10-05).
/// Durumsuzdur: koparsa sessizce yeniden bağlanır.
@MainActor
final class Scribe: LiveClientDelegate {
    var onInterim: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onUsage: (([String: Any]) -> Void)?
    private var client: LiveClient?
    private var key = ""
    private var stopped = true

    func start(key: String) {
        self.key = key
        stopped = false
        connect()
    }

    private func connect() {
        let setup: [String: Any] = [
            "model": "models/gemini-3.5-transcribe-live",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": ["languageCodes": ["tr-TR"]],
        ]
        let c = LiveClient(apiKey: key, setup: setup)
        c.delegate = self
        client = c
        c.connect()
    }

    func send(_ pcm16: Data) { client?.sendAudio(pcm16) }

    func stop() {
        stopped = true
        client?.delegate = nil
        client?.close()
        client = nil
    }

    func liveDidOpen() {}
    func liveDidSetup() { Log.i("döküm hazır (transcribe-live)") }

    func liveDidReceive(message m: [String: Any]) {
        if let u = m["usageMetadata"] as? [String: Any] { onUsage?(u) }
        guard let sc = m["serverContent"] as? [String: Any] else { return }
        if let t = (sc["interimInputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty { onInterim?(t) }
        if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty { onFinal?(t) }
    }

    func liveDidClose(code: Int, reason: String) {
        client = nil
        guard !stopped else { return }
        Log.w("döküm kapandı: kod=\(code) \(reason) — yeniden bağlanıyor")
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if !self.stopped { self.connect() }
        }
    }
}
