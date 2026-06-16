# TODO: vime.vim

作成日: 2026-06-16
生成元: planning-tasks
設計書: docs/DESIGN.md / docs/GLOSSARY.md

## 概要

英字を一気に日本語へ変換するモード式 IME の Neovim プラグイン。pure Lua(LuaJIT) + libanthy(FFI)。
依存の少ない純粋関数から積み上げる: romaji → anthy → session → ui → config/keymap → init。
副作用(FFI / ~/.anthy)は anthy.lua に閉じ込め、session は fake anthy を注入して状態遷移を FFI 非依存でテストする。

feasibility は検証済み(poc/FINDINGS.md)。poc/ のケースはテストに移植する。

## 実装タスク

### フェーズ1: 基盤構築

- [x] プラグイン構造の作成(`lua/vime/`, `tests/`, `plugin/` 不要なら省略)
- [x] テストフレームワーク選定・導入(plenary.nvim の busted 風 or busted)
- [x] テスト実行手段の整備(`Makefile` or `scripts/test`: `nvim --headless` でテスト実行)
- [x] `.luarc.json` の確認(既存。lua_ls の Neovim 設定)
- [x] [CHECK] テストランナーが空テストを実行できることを確認

### フェーズ2: romaji.lua(ローマ字→かな・純粋関数)

- [x] [RED] 基本五十音・濁音・半濁音の変換テスト(`ka→か`, `ga→が`, `pa→ぱ`)
- [x] [GREEN] 変換テーブル + 最長一致の最小実装
- [x] [RED] 拗音(`kyou→きょう`)・外来音(`fa→ふぁ`, `che→ちぇ`)のテスト
- [x] [GREEN] 拗音・外来音テーブルの実装
- [x] [RED] 促音のテスト(`tte→って`, `kekka→けっか`, `matcha→まっちゃ`)
- [x] [GREEN] 促音(同子音連続 / tch)の実装
- [x] [RED] 撥音のテスト(`kanji→かんじ`, `konnichiha→こんにちは`, `onna→おんな`, `tennki→てんき`, `nn→ん`, `hon'ya→ほんや`)
- [x] [GREEN] 撥音の look-ahead 実装(2つ目の n の次が母音/y なら1つ消費)
- [x] [RED] エッジのテスト(大文字小文字化 `Kyou→きょう`, 未定義文字 passthrough, 数字混在)
- [x] [GREEN] 大文字小文字化・未定義 passthrough の実装
- [x] [REFACTOR] テーブルと走査ロジックの整理(poc/romaji.lua から移植・命名整理)
- [x] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [x] [CHECK] lint/format/test の実行と確認

### フェーズ3: anthy.lua(libanthy FFI ラッパ・副作用境界)

- [x] [RED] `setup(lib_path)` のテスト(正常ロードで true、不正パスで false。クラッシュしない)
- [x] [GREEN] `ffi.cdef` + `ffi.load`(pcall) + `anthy_init` の実装
- [x] [RED] `new_session()` / `session:convert(yomi)` のテスト(実 libanthy で文節・候補を返す)
- [x] [GREEN] context 生成(UTF8) + `set_string`/`get_stat`/`get_segment` で `{segments=[{best,candidates}]}` を返す実装(必要 byte 長は `get_segment(...,nil,0)` で動的確保)
- [x] [RED] `session:resize(seg, delta)` のテスト(区切り直しで文節が変わる)
- [x] [GREEN] `anthy_resize_segment` + 再取得の実装
- [x] [RED] `session:commit(choices)` のテスト(全文節 commit で学習され、再変換で TOP が変わる)
- [x] [GREEN] `anthy_commit_segment` を全文節へ適用する実装
- [x] [RED] `session:close()` のテスト(context 解放)
- [x] [GREEN] `anthy_release_context` の実装
- [x] [REFACTOR] 公開インターフェースの整形(session が依存する形だけに絞る)
- [x] テスト用 fake anthy の作成(決め打ちの文節・候補を返すダブル。session テストで使用)
- [x] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [x] [CHECK] lint/format/test の実行と確認

### フェーズ4: session.lua(状態機械・fake anthy 注入)

- [x] [RED] COMPOSING: ローマ字入力で未確定読みが更新されるテスト(romaji 経由)
- [x] [GREEN] COMPOSING 状態と読み蓄積の実装
- [x] [RED] COMPOSING→CONVERTING: Space で変換し注目文節=0・TOP 候補になるテスト(fake anthy)
- [x] [GREEN] 変換開始の実装
- [x] [RED] 次候補: Space で注目文節の候補 index が巡回するテスト
- [x] [GREEN] 候補巡回の実装
- [x] [RED] 文節移動: C-f/C-b で注目 index が移動するテスト(端で clamp)
- [x] [GREEN] 文節移動の実装
- [x] [RED] 文節伸縮: C-o/C-i で resize が呼ばれ文節が再構成されるテスト
- [x] [GREEN] 文節伸縮の実装
- [x] [RED] 確定: Enter で全文節 commit され確定文字列を返し COMPOSING(空)へ戻るテスト
- [x] [GREEN] 確定(=学習)の実装
- [x] [RED] 取消: C-g/Esc で CONVERTING→変換前のかな(COMPOSING)へ戻るテスト
- [x] [GREEN] 取消の実装
- [x] [RED] 自動確定: CONVERTING 中の英字入力で現変換を確定し新規 COMPOSING になるテスト
- [x] [GREEN] 自動確定の実装
- [x] [RED] 境界・異常系: 空入力 Space は無反応、0文節、index 範囲外 clamp のテスト
- [x] [GREEN] 境界処理の実装
- [x] [REFACTOR] 状態遷移テーブルの整理(状態×イベントの見通し改善)
- [x] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [x] [CHECK] lint/format/test の実行と確認

