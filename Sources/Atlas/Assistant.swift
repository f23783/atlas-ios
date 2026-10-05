import AVFoundation
import Foundation
import UIKit

struct JevTrace: Identifiable {
    let id = UUID()
    let time = Date()
    let said: String
    let pick: JevPick?
    let error: String?
}

struct Turn: Identifiable {
    let id = UUID()
    var user = ""
    var model = ""
    var chips: [String] = []
    var timing: String?
    var cut = false
}

/// Oturumun tek sahibi (masaüstündeki LiveSession + ipc + app.js'in iPhone karşılığı).
@MainActor
final class Assistant: ObservableObject, LiveClientDelegate, ToolHost {
    enum Conn: String { case idle = "Kapalı", connecting = "Bağlanıyor", open = "Bağlı", reconnecting = "Yeniden bağlanıyor" }

    @Published var conn: Conn = .idle
    @Published var turns: [Turn] = []
    @Published var micOn = true { didSet { audio.muted = !micOn; micToggled() } }
    @Published var error: String?
    @Published var sessionTRY: Double = 0
    @Published var todayTRY: Double = 0
    /// Model sesi çalıyor mu (AudioIO yayınlamaz; ekrandaki "Konuşuyor" yazısı için 10 Hz'de yansıtılır).
    @Published var speaking = false
    /// Ekranda bekleyen Evet/Hayır sorusu (Kestirme onayı).
    @Published var pendingConfirm: (title: String, message: String)?
    private var confirmCont: CheckedContinuation<Bool, Never>?

    // Test paneli verisi
    @Published var jevTraces: [JevTrace] = []
    @Published var timingHist: [String: [[Double]]] = (UserDefaults.standard.dictionary(forKey: "timingHist") as? [String: [[Double]]]) ?? [:]

    // Ön-seçim: istemci sırası + paralel döküm
    private let scribe = Scribe()
    private var preMode: Bool { settings.toolMode == "jev_pre" }
    private var activeMode = "direct" // bağlantı anındaki kip (ayar sonradan değişse de oturum bunu kullanır)
    private var clientTurnOpen = false
    private var preroll: [Data] = []
    private var finalText = ""
    private var closeTimer: Task<Void, Never>?
    private var specTimer: Task<Void, Never>?
    private var speculative: (key: String, task: Task<JevPick?, Never>)?
    private var poller: Task<Void, Never>?

    let audio = AudioIO()
    private let settings: AppSettings
    private var client: LiveClient?
    private var handle: String?
    private var reconnects = 0
    private var openedAt = Date.distantPast
    private var stopping = false
    private var watchdog: Task<Void, Never>?
    private var lastReason = ""
    private var memoryContext = ""   // açılışta vault'tan: kişilik talimatları + son oturumlar
    private var searchBlocked = false // arama kotası yoksa bu oturumda kapat

    // Süre ölçümü (masaüstündeki timing ile aynı cetvel): başlangıç = sustuğun an / Gönder anı.
    private var tStart: Date?
    private var tFirst: Date?
    private var typed = false
    private var draining = false

    private static let fatal = try! NSRegularExpression(pattern: "quota|billing|api key|permission|not found|not supported|invalid", options: .caseInsensitive)

    init(settings: AppSettings) {
        self.settings = settings
        Timers.shared.host = self
        todayTRY = Ledger.todayUSD * Pricing.usdTry
        audio.onChunk = { [weak self] data in
            Task { @MainActor in self?.routeMic(data) }
        }
        scribe.onInterim = { [weak self] t in self?.onInterim(t) }
        scribe.onFinal = { [weak self] t in self?.onFinal(t) }
        scribe.onUsage = { [weak self] u in
            guard let self else { return }
            let usd = Pricing.usdTranscribe(u)
            self.sessionTRY += usd * Pricing.usdTry
            self.todayTRY = Ledger.add(usd) * Pricing.usdTry
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let ended = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
            Log.w("ses oturumu kesintisi: \(ended ? "bitti" : "başladı")")
            Task { @MainActor in if ended { self?.resumeAudio() } }
        }
        Task { await Pricing.refreshRate(); self.todayTRY = Ledger.todayUSD * Pricing.usdTry }
    }

    // MARK: Bağlan / kes

    func toggle() { conn == .idle ? start() : stop() }

