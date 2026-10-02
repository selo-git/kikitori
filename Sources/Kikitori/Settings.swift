import AppKit
import Carbon.HIToolbox

enum AudioSource: String, CaseIterable, Identifiable {
    case mic, system, both

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mic: return "マイクのみ"
        case .system: return "PCの音のみ"
        case .both: return "マイク + PCの音"
        }
    }
    var usesMic: Bool { self != .system }
    var usesSystem: Bool { self != .mic }
}

enum IndicatorMode: String, CaseIterable, Identifiable {
    case normal, quiet, hidden

    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "録音中はアイコンを赤くして経過時間を表示"
        case .quiet: return "録音中もアイコンを変えない"
        case .hidden: return "メニューバーにアイコンを出さない"
        }
    }
}

enum TranscriptLanguage: String, CaseIterable, Identifiable {
    case ja, en, auto

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ja: return "日本語"
        case .en: return "英語"
        case .auto: return "自動判定"
        }
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case toggle, pause, discard, peek

    var id: String { rawValue }
    /// Carbon ホットキーの ID
    var hotKeyID: UInt32 { UInt32(HotkeyAction.allCases.firstIndex(of: self)! + 1) }
    var label: String {
        switch self {
        case .toggle: return "録音の開始 / 終了"
        case .pause: return "一時停止 / 再開"
        case .discard: return "録音を破棄 (ゴミ箱へ)"
        case .peek: return "録音状態の表示 (切り替え)"
        }
    }
}

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String

    var label: String { HotKey.label(modifiers: modifiers, keyName: keyName) }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var audioSource: AudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: "audioSource") }
    }
    @Published var indicatorMode: IndicatorMode {
        didSet { defaults.set(indicatorMode.rawValue, forKey: "indicatorMode") }
    }
    /// アクションごとのショートカット (未設定のアクションはキーなし)
    @Published var hotkeys: [HotkeyAction: HotkeyBinding] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(stored), forKey: "hotkeys")
        }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: "playSounds") }
    }
    @Published var notifyOnComplete: Bool {
        didSet { defaults.set(notifyOnComplete, forKey: "notifyOnComplete") }
    }
    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: "copyToClipboard") }
    }
    @Published var keepAudio: Bool {
        didSet { defaults.set(keepAudio, forKey: "keepAudio") }
    }
    /// マイク・PCの音を別々のまま、元の音質で (FLAC) 残す
    @Published var keepRawTracks: Bool {
        didSet { defaults.set(keepRawTracks, forKey: "keepRawTracks") }
    }
    @Published var language: TranscriptLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: "prompt") }
    }
    @Published var outputDirectory: String {
        didSet { defaults.set(outputDirectory, forKey: "outputDirectory") }
    }
    @Published var modelPath: String {
        didSet { defaults.set(modelPath, forKey: "modelPath") }
    }

    /// ホットキーを設定画面で入力中かどうか(保存しない)
    @Published var isCapturingHotkey = false
    /// 他のアプリと衝突して登録できなかったショートカット(保存しない)
    @Published var failedHotkeys: Set<HotkeyAction> = []

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        defaults.register(defaults: [
            "audioSource": AudioSource.both.rawValue,
            "indicatorMode": IndicatorMode.normal.rawValue,
            "hotkeyKeyCode": kVK_ANSI_R,
            "hotkeyModifiers": controlKey | optionKey | cmdKey,
            "hotkeyKeyName": "R",
            "playSounds": true,
            "notifyOnComplete": true,
            "copyToClipboard": false,
            "keepAudio": true,
            "keepRawTracks": true,
            "language": TranscriptLanguage.ja.rawValue,
            "prompt": "",
            "outputDirectory": "\(home)/Documents/Kikitori",
            "modelPath": "\(home)/.cache/whisper-cpp/ggml-large-v3-turbo.bin",
        ])
        audioSource = AudioSource(rawValue: defaults.string(forKey: "audioSource") ?? "") ?? .both
        indicatorMode = IndicatorMode(rawValue: defaults.string(forKey: "indicatorMode") ?? "") ?? .normal
        hotkeys = Settings.loadHotkeys(defaults)
        playSounds = defaults.bool(forKey: "playSounds")
        notifyOnComplete = defaults.bool(forKey: "notifyOnComplete")
        copyToClipboard = defaults.bool(forKey: "copyToClipboard")
        keepAudio = defaults.bool(forKey: "keepAudio")
        keepRawTracks = defaults.bool(forKey: "keepRawTracks")
        language = TranscriptLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .ja
        prompt = defaults.string(forKey: "prompt") ?? ""
        outputDirectory = defaults.string(forKey: "outputDirectory") ?? "\(home)/Documents/Kikitori"
        modelPath = defaults.string(forKey: "modelPath") ?? ""
    }

    private static func loadHotkeys(_ defaults: UserDefaults) -> [HotkeyAction: HotkeyBinding] {
        let all = UInt32(controlKey | optionKey | cmdKey)
        let peek = HotkeyBinding(keyCode: UInt32(kVK_ANSI_I), modifiers: all, keyName: "I")
        if let data = defaults.data(forKey: "hotkeys"),
           let stored = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) {
            var hotkeys = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                HotkeyAction(rawValue: key).map { ($0, value) }
            })
            // 確認キーが無かったバージョンからの移行 (一度だけ。ユーザーが解除した場合は戻さない)
            if !defaults.bool(forKey: "peekHotkeyMigrated") {
                defaults.set(true, forKey: "peekHotkeyMigrated")
                if hotkeys[.peek] == nil, !hotkeys.values.contains(where: {
                    $0.keyCode == peek.keyCode && $0.modifiers == peek.modifiers
                }) {
                    hotkeys[.peek] = peek
                }
            }
            return hotkeys
        }
        // 初回 (または旧バージョンの設定から移行)
        defaults.set(true, forKey: "peekHotkeyMigrated")
        return [
            .toggle: HotkeyBinding(keyCode: UInt32(defaults.integer(forKey: "hotkeyKeyCode")),
                                   modifiers: UInt32(defaults.integer(forKey: "hotkeyModifiers")),
                                   keyName: defaults.string(forKey: "hotkeyKeyName") ?? "R"),
            .pause: HotkeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: all, keyName: "P"),
            .discard: HotkeyBinding(keyCode: UInt32(kVK_Delete), modifiers: all, keyName: "⌫"),
            .peek: peek,
        ]
    }

    /// メニュー表示用 (未設定なら空文字)
    func hotkeyLabel(_ action: HotkeyAction) -> String {
        hotkeys[action]?.label ?? ""
    }

    var outputURL: URL {
        URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }
}
