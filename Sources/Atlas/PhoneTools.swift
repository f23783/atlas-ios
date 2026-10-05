import CoreLocation
import EventKit
import Foundation
import UIKit
import UserNotifications

/// Araçların uygulamadan istediği şeyler (Assistant sağlar).
@MainActor
protocol ToolHost: AnyObject {
    /// Kullanıcıya ekranda Evet/Hayır sor (dışarıya dönük işler için; modelin "onaylandı" demesine güvenilmez).
    func confirm(title: String, message: String) async -> Bool
    /// Uygulamadan modele bilgi (zamanlayıcı bitti vb.); model kullanıcıya sesli iletir.
    func announce(_ text: String)
}

// MARK: - Kestirmeler

struct AllowedShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var about: String
    var confirm: Bool
}

/// shortcuts://x-callback-url ile Kestirme çalıştırır ve atlas://kestirme/<durum>/<jeton> dönüşünü bekler.
/// iOS kuralı: arka plandaki uygulama başka uygulama açamaz → telefon kilitliyken çalışmaz.
@MainActor
final class ShortcutRunner {
    static let shared = ShortcutRunner()
    private var waiting: CheckedContinuation<[String: Any], Never>?
    private var token = ""

    func run(name: String, input: String?) async -> [String: Any] {
        guard UIApplication.shared.applicationState == .active else {
            return ["hata": "Telefon kilitli ya da Atlas arka planda. Kestirme için kullanıcının kilidi açıp Atlas'ı öne getirmesi gerekiyor."]
        }
        if let w = waiting { w.resume(returning: ["durum": "yerine yenisi çalıştı"]); waiting = nil }
        token = String(UUID().uuidString.prefix(8))
        var c = URLComponents()
        c.scheme = "shortcuts"; c.host = "x-callback-url"; c.path = "/run-shortcut"
        c.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input ?? ""),
            URLQueryItem(name: "x-success", value: "atlas://kestirme/basarili/\(token)"),
            URLQueryItem(name: "x-error", value: "atlas://kestirme/hata/\(token)"),
            URLQueryItem(name: "x-cancel", value: "atlas://kestirme/iptal/\(token)"),
        ]
        guard let url = c.url else { return ["hata": "Adres oluşturulamadı"] }
        Log.i("kestirme → \(name)")
        guard await UIApplication.shared.open(url) else { return ["hata": "Kestirmeler uygulaması açılamadı"] }
        let t = token
        return await withCheckedContinuation { cont in
            waiting = cont
            Task {
                try? await Task.sleep(for: .seconds(45))
                if self.token == t, let w = self.waiting { self.waiting = nil; w.resume(returning: ["durum": "zaman aşımı (45 sn)"]) }
            }
        }
    }

    /// atlas://kestirme/... → true (işlendi)
    func handle(_ url: URL) -> Bool {
        guard url.host == "kestirme" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        let state = parts.first ?? "?"
        guard parts.count >= 2, parts[1] == token, let w = waiting else { return true }
        waiting = nil
        var out: [String: Any] = ["durum": state]
        for q in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[q.name] = q.value ?? "" }
        Log.i("kestirme ← \(state) \(out)")
        w.resume(returning: out)
        return true
    }
}

// MARK: - Konum (hava için)

final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?

    func current() async -> CLLocation? {
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                self.cont = c
                self.manager.delegate = self
                self.manager.desiredAccuracy = kCLLocationAccuracyKilometer
                switch self.manager.authorizationStatus {
                case .notDetermined: self.manager.requestWhenInUseAuthorization()
                case .denied, .restricted: self.finish(nil)
                default: self.manager.requestLocation()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.finish(nil) }
            }
        }
    }

    private func finish(_ l: CLLocation?) {
        cont?.resume(returning: l)
        cont = nil
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted: finish(nil)
        default: break
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { finish(l.last) }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { Log.w("konum: \(e.localizedDescription)"); finish(nil) }
}

// MARK: - Zamanlayıcı (yerel bildirim: uygulama kapalıyken de çalar)

@MainActor
final class Timers {
    static let shared = Timers()
    private var seq = 0
    private var live: [String: (label: String, due: Date)] = [:]
    weak var host: ToolHost?

    func set(seconds: Int, label: String) async -> [String: Any] {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        if !granted { Log.w("bildirim izni yok: zamanlayıcı yalnız uygulama açıkken sesli haber verir") }
        seq += 1
        let id = "atlas-timer-\(Int(Date().timeIntervalSince1970))-\(seq)"
        let content = UNMutableNotificationContent()
        content.title = "⏰ Zamanlayıcı"
        content.body = label
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)))
        let due = Date().addingTimeInterval(TimeInterval(seconds))
        live[id] = (label, due)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if self.live.removeValue(forKey: id) != nil {
                self.host?.announce("\"\(label)\" zamanlayıcısının süresi doldu. Kullanıcıya kısaca haber ver.")
            }
        }
        return ["kuruldu": ["etiket": label, "sure_saniye": seconds, "bildirim": granted]]
    }

    func list() -> [String: Any] {
        ["zamanlayicilar": live.map { ["etiket": $0.value.label, "kalan_saniye": max(0, Int($0.value.due.timeIntervalSinceNow))] }]
    }

    func cancelLast() -> [String: Any] {
        guard let last = live.max(by: { $0.key < $1.key }) else { return ["hata": "İptal edilecek zamanlayıcı yok."] }
        live.removeValue(forKey: last.key)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [last.key])
        return ["iptal_edildi": last.value.label]
    }
}

// MARK: - Takvim ve anımsatıcılar

