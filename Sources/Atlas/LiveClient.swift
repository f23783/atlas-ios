import Foundation

/// Gemini Live WebSocket istemcisi (SDK'sız). Tel biçimi masaüstü sürümünün kullandığı @google/genai'den
/// yakalandı (atlas-live/scripts/capture-wire.js, 2026-10-05):
///   OUT {"setup":{model, generationConfig:{responseModalities, speechConfig}, systemInstruction:{parts}, tools,
///         sessionResumption, inputAudioTranscription, outputAudioTranscription, contextWindowCompression}}
///   IN  {"setupComplete":{}}
///   OUT {"realtimeInput":{"audio":{"data":b64,"mimeType":"audio/pcm;rate=16000"}}} | {"realtimeInput":{"text":…}}
///   IN  {"serverContent":{modelTurn:{parts:[{inlineData:{data}}]}, outputTranscription, inputTranscription,
///         interrupted, generationComplete, turnComplete}, "usageMetadata":…}
///   IN  {"toolCall":{"functionCalls":[{name,args,id}]}}  →  OUT {"toolResponse":{"functionResponses":[{id,name,response}]}}
///   IN  {"sessionResumptionUpdate":{newHandle,resumable}} · {"goAway":{timeLeft}}
@MainActor
protocol LiveClientDelegate: AnyObject {
    func liveDidOpen()
    func liveDidSetup()
    func liveDidReceive(message: [String: Any])
    func liveDidClose(code: Int, reason: String)
}

final class LiveClient: NSObject, URLSessionWebSocketDelegate {
    weak var delegate: LiveClientDelegate?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let setup: [String: Any]
    private let apiKey: String
    private var closed = false
    // Kurulum tamamlanana kadar başka mesaj gitmesin: mikrofon soket açılmadan başlıyor, kuyruktaki ses parçaları
    // kurulumdan ÖNCE giderse sunucu 1007 "First message in the stream must be a setup message" ile kapatıyor.
    private var ready = false
    private var pending: [[String: Any]] = []
    private let lock = NSLock()
    /// Son gönderilen mesajın türü (kapanış günlüğü için: hatayı neyin tetiklediği).
    private(set) var lastSent = "-"

    init(apiKey: String, setup: [String: Any]) {
        self.apiKey = apiKey
        self.setup = setup
    }

    func connect() {
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)")!
        Log.i("soket: generativelanguage.googleapis.com (anahtar günlüğe yazılmaz)")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        let t = s.webSocketTask(with: url)
        t.maximumMessageSize = 16 * 1024 * 1024
        session = s
        task = t
        t.resume()
    }

    func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: Gönderme

    func send(_ obj: [String: Any]) {
        if obj["setup"] == nil {
            lock.lock()
            if !ready {
                // ses bekletilmez (bayatlar), diğerleri kurulumdan sonra sırayla gider
                if (obj["realtimeInput"] as? [String: Any])?["audio"] == nil { pending.append(obj) }
                lock.unlock()
                return
            }
            lock.unlock()
        }
        let kind = obj.keys.first.map { k in
            k == "realtimeInput" ? "realtimeInput." + ((obj[k] as? [String: Any])?.keys.first ?? "?") : k
        } ?? "?"
        if kind != "realtimeInput.audio" { lastSent = kind }
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { err in if let err { Log.e("gönderilemedi: \(err.localizedDescription)") } }
    }

    func sendAudio(_ pcm16: Data) {
        send(["realtimeInput": ["audio": ["data": pcm16.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    func sendText(_ text: String) {
        send(["realtimeInput": ["text": text]])
    }

    func sendToolResponses(_ responses: [[String: Any]]) {
        send(["toolResponse": ["functionResponses": responses]])
    }

    // MARK: Alma

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                var data: Data?
                switch msg {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    Task { @MainActor in
                        if obj["setupComplete"] != nil {
                            self.lock.lock(); self.ready = true; let q = self.pending; self.pending.removeAll(); self.lock.unlock()
                            q.forEach { self.send($0) }
                            self.delegate?.liveDidSetup()
                        }
                        self.delegate?.liveDidReceive(message: obj)
                    }
                }
                self.receiveLoop()
            case .failure(let err):
                if !self.closed { Log.w("alma hatası: \(err.localizedDescription)") } // kapanış didClose ile bildirilir
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        send(["setup": setup])
        receiveLoop()
        Task { @MainActor in self.delegate?.liveDidOpen() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        finish(code: closeCode.rawValue, reason: text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(code: -1, reason: error.localizedDescription) }
    }

    private func finish(code: Int, reason: String) {
        guard !closed else { return }
        closed = true
        Task { @MainActor in self.delegate?.liveDidClose(code: code, reason: reason) }
    }
}