### フェーズ5: ui.lua(extmark 描画 + 候補 popup)

- [x] [RED] 未確定下線: 読み列に `VimeUnconfirmed` extmark が byte 範囲で付くテスト
- [x] [GREEN] 未確定描画の実装(namespace + set_extmark)
- [x] [RED] 文節反転: 注目文節に `VimeSegment` が**正しい byte offset**で付くテスト(マルチバイト重点。文字数誤用でズレないこと)
- [x] [GREEN] 文節 byte 範囲計算 + 反転描画の実装
- [x] [RED] 候補 popup: floating window が生成され、ラベル付き候補が並び、破棄できるテスト
- [x] [GREEN] popup(nvim_open_win) の生成/ラベル付与/クローズの実装
- [x] [RED] 描画クリア: 確定/取消で extmark と popup が消えるテスト
- [x] [GREEN] クリア処理の実装
- [x] [REFACTOR] 描画ロジックの整理(byte offset 計算をヘルパに集約)
- [x] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [x] [CHECK] lint/format/test の実行と確認

### フェーズ6: config.lua(設定マージ)

- [x] [RED] デフォルト設定とユーザー上書きのマージテスト(keymaps/popup/highlight)
- [x] [GREEN] deep merge の実装
- [x] [RED] `anthy.lib` 未指定時の既知パス探索・無ければ無効フラグのテスト
- [x] [GREEN] パス探索/無効化の実装
- [x] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [x] [CHECK] lint/format/test の実行と確認

### フェーズ7: keymap.lua(キーディスパッチ)

- [x] [RED] 挿入モードキーが session/ui の対応操作にディスパッチされるテスト(spy/fake)
- [x] [GREEN] バッファローカル keymap 登録 + ディスパッチの実装
- [x] [RED] 状態に応じてキーの意味が変わる(Space=変換/次候補 等)テスト
- [x] [GREEN] 状態依存ディスパッチの実装
- [x] [REFACTOR] キー定義と動作の対応表の整理
- [x] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [x] [CHECK] lint/format/test の実行と確認

### フェーズ8: init.lua(setup・結線)

- [x] [RED] `setup(opts)` でハイライト定義・config マージ・anthy.setup・keymap 登録が行われるテスト
- [x] [GREEN] 結線の実装
- [x] [RED] anthy ロード失敗時に `vim.notify` 警告し、トグルしても無反応(無効化)になるテスト
- [x] [GREEN] 失敗時無効化の実装(Vim を壊さない)
- [x] [RED] 日本語入力 ON/OFF トグルのモード管理テスト
- [x] [GREEN] モード管理の実装
- [x] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [x] [CHECK] lint/format/test の実行と確認

### フェーズ9: 統合・品質保証

- [x] 実機 end-to-end 手動確認(tests/smoke.lua: 実キーストロークで `kyouhaiitenkidane`→`今日は良い天気だね`)
- [ ] [STRUCTURAL] モジュール間の重複・命名のコード整理(動作変更なし)
- [x] 全テスト実行と確認(36 件 green)
- [x] README(最小: 依存=anthy、setup 例、キーバインド表)
- [x] [REVIEW] 全体の簡易セルフレビューと修正
- [x] [CHECK] test の最終実行と確認

## 実装ノート

### DESIGN.md からの対応確認

- §3 スコープ(モード/ローマ字/変換/候補選択/移動・伸縮/学習/設定) → フェーズ2〜8 で網羅
- §4 状態機械(DIRECT/COMPOSING/CONVERTING) → フェーズ4
- §4.2 キー操作 → フェーズ7、§4.3 描画(byte offset) → フェーズ5
- §5.3 anthy インターフェース → フェーズ3
- §6 エラー処理(ロード失敗/空入力/0文節/範囲外) → フェーズ3・4・8
- §7 設定 → フェーズ6、§8 テスト方針 → 各フェーズ TDD + フェーズ5 で byte offset 重点

### 実装フェーズで確定する未決事項(DESIGN §9)

- BS の削除単位(ローマ字途中 vs 確定済みかな)→ フェーズ4 で扱う
- 候補一覧のラベル枯渇(候補 > ラベル数)→ フェーズ5 で扱う(ページング or 切り詰め)
- `.so` 自動探索のパス候補 → フェーズ6 で扱う
- 確定テキストの undo 単位 → フェーズ8/9 で扱う

### MUST ルール遵守事項

- TDD: RED → GREEN → REFACTOR → REVIEW → CHECK を厳守。テストなしに実装しない
- Tidy First: 構造変更([STRUCTURAL])と動作変更([BEHAVIORAL])を別コミットに分離
- コミット: Conventional Commit + emoji + [STRUCTURAL]/[BEHAVIORAL] プレフィックス
- 設計原則: SOLID/YAGNI、副作用は anthy.lua に閉じ込め、anthy は DIP でテスト時 fake 差し替え
- 最小実装: 頼まれていない機能・抽象化・過剰な異常系を足さない
