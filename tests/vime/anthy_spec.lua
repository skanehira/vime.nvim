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

  -- 注: ローカルの巨大な private_words_default 環境下で長い読みを convert すると
  -- anthy が SIGSEGV することがあるため、確実に動く短めの読みを使う。
  it("converts yomi into multi-segment best/candidates", function()
    local s = anthy.new_session()
    local segs = s:convert("きょうはいい")
    assert.is_true(#segs >= 2) -- 複数文節に分割される
    assert.are.equal(segs[1].candidates[1], segs[1].best) -- best は第1候補
    assert.is_true(#segs[1].candidates > 1) -- 候補が複数読める
    local joined = {}
    for _, seg in ipairs(segs) do
      joined[#joined + 1] = seg.best
    end
    assert.are_not.equal("きょうはいい", table.concat(joined)) -- かな→漢字変換された
    s:close()
  end)

  it("re-segments when a segment is resized", function()
    local s = anthy.new_session()
    local segs = s:convert("でんしゃにのる")
    assert.is_true(#segs >= 2) -- 複数文節に分割される
    local before = segs[1].best
    local resized = s:resize(1, 1) -- 第1文節を +1 伸長
    -- 文節境界が変わるので best も変わる(絶対値は辞書/学習依存のため相対変化で検証)
    assert.are_not.equal(before, resized[1].best)
    s:close()
  end)

  it("commits chosen candidates without error", function()
    local s = anthy.new_session()
    local segs = s:convert("わたしはがくせい")
    local choices = {}
    for i = 1, #segs do
      choices[i] = 1
    end
    assert.has_no.errors(function()
      s:commit(choices) -- 各文節の第1候補で確定(=学習)
    end)
    s:close()
  end)

  it("returns the original yomi of each segment and they concatenate back to the input", function()
    local s = anthy.new_session()
    local yomi = "きょうはいい"
    local segs = s:convert(yomi)
    assert.is_true(#segs >= 2) -- 複数文節への分割を前提
    local parts = {}
    for i = 1, #segs do
      parts[#parts + 1] = s:segment_yomi(i)
    end
    assert.are.equal(yomi, table.concat(parts))
    s:close()
  end)

  it("includes the reading length of each segment in read results", function()
    local s = anthy.new_session()
    local segs = s:convert("きょうはいい") -- 6 文字
    local total = 0
    for _, seg in ipairs(segs) do
      assert.is_true(seg.len >= 1)
      total = total + seg.len
    end
    assert.are.equal(6, total) -- 各文節の len の合計は読み全体の文字数と一致
    s:close()
  end)

  it("collapses to a single segment when the first segment is resized to full length", function()
    local s = anthy.new_session()
    local segs = s:convert("きょうはいい") -- 6 文字
    if #segs > 1 then
      segs = s:resize(1, 6 - segs[1].len) -- 第1文節を読み全体の長さまで伸長
    end
    assert.are.equal(1, #segs) -- 1文節に収束する
    assert.are.equal(6, segs[1].len)
    assert.is_true(#segs[1].candidates > 0)
    s:close()
  end)
end)

-- ユーザ辞書(私的辞書)に登録された語が候補に出るかをカウントする。
-- 注: 私的辞書はディスク永続で、vim.env.HOME を差し替えても anthy が getpwuid 由来の
-- 実 HOME を見るため隔離が効かないことがある。テストは絶対値ではなく相対変化で検証する。
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
    -- register_word は辞書登録 API(anthy_priv_dic_*)を持つ lib が要る。CI の libanthy-dev
    -- のように dic シンボルが本体・libanthydic どちらにもない環境では false を返す。
    -- その場合この仕様は検証不能なのでスキップする。
    if not anthy.register_word("ぶいめ", "vime") then
      return
    end
    assert.is_true(count_candidate("ぶいめ", "vime") >= 1) -- 登録後は候補に出る
  end)

  it("is idempotent when the same word is registered twice", function()
    if not anthy.register_word("ぶいめ", "vime") then
      return -- 辞書登録 API が無い環境ではスキップ(上記と同様)
    end
    local once = count_candidate("ぶいめ", "vime")
    assert.is_true(anthy.register_word("ぶいめ", "vime")) -- 2回目
    assert.are.equal(once, count_candidate("ぶいめ", "vime")) -- 件数が変わらない(重複登録されない)
  end)
end)
