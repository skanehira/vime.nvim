# TODO

実装フェーズ。TDD(RED → GREEN → REFACTOR → REVIEW → CHECK)で進める。
コミットは Conventional Commit + emoji + `[STRUCTURAL]` / `[BEHAVIORAL]` を付ける。

## ASCII 直入力モード

未確定領域に英字をリテラル混在させたい(例: `きょうは;iPhone;をかった`)ための機能。
詳細仕様は [ARCHITECTURE.md §3.2/§5/§6/§8](ARCHITECTURE.md) と [GLOSSARY.md](GLOSSARY.md) を参照。

### Phase 1: セグメント列モデルへリファクタ [STRUCTURAL]

- [ ] `session` の内部表現を `romaji` 単一バッファから `{kind=kana|latin, ...}` 配列(`_segments_buf` 等)へ置換
- [ ] `preedit`/`backspace`/`commit`/`commit_katakana`/`commit_alphabet`/`cancel`/`clear`/`is_latin` を新内部表現で実装(既存 API と挙動を維持)
- [ ] `session_spec.lua` の既存テストがすべて緑のまま

### Phase 2: ASCII モード入退室 [BEHAVIORAL]

- [ ] composing 中に ASCII トグル(`;`)で ASCII モード ON。kana 未確定は保留
- [ ] ASCII モード中の任意キーは末尾 latin セグメントへ追加
- [ ] ASCII モード中の ASCII トグルで OFF
- [ ] `s:is_ascii()` で判定可能

### Phase 3: ASCII モード OFF はトグルキーのみ [BEHAVIORAL]

- [ ] ASCII モード中の任意のキー(toggle 以外)はすべて latin に追加し、モード継続
- [ ] OFF は ASCII トグルを再度押した時のみ
- ※ `;;` リテラル化や pending 状態は持たない(ユーザー要件: シンプル優先)

### Phase 4: ASCII モード中の BS [BEHAVIORAL]

- [ ] ASCII モード中の BS は latin セグメントから 1byte 削除
- [ ] latin セグメントが空になったら latin セグメントを削除して ASCII モード OFF

### Phase 5: 変換時に kana セグメントを順次 converting [BEHAVIORAL]

- [ ] `start_conversion` は先頭の kana セグメントから anthy.convert
- [ ] `commit` は現 converting の kana を確定し、次の kana セグメントへ converting を移す(自動 start_conversion)
- [ ] 全 kana セグメント確定後はプリエディット全体(latin 含む)を返して composing(空)へ
- [ ] CONVERTING 中に ASCII トグルで現変換を確定して新しい latin セグメントへ

### Phase 6: 設定 IF [BEHAVIORAL]

- [ ] `config.defaults.keymaps.ascii_toggle = ";"` を追加(nil で無効)
- [ ] `session.new(anthy, { ascii_toggle = ";" })` で受け取る
- [ ] `init` から config を渡して結線
- [ ] `keymap.lua` は引き続き `input(ch)` 経路で `;` を session に渡す(専用キーマップ不要)

### Phase 7: 描画はセグメント列ベース [BEHAVIORAL]

- [ ] `session:preedit_segments()` で描画用セグメント配列を返す
- [ ] `init.render` が各セグメントを byte 範囲ごとに描画(latin/kana は VimeUnconfirmed、注目 kana は VimeSegment、confirmed はハイライトなし)
- ※ latin 専用ハイライトは持たない(ユーザー要件)

### Phase 8: スモークテスト [BEHAVIORAL]

- [ ] `tests/smoke.lua` に「きょうは;iPhone;をかった」→ Space で変換 → CR で確定 のシナリオを追加
