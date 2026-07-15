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
- カスタムローマ字テーブル（ACT 等の独自配列。完全置換で差し替え）
- 連文節変換（Anthy）と文節ごとの候補取得
- 候補選択（Space/C-n/C-p で順送り・逆送り、候補一覧 popup 表示）
- 文節の移動・伸縮
- 学習（全文節 commit による記憶）
- カタカナ確定（F7）
- 英小文字確定（F10。入力したローマ字をそのまま確定。例: ふぉお → foo）
- ユーザー辞書（SKK 辞書 JISYO JSON を CLI で anthy 私的辞書へ取り込み。送りなし=名詞のみ。§8.2）
- 設定インターフェース（libanthy パス・キーマップ・ハイライト・ローマ字テーブル）
- コマンドライン（`:`/`/`/`?`）での日本語入力（未確定はインライン、変換中の文節状態は floating window。§3.3・§6）
- terminal バッファ（terminal-job モード）での日本語入力（未確定は floating window 表示、確定のみ PTY へ送出。§3.3・§6）

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
├── init.lua      エントリ兼コントローラ。setup・キーマップ/autocmd 登録・モード管理・backend 切替
├── config.lua    デフォルト設定のマージ＋ libanthy パスの自動探索
├── romaji.lua    ローマ字→かな（純粋関数・FFI 非依存）
├── anthy.lua     libanthy FFI ラッパ（副作用の境界。FFI と学習の永続化はここだけ）
├── session.lua   変換セッションの状態機械（COMPOSING/CONVERTING、文節・候補・注目 index）
├── mode.lua      外向きモード名(direct/hiragana/ascii)の推論（純粋関数）
├── ui.lua        extmark 描画（未確定下線/文節反転）＋候補 popup・モード通知 popup・preedit float（floating window）
├── skk.lua       SKK 辞書（JISYO JSON）の解析＋取り込み（register 注入。anthy 非依存。CLI から使用）
├── import.lua    辞書取り込み CLI（nvim -l。skk.load + anthy.register_word を別プロセスで実行）
├── keymap.lua    キー(モード可変: i/t/c) → init のハンドラへディスパッチ
├── backend/      書込先の抽象化(§3.3)。session の状態をどこへどう反映するかを差し替える
│   ├── buffer.lua    通常バッファ + 挿入モード("i")。バッファへ直接書く既定の書込先
│   ├── terminal.lua  terminal バッファ + terminal-job モード("t")。preedit float 表示 + chansend
│   └── cmdline.lua   コマンドライン + cmdline モード("c")。setcmdline によるインライン表示
└── integrations/ 外部プラグイン連携（opt-in。本体は依存しない）
    └── nvim_cmp.lua  vime モード ON 中は nvim-cmp の補完を抑止する（pcall で optional）
```

### 3.1 依存方向

```
keymap ──► (init の handlers) ──► session ──► anthy (DIP インターフェース)
                                        └──► romaji (純粋関数)
   init ──► backend/{buffer,cmdline,terminal} (session の状態をどこへどう反映するか。§3.3)
   backend ──► ui (preedit の描画先。buffer は extmark、cmdline/terminal は preedit float)
   ui ◄── init (候補 popup を出す。位置は backend:popup_pos() 経由。モード通知 popup は常にカーソル直下)
   mode ◄── init (session+enabled を集約して外向きモード名を導出)
   User VimeModeChanged ◄── init (モード名が変わったときに発火・data に mode テーブル)
   User VimePreeditChanged ◄── init (未確定が変わったときに発火・data={state,preedit,available})
