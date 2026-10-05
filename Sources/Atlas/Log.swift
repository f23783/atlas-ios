import Foundation

/// Uygulama içi günlük: bağlantı, kapanış kodları, izinler, araçlar, hatalar. Dosyaya da yazılır
/// (Belgeler/atlas-log.txt), uygulama yeniden açılınca önceki oturumun satırları da görünür.
/// API anahtarı ASLA yazılmaz (bağlantı adresi günlüğe yalnız sunucu adıyla girer).
@MainActor
final class Log: ObservableObject {
    static let shared = Log()

    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let level: Character // i bilgi · ! uyarı · x hata · · önceki oturum
    }

    @Published private(set) var lines: [Line] = []
    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("atlas-log.txt")
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        if let old = try? String(contentsOf: file, encoding: .utf8) {
            let tail = old.split(separator: "\n").suffix(400)
            lines = tail.map { Line(text: String($0), level: "·") }
            if !lines.isEmpty { lines.append(Line(text: "──── yeni açılış ────", level: "·")) }
        }
    }

    func add(_ text: String, _ level: Character = "i") {
        let stamped = "\(fmt.string(from: Date())) \(level) \(text)"
        lines.append(Line(text: stamped, level: level))
        if lines.count > 1500 { lines.removeFirst(lines.count - 1500) }
        appendToFile(stamped + "\n")
    }

    /// Her iş parçacığından çağrılabilir.
    nonisolated static func i(_ text: String) { Task { @MainActor in shared.add(text, "i") } }
    nonisolated static func w(_ text: String) { Task { @MainActor in shared.add(text, "!") } }
    nonisolated static func e(_ text: String) { Task { @MainActor in shared.add(text, "x") } }

    var all: String { lines.map(\.text).joined(separator: "\n") }

    func clear() {
        lines.removeAll()
        try? "".write(to: file, atomically: true, encoding: .utf8)
    }

    private func appendToFile(_ s: String) {
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            let size = h.offsetInFile
            try? h.close()
            if size > 400_000 { // büyümesin: son 1000 satırı tut
                let keep = lines.suffix(1000).map(\.text).joined(separator: "\n") + "\n"
                try? keep.write(to: file, atomically: true, encoding: .utf8)
            }
        } else {
            try? s.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
