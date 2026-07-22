import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var updater: UpdaterService?

    var body: some View {
        Form {
            Section("一般") {
                Toggle("ログイン時に起動", isOn: $settings.launchAtLogin)
                    .disabled(!settings.canManageLoginItem)
                if !settings.canManageLoginItem {
                    Text(".appとして起動した場合のみ変更できます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("更新間隔", selection: $settings.pollIntervalMinutes) {
                    Text("1分").tag(1)
                    Text("2分").tag(2)
                    Text("5分").tag(5)
                }
                Toggle("バーの色をアクセントカラーに合わせる", isOn: $settings.useSystemAccent)
            }
            Section("アップデート") {
                Toggle("アップデートを自動で確認", isOn: $settings.autoUpdate)
                    .disabled(updater?.isAvailable != true)
                    .onChange(of: settings.autoUpdate) { _, on in
                        updater?.automaticallyChecksForUpdates = on
                    }
                Button("今すぐアップデートを確認") { updater?.checkForUpdates() }
                    .disabled(updater?.isAvailable != true)
                if updater?.isAvailable != true {
                    Text(".appとして起動した場合のみ利用できます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("通知") {
                Toggle("80% / 95% 到達時に通知", isOn: $settings.notifyThresholds)
            }
            Section("バブル") {
                Picker("表示する使用量", selection: $settings.bubbleMetric) {
                    Text("現在のセッション").tag(BubbleMetric.session)
                    Text("週間（すべてのモデル）").tag(BubbleMetric.weekly)
                    Text("Fable（週間）").tag(BubbleMetric.fable)
                }
                Toggle("割れた後、リセット時に復活", isOn: $settings.reviveBubble)
            }
            Section {
                LabeledContent("バージョン", value: Self.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 460)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: SettingsStore
    private let updater: UpdaterService?

    init(settings: SettingsStore, updater: UpdaterService? = nil) {
        self.settings = settings
        self.updater = updater
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "ClaudeBar 設定"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings, updater: updater))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
