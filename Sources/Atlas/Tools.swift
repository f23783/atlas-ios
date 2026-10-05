import CoreLocation
import Foundation

/// Modelin çağırabileceği araçlar (Faz 2): saat, Kestirmeler, hava (konumlu), zamanlayıcı, telefon, takvim, anımsatıcılar.
/// Tanımlar her bağlantıda yeniden üretilir (Kestirme izin listesi ayarlardan gelir; Live araçları bağlantıda sabitler).
@MainActor
enum Tools {
    static func declarations(shortcuts: [AllowedShortcut]) -> [[String: Any]] {
        var d: [[String: Any]] = [
            ["name": "get_current_time", "description": "Şu anki tarih ve saati (Europe/Istanbul) döndürür. Takvim/anımsatıcı tarihlerini hesaplamadan önce kullan."],
            ["name": "hava_durumu",
             "description": "Güncel hava ve 7 güne kadar tahmin. Şehir verilmezse telefonun bulunduğu yer kullanılır.",
             "parameters": ["type": "OBJECT", "properties": [
                "sehir": ["type": "STRING", "description": "Şehir adı. Kullanıcı belirtmediyse BOŞ bırak (konum kullanılır)."],
                "gun": ["type": "STRING", "enum": ["bugun", "yarin", "hafta"]],
             ] as [String: Any]]],
            ["name": "zamanlayici",
             "description": "Geri sayım: kur, listele, iptal. Süre dolunca telefon bildirim gösterir (uygulama kapalı olsa da) ve oturum açıksa sesli haber verilir.",
             "parameters": ["type": "OBJECT", "properties": [
                "islem": ["type": "STRING", "enum": ["kur", "listele", "iptal"]],
                "sure_saniye": ["type": "INTEGER", "description": "kur için toplam süre (10 dakika = 600)."],
                "etiket": ["type": "STRING", "description": "kur için kısa ad (ör. çay)."],
             ] as [String: Any], "required": ["islem"]]],
            ["name": "telefon",
             "description": "Bu iPhone'un durumu (pil, şarj, Düşük Güç Modu, ısı, depolama, parlaklık) ya da ekran parlaklığını ayarlama.",
             "parameters": ["type": "OBJECT", "properties": [
                "islem": ["type": "STRING", "enum": ["durum", "parlaklik_ayarla"]],
                "deger": ["type": "INTEGER", "description": "parlaklik_ayarla için yüzde (0-100)."],
             ] as [String: Any], "required": ["islem"]]],
            ["name": "takvim",
             "description": "Telefonun takvimi: etkinlikleri listele ya da etkinlik ekle. Tarihleri 'YYYY-MM-DD HH:MM' (İstanbul saati) ver.",
             "parameters": ["type": "OBJECT", "properties": [
                "islem": ["type": "STRING", "enum": ["listele", "ekle"]],
                "gun": ["type": "STRING", "description": "listele için: bugun, yarin, hafta ya da YYYY-MM-DD."],
                "baslik": ["type": "STRING"],
                "baslangic": ["type": "STRING", "description": "ekle için 'YYYY-MM-DD HH:MM'."],
                "sure_dakika": ["type": "INTEGER", "description": "ekle için süre, varsayılan 60."],
                "konum": ["type": "STRING"],
             ] as [String: Any], "required": ["islem"]]],
            ["name": "animsatici",
             "description": "Anımsatıcılar: açık olanları listele, yeni ekle (isteğe bağlı zamanlı), ya da adına göre tamamla.",
             "parameters": ["type": "OBJECT", "properties": [
                "islem": ["type": "STRING", "enum": ["listele", "ekle", "tamamla"]],
                "baslik": ["type": "STRING", "description": "ekle/tamamla için."],
                "tarih": ["type": "STRING", "description": "ekle için isteğe bağlı 'YYYY-MM-DD HH:MM'."],
             ] as [String: Any], "required": ["islem"]]],
        ]
        if !shortcuts.isEmpty {
            let list = shortcuts.map { "\($0.name): \($0.about)" }.joined(separator: " | ")
            d.append([
                "name": "kestirme_calistir",
                "description": "iPhone Kestirmeleri ile telefonu yönet (ses, müzik, alarm, ev aletleri vb.). Yalnız şunlar var: \(list). "
                    + "Telefon kilitliyse çalışmaz; o zaman kullanıcıdan kilidi açmasını iste.",
                "parameters": ["type": "OBJECT", "properties": [
                    "ad": ["type": "STRING", "enum": shortcuts.map(\.name)],
                    "girdi": ["type": "STRING", "description": "Kestirmeye verilecek isteğe bağlı metin."],
                ] as [String: Any], "required": ["ad"]],
            ])
        }
        return d
    }

