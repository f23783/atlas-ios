import Foundation

/// Oturumlar arası hafıza (Fido: "her session başı nerede kaldığını anımsamalı… FidoOS'te kendine özel persona dosyasına").
///  • Açılış: kişilik tanımının `## Talimatlar` bölümü + `Atlas-Live-Oturumlar.md`'deki son iki kayıt → sistem talimatı.
///  • Kapanış: konuşma dökümü → ucuz metin modeli özetler → Oturumlar dosyasının en üstüne yazılır (GitHub commit).
/// Yazma izni KODDA sabit: yalnız Oturumlar dosyası. Token yazma yetkili olsa da başka dosyaya yazılmaz.
@MainActor
final class SessionMemory {
    static let shared = SessionMemory()
    static let personaPath = "🛠️ 600-Arsenal/Kişilikler/Atlas-Live.md"
    static let sessionsPath = "🛠️ 600-Arsenal/Kişilikler/Atlas-Live-Oturumlar.md"
    private static let writable: Set<String> = [sessionsPath]
    private static let marker = "<!-- KAYITLAR: uygulama bu satırın altına yazar -->"
    private static let summaryModel = "gemini-flash-lite-latest"

    private var savedTurns = Set<UUID>()
    private var saving = false

    // MARK: Açılış bağlamı

    /// Sistem talimatına eklenecek metin (en fazla ~3000 karakter). Ağ yoksa vault önbelleğinden.
    func context(token: String) async -> String {
        async let persona = read(Self.personaPath, token: token)
        async let sessions = read(Self.sessionsPath, token: token)
        var out: [String] = []
        if let p = await persona, let t = Self.section(p, "## Talimatlar") {
            out.append("Kişilik talimatların (Fido'nun vault'undaki Atlas-Live notundan):\n" + String(t.prefix(1500)))
        }
        if let s = await sessions {
            let entries = Self.entries(s).prefix(2)
            if !entries.isEmpty {
                out.append("Son konuşmalarımız (en yenisi üstte; Atlas-Live-Oturumlar notundan):\n" + String(entries.joined(separator: "\n").prefix(1500)))
            }
        }
        Log.i("hafıza: \(out.isEmpty ? "yüklenemedi" : "\(out.joined().count) karakter sistem talimatına eklendi")")
        return out.joined(separator: "\n\n")
    }

    private func read(_ path: String, token: String) async -> String? {
        if !token.isEmpty, let (text, _) = try? await GitHubFile.get(path, token: token) { return text }
        return Vault.shared.cachedText(path) // çevrimdışı ya da token yok
    }

