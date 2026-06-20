# 用語集（ユビキタス言語）

vime.nvim の実装・ドキュメントで使う用語を統一する。コード上の識別子もこの語に揃える。

| 用語               | 英語(コード語)      | 定義                                                                                                              |
| ------------------ | ------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 入力モード         | input mode          | 日本語入力の ON/OFF 状態。OFF 時は通常の Vim 挿入                                                                 |
| 直接入力           | direct              | 日本語入力 OFF。英数字をそのまま入力する状態                                                                      |
| 読み               | yomi                | ローマ字から変換されたかな文字列。Anthy への入力                                                                  |
| ローマ字バッファ   | romaji buffer       | 未変換のローマ字断片(例: 確定前の `ky`)を一時保持する領域                                                         |
| 未確定             | preedit / composing | まだ確定していない入力中の文字列。下線で表示                                                                      |
| 変換               | henkan / convert    | 読み(かな)→漢字かな混じり文への変換                                                                               |
| 文節               | segment             | 変換の単位。Anthy が読みを自動分割する                                                                            |
| 候補               | candidate           | ある文節の変換候補。Anthy が複数返す                                                                              |
| 注目文節           | current segment     | 現在操作対象の文節。反転表示する                                                                                  |
| 候補一覧           | candidate popup     | 注目文節の候補を一覧表示する floating window                                                                      |
| 確定               | commit              | 変換結果をバッファに書き込み確定する。全文節 commit で学習される                                                  |
| 文節伸縮           | resize              | 文節の境界を伸ばす/縮める操作(`anthy_resize_segment`)                                                             |
| 学習               | learning            | 確定した変換を Anthy が `~/.anthy` に記憶し次回以降に反映                                                         |
| セッション         | session             | 1 回の「未確定→変換→確定」の状態を保持する変換単位                                                                |
| ユーザー辞書       | user dictionary     | ユーザの語を持つ Anthy の私的辞書(`private_words_default`)。CLI で SKK 辞書を取り込む                             |
| SKK 辞書           | SKK dictionary      | SKK 用の辞書。vime は JISYO 形式(JSON)を取り込む                                                                  |
| 送りなし           | okuri_nasi          | SKK 辞書の「読み→候補配列」エントリ(主に名詞)。vime の取り込み対象                                                |
| 送りあり           | okuri_ari           | SKK 辞書の活用語エントリ(語幹+送り子音)。vime は取り込まない                                                      |
| プリエディット     | preedit             | 未確定領域全体。kana セグメントと latin セグメントの並びで構成                                                    |
| かなセグメント     | kana segment        | プリエディット中のかな(読み)断片。anthy で変換対象                                                                |
| ラテンセグメント   | latin segment       | プリエディット中の英字リテラル断片。変換対象外でそのまま残る                                                      |
| ASCII モード       | ASCII mode          | 未確定かなを保留したまま英字をリテラル入力するモード(COMPOSING の変種)。再度トグルキーを押すまで OFF にならない   |
| ASCII トグル       | ascii_toggle        | ASCII モードを入退室するキー文字(既定 `;`、設定で変更可)。ASCII モード中の押下で即 OFF                            |
| 英字ラン           | latin run           | 大文字始まりで開始される単一の latin セグメント(かな未確定は事前に commit)                                        |
| モード             | mode                | 外向きのモード名 `direct`/`hiragana`/`ascii`。`vime.mode()` で取得。変換中は `hiragana`（state フィールドで細分） |
| モード通知         | mode notify         | モード切替時にカーソル下へ短時間出る floating window のラベル popup                                               |
| モード変化イベント | VimeModeChanged     | モード名(`mode().name`)が変わったときに発火する `User` autocmd。`data` に mode テーブル                           |

## 状態の呼称

| 状態       | 定義                                           |
| ---------- | ---------------------------------------------- |
| DIRECT     | 日本語入力 OFF。通常の挿入                     |
| COMPOSING  | 未確定(読み入力中)。下線表示                   |
| CONVERTING | 変換中。文節・候補を操作中。注目文節を反転表示 |

COMPOSING には ASCII モード(latin セグメントへ入力中)という変種がある。`session:is_ascii()` で判定する。

## 外向きのモード名

ステータスライン等から見える `vime.mode().name` の語彙。内部状態(DIRECT/COMPOSING/CONVERTING + ASCII フラグ)を 1 つの名前に束ねたもの。

| 名前     | 内部状態の対応                                                  |
| -------- | --------------------------------------------------------------- |
| direct   | DIRECT(日本語入力 OFF)                                          |
| hiragana | COMPOSING(かな入力中。latin ラン中も含む) **および** CONVERTING |
| ascii    | COMPOSING + `is_ascii()`(ASCII モード中)                        |

CONVERTING は候補一覧 popup 側で十分シグナルされるので、外向きの name には出さない（モード通知 popup が候補 popup と重なって邪魔になるため）。詳細を区別したいユーザは `vime.mode().state == "converting"` で判定できる。
