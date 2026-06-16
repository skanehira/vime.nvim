# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

vime.vim は挿入モードのままで日本語入力できる Neovim プラグイン（モード式 IME）。pure Lua(LuaJIT) + libanthy(FFI) で完結し、外部プロセスを起動しない。

詳細仕様は次の3点に従う（**実装・調査前に必ず参照**）:

- `docs/DESIGN.md` — 状態機械・モジュール構成・依存方向・設定 IF
- `docs/GLOSSARY.md` — ユビキタス言語（コード上の識別子もこの語に揃える）
- `poc/FINDINGS.md` — feasibility 検証で確定済みの罠と方針（再検証不要）

## コマンド

```sh
make test                                            # plenary.nvim で tests/vime/ を一括実行
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/vime/session_spec.lua" # 単一ファイル実行
nvim --headless -l tests/smoke.lua                   # 実 libanthy を使う E2E スモーク
```

- `tests/minimal_init.lua` が `HOME` を毎回 `tempname()` に差し替えるため、`~/.anthy` 学習はテストごとに隔離される。テスト前提を変える際はここを必ず確認する。
- smoke は `tests/smoke.lua` 内で nix store の `libanthy.dylib` をハードコードしている。環境が違うとパスを差し替える必要がある。

## アーキテクチャの要点

### 依存方向（DESIGN.md §5.2 に準拠）

```
keymap ──► session ──► anthy (DIP インターフェース)
                  └──► romaji (純粋関数)
   ui ◄── session (状態を読んで描画)
config ──► (各モジュールが参照)
init ──► 全モジュールを結線するコントローラ
```

- **副作用はすべて `anthy.lua` に閉じ込める**。FFI と `~/.anthy` 学習がここに入る。`session` は `anthy_module` を **コンストラクタ注入**（`session.new(anthy_module)`）で受け取り、テストでは `tests/vime/fake_anthy.lua` を渡す。
- **`romaji.lua` は純粋関数のみ**。FFI も Vim API も触らない。テストは入出力比較で完結する。
- **`init.lua` がコントローラ**。バッファ・カーソル位置・未確定領域(`start_col`/`len`)・popup 状態を保持し、`session` の状態変化を `ui` 描画に流す唯一の場所。新しいハンドラを足すときも `init.lua` の `handlers()` テーブル経由で `keymap.lua` に渡す。

### 必ず守る不変条件

- **文節ハイライトの範囲計算は byte オフセット**で行う。日本語1文字=3byte なので文字数で計算すると確実にズレる（FINDINGS D5）。`ui.highlight_segments` を変更するときは特に注意。
- **公開 API は 1-based、anthy 内部は 0-based**。`anthy.lua` の `Session:resize`/`Session:commit` が境界で `-1` 補正している。session/ui からは 1-based のまま扱うこと。
- **学習は「全文節 commit」でしか効かない**（FINDINGS D2）。`session:commit` は必ず `choices` 配列の全要素を `anthy_commit_segment` に流す。部分 commit を導入しない。
- **挿入モードを抜けるときに未確定を確定する**（`init.lua` の `InsertLeave` autocmd）。これがないと、ノーマルモードに残った未確定 extmark に対する `x`/`u` が壊れる。
- **`anthy.lua` は失敗しても例外を投げない**。`setup` は `false` を返し、`init.lua` 側で `vim.notify` + 無効化する。「Vim を壊さない」がエラーハンドリングの基本方針（DESIGN §6）。過剰な異常系は足さない（YAGNI）。

### キーマッピング

`keymap.lua` は挿入モードの印字可能 ASCII（0x21–0x7e）を**1文字ずつ全部** `handlers.input(ch)` にディスパッチする。`<`, `|`, `\` だけ `<lt>`/`<Bar>`/`<Bslash>` にエスケープする必要があるため、印字可能文字を増やすロジックを変える際は `SPECIAL_LHS` テーブルも併せて更新する。

## このリポジトリ固有の作業ルール

- 実装は `docs/TODO.md` のフェーズ単位で TDD（RED → GREEN → REFACTOR → REVIEW → CHECK）。テストファイルは `tests/vime/<module>_spec.lua` に置く（コロケーションではなく `tests/` 配下のミラー構造）。
- コミットは Conventional Commit + emoji + `[STRUCTURAL]` / `[BEHAVIORAL]` プレフィックスを必ず付ける（既存履歴に合わせる）。構造変更と動作変更は別コミットに分ける。
- LSP 警告は `lua_ls` を `.luarc.json`（LuaJIT + Neovim グローバル + busted DSL）で運用している。busted の `describe`/`it`/`assert` は warning にならない。
- ローマ字テーブルや拗音/促音/撥音のロジックを変えるときは `poc/romaji_poc.lua` のケースが既に `tests/vime/romaji_spec.lua` に移植されているのでそちらを更新する。`poc/` 配下の検証スクリプトは feasibility 確定済みのため通常は触らない。
