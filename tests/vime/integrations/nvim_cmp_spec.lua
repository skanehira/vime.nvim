local nvim_cmp = require("vime.integrations.nvim_cmp")

-- compute_enabled は cmp.setup の enabled 関数として渡る純粋ロジック。
-- 「vime ON 中は補完を抑止する」「OFF 中は cmp デフォルト判定に従う」だけの 2 条件。
describe("vime.integrations.nvim_cmp.compute_enabled", function()
  it("returns false when vime is active regardless of default_enabled", function()
    -- vime モード ON 中はデフォルト判定が true でも補完を出さない。
    assert.is_false(nvim_cmp.compute_enabled(true, function()
      return true
    end))
  end)

  it("delegates to default_enabled when vime is inactive", function()
    -- vime OFF 中は cmp デフォルト判定(prompt buftype/マクロ等)の結果をそのまま返す。
    assert.is_true(nvim_cmp.compute_enabled(false, function()
      return true
    end))
    assert.is_false(nvim_cmp.compute_enabled(false, function()
      return false
    end))
  end)
end)
