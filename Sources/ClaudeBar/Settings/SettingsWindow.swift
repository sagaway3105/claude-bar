import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var updater: UpdaterService?
    /// 週間モデル名（"Fable" 等）。表示名は状況で変わるため差し込みで扱う
    var fableLabel: String = "Fable"

    var body: some View {
        Form {
            Section(L("settings.general")) {
                Toggle(L("settings.launchAtLogin"), isOn: $settings.launchAtLogin)
                    .disabled(!settings.canManageLoginItem)
                if !settings.canManageLoginItem {
                    Text(L("settings.appOnlyNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker(L("settings.refreshInterval"), selection: $settings.pollIntervalMinutes) {
                    Text(L("settings.oneMinute")).tag(1)
                    Text(L("settings.twoMinutes")).tag(2)
                    Text(L("settings.fiveMinutes")).tag(5)
                }
                Toggle(L("settings.useSystemAccent"), isOn: $settings.useSystemAccent)
            }
            Section(L("settings.bubble")) {
                Picker(L("settings.bubblesShown"), selection: $settings.bubbleCount) {
                    Text(L("settings.one")).tag(1)
                    Text(L("settings.three", fableLabel)).tag(3)
                }
                Picker(L("settings.metricShown"), selection: $settings.bubbleMetric) {
                    Text(L("settings.metricSession")).tag(BubbleMetric.session)
                    Text(L("settings.metricWeeklyAll")).tag(BubbleMetric.weekly)
                    Text(L("settings.metricWeeklyModel", fableLabel)).tag(BubbleMetric.fable)
                }
                .disabled(settings.isTripleBubble)
                if settings.isTripleBubble {
                    Text(L("settings.tripleNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(L("settings.reviveBubble"), isOn: $settings.reviveBubble)
            }
            Section(L("settings.notifications")) {
                Toggle(L("settings.notifyThresholds"), isOn: $settings.notifyThresholds)
            }
            Section(L("settings.system")) {
                Toggle(L("settings.autoUpdate"), isOn: $settings.autoUpdate)
                    .disabled(updater?.isAvailable != true)
                    .onChange(of: settings.autoUpdate) { _, on in
                        updater?.automaticallyChecksForUpdates = on
                        updater?.automaticallyDownloadsUpdates = on
                    }
                Button(L("settings.checkUpdatesNow")) { updater?.checkForUpdates() }
                    .disabled(updater?.isAvailable != true)
                if updater?.isAvailable != true {
                    Text(L("settings.appOnlyNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L("settings.version"), value: Self.version)
                Button(L("settings.quitApp"), role: .destructive) { NSApp.terminate(nil) }
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
    /// 週間モデル名の表示に使う（設定画面のラベル差し込み用）
    weak var state: AppState?
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
            w.title = L("settings.windowTitle")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings, updater: updater, fableLabel: state?.fableLabel ?? "Fable"))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
