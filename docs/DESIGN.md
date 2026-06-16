# vime.vim 設計書

## 1. 概要

英字を一気に日本語へ変換する Neovim プラグイン。挿入モードでローマ字を打ち、IME と同じ操作感（モード切替・未確定表示・変換・候補選択・確定・学習）で日本語を入力する。

```
kyouhaiitenkidane → きょうはいいてんきだね → 今日はいい天気だね
       ①ローマ字→かな        ②かな→漢字(Anthy)
```

- 用語は [GLOSSARY.md](GLOSSARY.md) に準拠
- feasibility 検証の詳細は [poc/FINDINGS.md](../poc/FINDINGS.md) に準拠（本書では再掲しない）

## 2. ユーザーストーリー

- 入力者として、IME を OS で切り替えずに Vim の挿入モードのまま日本語を打ちたい
- 入力者として、ローマ字を打って Space で変換し、候補から選んで確定したい
- 入力者として、文節の区切りがずれたら伸縮して直したい
- 入力者として、一度選んだ変換は次回から優先してほしい（学習）
- 入力者として、英数字を打つときはモードを切ってそのまま入力したい

## 3. スコープ

### MVP に含む

- モード式 IME（日本語入力 ON/OFF トグル）
- ローマ字→かな変換（拗音・促音・撥音・外来音）
- 連文節変換（Anthy）と文節ごとの候補取得
- 候補選択（Space 順送り ＋ N 回で候補一覧 popup、ラベルキー一括選択）
- 文節の移動・伸縮
- 学習（全文節 commit による記憶）
- 設定インターフェース（`.so` パス・キーマップ・popup 閾値・ハイライト）

### MVP に含まない（将来）

- SKK 辞書連携 / ユーザー辞書 UI
- カスタムローマ字テーブルの設定 UI
- 複数行にまたがる変換
- 数字の漢数字自動選択など変換後処理
- mozc など他エンジン対応

## 4. UX と状態機械

### 4.1 状態遷移

```
        ┌──────────┐  C-j  ┌───────────────┐
        │  DIRECT  │ ───► │   COMPOSING    │ (未確定/下線)
        │ (日本語OFF)│ ◄─── │  読み入力中     │
        └──────────┘  C-j  └───────────────┘
                              │  ▲        │ Space(非空)
                       Enter/ │  │ C-g/Esc▼
                       BS等   │  │   ┌───────────────┐
                              │  └───│  CONVERTING    │ (変換中/反転)
                              │      │  文節・候補操作  │
                              └──────│                │
                                Enter└───────────────┘
                                (確定=全文節commit→学習)
```

### 4.2 キー操作とアクション

挿入モード・日本語入力 ON 中のキー（すべて設定で変更可）。

| キー               | 状態                 | アクション                                           |
| ------------------ | -------------------- | ---------------------------------------------------- |
| `C-j`              | DIRECT               | 日本語入力 ON（COMPOSING へ）                        |
| `C-j`              | COMPOSING/CONVERTING | 現在の未確定/変換を確定して日本語入力 OFF            |
| 英字               | COMPOSING            | ローマ字バッファに追加。確定したかなを未確定列へ追記 |
| 英字               | CONVERTING           | 現在の変換を自動確定し、新しい読みで COMPOSING       |
| `Space`            | COMPOSING(非空)      | 変換開始（第0文節を注目、TOP 候補）                  |
| `Space`            | CONVERTING           | 注目文節の次候補。閾値回数で候補一覧 popup           |
| ラベルキー(a/s/d…) | 候補一覧表示中       | その候補を選び注目文節へ反映                         |
| `C-f` / `C-b`      | CONVERTING           | 注目文節を次/前へ移動                                |
| `C-o` / `C-i`      | CONVERTING           | 注目文節を伸長/短縮（resize）                        |
| `Enter`            | COMPOSING            | 未確定のかなをそのまま確定                           |
| `Enter`            | CONVERTING           | 変換結果を確定（全文節 commit＝学習）                |
| `BS`               | COMPOSING            | ローマ字バッファ→未確定列の順に1単位削除             |
| `C-g` / `Esc`      | CONVERTING           | 変換を取り消し、変換前のかな(COMPOSING)へ戻す        |
| `C-g` / `Esc`      | COMPOSING            | 未確定を破棄                                         |

### 4.3 描画

- **未確定（COMPOSING）**: 読みをバッファに実テキストとして挿入し、`extmark` で下線ハイライト（`VimeUnconfirmed`）を範囲に付与
- **変換中（CONVERTING）**: 変換結果テキストを表示し、注目文節を反転（`VimeSegment`）。非注目文節は通常表示
- **候補一覧**: `nvim_open_win` の floating window でカーソル直下に表示。各候補にラベル（a/s/d…）
- **重要な実装制約**: 文節ハイライトの範囲指定は **byte オフセット**（日本語1文字=3byte）。文字数で計算するとずれる（[FINDINGS](../poc/FINDINGS.md) D5）

