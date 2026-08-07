import AppKit
import Observation
import SwiftUI

/// トリプルバブルの配置・漂い・個別ドラッグを持つ状態（設計は TRIPLE_BUBBLE.md）。
///
/// 塊全体の移動はウィンドウ自体を動かす（PanelController+Bubble）。
/// ここが持つのは「ホーム位置からの individual なズレ」だけ。
@MainActor
@Observable
final class TripleBubbleCluster {

    /// 重要度順の3枠。上からセッション → Fable → 週間で、少しずつ小さくなる
    enum Slot: Int, CaseIterable {
        case session = 0
        case fable = 1
        case weekly = 2

        var index: Int { rawValue }

        var metric: BubbleMetric {
            switch self {
            case .session: return .session
            case .fable: return .fable
            case .weekly: return .weekly
            }
        }

        /// 基準の直径（重要度順に少しずつ小さく）。
        /// 主役のセッションは1つ表示のバブル（72pt）と同じ大きさ・同じ膨張率
        var baseDiameter: CGFloat {
            switch self {
            case .session: return 72
            case .fable: return 62
            case .weekly: return 50
            }
        }

        func caption(fableLabel: String) -> String {
            switch self {
            case .session: return "5h"
            case .fable: return fableLabel
            case .weekly: return "週間"
            }
        }
    }

    /// ホーム位置。上からセッション→Fable→週間の優先度を保ちつつ、
    /// 縦一列に伸びないよう三角形に寄せて「ぎゅっと一塊」にする。
    /// 3ペアとも縁を約3pt重ねた密着配置: 漂いで最も離れた瞬間でもくびれが繋がったままになる。
    /// （5ptまで重ねると窮屈＝ユーザー確認済み。コンテナ内の融合は形状の和として描かれるため
    ///   軽い重なりは安全。Appleの「重ねるな」指針はコンテナ外の独立ガラス同士の話）
    static let homes: [CGPoint] = [
        CGPoint(x: 80, y: 81),   // セッション（最上・最大・やや左）
        CGPoint(x: 140, y: 103), // Fable（右へ振る）
        CGPoint(x: 99, y: 136),  // 週間（最下・最小）
    ]

    /// 個別ドラッグで動かせる範囲（リーシュ）。これを超えると塊ごと動く
    static let leashRadius: CGFloat = 28

    /// 個別ドラッグによるホームからのズレ
    var dragOffsets: [CGSize] = [.zero, .zero, .zero]

    /// 掴んでいる球（nilなら未ドラッグ）
    var draggingSlot: Slot?

    /// クリックのポヨン用スケール
    var bounceScales: [CGFloat] = [1, 1, 1]

    /// 割れて消えている球
    var poppedSlots: Set<Int> = []

    /// 割れた時点のリセット時刻（球ごと）。「リセットで新しい期間に入ったら復活」の判定に使う
    var poppedResetsAt: [Int: Date] = [:]

    /// 表面張力で吸い付いている相手（ヒステリシス用）
    private var snappedNeighbor: Slot?

    /// 縁の距離がこれ以下になったら吸い付く（強すぎると操作を奪うので浅めに）
    static let snapEnterGap: CGFloat = 4
    /// 吸い付いた後の落ち着く縁の距離（重ねない: Appleの指針）
    static let snapRestGap: CGFloat = 3
    /// これ以上引き離すと離れる（吸着より大きくしてヒステリシスにする）
    static let snapExitGap: CGFloat = 10
    /// 吸着の強さ（1.0で完全に吸い付く。弱めて「引っ張れば動く」感触を残す）
    static let snapStrength: CGFloat = 0.45

    func home(for slot: Slot) -> CGPoint { Self.homes[slot.index] }

    /// 使用量に応じた直径。膨らむのは主役のセッションだけ（膨張率は1つ表示と同じ）。
    /// 小さい球まで膨らむと使用量次第で主役との大小関係が崩れ、優先度が読めなくなる
    func diameter(for slot: Slot, state: AppState) -> CGFloat {
        guard slot == .session else { return slot.baseDiameter }
        let utilization = state.usage?.window(for: slot.metric)?.utilization ?? 0
        return slot.baseDiameter * PanelController.bubbleScaleFactor(for: utilization)
    }

