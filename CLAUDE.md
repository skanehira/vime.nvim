# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

vime.nvim は挿入モードのままで日本語入力できる Neovim プラグイン（モード式 IME）。pure Lua(LuaJIT) + libanthy(FFI) で完結し、外部プロセスを起動しない。

詳細仕様は次の2点に従う（**実装・調査前に必ず参照**）:

- `docs/ARCHITECTURE.md` — 設計判断・モジュール構成・依存方向・状態機械・不変条件と罠・設定 IF・テスト構成・feasibility 確定事項
- `docs/GLOSSARY.md` — ユビキタス言語（コード上の識別子もこの語に揃える）

## コマンド

```sh
make test                                            # plenary.nvim で tests/vime/ を一括実行
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/vime/session_spec.lua" # 単一ファイル実行
nvim --headless -l tests/smoke.lua                   # 実 libanthy を使う E2E スモーク
```

- `tests/minimal_init.lua` が `HOME` と `XDG_CONFIG_HOME` を毎回 `tempname()` 配下へ差し替え、学習をテスト（spec ファイル＝別 nvim）ごとに隔離する。原 anthy は `$HOME/.anthy`、anthy-unicode は `$XDG_CONFIG_HOME/anthy`（anthy-unicode の HOME は `getpwuid` 由来で env では変えられないので XDG 隔離が必須）。テスト前提を変える際はここを必ず確認する。
- libanthy のパスはハードコードせず `config.find_anthy_lib()`（`$VIME_ANTHY_LIB` → `~/.local/lib` 等の標準パス → nix glob。`libanthy-unicode`/`libanthy` 両名）で解決する。**`HOME` を temp 化すると `~` 展開が壊れるため、`minimal_init`/`smoke` は HOME 差し替え前に lib を解決して `VIME_ANTHY_LIB` に固定**する。別 lib を使うときも `VIME_ANTHY_LIB` を設定。
- `session_spec` も実 anthy を注入して動かす（fake は廃止）。学習で結果が揺れないよう、辞書依存の絶対値ではなく安定事実・相対変化で検証し、学習する `it` は describe 末尾に置く。
- 推奨エンジンは現役保守の anthy-unicode（別名 `libanthy-unicode`、ABI 互換なので cdef は無改変で 9100h とも共用）。dict が 9100h と異なり同じ読みでも分割/候補が変わる（例: きょうはいいてんきだね は 9100h=今日は… / unicode=今日…）ので、テストの絶対値依存は避ける。

## アーキテクチャの要点

### 依存方向（ARCHITECTURE.md §3.1 に準拠）

```
keymap ──► session ──► anthy (DIP インターフェース)
                  └──► romaji (純粋関数)
   ui ◄── session (状態を読んで描画)
config ──► (各モジュールが参照)
init ──► 全モジュールを結線するコントローラ
```

- **副作用はすべて `anthy.lua` に閉じ込める**。FFI と学習の永続化がここに入る。`session` は `anthy_module` を **コンストラクタ注入**（`session.new(anthy_module)`）で受け取り、テストでも実 anthy を注入する（fake は廃止）。
- **`romaji.lua` は純粋関数のみ**。FFI も Vim API も触らない。テストは入出力比較で完結する。
- **`init.lua` がコントローラ**。バッファ・カーソル位置・未確定領域(`start_col`/`len`)・popup 状態を保持し、`session` の状態変化を `ui` 描画に流す唯一の場所。新しいハンドラを足すときも `init.lua` の `handlers()` テーブル経由で `keymap.lua` に渡す。

### 必ず守る不変条件

- **文節ハイライトの範囲計算は byte オフセット**で行う。日本語1文字=3byte なので文字数で計算すると確実にズレる（ARCHITECTURE.md §6）。`ui.highlight_segments` を変更するときは特に注意。
- **公開 API は 1-based、anthy 内部は 0-based**。`anthy.lua` の `Session:resize`/`Session:commit` が境界で `-1` 補正している。session/ui からは 1-based のまま扱うこと。
- **学習は「全文節 commit」でしか効かない**（ARCHITECTURE.md §6）。`session:commit` は必ず `choices` 配列の全要素を `anthy_commit_segment` に流す。部分 commit を導入しない。
- **挿入モードを抜けるときに未確定を確定する**（`init.lua` の `InsertLeave` autocmd）。これがないと、ノーマルモードに残った未確定 extmark に対する `x`/`u` が壊れる。
- **`anthy.lua` は失敗しても例外を投げない**。`setup` は `false` を返し、`init.lua` 側で `vim.notify` + 無効化する。「Vim を壊さない」がエラーハンドリングの基本方針（ARCHITECTURE.md §7）。過剰な異常系は足さない（YAGNI）。

### キーマッピング

`keymap.lua` は挿入モードの印字可能 ASCII（0x21–0x7e）を**1文字ずつ全部** `handlers.input(ch)` にディスパッチする。`<`, `|`, `\` だけ `<lt>`/`<Bar>`/`<Bslash>` にエスケープする必要があるため、印字可能文字を増やすロジックを変える際は `SPECIAL_LHS` テーブルも併せて更新する。

## このリポジトリ固有の作業ルール

- 実装は `docs/TODO.md` のフェーズ単位で TDD（RED → GREEN → REFACTOR → REVIEW → CHECK）。テストファイルは `tests/vime/<module>_spec.lua` に置く（コロケーションではなく `tests/` 配下のミラー構造）。
- コミットは Conventional Commit + emoji + `[STRUCTURAL]` / `[BEHAVIORAL]` プレフィックスを必ず付ける（既存履歴に合わせる）。構造変更と動作変更は別コミットに分ける。
- LSP 警告は `lua_ls` を `.luarc.json`（LuaJIT + Neovim グローバル + busted DSL）で運用している。busted の `describe`/`it`/`assert` は warning にならない。
- ローマ字テーブルや拗音/促音/撥音のロジックを変えるときは `tests/vime/romaji_spec.lua` のケースを更新する。
