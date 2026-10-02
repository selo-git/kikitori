import AppKit
import SwiftUI

// 動作確認用: Kikitori --transcribe <音声ファイル> [<音声ファイル>…] で、録音済みファイルを文字起こしパイプラインに通す
// 複数渡すと、マイク + PCの音の録音として扱う (時刻合わせの確認用に、2本目以降は1.5秒ずつ遅れて始まったことにする)
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--transcribe" {
    let tracks = arguments[2...].enumerated().map { i, path in
        Track(url: URL(fileURLWithPath: path), startHostTime: Double(i) * 1.5)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kikitori-test-\(Int(Date().timeIntervalSince1970))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let options = TranscriptionOptions(language: "ja", prompt: "",
                                       keepAudio: true, keepRawTracks: true,
                                       modelPath: "\(home)/.cache/whisper-cpp/ggml-large-v3-turbo.bin",
                                       sourceLabel: "テスト")
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let result = try await Transcriber.process(folder: folder, tracks: tracks,
                                                       date: Date(), options: options)
            print(result.textURL.path)
            print(try String(contentsOf: result.textURL, encoding: .utf8))
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// 動作確認用: Kikitori --render-hud <フォルダ> で、録音状態の表示を状態ごとにPNGで書き出す
if arguments.count >= 3, arguments[1] == "--render-hud" {
    MainActor.assumeIsolated {
        let samples: [(String, RecorderStatus)] = [
            ("recording", RecorderStatus(state: .recording, elapsed: 754, tracks: [
                TrackStatus(name: "マイク", level: 0.12, problem: nil),
                TrackStatus(name: "PCの音", level: 0.03, problem: nil)])),
            ("paused", RecorderStatus(state: .paused, elapsed: 754)),
            ("warning", RecorderStatus(state: .recording, elapsed: 185, tracks: [
                TrackStatus(name: "マイク", level: 0.08, problem: nil),
                TrackStatus(name: "PCの音", level: 0, problem: "止まっています")])),
            ("idle", RecorderStatus(state: .idle, processingCount: 1)),
        ]
        for (name, status) in samples {
            let model = HUDModel()
            model.update(status)
            let renderer = ImageRenderer(content: HUDView(model: model).padding(14).background(Color(white: 0.75)))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arguments[2]).appendingPathComponent("hud-\(name).png"))
            }
        }
    }
    exit(0)
}

// 動作確認用: Kikitori --render-settings <フォルダ> で、設定画面の各ペインをPNGで書き出す
if arguments.count >= 3, arguments[1] == "--render-settings" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let sizes = [("large", NSSize(width: 760, height: 560)), ("small", NSSize(width: 620, height: 400))]
        for pane in SettingsPane.allCases {
            for (sizeName, size) in sizes where sizeName == "large" || pane == .recording || pane == .shortcuts {
                UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
                let hosting = NSHostingController(rootView: SettingsView())
                hosting.sizingOptions = [.minSize]
                let window = NSWindow(contentViewController: hosting)
                window.styleMask = [.titled, .closable, .resizable]
                window.setContentSize(size)
                window.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: arguments[2]).appendingPathComponent("settings-\(pane.rawValue)-\(sizeName).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                window.close()
            }
        }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