    // MARK: - 漂い（macOS 26は宣言的アニメーション / 旧OSは時刻からの直接計算）

    /// 球ごとに違う振幅・周期。さらにX/Yで周期をずらすことで、
    /// 3つが同じ動きに揃わず、それぞれ独立にふわふわ漂って見える。
    /// 振幅は塊全体の浮遊（±8.5pt）に埋もれない大きさにして「球ごとに生きてる」相対運動を見せる。
    /// 縁がほぼ接する配置なので漂いで周期的に軽く重なる＝くびれが太くなったり離れたりする表情になる
    private static let driftAmplitudeX: [CGFloat] = [3.5, -4.5, 4]
    private static let driftAmplitudeY: [CGFloat] = [4.5, 3.5, -4]
    private static let driftDurationX: [Double] = [3.4, 4.5, 3.8]
    private static let driftDurationY: [Double] = [5.0, 3.1, 5.5] // Xと違う周期にして円運動にしない
    private static let driftDelay: [Double] = [0, 0.9, 1.7]       // 開始位相もずらす

    func driftX(for slot: Slot, drifting: Bool) -> CGFloat {
        Self.driftAmplitudeX[slot.index] * (drifting ? 1 : -1)
    }

    func driftY(for slot: Slot, drifting: Bool) -> CGFloat {
        Self.driftAmplitudeY[slot.index] * (drifting ? 1 : -1)
    }

    func driftAnimationX(for slot: Slot) -> Animation {
        .easeInOut(duration: Self.driftDurationX[slot.index])
            .repeatForever(autoreverses: true)
            .delay(Self.driftDelay[slot.index])
    }

    func driftAnimationY(for slot: Slot) -> Animation {
        .easeInOut(duration: Self.driftDurationY[slot.index])
            .repeatForever(autoreverses: true)
            .delay(Self.driftDelay[slot.index] * 0.6)
    }

    /// 旧OS用: 時刻から漂いを直接計算する。
    /// 宣言的アニメーションの「終点」ではなく実際の表示位置が必要なため
    /// （球とくびれを同じ座標から描かないと繋がって見えない）。
    /// 波形はX/Yで周期が違うeaseInOut往復＝正弦波と同等になるよう合わせてある
    func driftOffset(for slot: Slot, at time: TimeInterval) -> CGSize {
        let i = slot.index
        let delay = Self.driftDelay[i]
        let x = sin((time - delay) * 2 * .pi / (Self.driftDurationX[i] * 2)) * Self.driftAmplitudeX[i]
        let y = sin((time - delay * 0.6) * 2 * .pi / (Self.driftDurationY[i] * 2)) * Self.driftAmplitudeY[i]
        let drag = dragOffsets[i]
        return CGSize(width: x + drag.width, height: y + drag.height)
    }

    /// 球の中心（旧OSのくびれ計算用）
    func center(for slot: Slot, at time: TimeInterval) -> CGPoint {
        let home = home(for: slot)
        let offset = driftOffset(for: slot, at: time)
        return CGPoint(x: home.x + offset.width, y: home.y + offset.height)
    }

    // MARK: - ヒットテストとドラッグ

    /// ウィンドウ内座標（SwiftUI座標系: 左上原点）でどの球を指しているか。
    /// 手前に描かれる小さい球を優先するため逆順に見る
    func slot(at point: CGPoint, state: AppState) -> Slot? {
        for slot in Slot.allCases.reversed() {
            let center = home(for: slot)
            let drag = dragOffsets[slot.index]
            let c = CGPoint(x: center.x + drag.width, y: center.y + drag.height)
            let r = diameter(for: slot, state: state) / 2 + 8 // 漂いぶんの余裕
            if hypot(point.x - c.x, point.y - c.y) <= r { return slot }
        }
        return nil
    }

