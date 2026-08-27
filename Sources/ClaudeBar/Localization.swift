import Foundation

/// ローカライズ済み文字列を引く。
///
/// SPMのリソースは `Bundle.module` に入るため、`NSLocalizedString` の既定
/// （`Bundle.main`）ではなくこちらを明示的に見に行く必要がある。
/// 言語の選択はシステム環境設定に自動追従し、未対応言語は
/// `defaultLocalization: "en"`（Package.swift）にフォールバックする。
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: nil, table: nil)
}

/// 書式付きのローカライズ文字列（`%@` / `%d` などを含むもの）。
///
/// 引数なしの `L(_:)` と別名にせず引数の有無で解決させると、
/// `L("key")` が可変長版に吸われて書式が展開されないまま返る事故が起きたため、
/// 呼び出し側から見て確実に別物になるよう引数ラベルを付けている
func L(_ key: String, _ a1: CVarArg) -> String {
    String(format: Bundle.module.localizedString(forKey: key, value: nil, table: nil),
           locale: .autoupdatingCurrent, a1)
}

func L(_ key: String, _ a1: CVarArg, _ a2: CVarArg) -> String {
    String(format: Bundle.module.localizedString(forKey: key, value: nil, table: nil),
           locale: .autoupdatingCurrent, a1, a2)
}
