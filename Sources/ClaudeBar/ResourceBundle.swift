import Foundation

/// アプリのリソースバンドル（Localizable.strings・効果音）の置き場所を解決する。
///
/// SwiftPM が生成する `Bundle.module` は「`.app` 直下」と「**ビルド時の絶対パス**」の
/// 2か所しか探さない。一方 `make-app.sh` は正規の場所である `Contents/Resources/` に置く。
/// 開発機では絶対パスのフォールバックが効いてしまうため気づけず、**配布先では必ず落ちる**
/// （Issue #2・v1.6.0 は使用量の初回反映で全ユーザーがクラッシュした）。
/// `Bundle.module` を直接使わず、必ずここを通すこと。
enum AppResources {
    static let bundleName = "ClaudeBar_ClaudeBar.bundle"

    /// 配布 `.app` の正規の場所（`Contents/Resources/`）**だけ**を見る。
    /// セルフテストはこれで判定する（フォールバックに救われて合格しないように）
    static var packagedBundle: Bundle? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName) else { return nil }
        return Bundle(url: url)
    }

    /// 実際に使うバンドル。配布 .app → .app 直下 → 開発ビルド（`Bundle.module`）の順
    static let bundle: Bundle = {
        if let packaged = packagedBundle { return packaged }
        if let beside = Bundle(url: Bundle.main.bundleURL.appendingPathComponent(bundleName)) { return beside }
        // `swift build` の素の実行ファイル。ここまで来て無ければ SwiftPM の
        // アクセサが（開発機のパスを添えて）fatalError する＝開発時にしか起きない
        return Bundle.module
    }()

    /// 配布 .app の組み立て検証（`CLAUDEBAR_SELFTEST=resources` で起動すると実行して終了）。
    /// **フォールバックを使わず** `Contents/Resources/` から実際に文字列と音を引けることを確かめる。
    /// make-app.sh がこれを走らせるので、CI とリリースの両方でバンドル欠落を検知できる
    static func selfTest() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            FileHandle.standardError.write("\(condition ? "✅" : "❌") \(label)\n".data(using: .utf8)!)
            if !condition { ok = false }
        }
        guard let bundle = packagedBundle else {
            check(false, "Contents/Resources/\(bundleName) が見つからない（Bundle.main.resourceURL=\(Bundle.main.resourceURL?.path ?? "nil")）")
            return false
        }
        check(true, "Contents/Resources/\(bundleName) を読み込めた")
        for lang in ["ja", "en"] {
            let value = bundle.path(forResource: lang, ofType: "lproj")
                .flatMap(Bundle.init(path:))?
                .localizedString(forKey: "panel.title", value: "", table: nil) ?? ""
            check(!value.isEmpty && value != "panel.title", "\(lang).lproj の panel.title = \"\(value)\"")
        }
        check(bundle.url(forResource: "bubble-pop", withExtension: "aiff") != nil, "bubble-pop.aiff がある")
        return ok
    }
}
