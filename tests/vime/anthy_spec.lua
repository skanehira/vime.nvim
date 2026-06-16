local anthy = require("vime.anthy")

local LIB = "/nix/store/m2z37mlz9rsh2azv9pny1860rpycic54-anthy-9100h/lib/libanthy.dylib"

local function contains(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

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

  it("converts yomi into segments with best and candidates", function()
    local s = anthy.new_session()
    local segs = s:convert("きょうはいいてんきだね")
    assert.are.equal(3, #segs)
    assert.are.equal("今日は", segs[1].best)
    assert.is_true(contains(segs[2].candidates, "いい")) -- 候補に いい が含まれる
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
