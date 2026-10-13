import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 文字起こしの順番待ち1件分
@MainActor
final class TranscriptionJob {
    let title: String
    var isRunning = false
    var progress: Double?

    init(title: String) {
        self.title = title
    }
}

extension Notification.Name {
    /// 設定画面などから、ファイルの文字起こしを依頼する (object: [URL] または nil = ファイル選択画面を出す)
    static let kikitoriTranscribeFiles = Notification.Name("KikitoriTranscribeFiles")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let hotKey = HotKey()
    private let hud = HUDController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    private var session: RecordingSession?
    private var isStarting = false
    /// 文字起こしは GPU を使うので、録音・ファイルとも1件ずつ順番に処理する
    private var jobs: [TranscriptionJob] = []
    private var queueTail: Task<Void, Never>?
    private var processingCount: Int { jobs.count }
    private var lastTranscript: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Kikitori"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKey.action = { [weak self] id, pressed in
            guard let action = HotkeyAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
            self?.perform(action, pressed: pressed)
        }
        hud.statusProvider = { [weak self] in self?.recorderStatus() ?? RecorderStatus() }
        hud.actions = HUDActions(
            start: { [weak self] in self?.startRecording() },
            togglePause: { [weak self] in self?.togglePause() },
            finish: { [weak self] in self?.stopRecording() },
            discard: { [weak self] in self?.discardRecording() }
        )
        registerHotKey()

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.registerHotKey()
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)

        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationHandler.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NotificationCenter.default.publisher(for: .kikitoriTranscribeFiles)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                if let urls = note.object as? [URL] {
                    self?.transcribeFiles(urls)
                } else {
                    self?.chooseFilesToTranscribe()
                }
            }
            .store(in: &cancellables)

        refreshStatusItem()
        recoverUnprocessed()

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showSettings()
        }
    }

    /// アイコン非表示モードでも、Finder/Spotlight から再度開けば設定画面を出す
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Finder の「このアプリケーションで開く」やアイコンへのドロップ
    func application(_ application: NSApplication, open urls: [URL]) {
        transcribeFiles(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.closeFilesImmediately()
    }

    // MARK: - 録音

    private func perform(_ action: HotkeyAction, pressed: Bool) {
        switch (action, pressed) {
        case (.peek, true):
            hud.toggle()
        case (_, false):
            break
        case (.toggle, true):
            toggleRecording()
        case (.pause, true):
            togglePause()
        case (.discard, true):
            discardRecording()
        }
    }

    private func recorderStatus() -> RecorderStatus {
        guard let session else {
            return RecorderStatus(state: .idle, processingCount: processingCount, processingProgress: currentProgress)
        }
        return RecorderStatus(state: session.isPaused ? .paused : .recording, elapsed: session.elapsed,
                              tracks: session.trackStatuses(), processingCount: processingCount,
                              processingProgress: currentProgress)
    }

    private var currentProgress: Double? {
        jobs.first(where: \.isRunning)?.progress
    }

    private func toggleRecording() {
        if session != nil {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard session == nil, !isStarting else { return }
        isStarting = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let folder = settings.outputURL.appendingPathComponent(formatter.string(from: Date()))
        let newSession = RecordingSession(folder: folder, source: settings.audioSource)

        Task {
            defer { isStarting = false }
            do {
                try await newSession.start()
                session = newSession
                playSound("Tink")
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshStatusItem() }
                }
                refreshStatusItem()
            } catch {
                _ = await newSession.stop()
                try? FileManager.default.removeItem(at: newSession.folder)
                showError("録音を開始できませんでした", error)
            }
        }
    }

    private func stopRecording() {
        guard let finished = session else { return }
        session = nil
        timer?.invalidate()
        timer = nil
        refreshStatusItem()

        Task {
            let tracks = await finished.stop()
            playSound("Pop")
            let options = TranscriptionOptions.current(source: finished.source)
            enqueue(title: "録音 \(finished.folder.lastPathComponent)") { job in
                await self.transcribe(folder: finished.folder, tracks: tracks, date: finished.startDate,
                                      options: options, job: job)
            }
        }
    }

    private func togglePause() {
        guard let session else { return }
        if session.isPaused {
            session.resume()
            playSound("Tink")
        } else {
            session.pause()
            playSound("Morse")
        }
        refreshStatusItem()
    }

    /// 録音を止めて、フォルダごと macOS のゴミ箱へ移す (ゴミ箱から元に戻せる)
    private func discardRecording() {
        guard let discarded = session else { return }
        session = nil
        timer?.invalidate()
        timer = nil
        refreshStatusItem()

        Task {
            _ = await discarded.stop()
            do {
                try FileManager.default.trashItem(at: discarded.folder, resultingItemURL: nil)
            } catch {
                try? FileManager.default.removeItem(at: discarded.folder)
            }
            playSound("Funk")
        }
    }

    /// 文字起こしを順番待ちに加える。前の文字起こしが終わってから始まる
    private func enqueue(title: String, work: @escaping (TranscriptionJob) async -> Void) {
        let job = TranscriptionJob(title: title)
        jobs.append(job)
        refreshStatusItem()
        let previous = queueTail
        queueTail = Task {
            await previous?.value
            job.isRunning = true
            await work(job)
            jobs.removeAll { $0 === job }
            refreshStatusItem()
        }
    }

    private func transcribe(folder: URL, tracks: [Track], date: Date, options: TranscriptionOptions,
                            job: TranscriptionJob) async {
        do {
            let result = try await Transcriber.process(folder: folder, tracks: tracks, date: date, options: options) { p in
                Task { @MainActor in job.progress = p }
            }
            lastTranscript = result.textURL
            if settings.copyToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.body, forType: .string)
            }
            if settings.notifyOnComplete {
                notify(title: "文字起こしが完了しました", body: String(result.body.prefix(120)), file: result.textURL)
            }
        } catch {
            NSLog("Kikitori: transcription failed: \(error)")
            notify(title: "文字起こしに失敗しました", body: "\(job.title)\n\(error.localizedDescription)", file: nil)
            // ファイルの文字起こしで何も作られなかった場合は、空のフォルダを残さない
            if options.originalFile != nil,
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    // MARK: - ファイルの文字起こし

    static let transcribableTypes: [UTType] = [.audio, .movie, .audiovisualContent]

    @objc private func chooseFilesToTranscribe() {
        let panel = NSOpenPanel()
        panel.title = "文字起こしする録画・音声ファイルを選択"
        panel.prompt = "文字起こし"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.transcribableTypes
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        transcribeFiles(panel.urls)
    }

    /// 1ファイルずつ保存フォルダに「<日時>_<元のファイル名>」のフォルダを作り、文字起こしを順番待ちに加える
    private func transcribeFiles(_ urls: [URL]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        for url in urls where !url.hasDirectoryPath {
            let type = UTType(filenameExtension: url.pathExtension)
            guard let type, Self.transcribableTypes.contains(where: { type.conforms(to: $0) }) else {
                notify(title: "文字起こしできないファイルです", body: "\(url.lastPathComponent) は録画・音声ファイルではありません。", file: nil)
                continue
            }
            let stem = String(url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(60))
            var folder = settings.outputURL.appendingPathComponent("\(stamp)_\(stem)")
            var n = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = settings.outputURL.appendingPathComponent("\(stamp)_\(stem)-\(n)")
                n += 1
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                notify(title: "文字起こしを開始できませんでした", body: error.localizedDescription, file: nil)
                continue
            }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let options = TranscriptionOptions.current(file: url)
            enqueue(title: url.lastPathComponent) { job in
                await self.transcribe(folder: folder, tracks: [Track(url: url, startHostTime: nil)], date: date,
                                      options: options, job: job)
            }
        }
    }

    /// 録音中にアプリが終了した場合などに残った録音を文字起こしする
    private func recoverUnprocessed() {
        for folder in Transcriber.unprocessedFolders(in: settings.outputURL, excluding: nil) {
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let options = TranscriptionOptions.current(source: settings.audioSource)
            enqueue(title: "録音 \(folder.lastPathComponent)") { job in
                await self.transcribe(folder: folder, tracks: Transcriber.tracks(inFolder: folder), date: date,
                                      options: options, job: job)
            }
        }
    }

    // MARK: - メニューバー

    private func refreshStatusItem() {
        guard let statusItem else { return }
        statusItem.isVisible = settings.indicatorMode != .hidden
        guard let button = statusItem.button else { return }

        if let session, settings.indicatorMode == .normal {
            let paused = session.isPaused
            let config = NSImage.SymbolConfiguration(paletteColors: [paused ? .systemOrange : .systemRed])
            button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill",
                                   accessibilityDescription: paused ? "一時停止中" : "録音中")?
                .withSymbolConfiguration(config)
            button.title = " " + elapsedText
            button.imagePosition = .imageLeading
        } else {
            let symbol = processingCount > 0 && settings.indicatorMode == .normal ? "text.bubble" : "waveform"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kikitori")
            image?.isTemplate = true
            button.image = image
            button.title = ""
        }
    }

    private var elapsedText: String {
        guard let session else { return "" }
        return formatElapsed(session.elapsed)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let session {
            status = session.isPaused ? "‖ 一時停止中 \(elapsedText)" : "● 録音中 \(elapsedText)"
        } else if processingCount > 0 {
            status = "文字起こし中… (\(processingCount)件)"
        } else {
            status = "待機中"
        }
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        for job in jobs {
            let detail = job.isRunning ? (job.progress.map { "\(Int($0 * 100))%" } ?? "準備中") : "順番待ち"
            let jobItem = NSMenuItem(title: "    \(job.title) — \(detail)", action: nil, keyEquivalent: "")
            jobItem.isEnabled = false
            menu.addItem(jobItem)
        }

        if let session {
            menu.addItem(item(withHotkey: session.isPaused ? "再開" : "一時停止", .pause, #selector(pauseFromMenu)))
            menu.addItem(item(withHotkey: "終了して文字起こし", .toggle, #selector(toggleFromMenu)))
            menu.addItem(item(withHotkey: "破棄してゴミ箱へ", .discard, #selector(discardFromMenu)))
        } else {
            menu.addItem(item(withHotkey: "録音を開始", .toggle, #selector(toggleFromMenu)))
        }
        if !settings.failedHotkeys.isEmpty {
            let names = HotkeyAction.allCases.filter(settings.failedHotkeys.contains).map(\.label).joined(separator: "、")
            menu.addItem(NSMenuItem(title: "⚠ 他のアプリと衝突して使えないショートカット: \(names)",
                                    action: nil, keyEquivalent: ""))
        }

        let sourceMenu = NSMenu()
        for source in AudioSource.allCases {
            let sourceItem = item(source.label, #selector(selectSource(_:)))
            sourceItem.representedObject = source.rawValue
            sourceItem.state = settings.audioSource == source ? .on : .off
            sourceMenu.addItem(sourceItem)
        }
        let sourceItem = NSMenuItem(title: "録音ソース: \(settings.audioSource.label)", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        sourceItem.isEnabled = session == nil
        menu.addItem(sourceItem)

        menu.addItem(.separator())
        menu.addItem(item("ファイルを文字起こし…", #selector(chooseFilesToTranscribe), key: "o"))
        let openLast = item("最新の文字起こしを開く", #selector(openLastTranscript))
        openLast.isEnabled = lastTranscript != nil
        menu.addItem(openLast)
        menu.addItem(item("保存フォルダを開く", #selector(openOutputFolder)))
        menu.addItem(.separator())
        menu.addItem(item("設定…", #selector(showSettings), key: ","))
        menu.addItem(item("Kikitori を終了", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// メニュー項目の右側にショートカットを表示する
    private func item(withHotkey title: String, _ action: HotkeyAction, _ selector: Selector) -> NSMenuItem {
        let menuItem = item(title, selector)
        let shortcut = settings.hotkeyLabel(action)
        if !shortcut.isEmpty {
            let attributed = NSMutableAttributedString(string: title + "\t")
            attributed.append(NSAttributedString(string: shortcut, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 240)]
            attributed.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attributed.length))
            attributed.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: NSRange(location: 0, length: attributed.length))
            menuItem.attributedTitle = attributed
        }
        return menuItem
    }

    @objc private func toggleFromMenu() { toggleRecording() }
    @objc private func pauseFromMenu() { togglePause() }
    @objc private func discardFromMenu() { discardRecording() }

    @objc private func selectSource(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let source = AudioSource(rawValue: raw) {
            settings.audioSource = source
        }
    }

    @objc private func openLastTranscript() {
        if let lastTranscript { NSWorkspace.shared.open(lastTranscript) }
    }

    @objc private func openOutputFolder() {
        try? FileManager.default.createDirectory(at: settings.outputURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.outputURL)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            // SwiftUI 側は最小サイズだけ決め、ウィンドウの大きさはユーザーが自由に変えられるようにする
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Kikitori 設定"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center()
            // 前回の位置と大きさを復元する
            window.setFrameAutosaveName("KikitoriSettings")
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        fitOnScreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 外部ディスプレイを外したときなどに、ウィンドウが画面からはみ出さないようにする
    private func fitOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    @objc private func quit() {
        if session != nil {
            let alert = NSAlert()
            alert.messageText = "録音中です。終了しますか?"
            alert.informativeText = "録音済みの音声は、次回起動時に文字起こしされます。"
            alert.addButton(withTitle: "終了")
            alert.addButton(withTitle: "キャンセル")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    // MARK: - その他

    private func registerHotKey() {
        hotKey.unregisterAll()
        guard !settings.isCapturingHotkey else { return }
        var failed: Set<HotkeyAction> = []
        for action in HotkeyAction.allCases {
            guard let binding = settings.hotkeys[action] else { continue }
            if !hotKey.register(id: action.hotKeyID, keyCode: binding.keyCode, modifiers: binding.modifiers) {
                failed.insert(action)
            }
        }
        // 同じ値を入れると設定変更として再通知され、ここが繰り返し呼ばれるので差分があるときだけ
        if settings.failedHotkeys != failed { settings.failedHotkeys = failed }
    }

    private func playSound(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if case KikitoriError.screenCapturePermission = error {
            alert.addButton(withTitle: "システム設定を開く")
            alert.addButton(withTitle: "閉じる")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, case KikitoriError.screenCapturePermission = error,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func notify(title: String, body: String, file: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file { content.userInfo = ["path": file.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 通知をクリックしたら文字起こしファイルを開く
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }
}
