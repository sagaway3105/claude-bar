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

    /// 塊全体の浮遊アニメーションによる見た目のズレ（presentation − モデル）。ビュー座標系。
    /// モデル座標だけで当たり判定すると、浮遊が最大に振れた瞬間に見えている球の縁を外す
    var tripleFloatOffset: CGSize {
        guard let assembly = bubbleAssembly,
              let pres = assembly.layer?.presentation() else { return .zero }
        let dx = pres.position.x - assembly.frame.origin.x
        let dy = pres.position.y - assembly.frame.origin.y
        // ウィンドウ座標(下原点)のズレをビュー座標(上原点)へ反転
        return CGSize(width: dx, height: -dy)
    }

    /// スクリーン座標のマウス位置がどの球の上か（塊の浮遊ぶんを補正して判定）
    func tripleSlot(at screenPoint: NSPoint, in window: NSWindow) -> TripleBubbleCluster.Slot? {
        let point = viewPoint(of: screenPoint, in: window)
        let float = tripleFloatOffset
        return tripleCluster.slot(
            at: CGPoint(x: point.x - float.width, y: point.y - float.height), state: state
        )
    }

    /// 塊の構成（破裂・復活）が変わった後、可動域を取り直す
    /// （古い外接のままだと残った球が画面端に届かない/はみ出す）
    func refreshTripleFloatBounds() {
        guard settings.isTripleBubble, let p = bubblePanel else { return }
        updateFloatBounds(around: NSPoint(x: p.frame.midX, y: p.frame.midY))
    }

    /// 球ごとの漂い（DriftHost）による見た目のズレ。ビュー座標（左上原点）。
    /// 塊の漂い `tripleFloatOffset` とは別で、こちらは球1つぶん
    func tripleBallDrift(_ slot: TripleBubbleCluster.Slot) -> CGSize {
        guard tripleHosts.indices.contains(slot.index) else { return .zero }
        let offset = tripleHosts[slot.index].driftOffset
        // AppKit座標(下原点)のズレをビュー座標(上原点)へ反転
        return CGSize(width: offset.width, height: -offset.height)
    }

    /// 球のスクリーン座標中心（破裂演出の位置決め用）。塊と球それぞれの漂いを補正して見た目に合わせる
    private func tripleBallScreenCenter(_ slot: TripleBubbleCluster.Slot) -> NSPoint? {
        guard let p = bubblePanel else { return nil }
        let home = tripleCluster.home(for: slot)
        let drag = tripleCluster.dragOffsets[slot.index]
        let ball = tripleBallDrift(slot)
        let group = tripleFloatOffset
        let float = CGSize(width: group.width + ball.width, height: group.height + ball.height)
        // ビュー座標(左上原点) → スクリーン座標(左下原点)
        return NSPoint(
            x: p.frame.origin.x + home.x + drag.width + float.width,
            y: p.frame.origin.y + p.frame.height - (home.y + drag.height + float.height)
        )
    }

    /// 見えている球の外接矩形（ビュー座標・左上原点）。ドラッグ中の個別ズレも含む。
    /// ホバーHUDの位置決めと、可動域（見えている縁が画面の縁へ届く基準）に使う
    func tripleClusterBounds() -> CGRect? {
        let visible = TripleBubbleCluster.Slot.allCases.filter { !tripleCluster.poppedSlots.contains($0.index) }
        guard !visible.isEmpty else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for slot in visible {
            let home = tripleCluster.home(for: slot)
            let drag = tripleCluster.dragOffsets[slot.index]
            // 球ごとの漂いで home からずれる分も含める（画面端で欠けない・HUDがずれない）
            let radius = tripleCluster.diameter(for: slot, state: state) / 2
                + TripleBubbleCluster.maxDriftAmplitude
            minX = min(minX, home.x + drag.width - radius)
            maxX = max(maxX, home.x + drag.width + radius)
            minY = min(minY, home.y + drag.height - radius)
            maxY = max(maxY, home.y + drag.height + radius)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 見えている球の外接矩形（スクリーン座標）。ホバーHUDの位置決めに使う。
    /// アセンブリはウィンドウ全体を占め塊の周囲に大きな余白があるため、
    /// アセンブリ枠を基準にするとHUDが塊から離れて見えてしまう
    func tripleClusterScreenBounds(in window: NSWindow) -> NSRect? {
        guard let b = tripleClusterBounds() else { return nil }
        // ビュー座標(左上原点) → スクリーン座標(左下原点)
        let frame = window.frame
        return NSRect(
            x: frame.origin.x + b.minX,
            y: frame.origin.y + frame.height - b.maxY,
            width: b.width,
            height: b.height
        )
    }

    // MARK: - 球ごとのポヨンと破裂

    /// 3つ表示のクリック遊び: 掴んでいた球だけが反応する（他の球は残らず動かない）。
    /// 1回目ポヨン、2回目強めのポヨン、3連打でその球だけ破裂💥
    func registerTripleBubbleTap() {
        guard let slot = lastTappedSlot else { bubbleTapCount = 0; return }
        if slot != tapCountSlot {
            // 連打カウントは球ごと。持ち越すと2球目への初回クリックで破裂してしまう
            bubbleTapCount = 1
            tapCountSlot = slot
        }
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
        // 掴んでいる最中の球は割らない（掴んだまま消えて空ドラッグになる。
        // 放した後の次の使用量判定で改めて割れる）
        guard tripleCluster.draggingSlot != slot else { return }
        // 二重起動を防ぐ（使用量更新は繰り返し来るが、膨張中はまだ割れていない）
        guard !strainingSlots.contains(slot.index) else { return }
        strainingSlots.insert(slot.index)

        // 「ぐぐ...パチン」: 音を鳴らしてその球だけ膨らませ、パチンの瞬間に割る
        Self.popSound?.stop()
        Self.popSound?.play()
        tripleCluster.strain(slot)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PanelController.popStrainDuration))
            guard let self else { return }
            self.strainingSlots.remove(slot.index)
            guard self.state.bubbleActive,
                  !self.tripleCluster.poppedSlots.contains(slot.index) else {
                self.tripleCluster.relaxStrain(slot)
                return
            }
            self.finishTriplePop(slot)
        }
    }

    /// 「パチン」の瞬間の処理（破裂の演出と後始末）
    private func finishTriplePop(_ slot: TripleBubbleCluster.Slot) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if let center = tripleBallScreenCenter(slot) {
            let utilization = state.usage?.window(for: slot.metric)?.utilization ?? 0
            showPopBurst(centeredOn: center, scale: Self.bubbleScaleFactor(for: utilization) * 0.8)
        }
        // 割れた時点のリセット時刻を控える（新しい期間に入るまで復活させない判定用）
        if let resets = state.usage?.window(for: slot.metric)?.resetsAt {
            tripleCluster.poppedResetsAt[slot.index] = resets
        }
        tripleCluster.pop(slot)
        tripleCluster.bounceScales[slot.index] = 1   // 次に生まれ直すときのために戻す
        refreshTripleFloatBounds()
        if tripleCluster.allPopped {
            // 3つとも割れたらバブル自体を畳み、復活を予約する。
            // 世代ガード: 0.6秒以内に再表示（1⇔3切替等）されたら畳まない
            let generation = bubbleHideGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                guard let self, self.tripleCluster.allPopped,
                      self.bubbleHideGeneration == generation else { return }
                if let frame = self.bubblePanel?.frame {
                    // 復活時に同じ場所へ生まれ直すための位置
                    self.lastBubbleCenter = NSPoint(x: frame.midX, y: frame.midY)
                }
                self.state.bubbleActive = false
                self.stopMouseTracking()
                self.removeBubbleMouseMonitor()
                self.bubblePanel?.orderOut(nil)
                self.tripleCluster.contentParked = true
                self.scheduleRevivalIfNeeded()
            }
        }
    }

    // MARK: - 全滅からの復活（scheduleRevivalIfNeeded の3つ表示ぶんの判定）

    /// 3メトリクスのうち最初に来るリセット時刻（全滅からの復活予約の基準）
    var tripleNextResetsAt: Date? {
        TripleBubbleCluster.Slot.allCases
            .compactMap { state.usage?.window(for: $0.metric)?.resetsAt }
            .filter { $0.timeIntervalSinceNow > 0 }
            .min()
    }

    /// 1球でも100%未満に戻っていれば復活できる（100%のままの球は割れたままでよい）
    var tripleCanRevive: Bool {
        TripleBubbleCluster.Slot.allCases.contains {
            (state.usage?.window(for: $0.metric)?.utilization ?? 0) < 100
        }
    }

    /// 割れたままの球のうち100%未満に戻っているものを生まれ直させる。
    /// バブル再表示（🫧・復活予約）の入口で呼び、全球割れたままの「見えない空ウィンドウ」を出さない
    func reviveTripleBallsBelowLimit() {
        for slot in TripleBubbleCluster.Slot.allCases
        where (state.usage?.window(for: slot.metric)?.utilization ?? 0) < 100 {
            tripleCluster.revive(slot)
        }
        refreshTripleFloatBounds()
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
                      settings.reviveBubble, hasResetSincePop(slot, window: window) {
                // リセットで新しい期間に入った → ぽわんっと生まれ直す
                tripleCluster.revive(slot)
                refreshTripleFloatBounds()
            }
        }
    }

    /// 割れた時点から使用量ウィンドウが新しい期間へ進んだか。
    /// 手動で割った球（100%未満）が次のポーリングで即復活しないよう、期間の進みで判定する。
    /// 割れた時点のリセット時刻が控えられていない（使用量未取得で割れた）場合は復活を許す
    private func hasResetSincePop(_ slot: TripleBubbleCluster.Slot, window: UsageWindow?) -> Bool {
        guard let poppedResets = tripleCluster.poppedResetsAt[slot.index] else { return true }
        guard let current = window?.resetsAt else { return false }
        // 60秒の遊び: リセット時刻の秒単位の揺れを新しい期間と誤認しない（単発モードの検知と同じ）
        return current > poppedResets.addingTimeInterval(60)
    }
}
