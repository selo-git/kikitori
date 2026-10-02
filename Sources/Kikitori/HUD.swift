import AppKit
import SwiftUI

/// 確認キーで表示を切り替える、画面上部の録音状態の表示。表示中はボタンで操作もできる
struct RecorderStatus {
    enum State { case idle, recording, paused }

    var state: State = .idle
    var elapsed: TimeInterval = 0
    var tracks: [TrackStatus] = []
    var processingCount = 0
}

/// 表示中のボタンから呼ぶ操作
struct HUDActions {
    var start: () -> Void = {}
    var togglePause: () -> Void = {}
    var finish: () -> Void = {}
    var discard: () -> Void = {}
    var close: () -> Void = {}
    /// 背景をドラッグして表示を動かす
    var dragChanged: () -> Void = {}
    var dragEnded: () -> Void = {}
}

final class HUDModel: ObservableObject {
    @Published var status = RecorderStatus()
    /// 表示用に滑らかにしたメーター値 (0〜1)。トラック名がキー
    @Published var displayLevels: [String: Double] = [:]

    func update(_ status: RecorderStatus) {
        self.status = status
        var levels: [String: Double] = [:]
        for track in status.tracks {
            let target = Self.normalized(track.level)
            let previous = displayLevels[track.name] ?? 0
            // 上がるときはすぐ、下がるときはゆっくり
            levels[track.name] = target > previous ? target : max(target, previous * 0.85)
        }
        displayLevels = levels
    }

    /// RMS を -50dB〜0dB の範囲で 0〜1 に
    static func normalized(_ rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(1, max(0, (db + 50) / 50))
    }
}

