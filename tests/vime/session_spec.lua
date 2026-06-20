local session = require("vime.session")
local anthy = require("vime.anthy")
local config = require("vime.config")

-- session の変換系は実 anthy を注入して検証する(fake は廃止)。
-- 決定性: minimal_init が spec ごとに HOME を tempname へ隔離するため学習はファイル単位で独立。
-- アサーションは辞書バージョン依存の絶対値を避け、安定事実(文節数/先頭文節)や相対変化で検証し、
-- 学習する it は副作用が後続の既定を変えないよう describe 末尾に置く。
assert(anthy.setup(assert(config.find_anthy_lib(), "libanthy not found; set $VIME_ANTHY_LIB")))

local function new()
  return session.new(anthy)
end

local function type_in(s, str)
  for i = 1, #str do
    s:input(str:sub(i, i))
  end
end

describe("vime.session COMPOSING", function()
  it("accumulates romaji into a kana preedit", function()
    local s = new()
    type_in(s, "kyou")
    assert.are.equal("composing", s:state())
    assert.are.equal("きょう", s:preedit())
  end)

  it("removes one kana at a time on backspace", function()
    local s = new()
    type_in(s, "kyou")
    s:backspace()
    assert.are.equal("きょ", s:preedit()) -- う を削除
  end)

  it("removes a whole kana even from incomplete romaji on backspace", function()
    local s = new()
    type_in(s, "supe") -- すぺ
    s:backspace()
    assert.are.equal("す", s:preedit()) -- ぺ ごと削除("すp" にならない)
    type_in(s, "ka") -- すか
    s:backspace()
    assert.are.equal("す", s:preedit()) -- か ごと削除
  end)

  it("commits the raw kana when committed while composing", function()
    local s = new()
    type_in(s, "aiueo")
    assert.are.equal("あいうえお", s:commit())
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
  end)

  it("commits the typed romaji as lowercase letters", function()
    local s = new()
    type_in(s, "foo") -- ふぉお
    assert.are.equal("ふぉお", s:preedit())
    assert.are.equal("foo", s:commit_alphabet()) -- 元のローマ字(英小文字)で確定
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
  end)
end)

describe("vime.session LATIN (uppercase)", function()
  it("keeps an uppercase-started run as latin without converting", function()
    local s = new()
    type_in(s, "API")
    assert.are.equal("composing", s:state())
    assert.is_true(s:is_latin())
    assert.are.equal("API", s:preedit())
  end)

  it("continues latin for following lowercase letters", function()
    local s = new()
    type_in(s, "Google")
    assert.are.equal("Google", s:preedit())
  end)

  it("keeps spaces inside the latin run (commit only on Enter)", function()
    local s = new()
    type_in(s, "Chrome")
    s:input(" ") -- 英字ラン中のスペースは区切りでなく文字
    type_in(s, "devtool")
    assert.are.equal("Chrome devtool", s:preedit())
    assert.is_true(s:is_latin())
  end)

  it("commits pending kana then starts a latin run on uppercase", function()
    local s = new()
    type_in(s, "wa") -- わ
    local confirmed = s:input("A")
    assert.are.equal("わ", confirmed)
    assert.are.equal("A", s:preedit())
    assert.is_true(s:is_latin())
  end)

  it("removes one latin character on backspace and returns to kana mode when empty", function()
    local s = new()
    type_in(s, "AB")
    s:backspace()
    assert.are.equal("A", s:preedit())
    s:backspace()
    assert.are.equal("", s:preedit())
    assert.is_false(s:is_latin())
  end)
end)

