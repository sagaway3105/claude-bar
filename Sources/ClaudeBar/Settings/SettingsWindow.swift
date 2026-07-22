import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

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
                Toggle("背景に合わせて文字色を調整", isOn: $settings.adaptiveBubbleTextColor)
                    .onChange(of: settings.adaptiveBubbleTextColor) { _, enabled in
                        if enabled, !BackdropSampler.hasPermission {
                            BackdropSampler.requestPermission()
                        }
                    }
                if settings.adaptiveBubbleTextColor, !BackdropSampler.hasPermission {
                    Text("「画面収録」の許可が必要です（バブル直下の明るさを読むためだけに使います）。許可後はアプリを再起動してください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("バージョン", value: Self.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 400)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "ClaudeBar 設定"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
