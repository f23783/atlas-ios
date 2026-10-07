import Foundation

/// TypeSafe Jev (masaüstündeki jev.js + tools/index.js pickTool karşılığı).
/// Girdi $0,042 / 1M token, çıktı ücretsiz. Fido'nun bütçesi: toplam $10 (bitince çağrı yapılmaz).
enum JevLedger {
    static let budgetUSD = 10.0
    static let pricePerToken = 0.042 / 1_000_000
    static var totalUSD: Double { UserDefaults.standard.double(forKey: "jev.total") }
    static var calls: Int { UserDefaults.standard.integer(forKey: "jev.calls") }
    static func add(tokens: Int) -> Double {
        let usd = Double(tokens) * pricePerToken
        UserDefaults.standard.set(totalUSD + usd, forKey: "jev.total")
        UserDefaults.standard.set(calls + 1, forKey: "jev.calls")
        return usd
    }
}

struct JevPick {
    let choice: String
    let confidence: Double
    let probabilities: [String: Double]
    let ms: Int
    let tokens: Int
    let usd: Double
    var speculative = false
}

enum Jev {
    static let none = "hicbiri"
    static let minConfidence = 0.5 // altında öneri verilmez (tahmin yürütmez)

    /// Jev'in seçeceği yetenekler ve "ne işe yarar" açıklamaları (Choice ölçütleri).
    @MainActor
    static func options(shortcuts: [AllowedShortcut]) -> [(String, String)] {
        var o: [(String, String)] = [
            ("atlas_bak", "Fido'nun kendisi, projeleri, hedefleri, kariyeri, ev ağı, homelab, notları, geçmiş kararları ya da Atlas'ın hafızası hakkında soru: \"ev ağı projem ne durumda\", \"Proxmox'u nasıl uyandırıyordum\", \"bu hafta ne üzerinde çalıştık\"."),
            ("hava_durumu", "Hava durumu: sıcaklık, yağmur/kar ihtimali, rüzgar, soğuk mu sıcak mı. \"Yarın şemsiye lazım mı?\""),
            ("zamanlayici", "Geri sayım ve kısa süreli hatırlatma: \"10 dakika sonra haber ver\", \"kaç dakika kaldı\"."),
            ("telefon", "Bu iPhone'un durumu: pil, şarj, Düşük Güç Modu, ısınma, depolama, ekran parlaklığı."),
            ("takvim", "Takvim etkinlikleri: \"yarın ne var\", \"cuma 14'e toplantı ekle\"."),
            ("animsatici", "Anımsatıcılar / yapılacaklar: \"ekmek almayı hatırlat\", \"listemde ne var\", \"tamamlandı\"."),
        ]
        if !shortcuts.isEmpty {
            o.append(("kestirme_calistir", "Telefonu Kestirmelerle yönetmek: " + shortcuts.map { "\($0.name) (\($0.about))" }.joined(separator: "; ")))
        }
        return o
    }

    static func pick(key: String, said: String, options: [(String, String)]) async throws -> JevPick {
        guard !key.isEmpty else { throw err("TypeSafe anahtarı yok (Ayarlar).") }
        guard JevLedger.totalUSD < JevLedger.budgetUSD - 0.001 else { throw err("Jev bütçesi doldu ($\(JevLedger.budgetUSD)).") }
        // Jev'in ilk seçeneğe eğilimi var (jev-1.13 jaggedness): sırayı her çağrıda karıştır.
        var criteria: [String: String] = [none: "Hiçbir araç uymuyor: sohbet, genel bilgi ya da bu araçların yapamadığı bir iş."]
        for (k, v) in options.shuffled() { criteria[k] = v }
        let body: [String: Any] = [
            "model": "jev-latest",
            "state": ["kullanicinin_sozu": said],
            "questions": ["arac": [
                "type": "choice",
                "instructions": "Kullanıcının isteğini yerine getirmek için aşağıdaki araçlardan hangisi gerekiyor? Hiçbiri uymuyorsa \"hicbiri\".",
                "criteria": criteria,
            ]],
        ]
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw err("Jev cevabı okunamadı") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let a = (obj["answers"] as? [String: Any])?["arac"] as? [String: Any] else {
            throw err("Jev \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(String(describing: obj).prefix(200))")
        }
        let tokens = (obj["usage"] as? [String: Any])?["input_tokens"] as? Int ?? 0
        let probs = (a["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return JevPick(choice: a["choice"] as? String ?? none, confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0,
                       probabilities: probs, ms: ms, tokens: tokens, usd: JevLedger.add(tokens: tokens))
    }

    /// Kısa ipucu (masaüstü deneyi: şemalı not Gemini'yi kilitliyordu, tek satır ipucu 8/8).
    static func hint(for p: JevPick) -> String? {
        guard p.choice != none, p.confidence >= minConfidence else { return nil }
        return "[İpucu: \(p.choice) aracını kullan]"
    }

    /// Ara ve kesin döküm karşılaştırması: noktalama, boşluk, büyük/küçük harf önemsiz.
    static func normalize(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr_TR")).filter { $0.isLetter || $0.isNumber }
    }

    private static func err(_ m: String) -> NSError { NSError(domain: "Jev", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}
