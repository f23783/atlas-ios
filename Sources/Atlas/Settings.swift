import Foundation
import Security

/// API anahtarları: koda ve IPA'ya girmez, kullanıcı uygulamada girer, iOS Keychain'de şifreli durur.
enum Keychain {
    private static let service = "com.f23783.atlas"

    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Masaüstü sürümündeki settings.js'in karşılığı (aynı seçenekler, aynı gerekçeler).
enum Catalog {
    static let voices: [(String, String)] = [
        ("Zephyr", "Parlak"), ("Puck", "Neşeli"), ("Charon", "Bilgilendirici"), ("Kore", "Kararlı"),
        ("Fenrir", "Heyecanlı"), ("Leda", "Genç"), ("Orus", "Kararlı"), ("Aoede", "Ferah"),
        ("Callirrhoe", "Rahat"), ("Autonoe", "Parlak"), ("Enceladus", "Nefesli"), ("Iapetus", "Net"),
        ("Umbriel", "Rahat"), ("Algieba", "Yumuşak"), ("Despina", "Yumuşak"), ("Erinome", "Net"),
        ("Algenib", "Boğuk"), ("Rasalgethi", "Bilgilendirici"), ("Laomedeia", "Neşeli"), ("Achernar", "Hafif"),
        ("Alnilam", "Kararlı"), ("Schedar", "Dengeli"), ("Gacrux", "Olgun"), ("Pulcherrima", "Atak"),
        ("Achird", "Samimi"), ("Zubenelgenubi", "Gündelik"), ("Vindemiatrix", "Nazik"), ("Sadachbia", "Canlı"),
        ("Sadaltager", "Bilgili"), ("Sulafat", "Sıcak"),
    ]
    static let models: [(id: String, label: String)] = [
        ("gemini-3.1-flash-live-preview", "3.1 Flash Live (şu an sorunsuz)"),
        ("gemini-3.8-live", "3.8 Live (en yeni)"),
        ("gemini-3.8-live-extended-thinking", "3.8 Live derin düşünen"),
    ]
    static let contextLimits: [(Int, String)] = [(8000, "8k · son ~5 dk"), (16000, "16k · son ~10 dk"), (32000, "32k · son ~20 dk")]

    static let systemInstruction = """
    Senin adın Atlas. Fido'nun sesli asistanısın ve onun iPhone'unda çalışıyorsun.
    Varsayılan dilin Türkçe; kullanıcı başka dilde konuşursa o dile geç.
    Konuşur gibi cevap ver: kısa cümleler, doğal tonlama. Liste, madde işareti, markdown kullanma.
    Emin değilsen söyle, uydurma.
    Canlı bilgi gerektiren sorularda (hava, saat, takvim, telefonun durumu) tahmin etme, aracı kullan.
    """
}

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var voice: String { didSet { d.set(voice, forKey: "voice") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var contextLimit: Int { didSet { d.set(contextLimit, forKey: "contextLimit") } }
    @Published var geminiKey: String { didSet { Keychain.set("gemini", geminiKey) } }
    @Published var typesafeKey: String { didSet { Keychain.set("typesafe", typesafeKey) } }
    /// Atlas'ın çalıştırabileceği Kestirmeler (izin listesi). Listede olmayan Kestirme çalıştırılamaz.
    @Published var shortcuts: [AllowedShortcut] {
        didSet { d.set(try? JSONEncoder().encode(shortcuts), forKey: "shortcuts") }
    }

    init() {
        voice = d.string(forKey: "voice") ?? "Kore"
        // 2026-10-05: 3.8 Live sunucu tarafında 1011 veriyordu, 3.1 Flash Live sorunsuzdu → varsayılan o.
        model = d.string(forKey: "model") ?? "gemini-3.1-flash-live-preview"
        let c = d.integer(forKey: "contextLimit")
        contextLimit = c == 0 ? 8000 : c
        geminiKey = Keychain.get("gemini")
        typesafeKey = Keychain.get("typesafe")
        shortcuts = (d.data(forKey: "shortcuts")).flatMap { try? JSONDecoder().decode([AllowedShortcut].self, from: $0) } ?? []
    }
}
