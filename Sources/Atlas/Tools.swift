import Foundation

/// Modelin çağırabileceği bir araç: Gemini'ye giden tanım + telefonda çalışan iş.
/// Faz 1: yalnız saat. Faz 2: Kestirmeler, hava (konum), zamanlayıcı, telefon durumu, takvim, anımsatıcılar.
struct Tool {
    let name: String
    let declaration: [String: Any]
    let run: ([String: Any]) async -> [String: Any]
}

enum Tools {
    static let clock = Tool(
        name: "get_current_time",
        declaration: ["name": "get_current_time", "description": "Şu anki tarih ve saati (Europe/Istanbul) döndürür."],
        run: { _ in
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR")
            f.timeZone = TimeZone(identifier: "Europe/Istanbul")
            f.dateStyle = .full
            f.timeStyle = .short
            return ["now": f.string(from: Date())]
        }
    )

    static let all: [Tool] = [clock]

    static func run(_ call: [String: Any]) async -> [String: Any] {
        let name = call["name"] as? String ?? ""
        let args = call["args"] as? [String: Any] ?? [:]
        guard let tool = all.first(where: { $0.name == name }) else { return ["hata": "Bilinmeyen araç: \(name)"] }
        return await tool.run(args)
    }
}

/// Gemini 3.x Live ücretli katman, USD / 1M token (masaüstündeki pricing.js ile aynı). Tahmin; ücretsiz katmanda fatura 0.
enum Pricing {
    static let input: [String: Double] = ["TEXT": 0.75, "AUDIO": 3.0, "IMAGE": 1.0, "VIDEO": 1.0]
    static let output: [String: Double] = ["TEXT": 4.5, "AUDIO": 12.0]
    static let thoughts = 4.5
    static var usdTry = 49.06 // TCMB'den açılışta güncellenir

    static func usd(_ u: [String: Any]) -> Double {
        func side(_ details: Any?, _ table: [String: Double], _ total: Any?, _ fallback: Double) -> Double {
            if let arr = details as? [[String: Any]], !arr.isEmpty {
                return arr.reduce(0) { $0 + Double(($1["tokenCount"] as? Int) ?? 0) * (table[$1["modality"] as? String ?? ""] ?? fallback) }
            }
            return Double((total as? Int) ?? 0) * fallback
        }
        let v = side(u["promptTokensDetails"], input, u["promptTokenCount"], input["AUDIO"]!)
            + side(u["responseTokensDetails"], output, u["responseTokenCount"], output["AUDIO"]!)
            + Double((u["thoughtsTokenCount"] as? Int) ?? 0) * thoughts
        return v / 1_000_000
    }

    static func refreshRate() async {
        guard let url = URL(string: "https://www.tcmb.gov.tr/kurlar/today.xml"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              let r = xml.range(of: #"Kod="USD"[\s\S]*?<ForexSelling>([\d.]+)</ForexSelling>"#, options: .regularExpression)
        else { return }
        let block = String(xml[r])
        if let m = block.range(of: #"<ForexSelling>([\d.]+)"#, options: .regularExpression) {
            let num = block[m].replacingOccurrences(of: "<ForexSelling>", with: "")
            if let v = Double(num), v > 0 { usdTry = v }
        }
    }
}