    static func run(_ call: [String: Any], shortcuts: [AllowedShortcut], host: ToolHost) async -> [String: Any] {
        let name = call["name"] as? String ?? ""
        let a = call["args"] as? [String: Any] ?? [:]
        switch name {
        case "get_current_time":
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR"); f.timeZone = TimeZone(identifier: "Europe/Istanbul")
            f.dateFormat = "d MMMM yyyy EEEE HH:mm"
            let iso = DateFormatter()
            iso.locale = Locale(identifier: "en_US_POSIX"); iso.timeZone = f.timeZone; iso.dateFormat = "yyyy-MM-dd HH:mm"
            return ["simdi": f.string(from: Date()), "iso": iso.string(from: Date())]
        case "hava_durumu":
            return await weather(sehir: (a["sehir"] as? String).flatMap { $0.isEmpty ? nil : $0 }, gun: a["gun"] as? String ?? "bugun")
        case "zamanlayici":
            switch a["islem"] as? String {
            case "kur":
                let s = (a["sure_saniye"] as? Int) ?? 0
                guard (1...86_400).contains(s) else { return ["hata": "sure_saniye 1–86400 olmalı."] }
                return await Timers.shared.set(seconds: s, label: (a["etiket"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Zamanlayıcı")
            case "listele": return Timers.shared.list()
            case "iptal": return Timers.shared.cancelLast()
            default: return ["hata": "islem: kur | listele | iptal"]
            }
        case "telefon": return Phone.status(a)
        case "takvim": return await Calendar2.events(a)
        case "animsatici": return await Calendar2.reminders(a)
        case "kestirme_calistir":
            guard let s = shortcuts.first(where: { $0.name == (a["ad"] as? String) }) else {
                return ["hata": "İzin listesinde böyle bir Kestirme yok."]
            }
            if s.confirm {
                let ok = await host.confirm(title: "Kestirme çalıştırılsın mı?", message: "\(s.name)\n\(s.about)")
                guard ok else { return ["durum": "kullanıcı onaylamadı"] }
            }
            return await ShortcutRunner.shared.run(name: s.name, input: a["girdi"] as? String)
        default:
            return ["hata": "Bilinmeyen araç: \(name)"]
        }
    }

    // MARK: Hava (Open-Meteo, anahtarsız)

    private static let wmo: [Int: String] = [
        0: "açık", 1: "çoğunlukla açık", 2: "parçalı bulutlu", 3: "kapalı", 45: "sisli", 48: "kırağılı sis",
        51: "hafif çisenti", 53: "çisenti", 55: "yoğun çisenti", 61: "hafif yağmur", 63: "yağmur", 65: "şiddetli yağmur",
        66: "donan yağmur", 67: "şiddetli donan yağmur", 71: "hafif kar", 73: "kar", 75: "yoğun kar", 77: "kar taneleri",
        80: "hafif sağanak", 81: "sağanak", 82: "şiddetli sağanak", 85: "kar sağanağı", 86: "yoğun kar sağanağı",
        95: "gök gürültülü fırtına", 96: "dolu ile fırtına", 99: "şiddetli dolu ile fırtına",
    ]

    private static func json(_ url: URL) async -> [String: Any]? {
        guard let (d, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func weather(sehir: String?, gun: String) async -> [String: Any] {
        var lat = 39.93, lon = 32.86, place = "Ankara"
        if let sehir {
            let q = sehir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sehir
            guard let g = await json(URL(string: "https://geocoding-api.open-meteo.com/v1/search?count=1&language=tr&name=\(q)")!),
                  let r = (g["results"] as? [[String: Any]])?.first else { return ["hata": "\"\(sehir)\" bulunamadı."] }
            lat = r["latitude"] as? Double ?? lat; lon = r["longitude"] as? Double ?? lon
            place = [r["name"], r["admin1"]].compactMap { $0 as? String }.joined(separator: ", ")
        } else if let loc = await LocationFetcher().current() {
            lat = loc.coordinate.latitude; lon = loc.coordinate.longitude
            let marks = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "tr_TR"))
            place = [marks?.first?.subLocality, marks?.first?.locality].compactMap { $0 }.joined(separator: ", ")
            if place.isEmpty { place = "bulunduğun yer" }
        } else {
            Log.w("konum alınamadı, Ankara kullanıldı")
            place = "Ankara (konum alınamadı)"
        }
        let u = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&timezone=Europe%2FIstanbul&forecast_days=7"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum"
        guard let w = await json(URL(string: u)!), let d = w["daily"] as? [String: Any],
              let times = d["time"] as? [String] else { return ["hata": "Hava servisine ulaşılamadı."] }
        func arr(_ k: String) -> [Double] { (d[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
        let code = arr("weather_code"), mx = arr("temperature_2m_max"), mn = arr("temperature_2m_min"), pp = arr("precipitation_probability_max")
        func day(_ i: Int) -> [String: Any] {
            ["tarih": times[i], "durum": wmo[Int(code[i])] ?? "kod \(Int(code[i]))", "en_yuksek": Int(mx[i].rounded()),
             "en_dusuk": Int(mn[i].rounded()), "yagis_ihtimali_yuzde": Int(pp[i])]
        }
        var out: [String: Any] = ["yer": place]
        out["gunler"] = gun == "hafta" ? times.indices.map(day) : [day(gun == "yarin" ? 1 : 0)]
        if gun == "bugun", let c = w["current"] as? [String: Any] {
            func n(_ k: String) -> Int { Int(((c[k] as? NSNumber)?.doubleValue ?? 0).rounded()) }
            out["simdi"] = ["sicaklik": n("temperature_2m"), "hissedilen": n("apparent_temperature"), "nem_yuzde": n("relative_humidity_2m"),
                            "ruzgar_kmh": n("wind_speed_10m"), "durum": wmo[n("weather_code")] ?? ""]
        }
        return out
    }
}

/// Gemini 3.x Live ücretli katman, USD / 1M token (masaüstündeki pricing.js ile aynı). Tahmin; ücretsiz katmanda fatura 0.
enum Pricing {
    static let input: [String: Double] = ["TEXT": 0.75, "AUDIO": 3.0, "IMAGE": 1.0, "VIDEO": 1.0]
    static let output: [String: Double] = ["TEXT": 4.5, "AUDIO": 12.0]
    static let thoughts = 4.5
    nonisolated(unsafe) static var usdTry = 49.06 // TCMB'den açılışta güncellenir

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

    /// gemini-3.5-transcribe-live: ses girdi $3,50 / 1M, metin çıktı $21 / 1M (paralel döküm, ön-seçim kipi).
    static func usdTranscribe(_ u: [String: Any]) -> Double {
        (Double((u["promptTokenCount"] as? Int) ?? 0) * 3.5 + Double((u["responseTokenCount"] as? Int) ?? 0) * 21) / 1_000_000
    }

    static func refreshRate() async {
        guard let url = URL(string: "https://www.tcmb.gov.tr/kurlar/today.xml"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              let r = xml.range(of: #"Kod="USD"[\s\S]*?<ForexSelling>[\d.]+"#, options: .regularExpression)
        else { Log.w("TCMB kuru alınamadı, yedek kur: \(usdTry)"); return }
        let block = String(xml[r])
        if let m = block.range(of: #"[\d.]+$"#, options: .regularExpression), let v = Double(block[m]), v > 0 {
            usdTry = v
            Log.i("kur: \(v) (TCMB)")
        }
    }
}
