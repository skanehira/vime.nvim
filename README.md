# vime.nvim

英字を日本語へ変換するモード式 IME の Neovim プラグイン。挿入モードのまま、OS の IME を切り替えずに日本語を入力できる。

```
kyouhaiitenkidane → きょうはいいてんきだね → 今日は良い天気だね
   ①ローマ字→かな(自前)        ②かな→漢字(Anthy)
```

かな→漢字変換は [anthy](https://github.com/xorgy/anthy) or [anthy-unicode](https://github.com/fujiwarat/anthy-unicode) を LuaJIT FFI で直接呼び出す。外部プロセス不要、pure Lua で完結する。

> 使い方・キー一覧・設定・ユーザー辞書の詳細はヘルプ `:help vime` を参照（[doc/vime.txt](doc/vime.txt)）。

https://github.com/user-attachments/assets/bb89ec5c-1ad2-44d0-8ab9-81774aa39ea0

## 必要環境

- Neovim 0.10+ (LuaJIT)
- `libanthy`（共有ライブラリ）— 現役保守の [anthy-unicode](https://github.com/fujiwarat/anthy-unicode) 推奨（原 anthy 9100h と ABI 互換）

| 環境            | 導入                                                                    |
| --------------- | ----------------------------------------------------------------------- |
| Fedora          | `sudo dnf install anthy-unicode`                                        |
| Debian / Ubuntu | `sudo apt install libanthy-dev`                                         |
| Arch (AUR)      | `anthy-unicode`                                                         |
| Nix             | `nix profile install nixpkgs#anthy`（宣言的構成に `pkgs.anthy` でも可） |
| macOS           | 下記のソースビルド、または `nix profile install nixpkgs#anthy`          |

macOS ソースビルド（`~/.local` に入れれば vime が自動検出する）:

```sh
git clone https://github.com/fujiwarat/anthy-unicode && cd anthy-unicode
meson setup build --prefix=$HOME/.local --sysconfdir=$HOME/.local/etc -Demacs=disabled
meson compile -C build && meson install -C build
```

`--sysconfdir` は**絶対パス必須**（相対だと `anthy_init` が失敗する）。

## セットアップ

`setup()` を呼ぶだけ。`libanthy` は自動探索する（`$VIME_ANTHY_LIB` → 標準パス → nix ストア）ので多くの環境で `lib` 指定は不要。見つからない場合は OS 別の導入手順が `:messages` に案内される。

```lua
-- lazy.nvim
{
  "skanehira/vime.nvim",
  config = function()
    require("vime").setup() -- 必要なら anthy = { lib = "/path/to/libanthy.dylib" }
  end,
}
```

設定値・キーマップの変更は `:help vime-configuration`。

## 使い方

挿入モードで `<C-j>` → ローマ字入力 → `<Space>` で変換 → `<CR>` で確定。文節移動・伸縮・カタカナ確定などのキー操作は `:help vime-usage` / `:help vime-mappings`。

モード切替時はカーソル下に短時間ラベル（既定: 直/あ/A）が出る。ステータスラインに自分で表示したい場合は `require("vime").mode()` と `User VimeModeChanged` autocmd を使う → `:help vime-mode-api`。

Anthy の既定辞書に無い固有名詞などは、SKK 辞書（JISYO JSON）を取り込んで候補に追加できる → `:help vime-dictionary`。

## カスタムローマ字テーブル（ACT 等）

`setup({ romaji = { table = ... } })` でローマ字→かなテーブルを差し替えられる。指定したテーブルは既定（wapuro）と**マージせず完全置換**する。撥音 `ん`・促音 `っ`・大文字英字ランの look-ahead ロジックはテーブル非依存で常に有効。

```lua
require("vime").setup({
  romaji = {
    table = {
      -- ACT 等の自前テーブル
      ka = "か", ki = "き",
      -- ...
    },
  },
})
```

既定の wapuro テーブルをベースに一部だけ差し替えたい場合は、`require("vime.romaji").default_table` をコピーしてから上書きする:

```lua
local default = require("vime.romaji").default_table
local mytable = vim.tbl_extend("force", {}, default)
mytable.kt = "きと" -- 例: 自前の拡張エントリを追加
require("vime").setup({ romaji = { table = mytable } })
```

`default_table` を直接書き換えない（モジュール状態を汚染するため必ずコピーすること）。

## 開発

```sh
make test   # plenary.nvim でテスト実行
```

設計・実装は [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)、用語は [`docs/GLOSSARY.md`](docs/GLOSSARY.md)。
