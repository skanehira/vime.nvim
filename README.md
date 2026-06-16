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

### libanthy の導入

現役で保守されている [anthy-unicode](https://github.com/fujiwarat/anthy-unicode) を推奨します（オリジナルの anthy 9100h は 2009 年で更新停止。anthy-unicode は ABI 互換なのでどちらでも動きます）。

| 環境            | 導入方法                                                                         |
| --------------- | -------------------------------------------------------------------------------- |
| Fedora          | `sudo dnf install anthy-unicode`                                                 |
| Debian / Ubuntu | `sudo apt install libanthy-dev`                                                  |
| Arch (AUR)      | `anthy-unicode`                                                                  |
| Nix             | `nix profile install nixpkgs#anthy`（9100h・ABI 互換）                           |
| macOS           | anthy-unicode をソースビルド（下記）、または `nix profile install nixpkgs#anthy` |

macOS でのソースビルド例（`~/.local` に入れれば vime が自動検出する）:

```sh
git clone https://github.com/fujiwarat/anthy-unicode && cd anthy-unicode
# meson/ninja が無ければ用意する（例: nix shell nixpkgs#meson nixpkgs#ninja）
meson setup build --prefix=$HOME/.local --sysconfdir=$HOME/.local/etc -Demacs=disabled
meson compile -C build && meson install -C build
```

- `--sysconfdir` は**絶対パス必須**（相対だと `anthy_init` が設定ファイルを見つけられず失敗する）。
- 共有ライブラリは原 anthy と区別するため `libanthy-unicode.dylib` という名前で入る。
- 学習データは `$XDG_CONFIG_HOME/anthy`（未設定なら `~/.config/anthy`）に保存される（原 anthy の `~/.anthy` から移行）。
- 変換精度などの検証結果は [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §11 を参照

Nix で宣言的に管理している場合（Home Manager / NixOS / nix-darwin）は、`nix profile install` の代わりに構成へ `anthy` を足す（反映後 vime が自動検出する）。

Home Manager（既存の `home.packages` に 1 行足すだけ）:

```nix
{ pkgs, ... }:
{
  home.packages = [
    pkgs.anthy # 9100h・ABI 互換
  ];
}
```

システム全体に入れる場合（NixOS / nix-darwin の `environment.systemPackages`）:

```nix
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.anthy ];
}
```

反映は構成に応じて `home-manager switch --flake .#<name>` / `sudo nixos-rebuild switch --flake .#<host>` / `darwin-rebuild switch --flake .#<host>`（`nh` 等のラッパーでも可）。共有ライブラリは `/nix/store/…-anthy-*/lib/libanthy.dylib` に置かれ、vime のパス探索（nix ストアの glob）が拾うため `lib` の明示指定は不要。

## セットアップ

`setup()` を呼ぶだけで、`libanthy-unicode` / `libanthy` を以下の順に**自動探索**します（多くの環境で `lib` 指定は不要）:

1. 環境変数 `$VIME_ANTHY_LIB`
2. ソースビルド/パッケージの標準パス（`~/.local/lib`・`/usr/lib`・`/usr/lib64`・Debian multiarch・Homebrew・nix プロファイル等）
3. nix ストア（ハッシュ非依存の glob 探索）

```lua
require("vime").setup({
  -- 自動探索で見つかる場合は anthy ブロックごと省略可
  anthy = {
    -- 見つからない / 別の lib を使いたい場合のみ明示する
    lib = "/path/to/libanthy.dylib",
  },
})
```

見つからない場合は OS 別の導入手順が `:messages` に案内されます。

`lazy.nvim` の例:

```lua
{
  "skanehira/vime.vim",
  config = function()
    require("vime").setup() -- lib は自動探索。必要なら anthy = { lib = ... } を渡す
  end,
}
```

## 使い方

挿入モードで `<C-j>` を押すと日本語入力が ON になる。

| キー              | 状態           | 動作                                                             |
| ----------------- | -------------- | ---------------------------------------------------------------- |
| `<C-j>`           | OFF            | 日本語入力 ON                                                    |
| `<C-j>`           | ON             | 未確定/変換中を確定して OFF                                      |
| 英字（小文字）    | 未確定         | ローマ字→かな（`,`→`、` `.`→`。` `/`→`・` `[`→`「` `]`→`」` も） |
| 英字（大文字始）  | 未確定         | 英字ラン（変換せず生の英字のまま。確定は `<CR>` のみ）           |
| `<Space>`         | 未確定（かな） | 変換開始（注目文節を反転）                                       |
| `<Space>`         | 変換中         | 次候補（N 回で候補一覧 popup、ラベルキーで選択）                 |
| `<Space>`         | 英字ラン       | スペースを英字に追加（確定しない）                               |
| `<Space>`         | 未確定なし     | 通常のスペースを挿入                                             |
| `<C-f>` / `<C-b>` | 変換中         | 注目文節を移動                                                   |
| `<C-o>` / `<C-i>` | 変換中         | 注目文節を伸長 / 短縮                                            |
| `<CR>`            | 変換中/未確定  | 確定（学習される）                                               |
| `<CR>`            | 未確定なし     | 通常の改行を挿入                                                 |
| `<F7>`            | 変換中/未確定  | 読みをカタカナに変換して確定                                     |
| `<C-g>`           | 変換中         | 変換を取り消してかなへ戻す                                       |
| `<C-g>`           | 未確定         | 未確定を破棄                                                     |
| `<BS>` / `<C-h>`  | 未確定（かな） | かな単位で削除                                                   |
| `<BS>` / `<C-h>`  | 英字ラン       | 英字を 1 文字削除                                                |
| `<C-w>` / `<C-u>` | 未確定/変換中  | 未確定をクリア（無ければ通常の単語/行削除）                      |
| `<Esc>`           | 変換中/未確定  | 確定して挿入モードを抜ける                                       |

キーマップ・候補一覧の閾値・ラベルは `setup()` で変更できる（[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §8）。

## 開発

```sh
make test   # plenary.nvim でテスト実行
```

設計・実装は [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)、用語は [`docs/GLOSSARY.md`](docs/GLOSSARY.md)。
