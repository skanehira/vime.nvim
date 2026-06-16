local session = require("vime.session")
local fake = require("tests.vime.fake_anthy")

-- 2文節の決め打ち変換結果
local FIXTURE = {
  { best = "今日は", candidates = { "今日は", "きょうは", "凶は" } },
  { best = "いい", candidates = { "いい", "良い" } },
}

local function new()
  return session.new(fake)
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
end)

describe("vime.session CONVERTING", function()
  before_each(function()
    fake.set_result(FIXTURE)
  end)

  it("enters converting with the first segment focused", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    assert.are.equal("converting", s:state())
    local view = s:segments()
    assert.are.same({ "今日は", "いい" }, view.list)
    assert.are.equal(1, view.current)
  end)

  it("cycles candidates of the focused segment", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    s:next_candidate()
    assert.are.equal("きょうは", s:segments().list[1])
  end)

  it("moves the focused segment with clamping", function()
    local s = new()
    type_in(s, "kyouhaii")
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
    fake.set_resized_result({
      { best = "今日はい", candidates = { "今日はい" } },
      { best = "い", candidates = { "い" } },
    })
    type_in(s, "kyouhaii")
    s:start_conversion()
    s:expand()
    assert.are.same({ seg = 1, delta = 1 }, s.anthy.log.resized[1])
    assert.are.equal("今日はい", s:segments().list[1])
  end)

  it("commits the selected candidates and learns", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    s:next_candidate() -- seg1 を きょうは に
    assert.are.equal("きょうはいい", s:commit())
    assert.are.same({ 2, 1 }, s.anthy.log.committed)
    assert.are.equal("composing", s:state())
    assert.are.equal("", s:preedit())
  end)

  it("exposes the focused segment candidates for the popup", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    assert.are.same({ "今日は", "きょうは", "凶は" }, s:candidates())
  end)

  it("selects a candidate by index for the focused segment", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    s:select(3) -- seg1 を 凶は に
    assert.are.equal("凶は", s:segments().list[1])
  end)

  it("clears the whole composition", function()
    local s = new()
    type_in(s, "kyou")
    s:start_conversion()
    s:clear()
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

  it("auto-commits when a letter is typed during conversion", function()
    local s = new()
    type_in(s, "kyouhaii")
    s:start_conversion()
    local confirmed = s:input("a")
    assert.are.equal("今日はいい", confirmed)
    assert.are.equal("composing", s:state())
    assert.are.equal("あ", s:preedit())
  end)
end)
