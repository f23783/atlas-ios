import SwiftUI

// Masaüstündeki matugen paletinin (2026-10-05, darth-vader duvar kâğıdı) sabit karşılığı.
enum Palette {
    static let bg = Color(red: 0.102, green: 0.067, blue: 0.063)
    static let raised = Color(red: 0.153, green: 0.114, blue: 0.110)
    static let text = Color(red: 0.945, green: 0.871, blue: 0.863)
    static let muted = Color(red: 0.847, green: 0.761, blue: 0.749)
    static let accent = Color(red: 1.0, green: 0.706, blue: 0.671)
    static let accentSoft = Color(red: 0.451, green: 0.200, blue: 0.176)
    static let user = Color(red: 0.878, green: 0.765, blue: 0.549)
    static let userSoft = Color(red: 0.345, green: 0.267, blue: 0.098)
}

struct ContentView: View {
    @EnvironmentObject var a: Assistant
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false
    @State private var showLog = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Orb().frame(height: 220).onTapGesture { a.toggle() }
            Text(hint).font(.callout).foregroundStyle(Palette.text).padding(.top, 2)
            Text("\(settings.model) · \(settings.voice) · bellek \(settings.contextLimit / 1000)k")
                .font(.caption2).foregroundStyle(Palette.muted.opacity(0.7))
            transcript
            bar
        }
        .background(Palette.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings) }
        .sheet(isPresented: $showLog) { LogView().environmentObject(Log.shared) }
        .alert(a.pendingConfirm?.title ?? "", isPresented: Binding(get: { a.pendingConfirm != nil }, set: { if !$0 && a.pendingConfirm != nil { a.answerConfirm(false) } })) {
            Button("Çalıştır") { a.answerConfirm(true) }
            Button("Vazgeç", role: .cancel) { a.answerConfirm(false) }
        } message: { Text(a.pendingConfirm?.message ?? "") }
        .alert("Atlas", isPresented: Binding(get: { a.error != nil }, set: { if !$0 { a.error = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: { Text(a.error ?? "") }
    }

    private var hint: String {
        switch a.conn {
        case .idle: return "Başlamak için dokun"
        case .connecting: return "Bağlanıyor…"
        case .reconnecting: return "Bağlantı yenileniyor…"
        case .open: return a.speaking ? "Konuşuyor" : (a.micOn ? "Dinliyorum" : "Mikrofon kapalı — yazabilirsin")
        }
    }

    private var header: some View {
        HStack {
            Text("Atlas").font(.headline).foregroundStyle(Palette.text)
            Spacer()
            Text(String(format: "₺%.2f · bugün ₺%.2f", a.sessionTRY, a.todayTRY).replacingOccurrences(of: ".", with: ","))
                .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
            Button { showLog = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                .foregroundStyle(Palette.muted).padding(.leading, 6)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .foregroundStyle(Palette.muted).padding(.horizontal, 6)
            HStack(spacing: 6) {
                Circle().fill(a.conn == .open ? Palette.accent : (a.conn == .idle ? Color.gray : Palette.user)).frame(width: 8, height: 8)
                Text(a.conn.rawValue).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Palette.raised, in: Capsule())
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if a.turns.isEmpty {
                        Text("Konuşma burada yazıya dökülecek.").font(.footnote).foregroundStyle(Palette.muted.opacity(0.6))
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    ForEach(a.turns) { t in
                        VStack(alignment: .leading, spacing: 6) {
                            if !t.user.isEmpty {
                                Text(t.user.trimmingCharacters(in: .whitespaces))
                                    .padding(10).background(Palette.userSoft, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            ForEach(t.chips, id: \.self) { c in
                                Text(c).font(.caption2).foregroundStyle(Palette.muted)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .overlay(Capsule().stroke(Palette.muted.opacity(0.4)))
                            }
                            if !t.model.isEmpty {
                                Text(t.model.trimmingCharacters(in: .whitespaces) + (t.cut ? " — kesildi" : ""))
                                    .padding(10).background(Palette.raised, in: RoundedRectangle(cornerRadius: 14))
                                    .opacity(t.cut ? 0.75 : 1)
                            }
                            if let tm = t.timing {
                                Text(tm).font(.caption2.monospacedDigit()).foregroundStyle(Palette.muted.opacity(0.75))
                            }
                        }
                        .foregroundStyle(Palette.text)
                        .id(t.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .onChange(of: a.turns.last?.model) { _, _ in if let id = a.turns.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            .onChange(of: a.turns.count) { _, _ in if let id = a.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Button { a.micOn.toggle() } label: {
                Image(systemName: a.micOn ? "mic.fill" : "mic.slash.fill").frame(width: 40, height: 40)
                    .background(a.micOn ? Palette.raised : Palette.accentSoft, in: Circle())
            }
            .foregroundStyle(a.micOn ? Palette.text : Palette.accent)
            .disabled(a.conn != .open)
            HStack {
                TextField("Yaz ya da konuş…", text: $draft).submitLabel(.send).onSubmit(submit)
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .foregroundStyle(Palette.accent)
            }
            .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
            .background(Palette.raised, in: Capsule())
            .disabled(a.conn != .open)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func submit() {
        a.send(text: draft)
        draft = ""
    }
}

/// Ses seviyesiyle dalgalanan orb (dinlerken kullanıcı rengi, konuşurken vurgu rengi).
struct Orb: View {
    @EnvironmentObject var a: Assistant
    @State private var lvl: Double = 0
    @State private var hue: Double = 0

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let active = a.conn == .open
                let speaking = active && a.audio.speaking
                let target = !active ? 0 : speaking ? Double(a.audio.outLevel) * 3.2 : Double(a.audio.inLevel) * 5
                let level = lvl + (min(target, 1) - lvl) * 0.18
                let mix = hue + ((speaking ? 1 : 0) - hue) * 0.08
                DispatchQueue.main.async { lvl = level; hue = mix }
                let pulse = (a.conn == .connecting || a.conn == .reconnecting) ? (sin(t * 4) + 1) / 2 : 0
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = active ? (mix > 0.5 ? Palette.accent : Palette.user) : Color.gray

                let glowR = 90 + level * 60 + pulse * 20
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                         with: .radialGradient(Gradient(colors: [base.opacity(active ? 0.35 + level * 0.3 : 0.15), .clear]),
                                               center: c, startRadius: 20, endRadius: glowR))
                for r in 0..<3 {
                    var p = Path()
                    let R = 62 + Double(r) * 11 + level * (14 + Double(r) * 8)
                    for k in 0...180 {
                        let ang = Double(k) / 180 * 2 * .pi
                        let wob = sin(ang * Double(3 + r) + t * (1.4 + Double(r) * 0.5)) * (1.5 + level * 9)
                        let pt = CGPoint(x: c.x + cos(ang) * (R + wob), y: c.y + sin(ang) * (R + wob))
                        k == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                    ctx.stroke(p, with: .color(base.opacity((active ? 0.55 : 0.3) - Double(r) * 0.14)), lineWidth: 2 - Double(r) * 0.4)
                }
                let coreR = 52 + level * 12 + pulse * 3
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
                         with: .radialGradient(Gradient(colors: [base.opacity(active ? 0.95 : 0.5), (active ? Palette.accentSoft : Color.gray).opacity(0.8)]),
                                               center: CGPoint(x: c.x - coreR * 0.3, y: c.y - coreR * 0.35), startRadius: 4, endRadius: coreR))
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var s: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Gemini API anahtarı", text: $s.geminiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("TypeSafe (Jev) anahtarı — Faz 3", text: $s.typesafeKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Anahtarlar") } footer: {
                    Text("Yalnız bu telefonun Keychain'inde saklanır; koda ve yedeklere girmez.")
                }
                ShortcutsSection()
                Section("Model") {
                    Picker("Model", selection: $s.model) {
                        ForEach(Catalog.models, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section {
                    Picker("Bellek", selection: $s.contextLimit) {
                        ForEach(Catalog.contextLimits, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: { Text("Konuşma belleği") } footer: {
                    Text("Live her turda belleğin tamamını faturalar; uzun bellek uzun konuşmayı pahalandırır.")
                }
                Section("Ses") {
                    Picker("Ses", selection: $s.voice) {
                        ForEach(Catalog.voices, id: \.0) { v in Text("\(v.0) — \(v.1)").tag(v.0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section { Text("Değişiklikler bir sonraki bağlantıda geçerli olur (ses ve model bağlantı anında sabitlenir).").font(.footnote) }
            }
            .navigationTitle("Ayarlar")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}


/// Hata günlüğü: bağlantı, kapanış kodları, izinler, araçlar. Paylaş ile metin olarak dışarı alınır.
struct LogView: View {
    @EnvironmentObject var log: Log
    @Environment(\.dismiss) private var dismiss
    @State private var onlyProblems = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(log.lines.filter { !onlyProblems || $0.level == "x" || $0.level == "!" }) { l in
                    Text(l.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(l.level == "x" ? Color.red : l.level == "!" ? Color.orange : l.level == "·" ? Color.secondary : Color.primary)
                        .id(l.id)
                        .textSelection(.enabled)
                }
                .listStyle(.plain)
                .onAppear { if let id = log.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .navigationTitle("Günlük")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Toggle("Yalnız sorunlar", isOn: $onlyProblems).toggleStyle(.button) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: log.all) { Image(systemName: "square.and.arrow.up") }
                    Button(role: .destructive) { log.clear() } label: { Image(systemName: "trash") }
                    Button("Bitti") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Atlas'ın çalıştırabileceği Kestirmeler. Listede olmayan çalışmaz; "onay" işaretliyse her seferinde ekranda sorulur.
struct ShortcutsSection: View {
    @EnvironmentObject var s: AppSettings
    @State private var name = ""
    @State private var about = ""
    @State private var confirm = true

    var body: some View {
        Section {
            ForEach(s.shortcuts) { sc in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(sc.name).bold()
                        if sc.confirm { Text("onaylı").font(.caption2).foregroundStyle(.orange) }
                    }
                    Text(sc.about).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { s.shortcuts.remove(atOffsets: $0) }
            TextField("Kestirme adı (Kestirmeler'deki gibi)", text: $name).textInputAutocapitalization(.never)
            TextField("Ne yapar? (Atlas buna bakarak seçer)", text: $about)
            Toggle("Her seferinde onay iste", isOn: $confirm)
            Button("Ekle") {
                s.shortcuts.append(AllowedShortcut(name: name.trimmingCharacters(in: .whitespaces), about: about, confirm: confirm))
                name = ""; about = ""; confirm = true
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || about.isEmpty)
        } header: { Text("Kestirmeler") } footer: {
            Text("Mesaj gönderme gibi dışarıya dönük işler için onayı açık bırak. Kestirmeler yalnız telefon kilidi açıkken çalışır. Değişiklik bir sonraki bağlantıda geçerli.")
        }
    }
}
