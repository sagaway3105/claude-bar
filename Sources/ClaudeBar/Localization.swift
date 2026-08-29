import Foundation

/// ローカライズ済み文字列を引く。
///
/// SPMのリソースは `Bundle.module` に入るため、`NSLocalizedString` の既定
/// （`Bundle.main`）ではなくこちらを明示的に見に行く必要がある。
/// 言語の選択はシステム環境設定に自動追従し、未対応言語は
/// `defaultLocalization: "en"`（Package.swift）にフォールバックする。
/// 実際に文字列を引くバンドル（`Bundle.module` の中の `<lang>.lproj`）。
///
/// `Bundle.module.localizedString` に任せると、**CFBundle の言語解決が
/// メインバンドルの `.lproj` / `CFBundleLocalizations` に制限される**ため、
/// メインバンドルを持たない生の実行ファイル（`swift build` の
/// `.build/debug/ClaudeBar`）では ja があっても英語に固定されてしまう
/// （配布用 .app は make-app.sh が空の `ja.lproj` を置いて回避している）。
/// ここでは `Locale.preferredLanguages` から自分で最適な言語を選び、
/// その `.lproj` を直接開くことで、開発ビルドでも .app でも同じ言語になる。
private let localizedBundle: Bundle = {
    // 引数1つの `preferredLocalizations(from:)` はメインバンドルの制約を受けて
    // 「en」を返してしまう（実測）。ユーザーの言語リストを明示的に渡す2引数版を使う
    let preferred = Bundle.preferredLocalizations(
        from: Bundle.module.localizations,
        forPreferences: Locale.preferredLanguages
    )
    for code in preferred {
        if let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
    }
    return .module
}()

/// 選んだ `.lproj` を先に引き、**キーが無ければ `Bundle.module` に落とす**。
/// `.lproj` を直接開くと CFBundle の `defaultLocalization`（en）への
/// フォールバックが効かず、未翻訳のキーがそのまま画面に出てしまうため
private func localized(_ key: String) -> String {
    let value = localizedBundle.localizedString(forKey: key, value: MissingKey.marker, table: nil)
    if value != MissingKey.marker { return value }
    return Bundle.module.localizedString(forKey: key, value: nil, table: nil)
}

private enum MissingKey {
    /// 実在しないことが確実な番兵（`value:` に渡すと未定義キーのときに返る）
    static let marker = "\u{0}claudebar.missing"
}

func L(_ key: String) -> String {
    localized(key)
}

/// 書式付きのローカライズ文字列（`%@` / `%d` などを含むもの）。
///
/// 引数なしの `L(_:)` と別名にせず引数の有無で解決させると、
/// `L("key")` が可変長版に吸われて書式が展開されないまま返る事故が起きたため、
/// 呼び出し側から見て確実に別物になるよう引数ラベルを付けている
func L(_ key: String, _ a1: CVarArg) -> String {
    String(format: localized(key),
           locale: .autoupdatingCurrent, a1)
}

func L(_ key: String, _ a1: CVarArg, _ a2: CVarArg) -> String {
    String(format: localized(key),
           locale: .autoupdatingCurrent, a1, a2)
}
