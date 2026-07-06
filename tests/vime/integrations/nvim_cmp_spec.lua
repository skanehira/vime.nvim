local nvim_cmp = require("vime.integrations.nvim_cmp")

-- compute_enabled は cmp.setup の enabled 関数として渡る純粋ロジック。
-- 第3引数 source_completing=true(vime source が候補提供中)は補完を出す(true)。
-- それ以外は「vime ON 中は抑止」「OFF 中は cmp デフォルト判定に従う」。
describe("vime.integrations.nvim_cmp.compute_enabled", function()
  local yes = function()
    return true
  end
  local no = function()
    return false
  end

  it("returns true while the vime source is completing even when vime is active", function()
    -- source モードで候補提供中は cmp を有効にする(CursorMovedI でメニューが閉じないように)。
    assert.is_true(nvim_cmp.compute_enabled(true, no, true))
  end)

  it("returns false when vime is active and not completing", function()
    -- 変換中など候補提供していないときは従来どおり補完を抑止する。
    assert.is_false(nvim_cmp.compute_enabled(true, yes, false))
  end)

  it("delegates to default_enabled when vime is inactive", function()
    -- vime OFF 中は cmp デフォルト判定(prompt buftype/マクロ等)の結果をそのまま返す。
    assert.is_true(nvim_cmp.compute_enabled(false, yes, false))
    assert.is_false(nvim_cmp.compute_enabled(false, no, false))
  end)
end)
