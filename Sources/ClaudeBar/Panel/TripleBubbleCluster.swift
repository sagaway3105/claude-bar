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
    func dragBall(_ slot: Slot, by delta: CGSize) -> CGSize {
        let raw = CGSize(width: delta.width, height: delta.height)
        let length = hypot(raw.width, raw.height)
        guard length > Self.leashRadius else {
            dragOffsets[slot.index] = raw
            return .zero
        }
        // リーシュが張り詰めた: 円周上で止め、超過分は塊の移動へ回す
        let scale = Self.leashRadius / length
        dragOffsets[slot.index] = CGSize(width: raw.width * scale, height: raw.height * scale)
        return CGSize(width: raw.width * (1 - scale), height: raw.height * (1 - scale))
    }

    /// 放したらゆるいばねでホームへ戻る（「なんとなく」優先度配置に落ち着く）
    func releaseBall() {
        draggingSlot = nil
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) {
            dragOffsets = [.zero, .zero, .zero]
        }
    }
}