    /// 個別ドラッグ。リーシュを超えた分は返り値で返し、呼び出し側が塊（ウィンドウ）を動かす
    @discardableResult
    func dragBall(_ slot: Slot, by delta: CGSize, state: AppState) -> CGSize {
        let raw = delta
        let length = hypot(raw.width, raw.height)
        var offset = raw
        var overflow = CGSize.zero
        if length > Self.leashRadius {
            // リーシュが張り詰めた: 円周上で止め、超過分は塊の移動へ回す
            let scale = Self.leashRadius / length
            offset = CGSize(width: raw.width * scale, height: raw.height * scale)
            overflow = CGSize(width: raw.width * (1 - scale), height: raw.height * (1 - scale))
        }
        dragOffsets[slot.index] = snapped(slot, offset: offset, state: state)
        return overflow
    }

    /// 表面張力の吸着。近づいたら縁が数pt空いた位置へ引き寄せ、
    /// 一度くっついたら大きく引き離すまで離れない（ヒステリシス）
    private func snapped(_ slot: Slot, offset: CGSize, state: AppState) -> CGSize {
        let home = home(for: slot)
        let center = CGPoint(x: home.x + offset.width, y: home.y + offset.height)
        let myRadius = diameter(for: slot, state: state) / 2

        for other in Slot.allCases where other != slot && !poppedSlots.contains(other.index) {
            let otherHome = self.home(for: other)
            let otherDrag = dragOffsets[other.index]
            let otherCenter = CGPoint(x: otherHome.x + otherDrag.width, y: otherHome.y + otherDrag.height)
            let sumRadius = myRadius + diameter(for: other, state: state) / 2
            let distance = hypot(center.x - otherCenter.x, center.y - otherCenter.y)
            let gap = distance - sumRadius

            let isSnappedToThis = snappedNeighbor == other
            let shouldSnap = isSnappedToThis ? gap < Self.snapExitGap : gap < Self.snapEnterGap
            guard shouldSnap, distance > 0.01 else { continue }

            if !isSnappedToThis {
                snappedNeighbor = other
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            // 縁が snapRestGap 空いた位置へ引き寄せる。
            // 完全には吸い付かせず（snapStrength）、引っ張れば動く感触を残す
            let target = sumRadius + Self.snapRestGap
            let ux = (center.x - otherCenter.x) / distance
            let uy = (center.y - otherCenter.y) / distance
            let pulled = CGPoint(x: otherCenter.x + ux * target, y: otherCenter.y + uy * target)
            let k = Self.snapStrength
            let blended = CGPoint(
                x: center.x + (pulled.x - center.x) * k,
                y: center.y + (pulled.y - center.y) * k
            )
            return CGSize(width: blended.x - home.x, height: blended.y - home.y)
        }
        snappedNeighbor = nil
        return offset
    }

    /// 放したらゆるいばねでホームへ戻る（「なんとなく」優先度配置に落ち着く）
    func releaseBall() {
        draggingSlot = nil
        snappedNeighbor = nil
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) {
            dragOffsets = [.zero, .zero, .zero]
        }
    }

    // MARK: - 球ごとのポヨンと破裂

    /// クリックのポヨン（強さは連打回数で変わる）
    func bounce(_ slot: Slot, intensity: CGFloat = 1) {
        withAnimation(.easeOut(duration: 0.11)) {
            bounceScales[slot.index] = 1 + 0.13 * intensity
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.11))
            withAnimation(.spring(response: 0.34, dampingFraction: 0.45)) {
                self?.bounceScales[slot.index] = 1
            }
        }
    }

    /// その球だけ割れて消える（他の球は残る）
    func pop(_ slot: Slot) {
        withAnimation(.easeOut(duration: 0.2)) {
            _ = poppedSlots.insert(slot.index)
        }
        bounceScales[slot.index] = 1
    }

    /// リセット後などに生まれ直す
    func revive(_ slot: Slot) {
        guard poppedSlots.contains(slot.index) else { return }
        poppedResetsAt.removeValue(forKey: slot.index)
        withAnimation(.bouncy(duration: 0.45)) {
            _ = poppedSlots.remove(slot.index)
        }
    }

    var allPopped: Bool { poppedSlots.count == Slot.allCases.count }
}