    func start() {
        guard !settings.geminiKey.isEmpty else { error = "Önce Ayarlar'dan Gemini API anahtarını gir."; Log.w("başlat: anahtar yok"); return }
        if preMode && settings.typesafeKey.isEmpty { error = "Ön-seçim kipi için Ayarlar'dan TypeSafe (Jev) anahtarını gir."; return }
        activeMode = settings.toolMode
        Log.i("başlat: model=\(settings.model) ses=\(settings.voice) bellek=\(settings.contextLimit) kip=\(activeMode)")
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else { self.error = "Mikrofon izni yok: Ayarlar → Atlas → Mikrofon."; Log.e("mikrofon izni yok"); return }
                do { try self.audio.start() } catch {
                    self.error = "Ses başlatılamadı: \(error.localizedDescription)"
                    Log.e("ses başlatılamadı: \(error)")
                    return
                }
                self.audio.muted = !self.micOn
                self.watchMic()
                self.stopping = false
                self.reconnects = 0
                self.handle = nil
                self.sessionTRY = 0
                UIApplication.shared.isIdleTimerDisabled = true
                self.poller?.cancel()
                self.poller = Task {
                    while !Task.isCancelled {
                        let sp = self.audio.speaking
                        if sp != self.speaking { self.speaking = sp }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                if self.activeMode == "jev_pre" { self.scribe.start(key: self.settings.geminiKey) }
                self.searchBlocked = false
                self.conn = .connecting
                Task {
                    // Hafıza en fazla 4 sn beklenir; gecikirse onsuz bağlan (konuşma beklemesin).
                    let ctx = await withTaskGroup(of: String?.self) { g -> String in
                        g.addTask { await SessionMemory.shared.context(token: self.settings.githubToken) }
                        g.addTask { try? await Task.sleep(for: .seconds(4)); return nil }
                        let first = await g.next() ?? nil
                        g.cancelAll()
                        return first ?? ""
                    }
                    if ctx.isEmpty { Log.w("hafıza zamanında yüklenemedi, onsuz bağlanılıyor") }
                    self.memoryContext = ctx
                    guard !self.stopping else { return }
                    self.connect(.connecting)
                }
            }
        }
    }

