import SwiftUI

@main
struct AtlasProbeApp: App {
    @StateObject private var probe = Probe()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(probe)
                .onOpenURL { probe.handle($0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var probe: Probe

    var body: some View {
        NavigationStack {
            List {
                Section("1 · Kilitliyken dinleme") {
                    Text(probe.status).font(.callout)
                    HStack {
                        Button(probe.running ? "Durdur" : "Başlat") { probe.running ? probe.stop() : probe.start() }
                            .buttonStyle(.borderedProminent)
                        Button("Sıfırla", role: .destructive) { probe.reset() }
                            .buttonStyle(.bordered)
                    }
                    LabeledContent("Toplam ölçüm", value: "\(probe.samples.count)")
                    LabeledContent("Arka planda / kilitliyken", value: "\(probe.backgroundCount)")
                    LabeledContent("…bunların sesli olanı", value: "\(probe.backgroundVoiceCount)")
                        .foregroundStyle(probe.backgroundVoiceCount > 0 ? Color.green : Color.secondary)
                }

                Section("2 · Kestirme çalıştır ve geri dön") {
                    TextField("Kestirme adı", text: $probe.shortcutName)
                        .textInputAutocapitalization(.never)
                    Button("Kestirmeyi çalıştır") { probe.runShortcut() }
                    ForEach(Array(probe.callbacks.prefix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }

                Section("Son ölçümler") {
                    ForEach(Array(probe.samples.suffix(40).reversed())) { s in
                        HStack(spacing: 8) {
                            Text(Probe.stamp(s.time)).font(.caption.monospaced())
                            GeometryReader { g in
                                Capsule()
                                    .fill(s.level > Probe.voiceLevel ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: max(2, min(1, CGFloat(s.level) * 8) * g.size.width))
                            }
                            .frame(height: 6)
                            if s.background {
                                Text("kilitli/arka").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AtlasProbe")
        }
    }
}
