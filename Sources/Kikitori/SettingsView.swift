import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case recording, shortcuts, display, transcription, storage, general

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recording: return "録音"
        case .shortcuts: return "ショートカット"
        case .display: return "表示と通知"
        case .transcription: return "文字起こし"
        case .storage: return "保存先"
        case .general: return "一般"
        }
    }
    var icon: String {
        switch self {
        case .recording: return "mic"
        case .shortcuts: return "keyboard"
        case .display: return "eye"
        case .transcription: return "text.bubble"
        case .storage: return "folder"
        case .general: return "gearshape"
        }
    }
}

/// 左にカテゴリ(幅固定)、右に各設定。右側はウィンドウに収まらなければスクロールする
struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @AppStorage("settingsPane") private var pane: SettingsPane = .recording
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var micAuthorized = false
    @State private var screenAuthorized = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            Form {
                switch pane {
                case .recording: recordingPane
                case .shortcuts: shortcutsPane
                case .display: displayPane
                case .transcription: transcriptionPane
                case .storage: storagePane
                case .general: generalPane
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - 各ペイン

    @ViewBuilder
    private var recordingPane: some View {
        Section("録音ソース") {
            Picker("録音する音", selection: $settings.audioSource) {
                ForEach(AudioSource.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if settings.audioSource.usesSystem {
                caption("オンライン会議では、ヘッドホンを使うと相手の声が二重に入りにくくなります。")
            }
        }
        Section("macOS の許可") {
            permissionRow("マイク", granted: micAuthorized, needed: settings.audioSource.usesMic,
                          pane: "Privacy_Microphone")
            permissionRow("画面収録とシステムオーディオ録音", granted: screenAuthorized,
                          needed: settings.audioSource.usesSystem, pane: "Privacy_ScreenCapture")
            caption("PCの音の許可は、オンにしたあとアプリの再起動が必要です。")
        }
    }

    @ViewBuilder
    private var shortcutsPane: some View {
        Section {
            ForEach(HotkeyAction.allCases) { action in
                LabeledContent {
                    HotkeyRecorder(settings: settings, action: action)
                } label: {
                    Text(action.label)
                    if settings.failedHotkeys.contains(action) {
                        Text("他のアプリと衝突しているため使えません").foregroundStyle(.red)
                    }
                }
            }
        } footer: {
            caption("どのアプリを使っていても反応します。⌃ ⌥ ⌘ のいずれかを含む組み合わせを登録できます。")
        }
        Section("それぞれの動き") {
            caption("録音の開始 / 終了: 終了すると自動で文字起こしが始まります。")
            caption("一時停止 / 再開: 止めている間の音は録音されません。")
            caption("録音を破棄: 録音を macOS のゴミ箱に移します。ゴミ箱から元に戻せます。")
            caption("録音状態の表示: 押すたびに、画面上部の表示を出したり消したりします。表示には録音時間と音量が出て、ボタンで一時停止・終了・削除もできます。")
        }
    }

    @ViewBuilder
    private var displayPane: some View {
        Section("メニューバー") {
            Picker("録音中の表示", selection: $settings.indicatorMode) {
                ForEach(IndicatorMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if settings.indicatorMode == .hidden {
                caption("アイコン非表示中に設定を開くには、Finder や Spotlight から Kikitori をもう一度開いてください。")
            }
            caption("macOS 自体のマイク使用中・画面収録中の表示(メニューバー右上の点や矢印)は、OS の仕様で常に表示されます。")
        }
        Section("音と通知") {
            Toggle("開始・停止時に効果音を鳴らす", isOn: $settings.playSounds)
            Toggle("文字起こし完了を通知する", isOn: $settings.notifyOnComplete)
        }
    }

    @ViewBuilder
    private var transcriptionPane: some View {
        Section("ファイルから文字起こし") {
            VStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("録画・音声ファイルをここにドロップ")
                Button("ファイルを選ぶ…") {
                    NotificationCenter.default.post(name: .kikitoriTranscribeFiles, object: nil)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            )
            .dropDestination(for: URL.self) { urls, _ in
                NotificationCenter.default.post(name: .kikitoriTranscribeFiles, object: urls)
                return !urls.isEmpty
            } isTargeted: { dropTargeted = $0 }
            caption("mp4・mov などの動画や、m4a・mp3・wav などの音声に対応しています。Finder で右クリック →「このアプリケーションで開く」→ Kikitori でも文字起こしできます。結果は保存先フォルダに作られ、複数のファイルは1件ずつ順番に処理します。")
        }
        Section("文字起こし") {
            Picker("言語", selection: $settings.language) {
                ForEach(TranscriptLanguage.allCases) { Text($0.label).tag($0) }
            }
            TextField("語彙ヒント", text: $settings.prompt, prompt: Text("固有名詞や専門用語など (任意)"), axis: .vertical)
                .lineLimit(2...5)
            caption("会議でよく出る人名・社名・専門用語を書いておくと、表記が正しくなりやすくなります。")
        }
        Section("完了後") {
            Toggle("クリップボードにコピー", isOn: $settings.copyToClipboard)
        }
    }

    @ViewBuilder
    private var storagePane: some View {
        Section("保存先") {
            LabeledContent("フォルダ") {
                Text(abbreviated(settings.outputDirectory))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Finder で開く") {
                    try? FileManager.default.createDirectory(at: settings.outputURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(settings.outputURL)
                }
                Button("変更…", action: chooseOutputDirectory)
            }
        }
        Section {
            Toggle(isOn: $settings.keepAudio) {
                Text("聞き返し用の音声 (.m4a)")
                Text("マイクとPCの音を1本にまとめた圧縮音声。1時間で約45MB")
            }
            Toggle(isOn: $settings.keepRawTracks) {
                Text("元の音声 (.flac)")
                Text("マイクとPCの音を別々のファイルで、元の音質のまま保存。1時間で約500MB (マイク+PCの音の場合)")
            }
        } header: {
            Text("保存するファイル")
        } footer: {
            caption("文字起こしのテキスト (.txt) と字幕 (.srt) は常に保存されます。")
        }
        Section("文字起こしのモデル") {
            modelRow("Whisper モデル", path: (settings.modelPath as NSString).expandingTildeInPath)
            modelRow("無音判定 (VAD) モデル", path: Transcriber.vadModelPath)
        }
    }

    @ViewBuilder
    private var generalPane: some View {
        Section("起動") {
            Toggle("ログイン時に自動で起動", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
        }
        Section("このアプリについて") {
            LabeledContent("バージョン",
                           value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
            HStack {
                Spacer()
                Button("Kikitori を終了") { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - 部品

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(_ title: String, granted: Bool, needed: Bool, pane: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if granted {
                    Label("許可済み", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(needed ? "未許可" : "未許可 (今の設定では不要)", systemImage: "exclamationmark.circle")
                        .foregroundStyle(needed ? .orange : .secondary)
                    Button("システム設定を開く") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        } label: {
            Text(title)
        }
    }

    private func modelRow(_ title: String, path: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        return LabeledContent {
            HStack(spacing: 6) {
                Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(exists ? .green : .red)
                Text(exists ? (path as NSString).lastPathComponent : "見つかりません")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(abbreviated(path))
        } label: {
            Text(title)
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func refreshPermissions() {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenAuthorized = CGPreflightScreenCaptureAccess()
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectory = url.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// クリックしてからキーの組み合わせを押すと登録されるボタン
struct HotkeyRecorder: View {
    @ObservedObject var settings: Settings
    let action: HotkeyAction
    @State private var isCapturing = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(isCapturing ? "キーを押してください… (esc で取消)" : (settings.hotkeys[action]?.label ?? "未設定")) {
                isCapturing ? stop() : start()
            }
            .font(.system(.body, design: .monospaced))
            .disabled(settings.isCapturingHotkey && !isCapturing)

            // 開始/終了キーは必須。それ以外は解除できる
            if action != .toggle, settings.hotkeys[action] != nil, !isCapturing {
                Button {
                    settings.hotkeys[action] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("ショートカットを解除")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isCapturing = true
        settings.isCapturingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let modifiers = HotKey.carbonModifiers(from: event.modifierFlags)
            // ⌃ ⌥ ⌘ のいずれかを含む組み合わせだけ許可 (単独キーや⇧だけだと普段の入力と衝突する)
            let required = UInt32(controlKey | optionKey | cmdKey)
            let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                                        keyName: HotKey.keyName(for: event))
            let usedByOther = settings.hotkeys.contains { $0.key != action && $0.value.keyCode == binding.keyCode
                && $0.value.modifiers == binding.modifiers }
            guard modifiers & required != 0, !usedByOther else {
                NSSound.beep()
                return nil
            }
            settings.hotkeys[action] = binding
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isCapturing {
            isCapturing = false
            settings.isCapturingHotkey = false
        }
    }
}