/// 非アクティブなパネルでも、最初のクリックでボタンが反応するようにする
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class HUDController {
    var statusProvider: (() -> RecorderStatus)?
    var actions = HUDActions()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var timer: Timer?
    /// ユーザーがドラッグで動かしたら、次に表示するときもその位置にする
    private var lastFrame: NSRect?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    static let pillSize = NSSize(width: 470, height: 52)
    private static let shadowMargin: CGFloat = 14

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let lastFrame, NSScreen.screens.contains(where: { $0.frame.intersects(lastFrame) }) {
            panel.setFrame(lastFrame, display: false)
        } else {
            position(panel)
        }
        refresh()
        panel.orderFrontRegardless()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let panel, panel.isVisible { lastFrame = panel.frame }
        panel?.orderOut(nil)
    }

    private func refresh() {
        if let status = statusProvider?() { model.update(status) }
    }

    private func makePanel() -> NSPanel {
        let margin = Self.shadowMargin
        let size = NSSize(width: Self.pillSize.width + margin * 2, height: Self.pillSize.height + margin * 2)
        // nonactivatingPanel: ボタンを押しても会議アプリなど前面のアプリからフォーカスを奪わない
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 全デスクトップ・フルスクリーンアプリの上にも出す
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 画面共有や画面収録に映らないようにする (共有アプリによっては映る場合がある)
        panel.sharingType = .none
        let actions = HUDActions(
            start: { [weak self] in self?.actions.start() },
            togglePause: { [weak self] in self?.actions.togglePause() },
            finish: { [weak self] in self?.actions.finish() },
            discard: { [weak self] in self?.actions.discard() },
            close: { [weak self] in self?.hide() },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragStart = nil }
        )
        let hosting = FirstMouseHostingView(rootView: HUDView(model: model, actions: actions).padding(margin))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        return panel
    }

    /// ウィンドウが動くと SwiftUI 側の座標もずれるので、画面上のマウス位置から計算する
    private func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
                                     y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
    }

    /// マウスがある画面の、メニューバーのすぐ下の中央に置く
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height + Self.shadowMargin - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    let actions: HUDActions
    /// 削除ボタンを一度押した状態 (もう一度押すと削除)
    @State private var deleteArmed: Bool
    @State private var disarmTask: Task<Void, Never>?

    init(model: HUDModel, actions: HUDActions, deleteArmed: Bool = false) {
        self.model = model
        self.actions = actions
        _deleteArmed = State(initialValue: deleteArmed)
    }

    private let secondary = Color(white: 0.82)
    private let warning = Color(red: 1, green: 0.84, blue: 0.04)
    private let red = Color(red: 1, green: 0.27, blue: 0.23)

    var body: some View {
        HStack(spacing: 14) {
            indicator
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondary)
                Text(time)
                    .font(.system(size: 20, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(model.status.state == .recording ? .white : Color(white: 0.6))
            }
            .fixedSize()
            detail
                .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(width: HUDController.pillSize.width, height: HUDController.pillSize.height)
        .background(
            Capsule()
                .fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.94))
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { _ in actions.dragChanged() }
                    .onEnded { _ in actions.dragEnded() })
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.status.state) { _, _ in disarm() }
    }

    private var title: String {
        switch model.status.state {
        case .recording: return "録音中"
        case .paused: return "一時停止中"
        case .idle: return "待機中"
        }
    }

    private var time: String {
        guard model.status.state != .idle else { return "--:--" }
        return formatElapsed(model.status.elapsed)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.status.state {
        case .recording:
            Circle().fill(red).frame(width: 10, height: 10)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.04))
                .frame(width: 10, height: 10)
        case .idle:
            Circle().strokeBorder(Color(white: 0.56), lineWidth: 1.5).frame(width: 10, height: 10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if deleteArmed {
            Text("もう一度押すとゴミ箱へ移します")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning)
        } else {
            switch model.status.state {
            case .recording:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.status.tracks, id: \.name) { track in
                        HStack(spacing: 6) {
                            Text(track.name)
                                .frame(width: 40, alignment: .leading)
                                .foregroundStyle(secondary)
                            if let problem = track.problem {
                                Label(problem, systemImage: "exclamationmark.triangle")
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(warning)
                            } else {
                                meter(model.displayLevels[track.name] ?? 0)
                            }
                        }
                        .font(.system(size: 11))
                    }
                }
            case .paused:
                Text("止めている間は録音されません")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
            case .idle:
                Text(model.status.processingCount > 0 ? "文字起こし中 \(model.status.processingCount)件" : "録音していません")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            switch model.status.state {
            case .recording, .paused:
                let paused = model.status.state == .paused
                HUDButton(symbol: paused ? "play.fill" : "pause.fill",
                          help: hint(paused ? "再開" : "一時停止", .pause)) {
                    disarm()
                    actions.togglePause()
                }
                HUDButton(symbol: "stop.fill", help: hint("終了して文字起こし", .toggle)) {
                    disarm()
                    actions.finish()
                }
                HUDButton(symbol: "trash", help: hint("削除 (ゴミ箱へ)", .discard), tint: deleteArmed ? red : nil) {
                    if deleteArmed {
                        disarm()
                        actions.discard()
                    } else {
                        arm()
                    }
                }
            case .idle:
                HUDButton(symbol: "record.circle", help: hint("録音を開始", .toggle), iconColor: red) {
                    actions.start()
                }
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 20)
            HUDButton(symbol: "xmark", help: hint("閉じる", .peek), size: 22) {
                disarm()
                actions.close()
            }
        }
    }

    private func hint(_ text: String, _ action: HotkeyAction) -> String {
        let key = Settings.shared.hotkeyLabel(action)
        return key.isEmpty ? text : "\(text) (\(key))"
    }

    private func arm() {
        deleteArmed = true
        disarmTask?.cancel()
        disarmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { deleteArmed = false }
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        deleteArmed = false
    }

    private func meter(_ level: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(Color(white: 0.95)).frame(width: geometry.size.width * level)
            }
        }
        .frame(height: 5)
    }
}

/// 表示内の丸いアイコンボタン
private struct HUDButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    var iconColor: Color = .white
    var size: CGFloat = 28
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(tint == nil ? iconColor : .white)
                .frame(width: size, height: size)
                .background(Circle().fill(tint ?? Color.white.opacity(hovering ? 0.24 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

func formatElapsed(_ seconds: TimeInterval) -> String {
    let t = Int(seconds)
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
        : String(format: "%02d:%02d", t / 60, t % 60)
}
