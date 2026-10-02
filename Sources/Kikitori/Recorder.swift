import Accelerate
import AVFoundation
import ScreenCaptureKit

enum KikitoriError: LocalizedError {
    case micPermissionDenied
    case noInputDevice
    case screenCapturePermission(Error)
    case noDisplay
    case toolNotFound(String)
    case modelNotFound(String)
    case toolFailed(String, Int32, String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "マイクの使用が許可されていません。システム設定 > プライバシーとセキュリティ > マイク で Kikitori を許可してください。"
        case .noInputDevice:
            return "マイク(入力デバイス)が見つかりません。"
        case .screenCapturePermission(let error):
            return "PCの音を録音できません。システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で Kikitori を許可し、アプリを再起動してください。\n(\(error.localizedDescription))"
        case .noDisplay:
            return "ディスプレイが見つからないため、PCの音を録音できません。"
        case .toolNotFound(let name):
            return "\(name) が見つかりません。`brew install \(name == "whisper-cli" ? "whisper-cpp" : name)` でインストールしてください。"
        case .modelNotFound(let path):
            return "Whisperモデルが見つかりません: \(path)"
        case .toolFailed(let name, let status, let output):
            return "\(name) が失敗しました (終了コード \(status))\n\(output)"
        case .noAudio:
            return "録音データがありません。"
        }
    }
}

/// 録音済みトラック。startHostTime は最初のサンプルのホスト時刻(秒)で、トラック間の時刻合わせに使う。
struct Track {
    let url: URL
    let startHostTime: Double?
}

/// PCMバッファを16bit CAFに書き出す。途中で音声が途切れた場合はホスト時刻に合わせて無音を挿入する。
/// 一時停止中のバッファは捨て、停止していた時間はタイムラインから除く。
final class AudioFileWriter {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private(set) var startHostTime: Double?
    private var pausedAt: Double?
    private var resumedAt: Double?
    private var pausedTotal: Double = 0
    private var currentLevel: Float = 0
    private var lastBufferAt: Date?

    init(url: URL) {
        self.url = url
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: Double?) {
        lock.lock()
        defer { lock.unlock() }
        // 状態確認の表示用。一時停止中も「音が届いているか」は追跡する
        lastBufferAt = Date()
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
            currentLevel = rms
        }
        if pausedAt != nil { return }
        if let hostTime, let resumedAt, hostTime < resumedAt { return }
        do {
            if file == nil {
                let format = buffer.format
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                startHostTime = hostTime
            }
            guard let file else { return }

            if let hostTime, let startHostTime {
                let rate = file.processingFormat.sampleRate
                let expected = AVAudioFramePosition((hostTime - startHostTime - pausedTotal) * rate)
                let gap = expected - framesWritten
                if gap > AVAudioFramePosition(rate * 0.1) {
                    try writeSilence(frames: gap, to: file)
                }
            }
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            NSLog("Kikitori: write failed \(url.lastPathComponent): \(error)")
        }
    }

    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile) throws {
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { return }
        let chunk: AVAudioFrameCount = 4096
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let channels = silence.floatChannelData else { return }
        for c in 0..<Int(format.channelCount) {
            channels[c].initialize(repeating: 0, count: Int(chunk))
        }
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            silence.frameLength = n
            try file.write(from: silence)
            remaining -= AVAudioFramePosition(n)
            framesWritten += AVAudioFramePosition(n)
        }
    }

    func pause(at hostTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        if pausedAt == nil { pausedAt = hostTime }
    }

    func resume(at hostTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let pausedAt else { return }
        // 書き込み開始前の停止は、開始時刻が後ろにずれるだけなので差し引かない
        if startHostTime != nil { pausedTotal += hostTime - pausedAt }
        self.pausedAt = nil
        resumedAt = hostTime
    }

    /// 直近のバッファの音量 (RMS) と最後にバッファが届いた時刻
    var meter: (level: Float, lastBufferAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        return (currentLevel, lastBufferAt)
    }

    func close() {
        lock.lock()
        file = nil // AVAudioFile は解放時にファイルを閉じる
        lock.unlock()
    }

    var track: Track? {
        lock.lock()
        defer { lock.unlock() }
        guard framesWritten > 0 else { return nil }
        return Track(url: url, startHostTime: startHostTime)
    }
}

// MARK: - マイク

