local anthy = require("vime.anthy")

local LIB = assert(require("vime.config").find_anthy_lib(), "libanthy not found; set $VIME_ANTHY_LIB")

describe("vime.anthy.setup", function()
  it("returns true for a valid library path", function()
    assert.is_true(anthy.setup(LIB))
  end)

  it("returns false for an invalid path without crashing", function()
    assert.is_false(anthy.setup("/nonexistent/libanthy.dylib"))
    -- 不正パス後も正規パスで復帰できる
    assert.is_true(anthy.setup(LIB))
  end)
end)

describe("vime.anthy session", function()
  before_each(function()
    assert.is_true(anthy.setup(LIB))
  end)

  it("converts yomi into multi-segment best/candidates", function()
    local s = anthy.new_session()
    local segs = s:convert("きょうはいいてんきだね")
    assert.is_true(#segs >= 2) -- 複数文節に分割される
    assert.are.equal(segs[1].candidates[1], segs[1].best) -- best は第1候補
    assert.is_true(#segs[1].candidates > 1) -- 候補が複数読める
    local joined = {}
    for _, seg in ipairs(segs) do
      joined[#joined + 1] = seg.best
    end
    assert.are_not.equal("きょうはいいてんきだね", table.concat(joined)) -- かな→漢字変換された
    s:close()
  end)

  it("re-segments when a segment is resized", function()
    local s = anthy.new_session()
    local segs = s:convert("でんしゃにのっておでかけする")
    assert.are.equal("電車", segs[1].best)
    local resized = s:resize(1, 1) -- 第1文節を +1 伸長
    assert.are.equal("電車に", resized[1].best)
    s:close()
  end)

  it("commits chosen candidates without error", function()
    local s = anthy.new_session()
    s:convert("わたしはがくせいです")
    assert.has_no.errors(function()
      s:commit({ 1, 1 }) -- 各文節の第1候補で確定(=学習)
    end)
    s:close()
  end)
end)

-- ユーザ辞書(私的辞書)への登録。HOME は spec 単位で隔離されるため新規語は事前に存在しない。
local function count_candidate(yomi, word)
  local s = anthy.new_session()
  local segs = s:convert(yomi)
  local n = 0
  for _, seg in ipairs(segs) do
    for _, c in ipairs(seg.candidates) do
      if c == word then
        n = n + 1
      end
    end
  end
  s:close()
  return n
end

describe("vime.anthy.register_word", function()
  before_each(function()
    assert.is_true(anthy.setup(LIB))
  end)

  it("makes a registered word appear as a conversion candidate", function()
    assert.are.equal(0, count_candidate("ぶいめ", "vime")) -- 登録前は出ない
    assert.is_true(anthy.register_word("ぶいめ", "vime"))
    assert.are.equal(1, count_candidate("ぶいめ", "vime")) -- 登録後は候補に出る
  end)

  it("is idempotent when the same word is registered twice", function()
    assert.is_true(anthy.register_word("ぶいめ", "vime"))
    assert.is_true(anthy.register_word("ぶいめ", "vime"))
    assert.are.equal(1, count_candidate("ぶいめ", "vime")) -- 重複登録されない
  end)
end)