    static func section(_ md: String, _ header: String) -> String? {
        guard let r = md.range(of: header + "\n") else { return nil }
        let rest = md[r.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// İşaretin altındaki "### …" kayıtları, en yenisi önce.
    static func entries(_ md: String) -> [String] {
        guard let r = md.range(of: marker) else { return [] }
        return md[r.upperBound...].components(separatedBy: "\n### ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { $0.hasPrefix("### ") ? $0 : "### " + $0 }
    }

    // MARK: Kapanış

    /// Özetlenmemiş turlar varsa özetle ve yaz. Uygulama arka plana geçerken de çağrılır.
    func save(turns: [Turn], geminiKey: String, token: String) async {
        let fresh = turns.filter { !savedTurns.contains($0.id) && (!$0.user.isEmpty || !$0.model.isEmpty) }
        guard !fresh.isEmpty, !saving else { return }
        guard !token.isEmpty else { Log.w("hafıza: GitHub token yok, oturum kaydedilmedi"); return }
        saving = true
        defer { saving = false }
        let transcript = fresh.map { t in
            var s = ""
            if !t.user.isEmpty { s += "Fido: \(t.user.trimmingCharacters(in: .whitespaces))\n" }
            if !t.chips.isEmpty { s += "(\(t.chips.joined(separator: ", ")))\n" }
            if !t.model.isEmpty { s += "Atlas: \(t.model.trimmingCharacters(in: .whitespaces))\n" }
            return s
        }.joined(separator: "\n")
        do {
            let bullets = try await summarize(String(transcript.suffix(9000)), key: geminiKey)
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR"); f.timeZone = TimeZone(identifier: "Europe/Istanbul"); f.dateFormat = "yyyy-MM-dd HH:mm"
            let entry = "### \(f.string(from: Date())) · iPhone · \(fresh.count) tur\n\(bullets)"
            try await append(entry, token: token)
            fresh.forEach { savedTurns.insert($0.id) }
            Log.i("hafıza: oturum kaydedildi (\(fresh.count) tur)")
        } catch {
            Log.e("hafıza: kaydedilemedi — \(error.localizedDescription)")
        }
    }

    private func summarize(_ transcript: String, key: String) async throws -> String {
        let prompt = """
        Aşağıda Fido ile sesli asistanı Atlas'ın konuşma dökümü var. Atlas bir sonraki konuşmada "nerede kalmıştık"ı \
        hatırlasın diye 2–5 madde yaz: ne konuşuldu, ne yapıldı/kararlaştırıldı (parantezdekiler kullanılan araçlar), \
        açık kalan ne. Her madde "- " ile başlasın, kısa ve somut, Türkçe. Önemsiz bir sohbetse tek madde yeter. \
        Yalnız maddeleri yaz.

        \(transcript)
        """
        var r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.summaryModel):generateContent")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": 400],
        ])
        let (d, resp) = try await URLSession.shared.data(for: r)
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let parts = (((obj?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]),
              let text = parts.compactMap({ $0["text"] as? String }).first else {
            throw NSError(domain: "Memory", code: 1, userInfo: [NSLocalizedDescriptionKey: "özet alınamadı: \(String(describing: obj?["error"] ?? "?").prefix(200))"])
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("-") || $0.hasPrefix("•") }
        return (lines.isEmpty ? ["- " + text.trimmingCharacters(in: .whitespacesAndNewlines)] : lines.map { $0.replacingOccurrences(of: "•", with: "-") })
            .prefix(6).joined(separator: "\n")
    }

    private func append(_ entry: String, token: String) async throws {
        let path = Self.sessionsPath
        guard Self.writable.contains(path) else { return } // izin listesi: kod dışına çıkılamaz
        for attempt in 0..<2 {
            let (text, sha) = try await GitHubFile.get(path, token: token)
            guard let r = text.range(of: Self.marker) else {
                throw NSError(domain: "Memory", code: 2, userInfo: [NSLocalizedDescriptionKey: "Oturumlar dosyasında işaret satırı yok"])
            }
            let head = String(text[..<r.upperBound])
            let kept = Self.entries(text).prefix(39) // en fazla 40 kayıt
            let updated = head + "\n" + ([entry] + kept).joined(separator: "\n\n") + "\n"
            do {
                try await GitHubFile.put(path, content: updated, sha: sha, message: "Atlas Live (iPhone): oturum özeti", token: token)
                return
            } catch let e as NSError where e.code == 409 && attempt == 0 {
                Log.w("hafıza: dosya bu arada değişmiş, yeniden deneniyor") // laptop aynı anda push ettiyse
            }
        }
    }
}

/// GitHub Contents API (yalnız tek dosya okuma/yazma).
enum GitHubFile {
    private static func url(_ path: String) -> URL {
        let enc = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "https://api.github.com/repos/\(Vault.repo)/contents/\(enc)")!
    }

    private static func request(_ u: URL, token: String) -> URLRequest {
        var r = URLRequest(url: u)
        r.timeoutInterval = 8
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
    }

    static func get(_ path: String, token: String) async throws -> (String, String) {
        var c = URLComponents(url: url(path), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "ref", value: "main")]
        let (d, resp) = try await URLSession.shared.data(for: request(c.url!, token: token))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let b64 = (o["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
              let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8), let sha = o["sha"] as? String
        else { throw NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: "okunamadı (\(code))"]) }
        return (text, sha)
    }

    static func put(_ path: String, content: String, sha: String, message: String, token: String) async throws {
        var r = request(url(path), token: token)
        r.httpMethod = "PUT"
        r.timeoutInterval = 15
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": message, "content": Data(content.utf8).base64EncodedString(), "sha": sha, "branch": "main",
        ])
        let (_, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201 else {
            throw NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: code == 403 ? "yazma yetkisi yok (403) — token Contents: Read and write olmalı" : "yazılamadı (\(code))"])
        }
    }
}
