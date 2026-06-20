local mode = require("vime.mode")

describe("vime.mode.compute", function()
  it("returns direct when not enabled", function()
    assert.are.same(
      { name = "direct", enabled = false, state = nil, ascii = false, latin = false },
      mode.compute({ enabled = false })
    )
  end)

  it("returns hiragana when composing without ascii/latin", function()
    assert.are.same(
      { name = "hiragana", enabled = true, state = "composing", ascii = false, latin = false },
      mode.compute({ enabled = true, state = "composing", ascii = false, latin = false })
    )
  end)

  it("returns ascii when composing with ascii flag", function()
    assert.are.same(
      { name = "ascii", enabled = true, state = "composing", ascii = true, latin = false },
      mode.compute({ enabled = true, state = "composing", ascii = true, latin = false })
    )
  end)

  it("returns hiragana with latin=true when in a latin run", function()
    assert.are.same(
      { name = "hiragana", enabled = true, state = "composing", ascii = false, latin = true },
      mode.compute({ enabled = true, state = "composing", ascii = false, latin = true })
    )
  end)

  it("keeps name=hiragana during conversion so mode notify does not flash", function()
    -- converting は外向きの name に出さない(候補 popup 側でシグナルされる)。
    -- 詳細を見たいユーザのため state フィールドだけは "converting" を保持する。
    assert.are.same(
      { name = "hiragana", enabled = true, state = "converting", ascii = false, latin = false },
      mode.compute({ enabled = true, state = "converting", ascii = true, latin = true })
    )
  end)
end)