describe("vime.session ASCII mode", function()
  it("enters ASCII mode on the toggle key and keeps the kana preedit", function()
    local s = new()
    type_in(s, "aka") -- あか
    s:input(";")
    assert.is_true(s:is_ascii())
    assert.are.equal("あか", s:preedit()) -- kana は保留(commit されない)
  end)

  it("appends following keys to the latin segment without converting", function()
    local s = new()
    type_in(s, "aka;iPhone")
    assert.are.equal("あかiPhone", s:preedit())
    assert.is_true(s:is_ascii())
  end)

  it("preserves case and accepts spaces inside the ASCII run", function()
    local s = new()
    type_in(s, "aka;Hello World")
    assert.are.equal("あかHello World", s:preedit())
  end)

  it("exits ASCII mode on the toggle key and starts a new kana segment", function()
    local s = new()
    type_in(s, "aka;iPhone;wo")
    assert.are.equal("あかiPhoneを", s:preedit())
    assert.is_false(s:is_ascii())
  end)

  it("enters ASCII mode from empty preedit", function()
    local s = new()
    s:input(";")
    assert.is_true(s:is_ascii())
    assert.are.equal("", s:preedit())
    type_in(s, "foo")
    assert.are.equal("foo", s:preedit())
  end)

  it("stays in ASCII mode for any non-toggle key (only the toggle key exits)", function()
    local s = new()
    type_in(s, "a;b") -- a→kana, ; ASCII ON, b→latin
    assert.is_true(s:is_ascii())
    type_in(s, "cd") -- 引き続き ASCII モード
    assert.are.equal("あbcd", s:preedit())
    assert.is_true(s:is_ascii())
  end)

  it("exits ASCII mode only when the toggle key is pressed again", function()
    local s = new()
    type_in(s, "a;bc;d") -- a→kana, ; ASCII ON, bc→latin, ; OFF, d→新規 kana
    assert.are.equal("あbcd", s:preedit())
    assert.is_false(s:is_ascii())
  end)

  it("removes one latin character on backspace in ASCII mode", function()
    local s = new()
    type_in(s, "a;XY")
    s:backspace()
    assert.are.equal("あX", s:preedit())
    assert.is_true(s:is_ascii())
  end)

  it("keeps ASCII mode on even when the latin segment becomes empty on backspace", function()
    local s = new()
    type_in(s, "a;X")
    s:backspace() -- X 削除 → latin 空セグメントは削除されるが ASCII モードは維持
    assert.are.equal("あ", s:preedit())
    assert.is_true(s:is_ascii()) -- ; を再度押すまで OFF にしない
  end)

  it("resumes typing into a new latin segment after the previous one was emptied", function()
    local s = new()
    type_in(s, "a;X")
    s:backspace() -- latin 空削除、ASCII モード継続
    type_in(s, "Y") -- ASCII モード中なので latin に追加(新規 latin セグメント作成)
    assert.are.equal("あY", s:preedit())
    assert.is_true(s:is_ascii())
  end)

  it("removes from the previous kana segment when backspace goes past the empty latin", function()
    local s = new()
    type_in(s, "a;X")
    s:backspace() -- X 削除 → latin 空削除
    s:backspace() -- 前の kana(a) から 1 文字削除
    assert.are.equal("", s:preedit())
  end)
end)

describe("vime.session CONVERTING with mixed kana/latin", function()
  it("keeps latin literal and unconverted kana visible in preedit while converting first kana", function()
    local s = new()
    type_in(s, "kyou;A;wokatta") -- kana(kyou) / latin(A) / kana(wokatta)
    s:start_conversion()
    assert.are.equal("converting", s:state())
    local pre = s:preedit()
    assert.is_true(pre:find("A", 1, true) ~= nil) -- latin はリテラルで残る
    assert.is_true(pre:find("をかった", 1, true) ~= nil) -- 未変換 kana はかな表示
  end)

  it("advances to the next kana segment on commit_step (returns nil while more remain)", function()
    local s = new()
    type_in(s, "kyou;A;wo")
    s:start_conversion()
    local result = s:commit_step()
    assert.is_nil(result) -- まだ converting 継続
    assert.are.equal("converting", s:state())
    -- 注目は kana(wo) になっており、その変換結果が preedit に出る
    local pre = s:preedit()
    assert.is_true(pre:find("A", 1, true) ~= nil) -- latin は健在
  end)

  it("returns the joined text after the last kana segment is committed via commit_step", function()
    local s = new()
    type_in(s, "kyou;A;wo")
    s:start_conversion()
    s:commit_step() -- kyou 確定 → kana(wo) 自動 converting
    local final = s:commit_step() -- wo 確定 → 全終了
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
    assert.is_true(final:find("A", 1, true) ~= nil)
  end)

  it("commit (一括) finalizes all remaining kana segments at once", function()
    local s = new()
    type_in(s, "kyou;A;wo")
    s:start_conversion()
    local final = s:commit() -- 残り kana も既定候補で convert+commit
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
    assert.is_true(final:find("A", 1, true) ~= nil)
  end)
end)

