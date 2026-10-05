import Foundation

/// Fido'nun ikinci beyni (FidoOS vault) — telefonda önbellek + az bağlamla arama (Atlas Kapısı'nın küçük hâli).
/// Kaynak: GitHub'daki özel repo (f23783/FidoOS), yalnız-okuma fine-grained token'la. Laptop oturum sonunda push eder.
/// Akış: bölümlere ayır → anahtar kelimeyle 8 aday → Jev her adaya "soruyu cevaplıyor mu?" (Noul) → en iyi 3 kısa parça.
/// Gemini'ye giden: en fazla ~3 × 600 karakter. Notların tamamı asla bağlama girmez.
@MainActor
final class Vault: ObservableObject {
    static let shared = Vault()
    static let repo = "f23783/FidoOS"
    /// Not olmayan teknik dosyalar (Fido: "her şeye ulaşabilir" — içerik için hariç tutma yok).
    static let skip = ["📋 Templates/", ".claude/", ".github/", "CLAUDE.md"]

    struct Section {
        let note: String     // dosya adı (uzantısız)
        let heading: String
        let modified: String
        let text: String
        let terms: Set<String>
        let headTerms: Set<String>
    }

    @Published private(set) var status = "Henüz eşitlenmedi"
    @Published private(set) var noteCount = 0
    private var sections: [Section] = []
    private var syncing = false
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // MARK: Eşitleme