import(CLI) ──► skk ──► (register fn 注入 = anthy.register_word)   # エディタとは別プロセス
config ──► (各モジュールが参照)
init ──► 全モジュールを結線するコントローラ
init ──► integrations/* (opt-in。is_enabled を依存注入で渡し、外部プラグイン側を片方向に触る)
```

- `session` は `anthy` を **コンストラクタ注入**（`session.new(anthy_module)`）で受け取り、インターフェース越し（`convert`/`resize`/`commit`/`close`）に使う（DIP）。テストでも実 anthy を注入する。
- `romaji` は純粋関数なので Vim API も FFI も触らない。単体テストは入出力比較で完結する。
- `anthy` だけが FFI と学習・私的辞書の永続化という副作用を持つ。ここに副作用を閉じ込める。
- `skk` は SKK 辞書（JISYO JSON）の解析と取り込みを担い、`anthy` へは直接依存せず `register(yomi, word)` コールバック注入で動く（DIP・純粋部分はテスト容易）。辞書取り込みはエディタ内ではなく CLI（`import.lua`）から `skk.load` に `anthy.register_word` を注入して実行する（別プロセス＝エディタを止めない）。
- `init` がコントローラ。`session` の状態変化を **backend**（現在アタッチ中の書込先。buffer/cmdline/terminal のいずれか 1 つ）へ流す唯一の場所。書込先固有の状態（バッファ番号・未確定領域の byte 範囲・keymap のモード等）は `st.backend` オブジェクトが保持し、`init` はそれを問い合わせる（§3.3）。`init` は辞書取り込みに関与しない。
- `integrations/*` は **opt-in** な外部プラグイン連携層。`pcall(require, "<plugin>")` で optional 依存にし、未インストールでも本体は壊れない。本体（`session`/`anthy`/`ui` 等）は integrations を一切 require しない（**依存方向は init → integrations → 外部プラグインの片方向**）。`is_enabled` のような本体の公開 API は関数参照を渡す形で注入し、循環 require を避ける。
- **自前自動補完**（`completion.enabled`、既定 ON）は composing 中に `session:completion_candidates()` の候補を自前 popup（`ui.show_popup`、変換フローと共用）で自動表示する。設計判断:
  - **補完は外部補完エンジン（nvim-cmp 等）に委譲しない**。vime は未確定を実テキストとして byte 単位（`start_col`/`len`）で管理しており、外部エンジンは候補の選択・確定・クローズでバッファを非同期に書き替える。「バッファの書き手が 2 人」になると二重挿入・巻き戻し・断片混入が原理的に避けられない（nvim-cmp source 統合を実装・検証して確認済み）。自前 popup なら全操作が同期・単独書き手で、plenary のヘッドレステストで end-to-end 検証できる。
  - 候補は「文節ごとのベスト連結」を先頭に「全文 1 文節候補群」を dedup して並べる（`session:completion_candidates()`）。入力のたびに再計算して popup を追従し、候補が無い状態（未確定なし・英字ラン・変換中など）で自動クローズする。
  - `<C-n>/<C-p>`・`<Esc>`（`completion_cancel`）は popup 表示中のみ buffer-local に張る（`keymap.attach_completion`、converting 限定キーと同じ動的 attach パターン。composing/converting は排他なので同じ lhs でも衝突しない）。選択は **インライン置換**: 未確定領域の表示を候補テキストへ `set_region_text` で置き換える（`session` は読みを保持し続けるので、`<Space>` の通常変換や `<BS>` の選択解除は読みへそのまま戻れる）。
  - 取消: 候補の **選択中**（インライン置換中）の `<Esc>` は `<C-g>`（cancel）と同じく未確定を破棄する（挿入モードには留まる）。候補 **未選択**（読みのまま）の `<Esc>` は素通しし、従来どおり挿入モードを抜けて InsertLeave が読みを確定する。
  - 確定（`<CR>`・選択したまま次の文字・InsertLeave・toggle OFF）は `session:commit_completion(item)` で anthy へ学習 commit する。未確定領域は選択時に置換済みなので、領域の追跡（`start_col += len`）だけ進める。
  - 補完確定は API 置換のため dot repeat（`.`）には載らない（`<Space>`/`<CR>` の変換フローは従来どおり feedkeys 経路で dot repeat 対応）。

### 3.2 各モジュールの責務と主要 API

#### `romaji.lua`（純粋関数）

```lua
romaji.to_kana(s, custom_table?)  -- ローマ字列 → ひらがな。custom_table 省略時は default_table。
romaji.to_katakana(s)             -- ひらがな(U+3041-3096) → カタカナ(+0x60)。それ以外は素通し
romaji.default_table              -- 既定の wapuro テーブル(読み取り専用扱い)
```

- ローマ字テーブル `T` は wapuro ローマ字。基本かな・拗音・外来音を持つ。`M.default_table` として公開。
- 外来音・拗音グライド（`fa`/`va`/`tsa`/`tha`/`kwa`…）は `expand()` で機械生成し、手で穴を埋め続けない。
- `to_kana` の評価順序は **テーブル最長一致（4→1 文字） → 撥音 `ん` look-ahead → 促音 `っ` look-ahead → 未知文字フォールバック**。テーブルを先に試すのは、ACT のような独自配列で `nh`/`tt`/`ss` などが既定の撥音/促音ルールと衝突するため、テーブル定義で上書き可能にしておく必要があるから。既定 wapuro でもこれらの2連続/3連続キーはテーブルに無いので、撥音・促音判定にそのまま落ちる（既存の挙動は維持される）。
- **カスタムテーブル**: `to_kana(s, custom_table)` の第2引数で完全置換できる（マージしない）。撥音 `ん`・促音 `っ`・大文字英字ランの判定はテーブル非依存で常に同じロジック。`setup({ romaji = { table = ... } })` 経由で session に渡る。

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

プリエディットを **セグメント列**（`kana`/`latin`）として保持する。`preedit` は各セグメントを連結して導出する。kana セグメントは `romaji.to_kana` を通し、latin セグメントは生英字のまま。カスタムローマ字テーブルが渡されている場合は `to_kana` の第2引数として伝播する。

```lua
session.new(anthy_module, opts) -- anthy 注入。opts.ascii_toggle で ASCII トグル文字、opts.romaji_table でカスタムローマ字テーブルを渡す
s:state()                   -- "composing" | "converting"
s:is_latin()                -- 英字ラン中か（大文字始まり。kana 未確定は commit 済み）
s:is_ascii()                -- ASCII モード中か（ascii_toggle で入退室。kana 未確定は保留）
s:preedit()                 -- 現在の未確定文字列（kana を to_kana して latin と連結）
s:preedit_segments()        -- 描画用ビュー { {kind="kana", text="きょうは"}, {kind="latin", text="iPhone"}, ... }
s:input(ch)                 -- 1文字入力。状態に応じ自動確定し、確定文字列を返す
s:backspace()               -- かな単位で1文字削除（latin セグメントなら1byte 削除）
s:start_conversion()        -- composing(kana セグメント有) → converting（先頭 kana から anthy.convert）
s:segments()                -- 表示ビュー { list = {各文節の選択テキスト}, current = 注目index }
s:candidates()              -- 注目文節の全候補（popup 用）
s:completion_candidates()   -- composing(単一 kana)中の補完候補 {text,yomi,single}[]（先頭=ベスト連結）
s:commit_completion(item)   -- 補完候補 item を Anthy に学習 commit し composing(空)へ。text を返す
s:select(idx) / s:next_candidate()
s:next_segment() / s:prev_segment()
s:expand() / s:shrink()     -- 注目文節を伸長/短縮（anthy.resize）
s:commit()                  -- converting なら残り全 kana セグメントを既定候補で一括確定(一括 commit)し、
                            -- プリエディット全体を返して composing(空)へ。InsertLeave/disable 等の
                            -- 「即座に全部確定したい」経路で使う
s:commit_step()             -- converting なら現 kana だけを確定し、次の kana セグメントがあれば
                            -- converting を継続(nil を返す)。無ければプリエディット全体を返して
                            -- composing(空)へ。Enter を押すたび 1 kana セグメントずつ進める
                            -- (on_commit が使う。複数 kana セグメントを含むプリエディットは
                            -- Enter を複数回押して順に確定していく)
s:commit_with_replacement(word) -- 注目文節を辞書登録した word で置き換えて全文節を確定(C-r 用)
s:commit_katakana()         -- 現在の読みをカタカナ化して確定
s:commit_alphabet()         -- 入力したローマ字(英小文字)をそのまま確定
s:cancel()                  -- converting→変換前のかなへ戻す、composing→未確定破棄
s:clear()                   -- 未確定・変換中を完全破棄して空の composing へ
```

#### `ui.lua`（描画）

```lua
ui.setup()                                          -- ハイライト群を定義（:highlight で上書き可）
ui.namespace()                                      -- extmark 用 namespace
ui.highlight_preedit(buf, row, col, byte_len)       -- 未確定(kana/latin)に下線。byte_len で範囲指定
ui.highlight_segments(buf, row, col, list, current) -- 注目文節を反転、他を下線(注目 kana 内の文節描画)
ui.show_popup(items, selected, pos?) / ui.close_popup()   -- 候補一覧(選択中を PmenuSel で強調・高 zindex で前面)
ui.show_mode_notify(label, duration_ms, pos?)       -- カーソル下(既定)にモードラベルを duration_ms 表示
ui.close_mode_notify()                              -- モード通知 popup を明示的に閉じる
ui.show_preedit_float(view, pos) / ui.close_preedit_float() -- 共有 preedit float(§3.3)。view は preedit_segments() の戻り値
ui.clear(buf)                                       -- extmark 全消去 + 候補 popup を閉じる
```

ハイライトは `VimeUnconfirmed`（既定 underline）/`VimeSegment`（既定 reverse）/`VimeModeNotify`（既定: 緑背景・白文字・bold、`default=true` なので `:highlight` で上書き可）。`ui.setup(opts)` の `opts.mode_notify_highlight` に `nvim_set_hl` 互換テーブルを渡すと明示上書き(default フラグなし)になり、`config.mode_notify.highlight` 経由で `init.setup()` から流れる。latin/kana を別色にしないので、ui の関数は既存と同じシグネチャを保つ。`show_popup`/`show_mode_notify` の第 3 引数 `pos`（省略可）は `nvim_open_win` 互換の配置テーブル（`{relative, row, col, anchor?}`）で、省略時は従来どおりカーソル直下。候補 popup（`show_candidate_window`）は `st.backend:popup_pos()`（§3.3）の戻り値を渡すので、backend ごとにふさわしい位置に出る。**モード通知 popup（`show_mode_notify`）は `init` から常に `pos` 省略で呼ばれるため、cmdline セッション中でもカーソル直下（=元の挿入位置）に固定表示される**（backend には追従しない）。`ui.show_preedit_float(view, pos)` は `session:preedit_segments()` の `view` をそのまま渡すと、下線・文節反転込みの 1 行 floating window に描画する内部ヘルパを持つ（`highlight_preedit`/`highlight_segments` をその float の scratch buffer に対して適用するので byte 計算の不変条件は 1 箇所のまま）。`buffer` backend の `render()` はバッファへ直接書くので使わない。`terminal`/`cmdline` backend が使う。モード通知 popup は `init` のモード変化検出から呼ばれ、`vim.defer_fn` で自動消滅し、連続切替時は先に開いている popup を閉じてから新しく開く（古い defer_fn が遅延発火しても win は既に無効なので no-op）。`zindex` は `max(200, host_z + 40)` で動的に決まり、ホストの floating window（AI 入力欄等）の中で入力していても隠れない。候補 popup は `max(250, host_z + 50)` なので、共存時は候補が前面に来る。

#### `mode.lua`（純粋関数）

```lua
mode.compute({enabled, state, ascii, latin}) -- 外向きの mode テーブル {name, enabled, state, ascii, latin}
```

`name` は `"direct"` | `"hiragana"` | `"ascii"` の 3 値。状態の組み合わせから一意に決まる。**変換中(`state == "converting"`)も `name = "hiragana"` を返す**（候補一覧 popup 側で十分シグナルされるため、モード通知 popup は出さない）。詳細を見たいユーザは `state` フィールド（`"composing"` | `"converting"` | `nil`）で判別できる。`session` の内部状態を `init` が集約して渡すだけの薄い関数で、FFI/Vim API には触らない。`init.mode()` 経由でユーザにも公開され（[§8.3](#83-モード公開-api-と-mode_notify)）、`init` のモード変化検出に使われる。

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

```lua
keymap.attach(buf, config, handlers, mode?)             -- mode 省略時は "i"。"c" は自動的にグローバルスコープになる
keymap.detach(buf, mode?)
keymap.attach_converting(buf, config, handlers, mode?) / keymap.detach_converting(buf, mode?)
keymap.attach_completion(buf, config, handlers, mode?) / keymap.detach_completion(buf, mode?)
```

日本語入力 ON の間だけキーマッピングを張る（OFF で外す）。`mode` は `"i"`（挿入モード。既定）/`"t"`（terminal-job モード）/`"c"`（コマンドライン）。`"i"`/`"t"` はバッファローカル（`vim.keymap.set(mode, lhs, fn, {buffer=buf,...})`）、`"c"` はグローバル（`:cnoremap` はバッファローカルにできないため）。`GLOBAL_MODES = {c = true}` で判定し、登録簿のキーも `"mode:buf"`（`"c"` は `"c:global"`）で分ける。`attach_converting`/`attach_completion` は上書き前の既存マッピング（他プラグイン由来含む）を `maparg`/`mapset` で保存・復元する（グローバルスコープでも同じ機構を使う）。

### 3.3 backend（書込先の抽象化）

`init` は「session の状態が変わった」ことを知っているだけで、それを **どこへどう反映するか** は `st.backend` オブジェクトに委譲する。同時にアタッチされる backend は常に 1 つ。`buffer`/`terminal` は InsertEnter/TermEnter で追従する準永続的な backend、`cmdline` は CmdlineEnter/CmdlineLeave の間だけ既存の backend に割り込む一時的な backend という違いがある（後述）。

各 backend が実装するインターフェース（`vime.BufferBackend`/`vime.TerminalBackend`/`vime.CmdlineBackend`。`lua/vime/backend/*.lua` の `---@class` 参照）:

```lua
backend.kind                  -- "buffer" | "terminal" | "cmdline"
backend.keymap_mode           -- "i" | "t" | "c"（keymap.attach/detach に渡すモード）
backend.supports(feature)     -- "completion" | "register_word" の対応可否(下記参照)
backend:sync_anchor()         -- 未確定が無い(idle)ときに実カーソル/実 cmdpos へ再アンカー
backend:set_region_text(text) -- 未確定領域を text で置換する(completion 対応 backend のみ必須。
                               -- select_completion() が候補のインライン置換に使う。terminal は
                               -- completion 非対応なので未実装)
backend:render(view)          -- preedit_segments() の view を描画先へ反映(下線/文節反転込み)
backend:clear()               -- 描画(extmark/float)と候補 popup を消す
backend:finalize(text)        -- 未確定領域を確定テキストで置き換える(buffer/cmdline)か、
                               -- 確定テキストを送出する(terminal。置換ではなく chansend)
backend:insert_literal(text)  -- 未確定が無いときの通常の Space/CR を書込先へ素通し
backend:passthrough(key)      -- BS/C-w/C-u/Esc 等を書込先の既定動作へそのまま流す
backend:popup_pos()           -- 候補 popup・preedit float の配置(nvim_open_win 互換)
backend:place_cursor()        -- カーソル/カーソル相当を未確定末尾へ(no-op のことがある)
```

`backend.supports(feature)` の feature は現状 `"completion"`/`"register_word"` の 2 つだけが `init.lua` から実際に問い合わせられる（`refresh_completion`/`M.completion_active`/`M.on_register_word`）。各 backend の `FEATURES` テーブルは `"dot_repeat"` も宣言する（buffer=`true`、terminal/cmdline=`false`）が、これは実行時のどこからも参照されないメタデータで、dot repeat が cmdline/terminal で効かないこと自体は各 backend の `finalize`/`insert_literal` が feedkeys 経路を持たないという実装上の構造で担保されている（テストは宣言値のみ検証する）。

| 操作 | `buffer`（既定） | `terminal` | `cmdline` |
| --- | --- | --- | --- |
| 書込先 | 実バッファ(`nvim_buf_set_text`) | preedit float（実バッファへは書かない） | `getcmdline`/`setcmdline`（プレーン文字列） |
| 未確定の表示 | extmark 下線/文節反転 | float 内で `highlight_preedit`/`highlight_segments` を流用 | インラインはプレーン。converting 中のみ共有 float に文節状態を併記 |
| 確定経路 | 挿入モード中は feedkeys（dot repeat 対応）、それ以外は API 置換 | `chansend(channel, text)`（置換ではなく PTY への送出） | `setcmdline` による API 置換のみ |
| `supports("completion"/"register_word")` | すべて `true` | すべて `false` | すべて `false` |
| keymap スコープ | バッファローカル（`"i"`） | バッファローカル（`"t"`） | グローバル（`"c"`） |
| アタッチ契機 | `InsertEnter`（`terminal`/`prompt` buftype は除外） | `TermEnter` | `CmdlineEnter`（`getcmdtype()` が `:`/`/`/`?` のときのみ） |
| 通常の離脱 | `InsertLeave` で **確定**（学習のみ。テキストは既にバッファにある） | `TermLeave`（`<C-\><C-n>` 等）で **破棄**（`on_insert_leave` と非対称。leave しただけで PTY へ文字が飛ぶのを避けるため） | `CmdlineLeave` で常に detach。`v:event.abort`（Esc/C-c）なら破棄、正常終了(`<CR>` 実行等)なら確定テキストは既に `setcmdline` 済みなので学習のみ |
| `<C-j>`(toggle)での OFF | 未確定/変換中を **確定**（`disable()` が `finalize(s:commit())`） | 未確定/変換中を **確定して PTY へ送出**（`disable()` は `TermLeave` を経由しない。上記「通常の離脱」の破棄とは逆の挙動になる） | cmdline backend の `finalize` で確定（実行はしない） |

terminal は離脱経路が 2 つあり挙動が逆になる点に注意: **`TermLeave`（terminal-job モードを抜けるだけ）は破棄**、**`<C-j>` で IME 自体を OFF にすると確定してシェルへ送出**される。前者は「一時的にノーマルモードへ戻る」操作、後者は「IME を使うのをやめる」操作という意図の違いに対応している。

`completion`（自前自動補完 popup）と `register_word`（`C-r` の辞書登録、`vim.ui.input` を使う）は `terminal`/`cmdline` では **常に無効**（`refresh_completion`/`M.completion_active`/`M.on_register_word` が `backend.supports(...)` で早期リターンする）。`vim.ui.input` を cmdline/terminal の中で開くとネストして UX が壊れるため、構造的に届かないようにしている。dot repeat（`.`）も同様に `buffer` backend の挿入モード中 feedkeys 経路にしか無く、terminal-job モード・cmdline に「挿入モード」という概念自体が無いので対応しない。

**cmdline backend の割り込みモデル**: `CmdlineEnter` で現在の `st.backend`（`buffer` か `terminal`）を `st.saved_backend` に退避し、`cmdline` backend を `st.backend` に差し替えて `"c"` グローバルマッピングを張る。`"c"` はグローバルなので既存 backend の `"i"`/`"t"` マッピングは detach しない（モードが異なり衝突しないため）。`CmdlineLeave` で `"c"` マッピングを detach し、`st.saved_backend` を `st.backend` へ復元する（`st.saved_backend` が無い＝退避前から backend が無かった場合のみ `attach_to_current_buf()` へフォールバック）。`enable()`/`toggle()` は `attach_to_current_context()` で現在のコンテキスト（`getcmdtype()` → `buftype` の順）を見て 3 backend のどれを張るか決めるので、cmdline セッション中に toggle しても正しく `cmdline` backend が選ばれる。cmdline セッション中に `<C-j>` で OFF にした場合も `disable()` が `st.saved_backend` のキーマップを合わせて detach する（割り込まれた側のマッピングが残留しないように）。

`terminal`/`cmdline` は `config.terminal.enabled`/`config.cmdline.enabled`（既定 `true`）で無効化できる（§8）。無効時は該当 autocmd が該当 backend を張らず、typed した文字は vime に横取りされずそのまま書込先へ届く。

## 4. 処理フロー

代表シナリオ「通常バッファの挿入モードで `kyou` と打って Space で変換、候補を選び Enter で確定」を追う（`buffer` backend の場合。`terminal`/`cmdline` backend は書込先が異なるだけで手順の骨格は同じ。§3.3）。

1. **キー入力**: 挿入モードで `k` を押すと、`keymap.lua` が張ったマッピングが `init.on_input("k")` を呼ぶ。
2. **セッション更新**: `init.on_input` は `session:input("k")` を呼ぶ。session はローマ字バッファに溜める。
3. **描画**: `init` の `render()` が `st.backend:clear()` で前回の描画を消し、`st.backend:render(session:preedit_segments())` を呼ぶ。`buffer` backend はこれを受けて未確定文字列（`session:preedit()` = `romaji.to_kana("kyou")` → `きょう`）を `set_region_text` でバッファに書き、`ui.highlight_preedit` で下線を引く。未確定領域は backend が持つ `start_col`/`len`（byte）で管理する。
4. **変換開始**: `Space` で `init.on_convert` → `session:start_conversion()`。session は `anthy:convert("きょう")` を呼び、文節配列を得て `converting` へ。`render()` 経由で `backend:render()` が `ui.highlight_segments` で注目文節を反転表示。
5. **候補選択**: `Space` を押すたび `session:next_candidate()` で次候補へ送る。2 回目以降の `Space`（または `C-n`/`C-p`）で `st.popup_open=true` となり、`render` が `open_popup_window` で注目文節の候補一覧を `st.backend:popup_pos()` の位置に表示する（`C-f`/`C-b`・`C-o`/`C-i` の文節移動/伸縮でも、開いていれば追従して出し直す）。選択中の候補（`session:current_candidate_index()`）は `PmenuSel` で強調表示。変換中に文字を打つと `session:input` が現在の変換を確定して新しい読みを開始する（ラベル選択は廃止）。
6. **確定**: `Enter` で `init.on_commit` → `session:commit_step()`。session は現在の kana セグメントを `anthy:commit(choices)` に流して**学習**し、確定文字列を返す（複数 kana セグメントが残っていれば `nil` を返し次のセグメントへ converting を継続。全セグメント確定で `composing(空)` へ）。`init` の `finalize()` が `st.backend:finalize(text)` を呼んで未確定領域を確定テキストに置換し、領域を畳む（`len=0`）。

`init` のハンドラは `handlers()` テーブルに集約され、`keymap.attach` 経由でキーへ束ねられる。新しい操作を足すときも、このテーブルにハンドラを追加して `keymap.lua` に渡す。

## 5. 状態機械

### 5.1 状態

| 状態       | 実装上の表現                      | 説明                                 |
| ---------- | --------------------------------- | ------------------------------------ |
| DIRECT     | `init` の `st.enabled == false`   | 日本語入力 OFF。通常の Vim 挿入      |
| COMPOSING  | `session:state() == "composing"`  | 未確定（読み入力中）。下線表示       |
| CONVERTING | `session:state() == "converting"` | 変換中。文節・候補を操作。注目を反転 |

DIRECT はコントローラ層の状態（session は ON の間だけ存在）。COMPOSING には 2 つの変種がある:

- **英字ラン**（`is_latin()`）: 大文字始まりで開始。**かな未確定はその時点で commit** され、新しい latin セグメントを 1 個だけ持つ。確定は Enter のみ。
- **ASCII モード**（`is_ascii()`）: ASCII トグル（既定 `;`）で入退室。**かな未確定はそのまま保留**したまま末尾に latin セグメントを増やして英字をリテラル入力する。OFF は **トグルキーを再度押した時のみ**（他のキーが間に挟まってもモードは継続）。後続のかな入力で新しい kana セグメントが追加され、プリエディットは「kana / latin / kana / ...」と並ぶ。Space 変換時は kana セグメントだけを順次 anthy に流し、latin はリテラルで残す。

```
        ┌──────────┐  C-j   ┌───────────────┐
        │  DIRECT  │ ────►  │   COMPOSING   │ (未確定/下線)
        │日本語OFF │ ◄────  │  読み入力中   │
        └──────────┘  C-j   └───────────────┘
                               │  ▲        │ Space(非空・非latin)
                        Enter/ │  │ C-g/Esc▼
                        BS等   │  │   ┌───────────────┐
                               │  └───│CONVERTING     │ (変換中/反転)
                               │      │文節・候補操作 │
                               └──────│               │
                                Enter └───────────────┘
                                (確定=全文節commit→学習)
```

### 5.2 キー操作（日本語入力 ON 中・すべて設定で変更可）

| キー               | 状態                 | アクション                                                                                                      |
| ------------------ | -------------------- | --------------------------------------------------------------------------------------------------------------- |
| `C-j`              | DIRECT               | 日本語入力 ON（COMPOSING へ）                                                                                   |
| `C-j`              | COMPOSING/CONVERTING | 現在の未確定/変換を確定して日本語入力 OFF                                                                       |
| 英字（小文字）     | COMPOSING            | ローマ字バッファに追加し、かなを未確定列へ                                                                      |
| 英字（大文字始）   | COMPOSING            | 英字ラン開始（かな未確定を commit して latin セグメントへ。確定は Enter のみ）                                  |
| 英字               | CONVERTING           | 現在の変換を自動確定し、新しい読みで COMPOSING                                                                  |
| `;`(ascii_toggle)  | COMPOSING            | ASCII モード ON。**かな未確定は保留**し latin セグメント開始                                                    |
| 任意キー           | ASCII モード         | 末尾 latin セグメントへ追加（変換しない・大小保持・モード継続）                                                 |
| `;`(ascii_toggle)  | ASCII モード         | ASCII モード OFF。次の入力で新しい kana セグメント開始                                                          |
| `;`(ascii_toggle)  | CONVERTING           | 現在の変換を自動確定し、新しい latin セグメントで ASCII モード                                                  |
| `Space`            | COMPOSING(非空)      | 先頭 kana セグメントから変換開始。latin はリテラルで残す                                                        |
| `Space`            | COMPOSING(英字ラン)  | スペースを英字に追加（確定しない）                                                                              |
| `Space`            | ASCII モード         | スペースを末尾 latin セグメントに追加（確定しない）                                                             |
| `Space`            | CONVERTING           | 注目文節の次候補（候補一覧 popup を更新）                                                                       |
| `C-n` / `C-p`      | CONVERTING           | 注目文節の次候補 / 前候補                                                                                       |
| `Space`            | 未確定なし           | 通常のスペースを挿入                                                                                            |
| `C-f` / `C-b`      | CONVERTING           | 注目文節を次/前へ移動（popup 追従）                                                                             |
| `C-o` / `C-i`      | CONVERTING           | 注目文節を伸長/短縮（resize、popup 追従）                                                                       |
| `Enter`            | COMPOSING            | 全セグメント(kana+latin)を連結して確定                                                                          |
| `Enter`            | CONVERTING           | 現 kana の変換を確定（全文節 commit＝学習）し、残りの kana/latin を順次確定                                     |
| `Enter`            | 未確定なし           | 通常の改行を挿入                                                                                                |
| `F7`               | COMPOSING/CONVERTING | 読みをカタカナに変換して確定                                                                                    |
| `F10`              | COMPOSING/CONVERTING | 入力したローマ字（英小文字）に変換して確定                                                                      |
| `BS` / `C-h`       | COMPOSING            | かな単位で1単位削除（latin/英字ランは1byte）。空 latin はセグメント削除（ASCII モードは継続、英字ランは抜ける） |
| `C-g` / `Esc`      | CONVERTING           | 変換を取り消し、変換前のかな(COMPOSING)へ戻す                                                                   |
| `C-g`              | COMPOSING            | 未確定を破棄                                                                                                    |
| `C-w` / `C-u`      | COMPOSING/CONVERTING | 未確定があればクリア、無ければ通常の単語/行削除                                                                 |
| `C-r`              | CONVERTING           | 注目文節の読みを `vim.ui.input` で受けた単語として私的辞書へ登録し、その単語で確定挿入                          |
| `Esc`(InsertLeave) | COMPOSING/CONVERTING | 未確定を確定して挿入モードを抜ける                                                                              |

文節操作系（`C-f`/`C-b`/`C-n`/`C-p`/`C-o`/`C-i`）と辞書登録（`C-r`）は **CONVERTING 中のみ** buffer-local にマップされる。DIRECT・COMPOSING・ASCII モードでは vime がマップを張らず、ユーザーの insert モードマッピング（または Vim 既定）がそのまま生きる。実装は `init.render()`/`finalize()` の末尾で `sync_converting_keymap()` が `keymap.attach_converting`/`detach_converting` を冪等に呼ぶ。

## 6. 必ず守る不変条件と罠

feasibility 検証（旧 PoC）で確定し、回帰しやすい要点。コードを変える前に必ず確認する。

- **文節ハイライトの範囲計算は byte オフセットで行う**。日本語 1 文字 = 3 byte なので、文字数で計算すると確実にズレる。`ui.highlight_segments` と `init` の `start_col`/`len` 管理は byte 基準。
- **公開 API は 1-based、anthy 内部は 0-based**。`anthy.lua` の `Session:resize`/`Session:commit` が境界で `-1` 補正する。session/ui からは 1-based のまま扱う。
- **学習は「全文節 commit」でしか効かない**。`session:commit` は必ず `choices` 配列の全要素を `anthy_commit_segment` に流す。部分 commit は学習されないので導入しない。確定 UX は「文単位」に寄せている。
- **挿入モードを抜けるときに未確定を確定する**（`init.lua` の `InsertLeave` autocmd）。これがないと、ノーマルモードに残った未確定 extmark に対する `x`/`u` が壊れる。
- **IME ON 中の書込先の切替は `InsertEnter`/`TermEnter`/`CmdlineEnter` で行う**（`BufEnter` は使わない）。`st.backend` は「いま編集中の唯一の書込先」を指す。ユーザーが IME ON のまま別バッファへ移動して `i`/`a` 等で挿入モードに入った瞬間、`init.lua` の `InsertEnter` autocmd が `attach_to_current_buf()` を呼び、旧 backend の keymap/描画を掃除して新バッファへ attach し直す（terminal-job モードは `TermEnter`/`attach_to_terminal_buf()`、cmdline セッションは `CmdlineEnter`/`attach_cmdline_backend()` が同役）。`BufEnter` を使わないのはパフォーマンス理由（telescope のプレビュー等 BufEnter は大量発火し、毎回 ~104 個の `vim.keymap.set/del` が走るとプレビューがもたつくため）。`InsertEnter` は `terminal`/`prompt` buftype を除外する（`terminal` は `TermEnter` 側で扱う。`prompt` は vime が `<C-r>` 等を握ると UX が壊れるため対象外のまま）。
- **terminal-job モードを抜けるときは未確定を「破棄」する（`InsertLeave` とは非対称）**。`init.lua` の `TermLeave` autocmd（`M.on_term_leave`）は `session:commit()` を呼ばない。leave しただけで確定テキストが `chansend` で PTY(シェル) へ送られてしまうのを避けるため。挿入モードの `InsertLeave` が未確定を**確定**するのとは意図的に非対称。
- **cmdline/terminal backend は dot repeat（`.`）の対象外**。`buffer` backend の確定経路（挿入モード中の feedkeys + `<C-G>u`）は Vim の「挿入モード」概念に依存しており、cmdline・terminal-job モードには挿入モードが無い。`cmdline`/`terminal` backend の `finalize` はどちらも feedkeys 経路を持たない（`cmdline` は `setcmdline` による API 置換、`terminal` は `chansend` による送出）ため、構造的に dot repeat には載らない。
- **`anthy.lua` は失敗しても例外を投げない**。`setup` は `false` を返し、`init` 側で `vim.notify` ＋無効化する。「Vim を壊さない」が基本方針。
- **撥音 `ん` の look-ahead**: `nn` を常に 2 文字消費すると `こんにちは→こんいちは`、`おんな→おんあ` になる。2 つ目の `n` の次が母音/`y` なら `n` を 1 つだけ `ん` にする（実 IME 準拠）。`namba→なmば`（難波は `nanba`）、`honya→ほにゃ`（本屋は `hon'ya`）も実 IME と同じ正しい挙動。
- **促音 `っ`**: 同子音の連続（`kk`/`tt`…）と `tch` で生成する。
- **外来音・拗音テーブルは `expand()` で機械生成する**。`fa`/`va`/`tsa`/`tha`/`kwa` などを手で 1 つずつ足し続けない（穴が残る）。`f`/`v`/`ts` は `u` スロットがベース音（ふ/ゔ/つ）なので skip する。
- **学習は副作用としてディスクに永続化される**。原 anthy(9100h) は `$HOME/.anthy`、anthy-unicode は `$XDG_CONFIG_HOME/anthy`（未設定なら `~/.config/anthy`）。テストはこれを一時ディレクトリへ隔離する（[§9](#9-テスト構成)）。
- **変換対象範囲の管理**: 「どこからどこまでが未確定か」は各 backend が `row`/`start_col`/`len`（`buffer`）または `anchor`/`len`（`cmdline`。§3.3）のように byte 基準で保持する。確定後やユーザーの直接編集でズレたら `backend:sync_anchor()` が実カーソル位置/実 cmdpos へ再アンカーする。
- **ASCII モードと anthy の分離**: ASCII モード中の入力は **anthy に渡さない**。Space 変換時も latin セグメントは **anthy 入力に含めない**。kana セグメントを 1 個ずつ `anthy.convert` し、latin セグメントは間に挟まれた byte 列としてプリエディットに残す（連結すると latin の位置を復元できなくなるため）。
- **ASCII モード OFF はトグルキーのみ**。COMPOSING で ascii_toggle を 2 連打すると「ASCII ON → ASCII OFF」になり、latin セグメントは空のまま閉じられる。ASCII モード中に latin を BS で全削除してもモードは継続する（タイプミスを直して入力再開できるように）。次の入力で新規 latin セグメントが自動で開かれる。ASCII モード中に ascii_toggle 文字をリテラル入力する手段はない（必要なら設定で別文字に変えるか、一旦 OFF にしてから打つ）。
- **学習は kana セグメント単位**。複数の kana セグメントを含むプリエディットを確定する場合、各 kana セグメントの「全文節 commit」が **順次** 走る。各 commit ごとに anthy が学習する（kana セグメント間で文節を跨いだ変換はしない）。
- **文節操作系キーは CONVERTING 中のみ vime に奪われる**。`C-f`/`C-b`/`C-n`/`C-p`/`C-o`/`C-i` は CONVERTING 入退場時に動的に attach/detach される（`init.sync_converting_keymap()`）。COMPOSING や ASCII モードで vime がこれらを握り潰すと、ユーザーが insert モードで割り当てたカーソル移動マッピング等が死ぬので、必ず converting 限定で attach すること。新しく「converting でのみ意味があるキー」を増やすときは `keymap.CONVERTING_ONLY` に追加する。
- **確定テキストは feedkeys でタイプ入力として流し、native の redo に載せる（dot repeat）**。挿入モード中の `finalize(text)` は「preedit を API で削除 → `text` と `<C-G>u` を 1 回の `nvim_feedkeys` で流す」経路を取る。API 編集（`nvim_buf_set_text`）は Vim の redo バッファに記録されないため、確定テキストを API で書くと `.`（dot repeat）が確定を再現できない。feedkeys で「タイプされた入力」として流すと redo に載り、`ciwきょう<CR><Esc>` → `.` が「単語削除＋きょう挿入」として Vim 本来の動作で再現され、count（`3.`）や `a`/`A`/`o` の位置も native に効く（operatorfunc は汚さない）。フラグは `"in"` ＋ `escape_ks=true`:
  - `"i"`（typeahead 先頭挿入）: 後続の `<Esc>` より先に確定テキストを処理する。末尾追加にすると `<Esc>` の後で処理されノーマルモードで暴発する。
  - `"n"`（remap 無効）: 確定テキストが ASCII（F10 の `foo` 等）でも vime のキーマッピングに再入しない。
  - `escape_ks=true`: `「む」`（U+3080 = E3 82 80）のように UTF-8 継続バイト 0x80 を含む文字が K_SPECIAL と衝突して化けるのを防ぐ。
  - `text` と `<C-G>u` を **同一 feedkeys** にまとめるのは順序保証のため（別々に `"i"` で流すと後発が前へ割り込み逆転する）。`on_input` の確定分岐は `commit → 確定テキスト feed → ch を再投入` の順で `ch` を先に `"i"` で積んでから確定テキストを積み、`[確定テキスト][<C-G>u][ch][後続]` の順序にする。
  - 非挿入モード（direct handler 呼び出し・`disable` 等）は従来どおり API で置換する（`in_insert_mode()` で分岐）。
- **確定単位ごとに undo ブロックを区切る**。`finalize` が流す `<C-G>u`（`:help i_CTRL-G_u`）で `Esc` 後の `u` が確定 1 回分ずつ巻き戻る。`insert_literal`（未確定なしの Space/改行素通し）は feedkeys で流すが `<C-G>u` を積まない＝Vim 標準の 1 ブロック挙動を維持する。新しい確定経路を足すときは必ず `finalize(text)` を通す。
- **dot repeat の制限（受容済み）**: `ikyou<Esc>` のように CR なしで挿入モードを抜けた暗黙確定分（`InsertLeave` 経由の commit）は feedkeys を通らないため redo に載らず、`.` の対象外。また `.` 再生時の undo は確定単位（`<C-G>u`）ごとに分かれる。
- **モード変化通知は `name` の変化のみで発火する**。`User VimeModeChanged` autocmd と `mode_notify` popup は `mode().name` が前回通知時と変わったときだけ起動する。`ascii`/`latin`/`state` のみが変わるケースは `name` 側に集約してあるので毎フレーム発火しない（latin ラン中は kana/latin が切り替わるたびに `latin` フラグが上下するため、また hiragana ↔ converting の遷移は `name` が "hiragana" のまま動かないため）。詳細フラグを見たいユーザは `args.data.state`/`args.data.ascii`/`args.data.latin` を参照する。
- **`to_kana` の評価順序は「テーブル最長一致 → 撥音 ん → 促音 っ → 未知フォールバック」**。テーブル先行は、ACT 等の独自配列で `nh`/`tt`/`ss` のような既定 look-ahead と衝突するキーをテーブルで上書き可能にするため。既定 wapuro ではこれらの連続キーがテーブルに無いので撥音/促音判定にそのまま落ち、既存挙動が維持される（[§8.4](#84-カスタムローマ字テーブル)）。

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
  romaji = {
    table = nil,  -- nil なら既定の wapuro。非 nil なら完全置換(ACT 等の独自配列、§8.2)
  },
  keymaps = {
    toggle = "<C-j>",       convert = "<Space>",   commit = "<CR>",
    cancel = "<C-g>",       next_segment = "<C-f>", prev_segment = "<C-b>",
    expand = "<C-o>",       shrink = "<C-i>",       katakana = "<F7>",
    next_candidate = "<C-n>", prev_candidate = "<C-p>", alphabet = "<F10>",
    ascii_toggle = ";",     -- ASCII モード入退室。nil で無効化
    register_word = "<C-r>", -- CONVERTING 中に注目文節を私的辞書へ登録して確定
    completion_cancel = "<Esc>", -- 補完候補の選択中は cancel と同じ取消。未選択なら素通し
  },
  mode_notify = {
    enabled = true,         -- モード切替時にカーソル下へ短時間ラベルを出す
    duration = 1000,        -- ms
    labels = { direct = "直", hiragana = "あ", ascii = "A" },
    highlight = nil,        -- nil なら緑背景デフォルト。{ bg=..., fg=..., bold=... } で上書き
  },
  completion = {
    enabled = true,  -- 読み入力中(composing)の自動補完 popup
  },
  integrations = {
    nvim_cmp = false,  -- true で vime モード ON 中は nvim-cmp の補完を抑止する
  },
  cmdline = {
    enabled = true,  -- ":"/"/"/"?" での日本語入力(§3.3)。cmp-cmdline 等と競合する場合は false
  },
  terminal = {
    enabled = true,  -- terminal バッファ(terminal-job モード)での日本語入力(§3.3)。
                      -- toggleterm.nvim 等が独自に terminal-job モードのキーマップを握る場合は false
  },
})
```

SKK 辞書の取り込みは設定ではなく CLI で行う（§8.2）。

ハイライト `VimeUnconfirmed`（既定 underline）/ `VimeSegment`（既定 reverse）/ `VimeModeNotify`（既定: 緑背景・白文字・bold）は `:highlight` または `setup()` の `mode_notify.highlight` で上書きできる。latin セグメントは未変換 kana と同じ `VimeUnconfirmed`。

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
- **単語1件登録**: `anthy.register_word`（per-entry API）も残す（テスト・少数登録用）。bulk 取り込みは上記の直接生成を使う。エディタ内からは CONVERTING 中の `C-r`（`init.on_register_word`）が `vim.ui.input` で単語を受け、注目文節の `current_segment_yomi()` を読みに `register_word` を呼ぶ。

### 8.3 モード公開 API と mode_notify

ステータスラインや独自 UI で「いま何モードか」を表示するための公開 API:

```lua
require("vime").mode()
-- => { name = "hiragana", enabled = true, state = "composing", ascii = false, latin = false }
--    name は "direct" | "hiragana" | "ascii"
--    state は "composing" | "converting" | nil(direct のとき)
```

変換中は `name = "hiragana"`, `state = "converting"` を返す。`name` から `"converting"` を抜いてあるのは、候補一覧 popup（[§3.2 ui.lua](#uilua描画)）側で十分シグナルされており、モード通知 popup を上に重ねると邪魔になるため。`User VimeModeChanged` も hiragana ↔ converting では発火しない。

モード `name` が変化したとき `User VimeModeChanged` autocmd が発火し、`data` に上記のテーブルが入る:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "VimeModeChanged",
  callback = function(args)
    -- args.data = { name = ..., enabled = ..., state = ..., ascii = ..., latin = ... }
    vim.cmd("redrawstatus")
  end,
})
```

既定では同じタイミングで `ui.show_mode_notify` がカーソル下に短時間ラベル popup を出す（既定は緑背景・白文字・bold、ホスト float の中でも前面に出る zindex で）。独自ステータスライン等で表示する場合は config で無効化、配色だけ変えたいなら highlight を上書きする:

```lua
-- 通知を切って自分で出す
require("vime").setup({ mode_notify = { enabled = false } })

-- 配色だけ青系に変える(label/duration はデフォルト維持)
require("vime").setup({
  mode_notify = { highlight = { bg = "#1e88e5", fg = "#ffffff", bold = true } },
})
```

`mode.lua` は純粋関数で、`init` が `st.enabled`/`session:state()`/`session:is_ascii()`/`session:is_latin()` を集約して渡す。判定ロジックは `mode.compute` 1 箇所に閉じる（[§3.2 mode.lua](#modelua純粋関数)）。

### 8.4 カスタムローマ字テーブル

`romaji.table` に table を渡すと、`romaji.to_kana` が wapuro 既定を捨ててそれを使う（**マージしない完全置換**）。`session.new(anthy, { romaji_table = ... })` 経由でセッションに伝わる。

- 撥音 `ん`・促音 `っ`・大文字英字ランの look-ahead はテーブル非依存で常に同じロジックなので、ACT 等で **配列のキー→かなだけを定義すれば足りる**。
- 既定をベースに一部だけ差し替えたい場合は `vim.tbl_extend("force", {}, require("vime.romaji").default_table, { ... })` のようにユーザ側でマージする。`default_table` は直接書き換えない。
- 使い方の具体例は [README](../README.md#カスタムローマ字テーブルact-等) を参照。

## 9. テスト構成

TDD（RED→GREEN→REFACTOR）。テストは plenary.nvim（busted 風）。`tests/vime/<module>_spec.lua` に置く（コロケーションではなく `tests/` 配下のミラー構造）。

```sh
make test                                            # tests/vime/ を一括実行
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/vime/session_spec.lua" # 単一ファイル実行
nvim --headless -l tests/smoke.lua                   # 実 libanthy を使う E2E スモーク
```

| 層         | テスト対象                                           | 手法                                                |
| ---------- | ----------------------------------------------------- | --------------------------------------------------- |
| `romaji`   | ローマ字→かな（拗音/促音/撥音/外来音/ん/大文字）     | 純粋関数。入出力比較                                |
| `session`  | 状態遷移・文節/候補/注目 index 管理                  | 実 anthy を注入し、状態と出力を検証                 |
| `mode`     | enabled/state/ascii/latin → モード名の推論           | 純粋関数。入出力比較                                |
| `anthy`    | FFI ラッパの薄い結線                                 | 実 libanthy で疎通（環境依存のため最小）            |
| `ui`       | extmark の byte 範囲計算・候補 popup・preedit float  | バッファ／win に対して状態を検証                    |
| `keymap`   | attach/detach のモード別挙動（`i`/`t`/`c`）・保存復元 | `nvim_buf_get_keymap`/`nvim_get_keymap`(`"c"`) で検証 |
| `skk`      | JISYO 解析（候補整形/エントリ展開/decode）・取り込み | 純粋部は入出力比較、load は temp JSON+注入          |
| `init`     | end-to-end（キー入力→確定までの結線・モード通知）    | 実 anthy で通しシナリオ                             |
| `terminal` | terminal backend の送出制御・TermEnter/TermLeave 結線 | 単体は DI した `send` の spy、結線は実 PTY(`jobstart({"cat"},{term=true})`) |
| `cmdline`  | cmdline backend の領域管理・CmdlineEnter/Leave 結線  | 実際に `:`/`/`/`?` を開いて `getcmdline`/`setcmdline` を検証 |

### テストの決定性

- **学習をテストごとに隔離する**。`tests/minimal_init.lua` と `tests/smoke.lua` が `HOME` と `XDG_CONFIG_HOME` を毎回 `tempname()` 配下へ差し替える（原 anthy=`$HOME/.anthy`、anthy-unicode の HOME は `getpwuid` 由来で env では変えられないため `$XDG_CONFIG_HOME/anthy` の隔離が必須）。spec ファイル＝別 nvim なので学習が混ざらない。
- **lib は HOME を temp 化する前に解決して `$VIME_ANTHY_LIB` に固定する**。temp 化後だと `~` 展開先が変わり `~/.local/lib` 等を見失う。
- **辞書バージョン依存の絶対値で検証しない**。anthy-unicode と 9100h は同じ読みでも分割/候補が変わる（例: `きょうはいいてんきだね` は 9100h=今日は… / unicode=今日…）。安定事実・相対変化で検証し、学習する `it` は describe 末尾に置く。
- `session` テストも実 anthy を注入する（fake は使わない）。
- **terminal-job モードは headless（UI 未 attach）では実際には遷移しない**（`:startinsert` しても `TermEnter` が発火せず `mode()` は `"n"` のまま。`nvim_ui_attach` が要る）。`terminal_spec.lua` はこの制約を前提に、backend の選択は `buftype == "terminal"` のみで判定する設計にし（実モード判定に依存しない）、`TermEnter` の結線検証は `nvim_exec_autocmds("TermEnter", {buffer=...})` で直接発火させて行う。`TermLeave` は同様に直接発火させず、`vime.on_term_leave()`（ハンドラ本体）を直接呼んで検証する（`TermLeave` autocmd 自体の登録は §9 のとおり `TermEnter` と対で存在するが、この結線自体は headless では検証していない）。
- **`nvim_feedkeys(keys, "tx", ...)` はタイプアヘッドが尽きた時点で cmdline が開いたままだと暗黙にキャンセルする**（headless の制約）。そのため「cmdline を開いたまま複数ステップの状態を確認する」テストは、同一の `feedkeys` 呼び出し内でプローブキー（例 `<F12>`）に一時マッピングした callback から `getcmdline()`/`mode()` 等を読み取る（`cmdline_spec.lua` の `probe_in_cmdline` ヘルパ）。別々の `feedkeys` 呼び出しに分割すると、1 回目の呼び出しの終わりで cmdline が閉じてしまい後続の呼び出しが意図通りに動かない。

## 10. 開発フロー

- コミットは Conventional Commit + emoji + `[STRUCTURAL]` / `[BEHAVIORAL]` プレフィックスを付ける。構造変更と動作変更は別コミットに分ける（Tidy First）。
- LSP 警告は `lua_ls` を `.luarc.json`（LuaJIT + Neovim グローバル + busted DSL）で運用。busted の `describe`/`it`/`assert` は warning にならない。

よくある変更箇所:

- **ローマ字テーブル / 拗音・促音・撥音のロジック**: `lua/vime/romaji.lua`。ケースは `tests/vime/romaji_spec.lua` にあるのでそちらを更新する。
- **新しいキー操作**: `init.lua` の `handlers()` テーブルにハンドラを足し、`keymap.lua` の `attach` でキーへ束ねる。印字可能 ASCII（0x21–0x7e）は 1 文字ずつ `handlers.input(ch)` に流れる。`<`/`|`/`\` だけ `<lt>`/`<Bar>`/`<Bslash>` にエスケープが要るので、印字可能文字のロジックを変えるなら `SPECIAL_LHS` テーブルも併せて更新する。
- **描画**: `ui.lua`。範囲は必ず byte オフセット（[§6](#6-必ず守る不変条件と罠)）。
- **新しい書込先（backend）を増やす**: `lua/vime/backend/*.lua`。既存 3 backend（[§3.3](#33-backend書込先の抽象化)）の interface（`sync_anchor`/`set_region_text`/`render`/`clear`/`finalize`/`insert_literal`/`passthrough`/`popup_pos`/`place_cursor`/`supports`。`set_region_text` は completion 対応時のみ必須）を実装し、`init.lua` にアタッチ契機（autocmd）と `attach_to_current_context()` の判定を足す。`keymap.lua` の `mode` 引数（`"i"`/`"t"`/`"c"`）を再利用できる新モードならそのまま渡せる。あわせて `tests/vime/<name>_spec.lua`（新規テスト、TDD で先に書く）・`config.lua` の `<name>.enabled` トグル・`doc/vime.txt`/README.md への使い方の追記も行う（`cmdline`/`terminal` 追加時の一式が実例）。

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
