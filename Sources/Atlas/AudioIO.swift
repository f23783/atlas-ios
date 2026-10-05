import AVFoundation

/// Mikrofon (→ 16 kHz PCM16, 100 ms parçalar) + model sesi çalma (24 kHz PCM16).
/// Yankı engelleme: inputNode voice processing — telefon hoparlöründen çıkan Atlas sesi mikrofona "kullanıcı"
/// olarak geri girmesin (masaüstünde kulaklık önerisinin iPhone'daki çözümü).
final class AudioIO {
    var onChunk: ((Data) -> Void)?
    /// Son mikrofon seviyesi (RMS, 0…1) ve sesin eşiği son geçtiği an — orb ve "sustuktan sonra" ölçümü için.
    private(set) var inLevel: Float = 0
    private(set) var outLevel: Float = 0
    private(set) var lastVoiceAt: Date?
    static let voiceLevel: Float = 0.02

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var queuedFrames: Int64 = 0
    private var configured = false // düğümler bir kez bağlanır; kesinti sonrası yeniden başlatmada tekrar bağlamak çökertir
    private let lock = NSLock()
    var muted = false

    var speaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return queuedFrames > 0
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        if !configured {
            try input.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outFormat)
            configured = true
        }
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: micFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); queuedFrames = 0; lock.unlock()
        pending.removeAll()
    }

    // MARK: Mikrofon

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        // Seviye (orb + konuşma algısı)
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = (sum / Float(max(n, 1))).squareRoot()
            inLevel = muted ? 0 : rms
            if !muted && rms > Self.voiceLevel { lastVoiceAt = Date() }
        }
        guard !muted, let converter else { return }

        // 16 kHz Int16'ya çevir
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        pending.append(Data(bytes: p, count: Int(out.frameLength) * 2))
        // 100 ms = 1600 örnek = 3200 bayt (Google'ın önerdiği parça boyu)
        while pending.count >= 3200 {
            let chunk = pending.prefix(3200)
            pending.removeFirst(3200)
            onChunk?(Data(chunk))
        }
    }

    // MARK: Çalma

    func play(pcm16 data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let v = Float(src[i]) / 32768
                dst[i] = v
                sum += v * v
            }
        }
        outLevel = (sum / Float(frames)).squareRoot()
        lock.lock(); queuedFrames += Int64(frames); lock.unlock()
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedFrames = max(0, self.queuedFrames - Int64(frames)); self.lock.unlock()
            if !self.speaking { self.outLevel = 0 }
        }
    }

    /// Kullanıcı söze girdi: çalan ve kuyruktaki sesi hemen kes.
    func flush() {
        player.stop()
        lock.lock(); queuedFrames = 0; lock.unlock()
        outLevel = 0
        player.play()
    }
}
