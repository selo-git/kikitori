import AppKit
import SwiftUI

/// 確認キーを押している間だけ画面上部に出す、録音状態の表示
struct RecorderStatus {
    enum State { case idle, recording, paused }

    var state: State = .idle
    var elapsed: TimeInterval = 0
    var tracks: [TrackStatus] = []
    var processingCount = 0
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

@MainActor
final class HUDController {
    var statusProvider: (() -> RecorderStatus)?

    private let model = HUDModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var requiredModifiers: NSEvent.ModifierFlags = []
    private var shownAt = Date()

    private static let pillSize = NSSize(width: 340, height: 52)
    private static let shadowMargin: CGFloat = 14

    var isVisible: Bool { panel?.isVisible ?? false }

    /// - Parameter modifiers: 確認キーの修飾キー。これが離されたら閉じる (キーを離したイベントの取りこぼし対策)
    func show(holding modifiers: NSEvent.ModifierFlags) {
        requiredModifiers = modifiers
        shownAt = Date()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        refresh()
        panel.orderFrontRegardless()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func tick() {
        let modifiersReleased = !NSEvent.modifierFlags.isSuperset(of: requiredModifiers)
        if modifiersReleased || Date().timeIntervalSince(shownAt) > 60 {
            hide()
            return
        }
        refresh()
    }

    private func refresh() {
        if let status = statusProvider?() { model.update(status) }
    }

    private func makePanel() -> NSPanel {
        let margin = Self.shadowMargin
        let size = NSSize(width: Self.pillSize.width + margin * 2, height: Self.pillSize.height + margin * 2)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 全デスクトップ・フルスクリーンアプリの上にも出す
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 画面共有や画面収録に映らないようにする (共有アプリによっては映る場合がある)
        panel.sharingType = .none
        let hosting = NSHostingView(rootView: HUDView(model: model).padding(margin))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        return panel
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

    private let secondary = Color(white: 0.82)
    private let warning = Color(red: 1, green: 0.84, blue: 0.04)

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
        }
        .padding(.horizontal, 20)
        .frame(width: 340, height: 52)
        .background(Capsule().fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.94)))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
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
            Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 10, height: 10)
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

func formatElapsed(_ seconds: TimeInterval) -> String {
    let t = Int(seconds)
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
        : String(format: "%02d:%02d", t / 60, t % 60)
}
