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
        /// 主役のセッションは1つ表示のバブル（64pt）と同じ大きさ
        var baseDiameter: CGFloat {
            // 検証用: CLAUDEBAR_TRIPLE_SIZES="72,62,50" で基準径を差し替えられる
            if let raw = ProcessInfo.processInfo.environment["CLAUDEBAR_TRIPLE_SIZES"] {
                let parts = raw.split(separator: ",").compactMap { Double($0) }
                if parts.count == 3 { return CGFloat(parts[index]) }
            }
            // 3球とも64pt以下。Liquid Glass は65pt以上で「大きい要素」扱いになり、
            // 背景に応じた light/dark 反転をしなくなる（＝球ごとに見え方が割れる）
            switch self {
            case .session: return 64
            case .fable: return 56
            case .weekly: return 48
            }
        }

        func caption(fableLabel: String) -> String {
            switch self {
            case .session: return "5h"
            case .fable: return fableLabel
            case .weekly: return L("panel.weekly")
            }
        }
    }

    /// ホーム位置。上からセッション→Fable→週間の優先度を保ちつつ、
    /// 縦一列に伸びないよう三角形に寄せて「ぎゅっと一塊」にする。
    /// 3ペアとも縁が約2pt重なる密着配置（3ptはやや深い・5ptは窮屈＝ユーザー確認済み）。
    /// 融合（くびれ）は廃止済みなので、重なりは単に手前の球が奥の球を隠すだけになる
    /// 2026-08-29: 直径を 72/62/50 → 64/56/48 にしたので、**この配置も取り直した**。
    /// 旧配置のままだと3ペアとも縁が +2.2〜+5.2pt 離れ、「密着した一塊」が崩れる。
    /// 3ペアとも縁が約2pt重なるよう三角形を解き直し、外接矩形の中心を
    /// ウィンドウ(220x210)の中心に合わせてある
    static let homes: [CGPoint] = [
        CGPoint(x: 84.9, y: 83.1),   // セッション（最上・最大・やや左）
        CGPoint(x: 139.1, y: 103.6), // Fable（右へ振る）
        CGPoint(x: 100.2, y: 134.9), // 週間（最下・最小）
    ]

    /// 個別ドラッグで動かせる範囲（リーシュ）。これを超えると塊ごと動く
    static let leashRadius: CGFloat = 28

    /// 個別ドラッグによるホームからのズレ
    var dragOffsets: [CGSize] = [.zero, .zero, .zero]

    /// 掴んでいる球（nilなら未ドラッグ）
    var draggingSlot: Slot?

    /// クリックのポヨン用スケール
    var bounceScales: [CGFloat] = [1, 1, 1]

    /// バブルの表示世代。showBubbleごとに進み、TripleBallCanvasはこれをidにして
    /// ビューを作り直す。ウィンドウを隠すと宣言的アニメーション（球ごとの漂い）が
    /// レンダーサーバから破棄され、再表示では復元されないため、毎回始め直す
    var showGeneration = 0

    /// バブルを畳んでいる間true。BubbleRootViewはこの間コンテンツを空にする。
    /// ウィンドウをorderOutしてもSwiftUIの無限アニメーション（漂い・ロゴ等）の
    /// 評価はCPU側で回り続け、非表示のまま約7%を食い続けるため、中身ごと畳む
    var contentParked = false

    /// 割れて消えている球
    var poppedSlots: Set<Int> = []

    /// 割れた時点のリセット時刻（球ごと）。「リセットで新しい期間に入ったら復活」の判定に使う
    var poppedResetsAt: [Int: Date] = [:]

    /// ドラッグ中に吸い付いている相手（ヒステリシス用）
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

    // MARK: - 漂い（球ごとのDriftHost=CAAnimationのパラメータ）

    /// 球ごとに違う振幅・周期。さらにX/Yで周期をずらすことで、
    /// 3つが同じ動きに揃わず、それぞれ独立にふわふわ漂って見える。
    /// 振幅は塊全体の浮遊（±8.5pt）に埋もれない大きさにして「球ごとに生きてる」相対運動を見せる
    // 2026-08-27: 球ごとのホスト化で**実際に描画されるようになった**ため、
    // 一度2倍にした振幅は元の値へ戻した（描画されるようになった途端に
    // 「動きが激しい」＝v1.5.3くらいがちょうどいい、というユーザー判断）。
    // 見た目の総移動量は「塊の漂い＋球ごとの漂い」なので、塊側（startFloating）を
    // 3つ表示のときだけ下げて合計を v1.5.3 相当に保つ
    private static let driftAmplitudeX: [CGFloat] = [3.5, -4.5, 4]
    private static let driftAmplitudeY: [CGFloat] = [4.5, 3.5, -4]
    private static let driftDurationX: [Double] = [3.4, 4.5, 3.8]
    private static let driftDurationY: [Double] = [5.0, 3.1, 5.5] // Xと違う周期にして円運動にしない
    private static let driftDelay: [Double] = [0, 0.9, 1.7]       // 開始位相もずらす
    /// 球が home からずれ得る最大距離。外接矩形と当たり判定の余裕に使う
    static var maxDriftAmplitude: CGFloat {
        let m = zip(driftAmplitudeX, driftAmplitudeY).map { max(abs($0), abs($1)) }.max() ?? 0
        return m * driftGain
    }

    /// 球ごとの漂いの倍率（検証・調整用: CLAUDEBAR_DRIFT_GAIN=%）
    static let driftGain: CGFloat = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_DRIFT_GAIN"] ?? "100") ?? 100
        return CGFloat(min(max(raw, 0), 1000) / 100)
    }()

    /// 球ごとの漂いパラメータ（DriftHost用）。振幅・周期・開始位相の組
    func driftParams(for slot: Slot) -> (ax: CGFloat, dx: Double, ay: CGFloat, dy: Double, phase: Double) {
        let i = slot.index
        let gain = Self.driftGain
        return (Self.driftAmplitudeX[i] * gain, Self.driftDurationX[i],
                Self.driftAmplitudeY[i] * gain, Self.driftDurationY[i], Self.driftDelay[i])
    }

    // MARK: - ヒットテストとドラッグ

    /// ウィンドウ内座標（SwiftUI座標系: 左上原点）でどの球を指しているか。
    /// 描画順（zIndex: セッション最前面）と同じ前から順に見る — 重なった部分では
    /// 見えている球が反応する。割れて消えている球は対象外
    /// （残すと跡地がクリックを奪い、掴むと空ドラッグになる）
    func slot(at point: CGPoint, state: AppState) -> Slot? {
        for slot in Slot.allCases where !poppedSlots.contains(slot.index) {
            let center = home(for: slot)
            let drag = dragOffsets[slot.index]
            let c = CGPoint(x: center.x + drag.width, y: center.y + drag.height)
            let r = diameter(for: slot, state: state) / 2 + Self.maxDriftAmplitude + 3 // 漂いぶんの余裕
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

    /// ドラッグ時の吸着。近づいたら縁が数pt空いた位置へ引き寄せ、
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

    /// 破裂前の「ぐぐぐ」: その球だけがじわっと膨らむ。
    /// 音源の軋み部分（PanelController.popStrainDuration）と長さを合わせる
    func strain(_ slot: Slot) {
        withAnimation(.timingCurve(0.35, 0, 0.75, 1, duration: PanelController.popStrainDuration)) {
            bounceScales[slot.index] = 1.16
        }
    }

    /// 膨張を戻す（破裂が取り消されたとき用）
    func relaxStrain(_ slot: Slot) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            bounceScales[slot.index] = 1
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
