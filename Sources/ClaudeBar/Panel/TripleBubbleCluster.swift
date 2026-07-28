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

        /// 基準の直径（重要度順に少しずつ小さく）
        var baseDiameter: CGFloat {
            switch self {
            case .session: return 76
            case .fable: return 64
            case .weekly: return 54
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

    /// ホーム位置。真っ直ぐ縦に並べず左右へ振り、塊を小さくまとめる。
    /// 隣同士は縁が約5pt空いた近接（Appleの「Liquid Glass要素を重ねるな」に従い重ねない）。
    /// セッション⇔週間は約41pt離してネックを張らせない
    static let homes: [CGPoint] = [
        CGPoint(x: 128, y: 112), // セッション（最上・最大・やや左）
        CGPoint(x: 176, y: 170), // Fable（右へ振る）
        CGPoint(x: 134, y: 218), // 週間（最下・最小・左へ戻す）
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

    /// 表面張力で吸い付いている相手（ヒステリシス用）
    private var snappedNeighbor: Slot?

    /// 縁の距離がこれ以下になったら吸い付く
    static let snapEnterGap: CGFloat = 8
    /// 吸い付いた後の落ち着く縁の距離（重ねない: Appleの指針）
    static let snapRestGap: CGFloat = 4
    /// これ以上引き離すと離れる（吸着より大きくしてヒステリシスにする）
    static let snapExitGap: CGFloat = 20

    func home(for slot: Slot) -> CGPoint { Self.homes[slot.index] }

    /// 使用量に応じた直径（現行バブルと同じ膨らみ方）
    func diameter(for slot: Slot, state: AppState) -> CGFloat {
        let utilization = state.usage?.window(for: slot.metric)?.utilization ?? 0
        return slot.baseDiameter * PanelController.bubbleScaleFactor(for: utilization)
    }

    // MARK: - 漂い（宣言的アニメーションでレンダーサーバへ委譲）

    /// 球ごとに違う振幅・周期にして有機的に見せる
    private static let driftAmplitudes: [CGSize] = [
        CGSize(width: 6, height: 8),
        CGSize(width: -8, height: 5),
        CGSize(width: 5, height: -7),
    ]
    private static let driftDurations: [Double] = [3.7, 4.6, 5.3]

    /// 漂い + 個別ドラッグの合成オフセット
    func offset(for slot: Slot, drifting: Bool) -> CGSize {
        let amplitude = Self.driftAmplitudes[slot.index]
        let drag = dragOffsets[slot.index]
        let sign: CGFloat = drifting ? 1 : -1
        return CGSize(
            width: amplitude.width * sign + drag.width,
            height: amplitude.height * sign + drag.height
        )
    }

    func driftAnimation(for slot: Slot) -> Animation {
        .easeInOut(duration: Self.driftDurations[slot.index]).repeatForever(autoreverses: true)
    }

    // MARK: - ヒットテストとドラッグ

    /// ウィンドウ内座標（SwiftUI座標系: 左上原点）でどの球を指しているか。
    /// 手前に描かれる小さい球を優先するため逆順に見る
    func slot(at point: CGPoint, state: AppState) -> Slot? {
        for slot in Slot.allCases.reversed() {
            let center = home(for: slot)
            let drag = dragOffsets[slot.index]
            let c = CGPoint(x: center.x + drag.width, y: center.y + drag.height)
            let r = diameter(for: slot, state: state) / 2 + 6 // 漂いぶんの余裕
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
            // 縁が snapRestGap 空いた位置へ吸い寄せる
            let target = sumRadius + Self.snapRestGap
            let ux = (center.x - otherCenter.x) / distance
            let uy = (center.y - otherCenter.y) / distance
            let snappedCenter = CGPoint(x: otherCenter.x + ux * target, y: otherCenter.y + uy * target)
            return CGSize(width: snappedCenter.x - home.x, height: snappedCenter.y - home.y)
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
            poppedSlots.insert(slot.index)
        }
        bounceScales[slot.index] = 1
    }

    /// リセット後などに生まれ直す
    func revive(_ slot: Slot) {
        guard poppedSlots.contains(slot.index) else { return }
        withAnimation(.bouncy(duration: 0.45)) {
            poppedSlots.remove(slot.index)
        }
    }

    var allPopped: Bool { poppedSlots.count == Slot.allCases.count }
}
