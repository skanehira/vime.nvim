# vime.nvim アーキテクチャ

コントリビュータが実装を把握するための文書。設計判断（なぜこうしたか）と実装の歩き方（コードのどこに何があるか）を 1 本にまとめる。

- 用語は [GLOSSARY.md](GLOSSARY.md) に準拠する（コード上の識別子もこの語に揃える）
- 導入手順・キー一覧は [../README.md](../README.md) を参照

## 1. 概要

挿入モードのまま、OS の IME を切り替えずに日本語を入力するモード式 IME プラグイン。pure Lua(LuaJIT) で完結し、外部プロセスを起動しない。変換は 2 段構成:

```
kyouhaiitenkidane → きょうはいいてんきだね → 今日はいい天気だね
       ①ローマ字→かな(自前)     ②かな→漢字(Anthy / FFI)
```

- ① **ローマ字→かな** は自前の純粋関数（`romaji.lua`）
- ② **かな→漢字（連文節変換・候補・学習）** は [Anthy](https://github.com/fujiwarat/anthy-unicode) の共有ライブラリを LuaJIT FFI で直叩き（`anthy.lua`）

文節区切り・候補生成・辞書・学習はすべて Anthy が行う。vime 側は「ローマ字→かな変換」「未確定領域の管理と描画」「キー操作のディスパッチ」だけを担う。

## 2. スコープ

### MVP に含む

- モード式 IME（日本語入力 ON/OFF トグル）
- ローマ字→かな変換（拗音・促音・撥音・外来音）
- 連文節変換（Anthy）と文節ごとの候補取得
- 候補選択（Space/C-n/C-p で順送り・逆送り、候補一覧 popup 表示）
- 文節の移動・伸縮
- 学習（全文節 commit による記憶）
- カタカナ確定（F7）
- 英小文字確定（F10。入力したローマ字をそのまま確定。例: ふぉお → foo）
- ユーザー辞書（SKK 辞書 JISYO JSON を CLI で anthy 私的辞書へ取り込み。送りなし=名詞のみ。§8.2）
- 設定インターフェース（libanthy パス・キーマップ・ハイライト）

### MVP に含まない（将来）

- ユーザー辞書 UI（登録/一覧/削除コマンド・対話的単語登録）
- SKK 従来テキスト形式 / YAML / mpk 入力、送りあり（活用語）の取り込み、TSV 形式
- カスタムローマ字テーブルの設定 UI
- 複数行にまたがる変換
- 数字の漢数字自動選択など変換後処理
- mozc など他エンジン対応

## 3. モジュール構成

純粋関数・副作用・状態・描画を分離する（高凝集・低結合）。

```
lua/vime/
├── init.lua      エントリ兼コントローラ。setup・キーマップ/autocmd 登録・モード管理・バッファ反映
├── config.lua    デフォルト設定のマージ＋ libanthy パスの自動探索
├── romaji.lua    ローマ字→かな（純粋関数・FFI 非依存）
├── anthy.lua     libanthy FFI ラッパ（副作用の境界。FFI と学習の永続化はここだけ）
├── session.lua   変換セッションの状態機械（COMPOSING/CONVERTING、文節・候補・注目 index）
├── ui.lua        extmark 描画（未確定下線/文節反転）＋候補 popup（floating window）
├── skk.lua       SKK 辞書（JISYO JSON）の解析＋取り込み（register 注入。anthy 非依存。CLI から使用）
├── import.lua    辞書取り込み CLI（nvim -l。skk.load + anthy.register_word を別プロセスで実行）
└── keymap.lua    挿入モードのキー → init のハンドラへディスパッチ
```

### 3.1 依存方向

```
keymap ──► (init の handlers) ──► session ──► anthy (DIP インターフェース)
                                        └──► romaji (純粋関数)
   ui ◄── init (session の状態を読んで描画)
import(CLI) ──► skk ──► (register fn 注入 = anthy.register_word)   # エディタとは別プロセス
config ──► (各モジュールが参照)
init ──► 全モジュールを結線するコントローラ
```

- `session` は `anthy` を **コンストラクタ注入**（`session.new(anthy_module)`）で受け取り、インターフェース越し（`convert`/`resize`/`commit`/`close`）に使う（DIP）。テストでも実 anthy を注入する。
- `romaji` は純粋関数なので Vim API も FFI も触らない。単体テストは入出力比較で完結する。
- `anthy` だけが FFI と学習・私的辞書の永続化という副作用を持つ。ここに副作用を閉じ込める。
- `skk` は SKK 辞書（JISYO JSON）の解析と取り込みを担い、`anthy` へは直接依存せず `register(yomi, word)` コールバック注入で動く（DIP・純粋部分はテスト容易）。辞書取り込みはエディタ内ではなく CLI（`import.lua`）から `skk.load` に `anthy.register_word` を注入して実行する（別プロセス＝エディタを止めない）。
- `init` がコントローラ。バッファ・カーソル位置・未確定領域（`start_col`/`len`）・popup 状態を保持し、`session` の状態変化を `ui` 描画へ流す唯一の場所。`init` は辞書取り込みに関与しない。

### 3.2 各モジュールの責務と主要 API

#### `romaji.lua`（純粋関数）

```lua
romaji.to_kana(s)      -- ローマ字列 → ひらがな
romaji.to_katakana(s)  -- ひらがな(U+3041-3096) → カタカナ(+0x60)。それ以外は素通し
```

- ローマ字テーブル `T` は wapuro ローマ字。基本かな・拗音・外来音を持つ。
- 外来音・拗音グライド（`fa`/`va`/`tsa`/`tha`/`kwa`…）は `expand()` で機械生成し、手で穴を埋め続けない。
- `to_kana` は最長一致（4→1 文字）。撥音 `ん` と促音 `っ` は look-ahead で特別処理（[§6 不変条件](#6-必ず守る不変条件と罠) 参照）。

#### `anthy.lua`（FFI ラッパ・副作用境界）

```lua
anthy.setup(lib_path)        -- ffi.load + anthy_init。成功で true、失敗でも例外を投げず false
anthy.new_session()          -- anthy context を生成（encoding=UTF8）。Session を返す
anthy.register_word(yomi, word) -- 読み→単語を私的辞書へ名詞(#T35)登録(per-entry API・単語1件用)
anthy.private_dic_path()     -- 変換が読む private_words_default のパス(辞書一括生成の書き込み先)

Session:convert(yomi)        -- set_string → 全文節 {best, candidates=[...]} 配列を返す
Session:resize(seg, delta)   -- 第 seg 文節(1-based)を delta(+1伸長/-1短縮)して再構成
Session:commit(choices)      -- 各文節の選択 index(1-based 配列)で確定（=全文節 commit=学習）
Session:close()              -- context 解放
```

- 公開 index は Lua 慣習で **1-based**、anthy 内部は **0-based**。`resize`/`commit` の境界で `-1` 補正している。
- 候補文字列のバイト長は `anthy_get_segment(ctx, seg, cand, nil, 0)` で取得してから動的確保する（切り詰めを起こさない）。
- 辞書登録 API（`anthy_priv_dic_add_entry` 等）は本体 `libanthy` ではなく **`libanthydic`** にある。`register_word` は初回に本体 lib が dic シンボルを持つか試し、無ければ `config.find_anthy_dic_lib`（`libanthy`→`libanthydic` 名置換、または `$VIME_ANTHY_DIC_LIB`）で別ロードする。
- `private_dic_path` は **変換エンジンが読む**私的辞書パスを返す（anthy-unicode=`$XDG_CONFIG_HOME/anthy`（既定 `~/.config/anthy`）/ 原 anthy=`~/.anthy`）。`anthy_dic_util_get_anthydir()` はシステム辞書 dir を返し**こことは別物**なので使わない。辞書一括生成（§8.2）はこのパスへ直接書く。

#### `session.lua`（状態機械）

ローマ字バッファ（`romaji` フィールド）を真実とし、preedit は都度 `romaji.to_kana` で導出する。

```lua
session.new(anthy_module)   -- anthy を注入してセッション生成
s:state()                   -- "composing" | "converting"
s:is_latin()                -- 英字ラン中か（大文字始まり。変換せず生英字）
s:preedit()                 -- 現在の未確定文字列（latin なら生英字、否なら かな）
s:input(ch)                 -- 1文字入力。状態に応じ自動確定し、確定文字列を返す
s:backspace()               -- かな単位で1文字削除
s:start_conversion()        -- composing(非空) → converting（anthy.convert を呼ぶ）
s:segments()                -- 表示ビュー { list = {各文節の選択テキスト}, current = 注目index }
s:candidates()              -- 注目文節の全候補（popup 用）
s:select(idx) / s:next_candidate()
s:next_segment() / s:prev_segment()
s:expand() / s:shrink()     -- 注目文節を伸長/短縮（anthy.resize）
s:commit()                  -- converting なら全文節 commit(学習)、composing なら かな をそのまま確定。確定文字列を返す
s:commit_katakana()         -- 現在の読みをカタカナ化して確定
s:commit_alphabet()         -- 入力したローマ字(英小文字)をそのまま確定
s:cancel()                  -- converting→変換前のかなへ戻す、composing→未確定破棄
s:clear()                   -- 未確定・変換中を完全破棄して空の composing へ
```

#### `ui.lua`（描画）

```lua
ui.setup()                                          -- ハイライト群を定義（:highlight で上書き可）
ui.namespace()                                      -- extmark 用 namespace
ui.highlight_preedit(buf, row, col, byte_len)       -- 未確定に下線
ui.highlight_segments(buf, row, col, list, current) -- 文節列。注目を反転、他を下線
ui.show_popup(items, selected) / ui.close_popup()   -- 候補一覧(選択中を PmenuSel で強調・高 zindex で前面)
ui.clear(buf)                                       -- extmark 全消去 + popup を閉じる
```

ハイライトは `VimeUnconfirmed`（既定 underline）と `VimeSegment`（既定 reverse）。

#### `config.lua`（設定・パス解決）

```lua
config.merge(user)              -- defaults へ user を再帰マージ
config.lib_candidates()         -- libanthy の既定探索候補（名前 × 標準ディレクトリ + nix glob）
config.find_anthy_lib(cands)    -- 実在する最初のパスを返す。省略時は $VIME_ANTHY_LIB → 既定候補
config.find_anthy_dic_lib(main) -- libanthydic を解決（$VIME_ANTHY_DIC_LIB → main lib 名置換 → nil）
```

#### `skk.lua`（SKK 辞書の取り込み）

```lua
skk.clean_candidate(cand)       -- 候補1件を整形。;注釈除去・#・(concat 除外・空→nil（純粋）
skk.entries(decoded)            -- okuri_nasi を {yomi,word} 配列へ展開（okuri_ari/#読みは除外）, stats（純粋）
skk.decode(content)             -- JISYO JSON 文字列→table。不正は nil（例外なし）
skk.to_lines(entries)           -- {yomi,word} を「読み #T35*1 単語」行へ（空白含む行は除外）, skipped（純粋）
skk.sort_unique(lines)          -- 行を重複排除しバイト順ソート（texttrie はソート済みを要求。§8.2）（純粋）
skk.load(path, register)        -- ファイルを読み各エントリを register(yomi,word)。同期。単語1件 API 用（テスト/少数登録）
```

取り込み CLI は `lua/vime/import.lua`（`nvim -l` で別プロセス実行）。`anthy.setup` → `anthy.private_dic_path()` を解決 → 既存＋各 JSON の `to_lines` を `sort_unique` して `private_words_default` を直接生成する（per-entry API は使わない。§8.2）。

#### `keymap.lua`（キーディスパッチ）

日本語入力 ON の間だけ、対象バッファにローカルの挿入モードマッピングを張る（OFF で外す）。

## 4. 処理フロー

代表シナリオ「`kyou` と打って Space で変換、候補を選び Enter で確定」を追う。

1. **キー入力**: 挿入モードで `k` を押すと、`keymap.lua` が張ったマッピングが `init.on_input("k")` を呼ぶ。
2. **セッション更新**: `init.on_input` は `session:input("k")` を呼ぶ。session はローマ字バッファに溜める。
3. **描画**: `init` の `render()` が `session:preedit()`（=`romaji.to_kana("kyou")` → `きょう`）を未確定領域として `set_region_text` でバッファに書き、`ui.highlight_preedit` で下線を引く。未確定領域は `start_col`/`len`（byte）で管理する。
4. **変換開始**: `Space` で `init.on_convert` → `session:start_conversion()`。session は `anthy:convert("きょう")` を呼び、文節配列を得て `converting` へ。`render()` が `ui.highlight_segments` で注目文節を反転表示。
5. **候補選択**: `Space` を押すたび `session:next_candidate()` で次候補へ送る。2 回目以降の `Space`（または `C-n`/`C-p`）で `st.popup_open=true` となり、`render` が `open_popup_window` で注目文節の候補一覧を表示する（`C-f`/`C-b`・`C-o`/`C-i` の文節移動/伸縮でも、開いていれば追従して出し直す）。選択中の候補（`session:current_candidate_index()`）は `PmenuSel` で強調表示。変換中に文字を打つと `session:input` が現在の変換を確定して新しい読みを開始する（ラベル選択は廃止）。
6. **確定**: `Enter` で `init.on_commit` → `session:commit()`。session は全文節を `anthy:commit(choices)` に流して**学習**し、確定文字列を返す。`init` の `finalize()` が未確定領域を確定テキストに置換し、領域を畳む（`len=0`）。

`init` のハンドラは `handlers()` テーブルに集約され、`keymap.attach` 経由でキーへ束ねられる。新しい操作を足すときも、このテーブルにハンドラを追加して `keymap.lua` に渡す。

## 5. 状態機械

### 5.1 状態

| 状態       | 実装上の表現                      | 説明                                 |
| ---------- | --------------------------------- | ------------------------------------ |
| DIRECT     | `init` の `st.enabled == false`   | 日本語入力 OFF。通常の Vim 挿入      |
| COMPOSING  | `session:state() == "composing"`  | 未確定（読み入力中）。下線表示       |
| CONVERTING | `session:state() == "converting"` | 変換中。文節・候補を操作。注目を反転 |

DIRECT はコントローラ層の状態（session は ON の間だけ存在）。COMPOSING には「英字ラン」（`is_latin()`）という変種があり、大文字始まりの入力を変換せず生英字のまま保持し、確定は Enter のみ。

```
        ┌──────────┐  C-j   ┌───────────────┐
        │  DIRECT  │ ────►  │   COMPOSING    │ (未確定/下線)
        │日本語OFF │ ◄────  │  読み入力中     │
        └──────────┘  C-j   └───────────────┘
                               │  ▲        │ Space(非空・非latin)
                        Enter/ │  │ C-g/Esc▼
                        BS等   │  │   ┌───────────────┐
                               │  └───│  CONVERTING    │ (変換中/反転)
                               │      │  文節・候補操作  │
                               └──────│                │
                                Enter └───────────────┘
                                (確定=全文節commit→学習)
```

### 5.2 キー操作（日本語入力 ON 中・すべて設定で変更可）

| キー               | 状態                 | アクション                                        |
| ------------------ | -------------------- | ------------------------------------------------- |
| `C-j`              | DIRECT               | 日本語入力 ON（COMPOSING へ）                     |
| `C-j`              | COMPOSING/CONVERTING | 現在の未確定/変換を確定して日本語入力 OFF         |
| 英字（小文字）     | COMPOSING            | ローマ字バッファに追加し、かなを未確定列へ        |
| 英字（大文字始）   | COMPOSING            | 英字ラン開始（変換せず生英字。確定は Enter のみ） |
| 英字               | CONVERTING           | 現在の変換を自動確定し、新しい読みで COMPOSING    |
| `Space`            | COMPOSING(非空)      | 変換開始。候補一覧 popup を表示（第0文節を注目）   |
| `Space`            | COMPOSING(英字ラン)  | スペースを英字に追加（確定しない）                |
| `Space`            | CONVERTING           | 注目文節の次候補（候補一覧 popup を更新）          |
| `C-n` / `C-p`      | CONVERTING           | 注目文節の次候補 / 前候補                          |
| `Space`            | 未確定なし           | 通常のスペースを挿入                              |
| `C-f` / `C-b`      | CONVERTING           | 注目文節を次/前へ移動（popup 追従）               |
| `C-o` / `C-i`      | CONVERTING           | 注目文節を伸長/短縮（resize、popup 追従）          |
| `Enter`            | COMPOSING            | 未確定のかなをそのまま確定                        |
| `Enter`            | CONVERTING           | 変換結果を確定（全文節 commit＝学習）             |
| `Enter`            | 未確定なし           | 通常の改行を挿入                                  |
| `F7`               | COMPOSING/CONVERTING | 読みをカタカナに変換して確定                      |
| `F10`              | COMPOSING/CONVERTING | 入力したローマ字（英小文字）に変換して確定        |
| `BS` / `C-h`       | COMPOSING            | かな単位で1単位削除（英字ランは1文字）            |
| `C-g` / `Esc`      | CONVERTING           | 変換を取り消し、変換前のかな(COMPOSING)へ戻す     |
| `C-g`              | COMPOSING            | 未確定を破棄                                      |
| `C-w` / `C-u`      | COMPOSING/CONVERTING | 未確定があればクリア、無ければ通常の単語/行削除   |
| `Esc`(InsertLeave) | COMPOSING/CONVERTING | 未確定を確定して挿入モードを抜ける                |

## 6. 必ず守る不変条件と罠

feasibility 検証（旧 PoC）で確定し、回帰しやすい要点。コードを変える前に必ず確認する。

- **文節ハイライトの範囲計算は byte オフセットで行う**。日本語 1 文字 = 3 byte なので、文字数で計算すると確実にズレる。`ui.highlight_segments` と `init` の `start_col`/`len` 管理は byte 基準。
- **公開 API は 1-based、anthy 内部は 0-based**。`anthy.lua` の `Session:resize`/`Session:commit` が境界で `-1` 補正する。session/ui からは 1-based のまま扱う。
- **学習は「全文節 commit」でしか効かない**。`session:commit` は必ず `choices` 配列の全要素を `anthy_commit_segment` に流す。部分 commit は学習されないので導入しない。確定 UX は「文単位」に寄せている。
- **挿入モードを抜けるときに未確定を確定する**（`init.lua` の `InsertLeave` autocmd）。これがないと、ノーマルモードに残った未確定 extmark に対する `x`/`u` が壊れる。
- **`anthy.lua` は失敗しても例外を投げない**。`setup` は `false` を返し、`init` 側で `vim.notify` ＋無効化する。「Vim を壊さない」が基本方針。
- **撥音 `ん` の look-ahead**: `nn` を常に 2 文字消費すると `こんにちは→こんいちは`、`おんな→おんあ` になる。2 つ目の `n` の次が母音/`y` なら `n` を 1 つだけ `ん` にする（実 IME 準拠）。`namba→なmば`（難波は `nanba`）、`honya→ほにゃ`（本屋は `hon'ya`）も実 IME と同じ正しい挙動。
- **促音 `っ`**: 同子音の連続（`kk`/`tt`…）と `tch` で生成する。
- **外来音・拗音テーブルは `expand()` で機械生成する**。`fa`/`va`/`tsa`/`tha`/`kwa` などを手で 1 つずつ足し続けない（穴が残る）。`f`/`v`/`ts` は `u` スロットがベース音（ふ/ゔ/つ）なので skip する。
- **学習は副作用としてディスクに永続化される**。原 anthy(9100h) は `$HOME/.anthy`、anthy-unicode は `$XDG_CONFIG_HOME/anthy`（未設定なら `~/.config/anthy`）。テストはこれを一時ディレクトリへ隔離する（[§9](#9-テスト構成)）。
- **変換対象範囲の管理**: 挿入モードの「どこからどこまでが未確定か」は `init` が `row`/`start_col`/`len`（byte）で保持する。確定後やユーザーの直接編集でズレたら `sync_anchor()` が実カーソル位置へ再アンカーする。

## 7. エラーハンドリング（最小・Vim を壊さない）

| 事象                           | 対応                                                           |
| ------------------------------ | -------------------------------------------------------------- |
| `ffi.load` 失敗 / lib パス不正 | `setup` で `vim.notify` 警告し無効化（`C-j` しても何もしない） |
| `anthy_init() != 0`            | 同上。日本語入力 ON を拒否                                     |
| lib が見つからない             | OS 別の導入案内を `:messages` に出す（`init.install_hint`）    |
| 空入力で `Space`               | 何もしない（変換しない）                                       |
| 文節 0 件                      | COMPOSING に留まる                                             |
| 候補/文節の範囲外 index        | session 側で境界 clamp（anthy 自体はクラッシュしないが防御）   |

過剰な異常系は作らない（YAGNI）。想定外入力は「変換せず素通し」が基本方針。

## 8. 設定インターフェース

```lua
require("vime").setup({
  anthy = {
    lib = nil,  -- 未指定なら自動探索（§8.1）。明示も可
  },
  keymaps = {
    toggle = "<C-j>",       convert = "<Space>",   commit = "<CR>",
    cancel = "<C-g>",       next_segment = "<C-f>", prev_segment = "<C-b>",
    expand = "<C-o>",       shrink = "<C-i>",       katakana = "<F7>",
    next_candidate = "<C-n>", prev_candidate = "<C-p>", alphabet = "<F10>",
  },
})
```

SKK 辞書の取り込みは設定ではなく CLI で行う（§8.2）。

ハイライト `VimeUnconfirmed`（既定 underline）/ `VimeSegment`（既定 reverse）は `:highlight` で上書きできる。

### 8.1 libanthy パスの自動探索

`anthy.lib` 未指定なら `config.find_anthy_lib()` が次の順で解決する（多くの環境で `lib` 指定は不要）:

1. 環境変数 `$VIME_ANTHY_LIB`
2. 標準パス（`~/.local/lib`・`~/.nix-profile/lib`・`/run/current-system/sw/lib`・Homebrew・`/usr/lib`・`/usr/lib64`・Debian multiarch 等）× ライブラリ名（`libanthy-unicode` を優先、次に `libanthy`）
3. nix ストア（ハッシュ非依存の glob 探索）

導入方法は [README](../README.md) を参照。推奨は現役保守の **anthy-unicode**（ABI 互換なので原 anthy 9100h とも cdef 共用）。

### 8.2 ユーザー辞書（SKK 辞書の取り込み）

[skk-dict/jisyo](https://github.com/skk-dict/jisyo) の **JISYO 形式（JSON）** 辞書を、エディタとは別プロセスの **CLI（`lua/vime/import.lua`、`nvim -l` で実行）** で Anthy の私的辞書へ取り込む。

- **直接テキスト生成（per-entry API を使わない）**: `anthy_priv_dic_add_entry` は1語ごとにロック＋トライ索引更新＋ディスク書き込みを行うため、L（21 万語超）では数分かかる。代わりに **`private_words_default`（`読み #T35*freq 単語` のテキスト）を1回で生成**する。anthy は読み込み時にこのテキストから索引を組むので正しく動き、**L でも 1 秒未満**。
- **ソート必須**: anthy の私的辞書（texttrie）は**読みがバイト順ソート済み**であることを要求する。未ソートだと一部しか引けない。CLI は既存行＋新規行を `skk.sort_unique`（重複排除＋バイト順）して書き戻す。
- **書き込み先**: `anthy.private_dic_path()`（§3.2 anthy。`anthy_dic_util_get_anthydir()` のシステム辞書 dir とは別）。既存語（他ツール登録分）は保持してマージする。
- **取り込み対象**: `okuri_nasi`（読み→候補配列）のみ。すべて **名詞（`#T35`）**。`okuri_ari`（送りあり＝活用語）は anthy の「読み→単語＋活用品詞」モデルに噛み合わない（キーが読みでなく語幹＋送り子音、候補が語幹のみ、活用品詞情報なし）ため除外。候補の `;注釈` は除去し、数値テンプレート `#`・`(concat …)`・空白を含む語は取り込まない。
- **freq は低く（`*1`）**: 高 freq だと L が anthy 既定の変換順・学習を広く上書きする（例: さくら→砂倉）。低 freq なら**既定を壊さず候補として追加**される — 既知の読みは既定が先頭のまま取り込み語は後ろ、anthy に無い読みはかなの直後に出る（実測: もうろく→耄碌 が2番目）。
- **私的辞書はグローバル**: vime 専用ではなく **同じ PC で Anthy を使う全アプリ（ibus/fcitx/Emacs 等）共有・永続**。掃除は `private_words_default` を退避する。
- **連文節への統合**: 私的辞書の語は anthy の連文節変換に統合され、文中の文節にも候補として現れる（ルックアップ層ではなく anthy 私的辞書を使う利点）。
- **反映タイミング**: CLI が書き込んだ後、エディタ側で新しく作る `anthy` context が読むため反映される。設定（再起動）不要。
- **単語1件登録**: `anthy.register_word`（per-entry API）も残す（テスト・少数登録用）。bulk 取り込みは上記の直接生成を使う。

## 9. テスト構成

TDD（RED→GREEN→REFACTOR）。テストは plenary.nvim（busted 風）。`tests/vime/<module>_spec.lua` に置く（コロケーションではなく `tests/` 配下のミラー構造）。

```sh
make test                                            # tests/vime/ を一括実行
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/vime/session_spec.lua" # 単一ファイル実行
nvim --headless -l tests/smoke.lua                   # 実 libanthy を使う E2E スモーク
```

| 層        | テスト対象                                       | 手法                                     |
| --------- | ------------------------------------------------ | ---------------------------------------- |
| `romaji`  | ローマ字→かな（拗音/促音/撥音/外来音/ん/大文字） | 純粋関数。入出力比較                     |
| `session` | 状態遷移・文節/候補/注目 index 管理              | 実 anthy を注入し、状態と出力を検証      |
| `anthy`   | FFI ラッパの薄い結線                             | 実 libanthy で疎通（環境依存のため最小） |
| `ui`      | extmark の byte 範囲計算                         | バッファに対し extmark 範囲を検証        |
| `skk`     | JISYO 解析（候補整形/エントリ展開/decode）・取り込み | 純粋部は入出力比較、load は temp JSON+注入 |
| `init`    | end-to-end（キー入力→確定までの結線）            | 実 anthy で通しシナリオ                  |

### テストの決定性

- **学習をテストごとに隔離する**。`tests/minimal_init.lua` と `tests/smoke.lua` が `HOME` と `XDG_CONFIG_HOME` を毎回 `tempname()` 配下へ差し替える（原 anthy=`$HOME/.anthy`、anthy-unicode の HOME は `getpwuid` 由来で env では変えられないため `$XDG_CONFIG_HOME/anthy` の隔離が必須）。spec ファイル＝別 nvim なので学習が混ざらない。
- **lib は HOME を temp 化する前に解決して `$VIME_ANTHY_LIB` に固定する**。temp 化後だと `~` 展開先が変わり `~/.local/lib` 等を見失う。
- **辞書バージョン依存の絶対値で検証しない**。anthy-unicode と 9100h は同じ読みでも分割/候補が変わる（例: `きょうはいいてんきだね` は 9100h=今日は… / unicode=今日…）。安定事実・相対変化で検証し、学習する `it` は describe 末尾に置く。
- `session` テストも実 anthy を注入する（fake は使わない）。

## 10. 開発フロー

- コミットは Conventional Commit + emoji + `[STRUCTURAL]` / `[BEHAVIORAL]` プレフィックスを付ける。構造変更と動作変更は別コミットに分ける（Tidy First）。
- LSP 警告は `lua_ls` を `.luarc.json`（LuaJIT + Neovim グローバル + busted DSL）で運用。busted の `describe`/`it`/`assert` は warning にならない。

よくある変更箇所:

- **ローマ字テーブル / 拗音・促音・撥音のロジック**: `lua/vime/romaji.lua`。ケースは `tests/vime/romaji_spec.lua` にあるのでそちらを更新する。
- **新しいキー操作**: `init.lua` の `handlers()` テーブルにハンドラを足し、`keymap.lua` の `attach` でキーへ束ねる。印字可能 ASCII（0x21–0x7e）は 1 文字ずつ `handlers.input(ch)` に流れる。`<`/`|`/`\` だけ `<lt>`/`<Bar>`/`<Bslash>` にエスケープが要るので、印字可能文字のロジックを変えるなら `SPECIAL_LHS` テーブルも併せて更新する。
- **描画**: `ui.lua`。範囲は必ず byte オフセット（[§6](#6-必ず守る不変条件と罠)）。

## 11. feasibility（確定事項）

ここに挙げた事実は旧 PoC で実機検証済み（macOS / Apple Silicon / Neovim 0.12 / LuaJIT 2.1 / anthy）。再検証は不要。

| 項目                      | 結果                                                                       |
| ------------------------- | -------------------------------------------------------------------------- |
| FFI 疎通                  | Neovim 実機で動作。外部プロセス不要                                        |
| 連文節変換・候補取得      | 候補選択で 93%、ユーザー分割変換（IME 的）で到達 100%                      |
| 文節伸縮 `resize_segment` | 区切りミスの矯正に使える                                                   |
| 学習 `commit_segment`     | 全文節 commit で記憶し、別 context へ永続化                                |
| 堅牢性                    | 空文字/超長文/範囲外アクセスでクラッシュしない（呼び出し側でも境界 clamp） |
| レイテンシ                | init 0.13ms、1 変換 0.2〜2ms（IME 基準 30ms に対し桁違いに高速）           |
| インライン描画            | extmark 下線/文節反転/floating popup/挿入モードキー横取り すべて可         |