describe("vime.session CONVERTING (real anthy)", function()
  it("enters converting with the first segment focused", function()
    local s = new()
    type_in(s, "kyouhaii") -- きょうはいい → [今日は | いい]
    s:start_conversion()
    assert.are.equal("converting", s:state())
    local view = s:segments()
    assert.are.equal(2, #view.list)
    assert.are.equal("今日は", view.list[1])
    assert.are.equal(1, view.current)
  end)

  it("cycles candidates of the focused segment", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    local second = s:candidates()[2] -- 注目文節の2番目候補
    s:next_candidate()
    assert.are.equal(second, s:segments().list[1])
  end)

  it("cycles candidates backward and wraps to the last", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    local last = s:candidates()[#s:candidates()] -- 注目文節の末尾候補
    s:prev_candidate() -- 先頭(1)から前へ → 末尾へ wrap
    assert.are.equal(last, s:segments().list[1])
  end)

  it("reports the selected candidate index of the focused segment", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    assert.are.equal(1, s:current_candidate_index()) -- 初期は先頭候補
    s:next_candidate()
    assert.are.equal(2, s:current_candidate_index())
  end)

  it("moves the focused segment with clamping", function()
    local s = new()
    type_in(s, "kyouhaii") -- 2文節
    s:start_conversion()
    s:next_segment()
    assert.are.equal(2, s:segments().current)
    s:next_segment() -- 端で clamp
    assert.are.equal(2, s:segments().current)
    s:prev_segment()
    assert.are.equal(1, s:segments().current)
  end)

  it("resizes the focused segment", function()
    local s = new()
    type_in(s, "denshaninotteodekakesuru") -- でんしゃにのっておでかけする(先頭=電車)
    s:start_conversion()
    assert.are.equal("電車", s:segments().list[1])
    s:expand() -- 第1文節を +1 伸長
    assert.are.equal("電車に", s:segments().list[1])
  end)

  it("exposes the focused segment candidates for the popup", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    local cands = s:candidates()
    assert.are.equal("今日は", cands[1])
    assert.is_true(#cands > 1) -- 複数候補が読める
  end)

  it("selects a candidate by index for the focused segment", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    local third = s:candidates()[3]
    s:select(3)
    assert.are.equal(third, s:segments().list[1])
  end)

  it("commits the selected candidates and returns the joined text", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    local joined = table.concat(s:segments().list)
    assert.are.equal(joined, s:commit()) -- 既定候補で確定(=学習だが既定なので既定は不変)
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
  end)

  it("commits the reading as katakana even during conversion", function()
    local s = new()
    type_in(s, "kyouhaii") -- 読み: きょうはいい
    s:start_conversion()
    assert.are.equal("キョウハイイ", s:commit_katakana())
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
  end)

  it("commits the typed romaji as letters even during conversion", function()
    local s = new()
    type_in(s, "kyou")
    s:start_conversion()
    assert.are.equal("kyou", s:commit_alphabet()) -- 変換中でも元のローマ字で確定
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
  end)

  it("cancels conversion back to composing", function()
    local s = new()
    type_in(s, "kyou")
    s:start_conversion()
    s:cancel()
    assert.are.equal("composing", s:state())
    assert.are.equal("きょう", s:preedit())
  end)

  it("clears the whole composition", function()
    local s = new()
    type_in(s, "kyou")
    s:start_conversion()
    s:clear()
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
  end)

  it("auto-commits the defaults when a letter is typed during conversion", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    local joined = table.concat(s:segments().list)
    local confirmed = s:input("a")
    assert.are.equal(joined, confirmed)
    assert.are.equal("composing", s:state())
    assert.are.equal("あ", s:preedit())
  end)

  -- 学習は後続の既定を変えうるため describe 末尾に置く(この spec の HOME は隔離済み)。
  it("learns the committed candidate so it becomes the next default", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    s:next_segment() -- 第2文節(いい)へ
    local target = s:candidates()[2] -- 非既定候補(例: 良い)
    s:select(2)
    s:commit() -- 第2文節を非既定で確定 → 学習
    local s2 = new()
    type_in(s2, "kyouhaii")
    s2:start_conversion()
    assert.are.equal(target, s2:segments().list[2]) -- 既定が学習結果に変化
  end)
end)
