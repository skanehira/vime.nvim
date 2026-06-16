# vime.vim

英字を一気に日本語へ変換するモード式 IME の Neovim プラグイン。挿入モードのまま、OS の IME を切り替えずに日本語を入力できる。

```
kyouhaiitenkidane → きょうはいいてんきだね → 今日は良い天気だね
   ①ローマ字→かな(自前)        ②かな→漢字(Anthy)
```

かな→漢字変換は [Anthy](https://anthy.osdn.jp/) を LuaJIT FFI で直接呼び出す。外部プロセス不要、pure Lua で完結する。

## 必要環境

- Neovim 0.10+ (LuaJIT)
- `libanthy`（共有ライブラリ）
  - nix: `anthy` パッケージ
  - Homebrew 等で導入したパスでも可
- 変換精度などの詳細は [`poc/FINDINGS.md`](poc/FINDINGS.md) を参照

## セットアップ

```lua
require("vime").setup({
  anthy = {
    -- 省略時は既知パスを自動探索する。見つからなければ anthy.lib を指定する
    lib = "/path/to/libanthy.dylib",
  },
})
```

`lazy.nvim` の例:

```lua
{
  "skanehira/vime.vim",
  config = function()
    require("vime").setup({ anthy = { lib = "/path/to/libanthy.dylib" } })
  end,
}
```

## 使い方

挿入モードで `<C-j>` を押すと日本語入力が ON になる。

| キー | 状態 | 動作 |
|------|------|------|
| `<C-j>` | OFF | 日本語入力 ON |
| `<C-j>` | ON | 未確定/変換中を確定して OFF |
| 英字 | 未確定 | ローマ字→かな（下線表示） |
| `<Space>` | 未確定 | 変換開始（注目文節を反転） |
| `<Space>` | 変換中 | 次候補（N 回で候補一覧 popup、ラベルキーで選択） |
| `<C-f>` / `<C-b>` | 変換中 | 注目文節を移動 |
| `<C-o>` / `<C-i>` | 変換中 | 注目文節を伸長 / 短縮 |
| `<CR>` | 変換中/未確定 | 確定（学習される） |
| `<C-g>` | 変換中 | 変換を取り消してかなへ戻す |
| `<BS>` | 未確定 | 1 文字削除 |

キーマップ・候補一覧の閾値・ラベルは `setup()` で変更できる（[`docs/DESIGN.md`](docs/DESIGN.md) §7）。

## 開発

```sh
make test   # plenary.nvim でテスト実行
```

設計は [`docs/DESIGN.md`](docs/DESIGN.md)、用語は [`docs/GLOSSARY.md`](docs/GLOSSARY.md)、タスクは [`docs/TODO.md`](docs/TODO.md)。
