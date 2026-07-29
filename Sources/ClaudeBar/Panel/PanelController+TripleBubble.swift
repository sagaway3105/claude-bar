import AppKit
import SwiftUI

/// 3つ表示（トリプルバブル）固有の挙動。設計は TRIPLE_BUBBLE.md。
///
/// ウィンドウ生成・ドラッグ・浮遊・ホバーHUDといったバブル共通の仕組みは
/// PanelController+Bubble.swift にあり、ここは「球ごとに分かれる」処理
/// （どの球を掴んだかの座標変換・球ごとのポヨン・破裂・リセット復活）だけを持つ。
extension PanelController {

    // MARK: - 座標変換

    /// スクリーン座標 → SwiftUIのビュー座標（左上原点）。どの球を掴んだかの判定に使う
    func viewPoint(of screenPoint: NSPoint, in window: NSWindow) -> CGPoint {
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        return CGPoint(x: inWindow.x, y: window.frame.height - inWindow.y)
    }

    /// 球のスクリーン座標中心（破裂演出の位置決め用）
    private func tripleBallScreenCenter(_ slot: TripleBubbleCluster.Slot) -> NSPoint? {
        guard let p = bubblePanel else { return nil }
        let home = tripleCluster.home(for: slot)
        let drag = tripleCluster.dragOffsets[slot.index]
        // ビュー座標(左上原点) → スクリーン座標(左下原点)
        return NSPoint(
            x: p.frame.origin.x + home.x + drag.width,
            y: p.frame.origin.y + p.frame.height - (home.y + drag.height)
        )
    }

    // MARK: - 球ごとのポヨンと破裂

    /// 3つ表示のクリック遊び: 掴んでいた球だけが反応する（他の球は残らず動かない）。
    /// 1回目ポヨン、2回目強めのポヨン、3連打でその球だけ破裂💥
    func registerTripleBubbleTap() {
        guard let slot = lastTappedSlot else { bubbleTapCount = 0; return }
        if bubbleTapCount >= 3 {
            bubbleTapCount = 0
            popTripleBall(slot)
            return
        }
        tripleCluster.bounce(slot, intensity: bubbleTapCount == 1 ? 1.0 : 1.6)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        scheduleBubbleTapReset()
    }

    /// その球だけ割れる（他は残る）。全部割れたらウィンドウを畳む
    func popTripleBall(_ slot: TripleBubbleCluster.Slot) {
        guard !tripleCluster.poppedSlots.contains(slot.index) else { return }
        NSSound(named: "Pop")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if let center = tripleBallScreenCenter(slot) {
            let utilization = state.usage?.window(for: slot.metric)?.utilization ?? 0
            showPopBurst(centeredOn: center, scale: Self.bubbleScaleFactor(for: utilization) * 0.8)
        }
        tripleCluster.pop(slot)
        if tripleCluster.allPopped {
            // 3つとも割れたらバブル自体を畳み、復活を予約する
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                guard let self, self.tripleCluster.allPopped else { return }
                self.state.bubbleActive = false
                self.stopMouseTracking()
                self.removeBubbleMouseMonitor()
                self.bubblePanel?.orderOut(nil)
            }
        }
    }

    // MARK: - 使用量の反映

    /// 使用量更新時、3つ表示の各球について100%破裂とリセット復活を判定する
    func updateTripleBallsOnUsage() {
        guard settings.isTripleBubble, state.bubbleActive else { return }
        for slot in TripleBubbleCluster.Slot.allCases {
            let window = state.usage?.window(for: slot.metric)
            let utilization = window?.utilization ?? 0
            if utilization >= 100, !tripleCluster.poppedSlots.contains(slot.index) {
                popTripleBall(slot)
            } else if utilization < 100, tripleCluster.poppedSlots.contains(slot.index),
                      settings.reviveBubble {
                // リセットで使用量が戻った → ぽわんっと生まれ直す
                tripleCluster.revive(slot)
            }
        }
    }
}