    func sync(token: String) async {
        guard !token.isEmpty else { status = "GitHub token yok (Ayarlar)"; return }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        status = "Eşitleniyor…"
        do {
            let tree = try await api("https://api.github.com/repos/\(Self.repo)/git/trees/main?recursive=1", token: token)
            guard let items = (try JSONSerialization.jsonObject(with: tree) as? [String: Any])?["tree"] as? [[String: Any]] else {
                throw err("Ağaç okunamadı")
            }
            var index = loadIndex()
            var fresh: [String: String] = [:]
            var fetched = 0
            for it in items {
                guard (it["type"] as? String) == "blob", let path = it["path"] as? String, let sha = it["sha"] as? String,
                      path.hasSuffix(".md"), !Self.skip.contains(where: { path.hasPrefix($0) }) else { continue }
                fresh[path] = sha
                let file = dir.appendingPathComponent(sha + ".md")
                if index[path] == sha, FileManager.default.fileExists(atPath: file.path) { continue }
                let enc = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
                let body = try await api("https://api.github.com/repos/\(Self.repo)/contents/\(enc)?ref=main", token: token, raw: true)
                try body.write(to: file)
                fetched += 1
            }
            // silinen notların önbelleğini temizle
            for (path, sha) in index where fresh[path] != sha {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(sha + ".md"))
            }
            index = fresh
            saveIndex(index)
            build(index)
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            status = "\(noteCount) not · \(sections.count) bölüm · \(f.string(from: Date()))"
            Log.i("vault eşitlendi: \(noteCount) not, \(fetched) indirildi, \(sections.count) bölüm")
        } catch {
            status = "Eşitlenemedi: \(error.localizedDescription)"
            Log.e("vault eşitlenemedi: \(error.localizedDescription)")
            if sections.isEmpty { build(loadIndex()) } // çevrimdışıysa eski önbellekle devam
        }
    }

    func loadCached() {
        if sections.isEmpty { build(loadIndex()) }
        if noteCount > 0 { status = "\(noteCount) not (önbellek)" }
    }

    private func api(_ url: String, token: String, raw: Bool = false) async throws -> Data {
        var r = URLRequest(url: URL(string: url)!)
        r.timeoutInterval = 15
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(raw ? "application/vnd.github.raw" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw err(code == 401 || code == 403 ? "GitHub yetkisi reddetti (\(code)) — token'ı kontrol et" : "GitHub \(code)") }
        return d
    }

    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func loadIndex() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))) ?? [:]
    }
    private func saveIndex(_ i: [String: String]) { try? JSONEncoder().encode(i).write(to: indexURL) }

    // MARK: Bölümlere ayırma

    private func build(_ index: [String: String]) {
        var out: [Section] = []
        for (path, sha) in index {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(sha + ".md"), encoding: .utf8) else { continue }
            let note = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
            var body = text
            var modified = ""
            if body.hasPrefix("---"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
                let fm = String(body[body.startIndex..<end.lowerBound])
                if let m = fm.range(of: #"modified:\s*(\S+)"#, options: .regularExpression) {
                    modified = String(fm[m]).replacingOccurrences(of: "modified:", with: "").trimmingCharacters(in: .whitespaces)
                }
                body = String(body[end.upperBound...])
            }
            var heading = note
            var buf: [Substring] = []
            func flush() {
                let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                buf.removeAll()
                guard t.count > 40 else { return }
                // uzun bölümleri ~900 karakterlik parçalara böl
                var rest = Substring(t)
                while !rest.isEmpty {
                    let piece = String(rest.prefix(900))
                    rest = rest.dropFirst(900)
                    out.append(Section(note: note, heading: heading, modified: modified, text: piece,
                                       terms: Self.terms(piece), headTerms: Self.terms(note + " " + heading)))
                }
            }
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("#") {
                    flush()
                    heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                } else {
                    buf.append(line)
                }
            }
            flush()
        }
        sections = out
        noteCount = index.count
    }

    // MARK: Arama

    private static let stop: Set<String> = ["ve", "ile", "bir", "bu", "şu", "ne", "mi", "mı", "mu", "mü", "da", "de", "ki", "için",
                                            "gibi", "çok", "daha", "en", "ben", "sen", "benim", "nasıl", "neydi", "var", "yok", "olan", "ama"]

    /// Türkçe eklemeli dil: kelimenin ilk 5 harfi ("projeleri" ~ "proje", "başvurusu" ~ "başvuru").
    static func terms(_ s: String) -> Set<String> {
        let words = s.lowercased(with: Locale(identifier: "tr_TR")).split { !$0.isLetter && !$0.isNumber }
        return Set(words.filter { $0.count >= 3 && !stop.contains(String($0)) }.map { String($0.prefix(5)) })
    }

    func candidates(_ query: String, limit: Int = 8) -> [Section] {
        let q = Self.terms(query)
        guard !q.isEmpty, !sections.isEmpty else { return [] }
        let n = Double(sections.count)
        var df: [String: Double] = [:]
        for t in q { df[t] = Double(sections.filter { $0.terms.contains(t) || $0.headTerms.contains(t) }.count) }
        func score(_ s: Section) -> Double {
            q.reduce(0) { acc, t in
                let idf = log((n + 1) / ((df[t] ?? 0) + 1)) + 0.1
                return acc + (s.terms.contains(t) ? idf : 0) + (s.headTerms.contains(t) ? 2 * idf : 0)
            }
        }
        return sections.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// atlas_bak aracı: adaylar → Jev ile eleme (anahtar varsa) → en fazla 3 kısa parça.
    func search(_ query: String, jevKey: String) async -> [String: Any] {
        loadCached()
        guard !sections.isEmpty else { return ["hata": "Vault önbelleği boş: Ayarlar'dan GitHub token gir ve eşitle."] }
        let cands = candidates(query)
        guard !cands.isEmpty else { return ["bulunan": [] as [Any], "mesaj": "Notlarda bununla eşleşen bir şey yok."] }
        var chosen = Array(cands.prefix(3))
        var how = "anahtar kelime"
        if !jevKey.isEmpty, let ranked = try? await rerank(query, cands, key: jevKey) {
            chosen = ranked
            how = "Jev"
        }
        if chosen.isEmpty { return ["bulunan": [] as [Any], "mesaj": "Notlarda bu soruyu cevaplayan bir bölüm bulunamadı.", "yontem": how] }
        Log.i("atlas_bak \"\(query)\" → \(chosen.map { "\($0.note)/\($0.heading)" }.joined(separator: ", ")) (\(how))")
        return [
            "yontem": how,
            "bulunan": chosen.map { s -> [String: Any] in
                ["not": s.note, "bolum": s.heading, "guncelleme": s.modified, "metin": String(s.text.prefix(600))]
            },
        ]
    }

    /// Jev: her aday için Noul "bu bölüm soruyu cevaplamaya yardım eder mi?" (tek istek, paralel). ≥ 0,5 olanlardan en iyi 3.
    private func rerank(_ query: String, _ cands: [Section], key: String) async throws -> [Section] {
        guard JevLedger.totalUSD < JevLedger.budgetUSD - 0.001 else { throw err("Jev bütçesi doldu") }
        var state: [String: Any] = ["soru": query]
        var questions: [String: Any] = [:]
        for (i, s) in cands.enumerated() {
            state["b\(i)"] = "[\(s.note) — \(s.heading)] " + String(s.text.prefix(500))
            questions["b\(i)"] = [
                "type": "noul",
                "instructions": "`b\(i)` bölümü, `soru` alanındaki soruyu cevaplamak için gereken bilgiyi içeriyor mu?",
                "criteria": ["true": "Bölüm sorunun cevabını ya da doğrudan ilgili bilgiyi içeriyor.",
                             "false": "Bölüm konuyla ilgisiz ya da yalnız aynı kelimeleri tesadüfen içeriyor."],
            ]
        }
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": "jev-latest", "state": state, "questions": questions])
        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["answers"] as? [String: Any] else { throw err("Jev cevabı yok") }
        let tokens = (obj["usage"] as? [String: Any])?["input_tokens"] as? Int ?? 0
        _ = JevLedger.add(tokens: tokens)
        let scored = cands.enumerated().map { (i, s) -> (Section, Double) in
            let p = ((answers["b\(i)"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue ?? 0
            return (s, p)
        }
        Log.i("Jev vault elemesi \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(tokens) tok: " + scored.map { String(format: "%.2f", $0.1) }.joined(separator: " "))
        return scored.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    private func err(_ m: String) -> NSError { NSError(domain: "Vault", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}