final class MicCapture {
    private let engine = AVAudioEngine()
    let writer: AudioFileWriter

    init(url: URL) {
        writer = AudioFileWriter(url: url)
    }

    static func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw KikitoriError.micPermissionDenied
        default:
            throw KikitoriError.micPermissionDenied
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw KikitoriError.noInputDevice }
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let hostTime = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
            writer.write(buffer, hostTime: hostTime)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
    }
}

// MARK: - PCの音 (ScreenCaptureKit)

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "kikitori.system-audio")
    let writer: AudioFileWriter
    /// 録音中に macOS 側でストリームが止められた (権限の取り消しなど)
    private(set) var stoppedWithError = false

    init(url: URL) {
        writer = AudioFileWriter(url: url)
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw KikitoriError.screenCapturePermission(error)
        }
        guard let display = content.displays.first else { throw KikitoriError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // 映像は使わないので最小限に
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
        } catch {
            throw KikitoriError.screenCapturePermission(error)
        }
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        writer.close()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let hostTime = sampleBuffer.presentationTimeStamp.seconds
        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer) else { return }
            writer.write(buffer, hostTime: hostTime.isFinite ? hostTime : nil)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Kikitori: system audio stream stopped: \(error)")
        stoppedWithError = true
    }
}

// MARK: - 録音セッション

struct TrackStatus {
    let name: String
    /// RMS (0〜1)
    let level: Float
    let problem: String?
}

final class RecordingSession {
    let folder: URL
    let source: AudioSource
    let startDate = Date()
    private(set) var pausedSince: Date?
    private var pausedDuration: TimeInterval = 0
    private var mic: MicCapture?
    private var system: SystemAudioCapture?

    init(folder: URL, source: AudioSource) {
        self.folder = folder
        self.source = source
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if source.usesMic {
            try await MicCapture.ensurePermission()
        }
        if source.usesSystem {
            let system = SystemAudioCapture(url: folder.appendingPathComponent("system.caf"))
            try await system.start()
            self.system = system
        }
        if source.usesMic {
            let mic = MicCapture(url: folder.appendingPathComponent("mic.caf"))
            do {
                try mic.start()
            } catch {
                await system?.stop()
                throw error
            }
            self.mic = mic
        }
    }

    var isPaused: Bool { pausedSince != nil }

    /// 一時停止を除いた録音時間
    var elapsed: TimeInterval {
        Date().timeIntervalSince(startDate) - pausedDuration - (pausedSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// 状態確認の表示用に、各トラックの音量と異常を返す
    func trackStatuses() -> [TrackStatus] {
        let now = Date()
        // 開始直後はまだバッファが来ていないことがあるので、少し待ってから判定する
        let warmedUp = now.timeIntervalSince(startDate) > 2
        var result: [TrackStatus] = []
        if let mic {
            let meter = mic.writer.meter
            let stale = meter.lastBufferAt.map { now.timeIntervalSince($0) > 2 } ?? warmedUp
            result.append(TrackStatus(name: "マイク", level: stale ? 0 : meter.level,
                                      problem: stale ? "届いていません" : nil))
        }
        if let system {
            let meter = system.writer.meter
            let stale = meter.lastBufferAt.map { now.timeIntervalSince($0) > 2 } ?? warmedUp
            // PCの音は何も再生していないと届かないことがあるため、途切れただけでは警告しない
            result.append(TrackStatus(name: "PCの音", level: stale ? 0 : meter.level,
                                      problem: system.stoppedWithError ? "止まっています" : nil))
        }
        return result
    }

    /// 両トラックに同じホスト時刻を渡して、再開後もマイクとPCの音がずれないようにする
    func pause() {
        guard pausedSince == nil else { return }
        pausedSince = Date()
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        mic?.writer.pause(at: now)
        system?.writer.pause(at: now)
    }

    func resume() {
        guard let pausedSince else { return }
        pausedDuration += Date().timeIntervalSince(pausedSince)
        self.pausedSince = nil
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        mic?.writer.resume(at: now)
        system?.writer.resume(at: now)
    }

    func stop() async -> [Track] {
        mic?.stop()
        await system?.stop()
        return [mic?.writer.track, system?.writer.track].compactMap { $0 }
    }

    /// アプリ終了時用。ファイルだけ閉じて、次回起動時に文字起こしする。
    func closeFilesImmediately() {
        mic?.stop()
        system?.writer.close()
    }
}
