import AVFoundation
import Foundation

struct TranscriptionOptions {
    var language: String
    var prompt: String
    var keepAudio: Bool
    var keepRawTracks: Bool
    var modelPath: String
    var sourceLabel: String

    @MainActor
    static func current(source: AudioSource) -> TranscriptionOptions {
        let s = Settings.shared
        return TranscriptionOptions(language: s.language.rawValue, prompt: s.prompt, keepAudio: s.keepAudio,
                                    keepRawTracks: s.keepRawTracks,
                                    modelPath: (s.modelPath as NSString).expandingTildeInPath,
                                    sourceLabel: source.label)
    }
}

struct TranscriptResult {
    let textURL: URL
    let body: String
}

enum Transcriber {
    static let tempFileNames = ["mic.caf", "system.caf"]

    static var vadModelPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper-cpp/ggml-silero-v5.1.2.bin").path
    }

    /// 録音トラックをミックスして文字起こしし、<フォルダ名>.txt / .srt (/ .m4a) を作る
    static func process(folder: URL, tracks: [Track], date: Date, options: TranscriptionOptions) async throws -> TranscriptResult {
        guard !tracks.isEmpty else { throw KikitoriError.noAudio }
        guard let ffmpeg = Shell.find("ffmpeg") else { throw KikitoriError.toolNotFound("ffmpeg") }
        guard let whisper = Shell.find("whisper-cli") else { throw KikitoriError.toolNotFound("whisper-cli") }
        guard FileManager.default.fileExists(atPath: options.modelPath) else {
            throw KikitoriError.modelNotFound(options.modelPath)
        }

        let name = folder.lastPathComponent
        let base = folder.appendingPathComponent(name)
        let wav = folder.appendingPathComponent(".asr-16k.wav")
        let m4a = base.appendingPathExtension("m4a")

        // 1. ffmpeg: トラックの開始時刻を揃えて
        //    - 元の音声をトラック別に FLAC で保存 (音質はそのまま。開始のずれは先頭の無音で揃える)
        //    - ミックスして保存用 m4a + 認識用 16kHz wav
        let earliest = tracks.compactMap(\.startHostTime).min()
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
        for track in tracks { args += ["-i", track.url.path] }
        var filters: [String] = []
        var rawOutputs: [(label: String, url: URL)] = []
        for (i, track) in tracks.enumerated() {
            var aligned = "[\(i):a]"
            if tracks.count > 1, let start = track.startHostTime, let earliest {
                let delay = start - earliest
                if delay > 0.01 && delay < 5 {
                    filters.append("[\(i):a]adelay=\(Int(delay * 1000)):all=1[d\(i)]")
                    aligned = "[d\(i)]"
                }
            }
            if options.keepRawTracks {
                filters.append("\(aligned)asplit=2[s\(i)][raw\(i)]")
                aligned = "[s\(i)]"
                let stem = track.url.deletingPathExtension().lastPathComponent
                rawOutputs.append(("[raw\(i)]", folder.appendingPathComponent("\(name)_\(stem).flac")))
            }
            filters.append("\(aligned)aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=mono[a\(i)]")
        }
        if tracks.count > 1 {
            let inputs = tracks.indices.map { "[a\($0)]" }.joined()
            filters.append("\(inputs)amix=inputs=\(tracks.count):duration=longest:normalize=0,alimiter=limit=0.95[mix]")
        } else {
            filters.append("[a0]anull[mix]")
        }
        filters.append(options.keepAudio ? "[mix]asplit=2[keep][asr]" : "[mix]anull[asr]")
        filters.append("[asr]aresample=16000[a16]")
        args += ["-filter_complex", filters.joined(separator: ";")]
        if options.keepAudio {
            args += ["-map", "[keep]", "-c:a", "aac", "-b:a", "96k", m4a.path]
        }
        for raw in rawOutputs {
            args += ["-map", raw.label, "-c:a", "flac", "-sample_fmt", "s16", raw.url.path]
        }
        args += ["-map", "[a16]", "-ac", "1", "-c:a", "pcm_s16le", wav.path]
        _ = try await Shell.run(ffmpeg, args)

        let duration = (try? AVAudioFile(forReading: wav)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0

        // 2. whisper-cli で文字起こし (SRT出力)
        var wargs = ["-m", options.modelPath, "-f", wav.path, "-l", options.language,
                     "-osrt", "-of", base.path, "-np"]
        if !options.prompt.isEmpty { wargs += ["--prompt", options.prompt] }
        if FileManager.default.fileExists(atPath: vadModelPath) { wargs += ["--vad", "-vm", vadModelPath] }
        _ = try await Shell.run(whisper, wargs)

        // 3. SRT → タイムスタンプ付きテキスト
        let srtURL = base.appendingPathExtension("srt")
        let srt = (try? Data(contentsOf: srtURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let segments = parseSRT(srt)
        let lines = segments.map { "[\(timestamp($0.start))] \($0.text)" }
        let body = lines.isEmpty ? "(音声が検出されませんでした)" : lines.joined(separator: "\n")

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ja_JP")
        dateFormatter.dateFormat = "yyyy年M月d日(E) HH:mm:ss"
        let header = """
        日時: \(dateFormatter.string(from: date))
        長さ: \(timestamp(duration))
        録音ソース: \(options.sourceLabel)

        """
        let textURL = base.appendingPathExtension("txt")
        try (header + "\n" + body + "\n").write(to: textURL, atomically: true, encoding: .utf8)

        // 4. 一時ファイル削除
        try? FileManager.default.removeItem(at: wav)
        for track in tracks where track.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            try? FileManager.default.removeItem(at: track.url)
        }

        return TranscriptResult(textURL: textURL, body: body)
    }

    struct Segment {
        let start: Double
        let text: String
    }

    static func parseSRT(_ srt: String) -> [Segment] {
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [Segment] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let startString = lines[timeIndex].components(separatedBy: "-->")[0].trimmingCharacters(in: .whitespaces)
            let text = lines[(timeIndex + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let start = seconds(fromSRT: startString) else { continue }
            result.append(Segment(start: start, text: text))
        }
        return result
    }

    static func seconds(fromSRT s: String) -> Double? {
        // "HH:MM:SS,mmm"
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + sec
    }

    static func timestamp(_ seconds: Double) -> String {
        let t = Int(seconds)
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// 前回、録音中にアプリが終了した等で文字起こしされていないフォルダ
    static func unprocessedFolders(in root: URL, excluding active: URL?) -> [URL] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.filter { folder in
            guard folder.standardizedFileURL != active?.standardizedFileURL else { return false }
            let hasTemp = tempFileNames.contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let hasText = fm.fileExists(atPath: folder.appendingPathComponent(folder.lastPathComponent + ".txt").path)
            return hasTemp && !hasText
        }.sorted { $0.path < $1.path }
    }

    static func tracks(inFolder folder: URL) -> [Track] {
        tempFileNames
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Track(url: $0, startHostTime: nil) }
    }
}

enum Shell {
    static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let name = (path as NSString).lastPathComponent
                    continuation.resume(throwing: KikitoriError.toolFailed(name, process.terminationStatus,
                                                                           String(output.suffix(1000))))
                }
            }
        }
    }
}