## 5. アーキテクチャ

### 5.1 モジュール構成

純粋関数・副作用・状態・描画を分離する（高凝集・低結合・コロケーション）。

```
lua/vime/
├── init.lua      エントリ。setup(opts)、ハイライト定義、キーマップ登録、モード管理
├── config.lua    デフォルト設定 + ユーザー設定のマージ
├── romaji.lua    ローマ字→かな（純粋関数・FFI非依存）  ← poc/romaji.lua が原型
├── anthy.lua     libanthy FFI ラッパ（副作用の境界）
├── session.lua   変換セッションの状態機械（COMPOSING/CONVERTING、文節・候補・注目index）
├── ui.lua        extmark 描画（未確定下線/文節反転）＋ 候補 popup
└── keymap.lua    挿入モードのキー → session/ui 操作へディスパッチ
```

### 5.2 依存方向

```
keymap ──► session ──► anthy (インターフェース)
                  └──► romaji (純粋関数)
   ui ◄── session (状態を読んで描画)
config ──► (各モジュールが参照)
```

- `session` は `anthy` を**インターフェース越し**に使い（DIP）、テスト時は fake anthy（決め打ち候補を返す）へ差し替え可能にする
- `romaji` は純粋関数なので単体テストが容易（読み列の期待値比較）
- `anthy` だけが FFI・`~/.anthy` 副作用を持つ。ここに副作用を閉じ込める

### 5.3 anthy.lua のインターフェース（案）

```lua
-- anthy.lua が公開する関数（session はこの形だけに依存）
anthy.setup(lib_path)            -- ffi.load + anthy_init。失敗時 false を返す
anthy.new_session()              -- context 生成（encoding=UTF8）
session:convert(yomi)            -- set_string → {segments=[{best, candidates=[...]}], ...}
session:resize(seg_index, delta) -- resize_segment → 再取得
session:commit(choices)          -- 各文節の選択 index を commit（=学習）
session:close()                  -- release_context
```

## 6. エラーハンドリング（最小・Vim を壊さない）

| 事象                             | 対応                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------- |
| `ffi.load` 失敗 / `.so` パス不正 | `setup` で `vim.notify` 警告。プラグインを無効化（`C-j` しても何もしない）      |
| `anthy_init() != 0`              | 同上。日本語入力 ON を拒否                                                      |
| 空入力で `Space`                 | 何もしない（変換しない）                                                        |
| 文節 0 件                        | COMPOSING に留まる                                                              |
| 候補/文節の範囲外 index          | session 側で境界 clamp（PoC で anthy 自体はクラッシュしないと確認済みだが防御） |

過剰な異常系は作らない（YAGNI）。想定外入力は「変換せず素通し」が基本方針。

## 7. 設定インターフェース（案）

```lua
require("vime").setup({
  anthy = {
    lib = "/nix/store/.../libanthy.dylib", -- 必須。未指定なら既知パスを探索し、無ければ無効化
  },
  keymaps = {
    toggle        = "<C-j>",
    convert       = "<Space>",
    commit        = "<CR>",
    cancel        = "<C-g>",
    next_segment  = "<C-f>",
    prev_segment  = "<C-b>",
    expand        = "<C-o>",
    shrink        = "<C-i>",
  },
  popup = {
    threshold = 3,            -- Space を N 回で候補一覧
    labels    = "asdfghjkl",  -- 一括選択ラベル
  },
  highlight = {
    preedit = "VimeUnconfirmed", -- 既定: underline
    segment = "VimeSegment",     -- 既定: reverse
  },
})
```

## 8. テスト方針

TDD（RED→GREEN→REFACTOR）。テストフレームワークは Neovim Lua の定番（busted/plenary 等、実装時に選定）。

| 層        | テスト対象                                       | 手法                                           |
| --------- | ------------------------------------------------ | ---------------------------------------------- |
| `romaji`  | ローマ字→かな（拗音/促音/撥音/外来音/ん/大文字） | 純粋関数。入出力比較（poc のケースを移植）     |
| `session` | 状態遷移・文節/候補/注目 index 管理              | fake anthy を注入し、状態と出力を検証          |
| `anthy`   | FFI ラッパの薄い結線                             | 実 libanthy で疎通テスト（環境依存のため最小） |
| `ui`      | extmark の byte 範囲計算                         | バッファに対し extmark 範囲を検証              |

byte オフセット計算（文節ハイライト）は回帰しやすいので重点的にテストする。

## 9. 未決事項（実装フェーズで確定）

- ローマ字バッファの BS 挙動の細部（`kya` 入力途中の削除単位）
- 候補一覧 popup のラベル枯渇時（候補 > ラベル数）の扱い（ページング or スクロール）
- `.so` 自動探索のパス候補リスト（nix / Homebrew 等）
- 確定テキスト挿入時の undo 単位（1 変換 = 1 undo か）