    /// Mikrofon bekçisi: 1,5 sn'de hiç tampon gelmezse girişi yeniden başlat (bir kez), yine gelmezse söyle.
    private func watchMic(attempt: Int = 0) {
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard self.conn != .idle || attempt == 0, !self.stopping else { return }
            let n = self.audio.buffers
            if n > 0 { if attempt > 0 { Log.i("mikrofon: yeniden başlatma sonrası çalışıyor") }; return }
            if attempt == 0 {
                Log.w("mikrofon: 1,5 sn'de ses gelmedi — giriş yeniden başlatılıyor")
                do { try self.audio.restartInput(); self.watchMic(attempt: 1) } catch { Log.e("mikrofon yeniden başlatılamadı: \(error)") }
            } else {
                Log.e("mikrofon: yeniden başlatmaya rağmen ses yok")
                self.error = "Mikrofondan ses gelmiyor. Orb'a dokunup kapatıp yeniden aç."
            }
        }
    }

    /// Kip ya da ses değişince: oturumu yeni ayarla yeniden aç.
    func restart() {
        guard conn != .idle else { return }
        stop()
        Task { try? await Task.sleep(for: .milliseconds(300)); self.start() }
    }

    func stop() {
        Log.i("durdur")
        stopping = true
        scribe.stop()
        resetClientTurn()
        watchdog?.cancel()
        poller?.cancel()
        speaking = false
        client?.close()
        client = nil
        audio.stop()
        conn = .idle
        UIApplication.shared.isIdleTimerDisabled = false
        saveMemory()
    }

    /// Özetlenmemiş konuşmayı vault'a yaz (kapanışta ve uygulama arka plana geçerken).
    func saveMemory() {
        let turns = self.turns, key = settings.geminiKey, token = settings.githubToken
        let bg = UIApplication.shared.beginBackgroundTask(withName: "hafiza")
        Task {
            await SessionMemory.shared.save(turns: turns, geminiKey: key, token: token)
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    private func resumeAudio() {
        guard conn != .idle else { return }
        do { try audio.start(); Log.i("ses yeniden başladı") } catch { Log.e("ses yeniden başlatılamadı: \(error)") }
    }

    private func setupMessage() -> [String: Any] {
        var setup: [String: Any] = [
            "model": "models/\(settings.model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": settings.voice]]],
            ],
            "systemInstruction": ["parts": [["text": systemText()]], "role": "user"],
            "tools": toolsList(),
            "outputAudioTranscription": [:] as [String: Any],
            // 15 dk sınırını kaldırır ve maliyete tavan koyar (Live her turda tüm bağlamı faturalar).
            "contextWindowCompression": ["triggerTokens": String(effectiveContextLimit), "slidingWindow": [:] as [String: Any]],
        ]
        setup["sessionResumption"] = handle.map { ["handle": $0] } ?? [:] as [String: Any]
        if activeMode == "jev_pre" {
            // Sırayı istemci tutar; kullanıcı dökümü paralel döküm modelinden gelir (ajanınki geç ve tekrar olurdu).
            setup["realtimeInputConfig"] = ["automaticActivityDetection": ["disabled": true]]
        } else {
            setup["inputAudioTranscription"] = [:] as [String: Any]
        }
        return setup
    }

    private var searchOn: Bool { settings.googleSearch && !searchBlocked }

    /// Arama sonuçları bağlama eklenir; 8k sınırla ilk sıkıştırmada sunucu 1007 "invalid argument" veriyor.
    /// Ölçüm (2026-10-05, 3.8 Live, faturalı anahtar): 8k ✗ · 16k ✓ · 32k ✓ · sınırsız ✓. Arama açıkken en az 16k.
    private var effectiveContextLimit: Int { searchOn ? max(settings.contextLimit, 16000) : settings.contextLimit }

    private func systemText() -> String {
        var s = Catalog.systemInstruction
        if searchOn { s += "\nGüncel olaylar, haberler, fiyatlar gibi internette olan bilgiler için Google araması yap." }
        if !memoryContext.isEmpty { s += "\n\n" + memoryContext }
        return s
    }

    private func toolsList() -> [[String: Any]] {
        var t: [[String: Any]] = [["functionDeclarations": Tools.declarations(shortcuts: settings.shortcuts)]]
        if searchOn { t.append(["googleSearch": [:] as [String: Any]]) }
        return t
    }

    private func connect(_ phase: Conn) {
        Log.i("bağlanıyor (\(phase.rawValue))\(handle != nil ? ", devam anahtarıyla" : "")")
        conn = phase
        resetClientTurn() // yeni bağlantıda sunucu açık sırayı bilmez
        client?.delegate = nil
        client?.close()
        let c = LiveClient(apiKey: settings.geminiKey, setup: setupMessage())
        c.delegate = self
        client = c
        c.connect()
    }

    // MARK: LiveClientDelegate

    func liveDidOpen() { openedAt = Date(); Log.i("soket açıldı, kurulum gönderildi") }

    func liveDidSetup() { conn = .open; error = nil; Log.i("kurulum tamam (setupComplete)") }

    func liveDidClose(code: Int, reason: String) {
        let lastSentKind = client?.lastSent ?? "-"
        client = nil
        if stopping { return }
        lastReason = reason.isEmpty ? "kod \(code)" : reason
        Log.e("bağlantı kapandı: kod=\(code) sebep=\(reason.isEmpty ? "-" : reason) (açık kaldı \(String(format: "%.1f", Date().timeIntervalSince(openedAt))) sn, son gönderilen: \(lastSentKind))")
        // Arama açıkken kota hatası: anahtarın projesinde arama kotası yok (masaüstünde ücretsiz katmanda böyleydi).
        // Bağlantıyı öldürme; aramayı bu oturum için kapat, hemen yeniden bağlan.
        // Arama açıkken konuşma ortasında "invalid argument": telefonda model aramaya kalkınca görüldü (2026-10-05, sebep doğrulanmadı).
        // Oturumu öldürme: aramayı bu oturumda kapat, devam anahtarıyla kaldığı yerden sür.
        if searchOn && lastReason.lowercased().contains("invalid argument") && Date().timeIntervalSince(openedAt) > 2 {
            searchBlocked = true
            Log.w("arama açıkken 'invalid argument': Google araması bu oturumda kapatıldı, kaldığı yerden devam")
            current { $0.chips.append("internet araması bu oturumda kapatıldı (hata)") }
            connect(.reconnecting)
            return
        }
        if searchOn && lastReason.lowercased().contains("quota") {
            searchBlocked = true
            Log.w("arama kotası yok: Google araması bu oturumda kapatıldı, yeniden bağlanılıyor")
            current { $0.chips.append("internet araması kullanılamıyor (kota)") }
            handle = nil
            connect(.reconnecting)
            return
        }
        let r = NSRange(lastReason.startIndex..., in: lastReason)
        if code == 1008 || Self.fatal.firstMatch(in: lastReason, range: r) != nil {
            error = "Bağlantı kapandı: \(lastReason)"
            stop()
            return
        }
        // Açılır açılmaz ölen bağlantı: devam anahtarı bozuk durumu geri getiriyor olabilir → temiz başla.
        if handle != nil && Date().timeIntervalSince(openedAt) < 3 { handle = nil; Log.w("açılır açılmaz kapandı: devam anahtarı bırakıldı") }
        reconnects += 1
        if reconnects > 5 {
            error = "Yeniden bağlanılamadı (\(lastReason)). Ayarlar'dan başka model dene."
            stop()
            return
        }
        conn = .reconnecting
        let delay = min(0.5 * pow(2, Double(reconnects - 1)), 8)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if !self.stopping { self.connect(.reconnecting) }
        }
    }

    func liveDidReceive(message m: [String: Any]) {
        if let u = m["usageMetadata"] as? [String: Any] {
            let usd = Pricing.usd(u)
            Log.i("kullanım: girdi \((u["promptTokenCount"] as? Int) ?? 0) · çıktı \((u["responseTokenCount"] as? Int) ?? 0) tok · $\(String(format: "%.5f", usd))")
            sessionTRY += usd * Pricing.usdTry
            todayTRY = Ledger.add(usd) * Pricing.usdTry
        }
        if let r = m["sessionResumptionUpdate"] as? [String: Any], (r["resumable"] as? Bool) == true, let h = r["newHandle"] as? String {
            handle = h
        }
        if m["goAway"] != nil { Log.w("goAway: bağlantı yenileniyor"); connect(.reconnecting); return } // sunucu birazdan kapatacak: devam anahtarıyla yenile
        if let tc = m["toolCall"] as? [String: Any], let calls = tc["functionCalls"] as? [[String: Any]] {
            watchdog?.cancel()
            Task { await handleTools(calls) }
        }
        guard let sc = m["serverContent"] as? [String: Any] else { return }
        reconnects = 0
        if sc["modelTurn"] != nil || sc["outputTranscription"] != nil || sc["interrupted"] != nil { watchdog?.cancel() }

        if sc["groundingMetadata"] != nil, !(turns.last?.chips.contains("internette aradı") ?? false) {
            current { $0.chips.append("internette aradı") }
            Log.i("Google araması kullanıldı")
        }
        if (sc["interrupted"] as? Bool) == true {
            audio.flush()
            finishTiming(cut: true)
            endTurn(cut: true)
        }
        if let parts = (sc["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for p in parts {
                if let b64 = (p["inlineData"] as? [String: Any])?["data"] as? String, let d = Data(base64Encoded: b64) {
                    audio.play(pcm16: d)
                    onFirstAudio()
                }
            }
        }
        if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String { append(user: t) }
        if let t = (sc["outputTranscription"] as? [String: Any])?["text"] as? String { append(model: t) }
        if (sc["turnComplete"] as? Bool) == true {
            if tFirst != nil { draining = true; waitDrain() }
            endTurn(cut: false)
        }
    }

    // MARK: Araçlar + bekçi

    private func handleTools(_ calls: [[String: Any]]) async {
        var responses: [[String: Any]] = []
        for call in calls {
            let name = call["name"] as? String ?? "?"
            current { $0.chips.append("araç: \(Self.label(name))") }
            Log.i("araç → \(name) \(call["args"].map { "\($0)" } ?? "")")
            let result = await Tools.run(call, shortcuts: settings.shortcuts, host: self, jevKey: settings.typesafeKey)
            Log.i("araç ← \(name) \(String(describing: result).prefix(300))")
            responses.append(["id": call["id"] ?? "", "name": name, "response": result])
        }
        client?.sendToolResponses(responses)
        // Bekçi: araç sonucundan sonra model 6 sn susarsa bir kez dürt (masaüstünde 50 denemede 7 kez gerekti).
        watchdog?.cancel()
        watchdog = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self.conn == .open else { return }
            self.client?.sendText("[Sistem bildirimi — kullanıcı söylemedi] Araç sonucu geldi. Şimdi kullanıcıya kısaca sesli cevap ver.")
            self.current { $0.chips.append("bekçi dürttü") }
            Log.w("bekçi: model 6 sn sustu, dürtüldü")
        }
    }

    static func label(_ n: String) -> String {
        ["get_current_time": "saat", "atlas_bak": "Atlas'a baktı", "hava_durumu": "hava", "zamanlayici": "zamanlayıcı", "telefon": "telefon",
         "takvim": "takvim", "animsatici": "anımsatıcı", "kestirme_calistir": "kestirme"][n] ?? n
    }

    // MARK: ToolHost

    func confirm(title: String, message: String) async -> Bool {
        confirmCont?.resume(returning: false)
        return await withCheckedContinuation { c in
            confirmCont = c
            pendingConfirm = (title, message)
        }
    }

    func answerConfirm(_ yes: Bool) {
        Log.i("onay: \(yes ? "evet" : "hayır")")
        pendingConfirm = nil
        confirmCont?.resume(returning: yes)
        confirmCont = nil
    }

    func announce(_ text: String) {
        guard conn == .open else { return }
        client?.sendText("[Sistem bildirimi — kullanıcı söylemedi] \(text)")
    }

    // MARK: Metin girişi

    func send(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, conn == .open else { return }
        endTurn(cut: false)
        turns.append(Turn(user: t))
        tStart = Date(); typed = true; tFirst = nil
        guard activeMode == "jev_pre" else { client?.sendText(t); return }
        Task {
            let p = await self.jevPick(t)
            // Elle sırada metni activityStart/End ile sarmak 1007 veriyor: ipucu bağlam olarak, metin düz (masaüstü deneyi).
            if let p, let h = Jev.hint(for: p) { self.sendHint(h) }
            self.client?.sendText(t)
        }
    }

    // MARK: Ön-seçim (istemci sırası)

    private func routeMic(_ data: Data) {
        guard activeMode == "jev_pre" else { client?.sendAudio(data); return }
        scribe.send(data)
        if clientTurnOpen { client?.sendAudio(data) } else {
            preroll.append(data)
            if preroll.count > 15 { preroll.removeFirst() } // 15 × 100 ms: konuşmanın ilk hecesi kaybolmasın
        }
    }

    private func onInterim(_ text: String) {
        guard conn == .open, micOn else { return }
        closeTimer?.cancel(); closeTimer = nil // kesin metinden sonra konuşma sürdüyse sırayı kapatma
        if !clientTurnOpen {
            clientTurnOpen = true
            client?.send(["realtimeInput": ["activityStart": [:] as [String: Any]]]) // model konuşuyorsa keser (söze girme)
            for b in preroll { client?.sendAudio(b) }
            Log.i("sıra açıldı (\"\(text)\", tampon \(preroll.count))")
            preroll.removeAll()
            endTurn(cut: false)
        }
        let full = finalText + text
        current { $0.user = full }
        specTimer?.cancel()
        specTimer = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.prefetch(full)
        }
    }

    private func onFinal(_ text: String) {
        guard clientTurnOpen else { return }
        finalText += text
        current { $0.user = self.finalText }
        closeTimer?.cancel()
        closeTimer = Task {
            try? await Task.sleep(for: .milliseconds(200)) // cümle ortası duraklama payı
            guard !Task.isCancelled else { return }
            await self.closeTurn()
        }
    }

    private func prefetch(_ text: String) {
        let key = Jev.normalize(text)
        guard !key.isEmpty, speculative?.key != key else { return }
        speculative = (key, Task { await self.jevPick(text, record: false) })
    }

    private func closeTurn() async {
        closeTimer = nil
        specTimer?.cancel()
        let text = finalText.trimmingCharacters(in: .whitespaces)
        finalText = ""
        if !text.isEmpty {
            var p: JevPick?
            if let s = speculative, s.key == Jev.normalize(text) {
                p = await s.task.value
                p?.speculative = true
                if let p { record(JevTrace(said: text, pick: p, error: nil)) }
            } else {
                p = await jevPick(text)
            }
            speculative = nil
            if let p, let h = Jev.hint(for: p) { sendHint(h) }
        }
        clientTurnOpen = false
        client?.send(["realtimeInput": ["activityEnd": [:] as [String: Any]]])
        Log.i("sıra kapandı: \"\(text)\"")
    }

    private func sendHint(_ h: String) {
        // clientContent: "konuşmayı tetiklemeyen bağlam" (masaüstü deneyinde 8/8; realtime metin notu takılıyordu)
        client?.send(["clientContent": ["turns": [["role": "user", "parts": [["text": h]]]], "turnComplete": false]])
    }

    private func jevPick(_ said: String, record rec: Bool = true) async -> JevPick? {
        do {
            let p = try await Jev.pick(key: settings.typesafeKey, said: said, options: Jev.options(shortcuts: settings.shortcuts))
            if rec { record(JevTrace(said: said, pick: p, error: nil)) }
            return p
        } catch {
            Log.w("Jev: \(error.localizedDescription) — ipucusuz devam")
            record(JevTrace(said: said, pick: nil, error: error.localizedDescription))
            return nil
        }
    }

    private func record(_ t: JevTrace) {
        jevTraces.insert(t, at: 0)
        if jevTraces.count > 50 { jevTraces.removeLast() }
        if let p = t.pick {
            Log.i("Jev → \(p.choice) %\(Int(p.confidence * 100)) \(p.ms) ms\(p.speculative ? " (önceden)" : "")")
            current { $0.chips.append(p.choice == Jev.none ? "Jev → araç yok" : "Jev → \(Self.label(p.choice)) %\(Int(p.confidence * 100))") }
        }
    }

    private func resetClientTurn() {
        clientTurnOpen = false
        preroll.removeAll()
        finalText = ""
        closeTimer?.cancel(); closeTimer = nil
        specTimer?.cancel(); specTimer = nil
        speculative = nil
    }

    func micToggled() {
        if !micOn, activeMode == "jev_pre", clientTurnOpen { Task { await closeTurn() } }
    }

    func resetTimingHist() {
        timingHist = [:]
        UserDefaults.standard.removeObject(forKey: "timingHist")
    }

    // MARK: Transkript

    private var turnOpen = false

    private func current(_ edit: (inout Turn) -> Void) {
        if !turnOpen || turns.isEmpty { turns.append(Turn()); turnOpen = true }
        edit(&turns[turns.count - 1])
    }

    private func append(user t: String) { current { $0.user += t } }
    private func append(model t: String) { current { $0.model += t } }

    private func endTurn(cut: Bool) {
        if cut, !turns.isEmpty { turns[turns.count - 1].cut = true }
        turnOpen = false
        if turns.count > 60 { turns.removeFirst(turns.count - 60) }
    }

    // MARK: Süre ölçümü

    private func onFirstAudio() {
        guard tFirst == nil else { return }
        tFirst = Date()
        if !typed {
            // 20 sn'den eski ses = bu cevap kullanıcıya değil (bekçi vb.): ölçme
            if let v = audio.lastVoiceAt, tFirst!.timeIntervalSince(v) < 20 { tStart = v } else { tStart = nil }
        }
    }

    private func waitDrain() {
        Task {
            while self.draining && self.audio.speaking { try? await Task.sleep(for: .milliseconds(50)) }
            if self.draining { self.finishTiming(cut: false) }
        }
    }

    private func finishTiming(cut: Bool) {
        defer { tStart = nil; tFirst = nil; typed = false; draining = false }
        guard let s = tStart, let f = tFirst else { return }
        let first = f.timeIntervalSince(s), total = Date().timeIntervalSince(s)
        let text = String(format: "ilk ses %.1f sn · %@ %.1f sn — %@", first, cut ? "kesildi" : "bitiş", total, typed ? "yazılı" : "sustuktan sonra")
            .replacingOccurrences(of: ".", with: ",")
        if let i = turns.lastIndex(where: { !$0.model.isEmpty }) { turns[i].timing = text }
        if !cut {
            let key = "\(activeMode)|\(typed ? "yazılı" : "sesli")"
            timingHist[key, default: []].append([first, total])
            timingHist[key] = Array(timingHist[key]!.suffix(30))
            UserDefaults.standard.set(timingHist, forKey: "timingHist")
        }
    }
}

/// Günlük harcama (USD), UserDefaults'ta.
enum Ledger {
    private static var key: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        return "usd-" + f.string(from: Date())
    }
    static var todayUSD: Double { UserDefaults.standard.double(forKey: key) }
    static func add(_ usd: Double) -> Double {
        let v = todayUSD + usd
        UserDefaults.standard.set(v, forKey: key)
        return v
    }
}