@MainActor
enum Calendar2 {
    static let store = EKEventStore()
    static let tz = TimeZone(identifier: "Europe/Istanbul")!

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        for f in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = tz; df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    static func show(_ d: Date, time: Bool = true) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "tr_TR"); df.timeZone = tz
        df.dateFormat = time ? "d MMMM EEEE HH:mm" : "d MMMM EEEE"
        return df.string(from: d)
    }

    /// "bugun" | "yarin" | "hafta" | "YYYY-MM-DD"
    static func range(_ gun: String?) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let today = cal.startOfDay(for: Date())
        switch gun ?? "bugun" {
        case "yarin": let s = cal.date(byAdding: .day, value: 1, to: today)!; return (s, cal.date(byAdding: .day, value: 1, to: s)!)
        case "hafta": return (today, cal.date(byAdding: .day, value: 7, to: today)!)
        case let x: if let d = parse(x) { let s = cal.startOfDay(for: d); return (s, cal.date(byAdding: .day, value: 1, to: s)!) }
            return (today, cal.date(byAdding: .day, value: 1, to: today)!)
        }
    }

    static func events(_ a: [String: Any]) async -> [String: Any] {
        guard (try? await store.requestFullAccessToEvents()) == true else { return ["hata": "Takvim izni yok (Ayarlar → Atlas → Takvimler)."] }
        let islem = a["islem"] as? String ?? "listele"
        if islem == "ekle" {
            guard let title = a["baslik"] as? String, let start = parse(a["baslangic"] as? String) else {
                return ["hata": "ekle için baslik ve baslangic ('YYYY-MM-DD HH:MM') gerekli."]
            }
            let e = EKEvent(eventStore: store)
            e.title = title
            e.startDate = start
            e.endDate = start.addingTimeInterval(Double((a["sure_dakika"] as? Int) ?? 60) * 60)
            if let loc = a["konum"] as? String { e.location = loc }
            e.calendar = store.defaultCalendarForNewEvents
            do { try store.save(e, span: .thisEvent) } catch { return ["hata": error.localizedDescription] }
            return ["eklendi": ["baslik": title, "zaman": show(start)]]
        }
        let (s, eDate) = range(a["gun"] as? String)
        let list = store.events(matching: store.predicateForEvents(withStart: s, end: eDate, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .prefix(25)
            .map { ev -> [String: Any] in
                ["baslik": ev.title ?? "", "zaman": ev.isAllDay ? show(ev.startDate, time: false) + " (tüm gün)" : show(ev.startDate), "konum": ev.location ?? ""]
            }
        return ["aralik": "\(show(s, time: false)) – \(show(eDate.addingTimeInterval(-1), time: false))", "etkinlikler": Array(list)]
    }

    static func reminders(_ a: [String: Any]) async -> [String: Any] {
        guard (try? await store.requestFullAccessToReminders()) == true else { return ["hata": "Anımsatıcılar izni yok (Ayarlar → Atlas → Anımsatıcılar)."] }
        let islem = a["islem"] as? String ?? "listele"
        if islem == "ekle" {
            guard let title = a["baslik"] as? String, !title.isEmpty else { return ["hata": "ekle için baslik gerekli."] }
            let r = EKReminder(eventStore: store)
            r.title = title
            r.calendar = store.defaultCalendarForNewReminders()
            if let d = parse(a["tarih"] as? String) {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                r.dueDateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                r.addAlarm(EKAlarm(absoluteDate: d))
            }
            do { try store.save(r, commit: true) } catch { return ["hata": error.localizedDescription] }
            return ["eklendi": title]
        }
        let open: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { c.resume(returning: $0 ?? []) }
        }
        if islem == "tamamla" {
            let q = (a["baslik"] as? String ?? "").lowercased()
            guard !q.isEmpty, let r = open.first(where: { ($0.title ?? "").lowercased().contains(q) }) else { return ["hata": "Eşleşen açık anımsatıcı yok."] }
            r.isCompleted = true
            do { try store.save(r, commit: true) } catch { return ["hata": error.localizedDescription] }
            return ["tamamlandi": r.title ?? ""]
        }
        return ["acik_animsaticilar": open.prefix(30).map { r -> [String: Any] in
            var o: [String: Any] = ["baslik": r.title ?? ""]
            if let d = r.dueDateComponents?.date { o["zaman"] = show(d) }
            return o
        }]
    }
}

// MARK: - Telefon durumu

@MainActor
enum Phone {
    static func status(_ a: [String: Any]) -> [String: Any] {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        if (a["islem"] as? String) == "parlaklik_ayarla" {
            guard UIApplication.shared.applicationState == .active, let screen else { return ["hata": "Parlaklık yalnız Atlas öndeyken ayarlanabilir."] }
            let v = max(0, min(100, (a["deger"] as? Int) ?? 50))
            screen.brightness = CGFloat(v) / 100
            return ["parlaklik_yuzde": v]
        }
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        let state: String = switch dev.batteryState {
        case .charging: "şarj oluyor"
        case .full: "dolu"
        case .unplugged: "pilden"
        default: "bilinmiyor"
        }
        let thermal: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "normal"
        case .fair: "ılık"
        case .serious: "sıcak"
        case .critical: "çok sıcak"
        @unknown default: "bilinmiyor"
        }
        var out: [String: Any] = [
            "pil_yuzde": dev.batteryLevel < 0 ? -1 : Int((dev.batteryLevel * 100).rounded()),
            "pil_durumu": state,
            "dusuk_guc_modu": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "isi": thermal,
            "ios": dev.systemVersion,
        ]
        if let screen { out["parlaklik_yuzde"] = Int((screen.brightness * 100).rounded()) }
        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity {
            out["depolama_bos_gb"] = Double(free / 100_000_000) / 10
            out["depolama_toplam_gb"] = Double(total / 100_000_000) / 10
        }
        return out
    }
}
