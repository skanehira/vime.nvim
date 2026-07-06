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

-- confirm_selected は <CR> 確定(Google 日本語入力風)のため on_commit から呼ばれる。
-- cmp を fake で package.loaded に差し込み、cmp 本体なしで検証する。
describe("vime.integrations.nvim_cmp.confirm_selected", function()
  after_each(function()
    package.loaded.cmp = nil
  end)

  it("confirms the entry and returns true when a candidate is selected", function()
    local confirmed = false
    package.loaded.cmp = {
      visible = function()
        return true
      end,
      get_selected_entry = function()
        return { word = "今日" }
      end,
      confirm = function()
        confirmed = true
        return true
      end,
    }
    assert.is_true(nvim_cmp.confirm_selected())
    assert.is_true(confirmed)
  end)

  it("closes the menu and returns false when no candidate is selected", function()
    -- 未選択の <CR>: cmp に確定させず、メニューを閉じてから vime のかな確定に委ねる。
    -- (メニューを開いたまま vime が feedkeys 確定すると未確定が二重に入るため)
    local confirmed, closed = false, false
    package.loaded.cmp = {
      visible = function()
        return true
      end,
      get_selected_entry = function()
        return nil
      end,
      confirm = function()
        confirmed = true
        return true
      end,
      close = function()
        closed = true
      end,
    }
    assert.is_false(nvim_cmp.confirm_selected())
    assert.is_false(confirmed) -- cmp.confirm は呼ばれない
    assert.is_true(closed) -- メニューは閉じる
  end)

  it("returns false when the menu is not visible", function()
    package.loaded.cmp = {
      visible = function()
        return false
      end,
      get_selected_entry = function()
        return { word = "今日" }
      end,
      confirm = function()
        return true
      end,
    }
    assert.is_false(nvim_cmp.confirm_selected())
  end)

  it("returns false when nvim-cmp is not available", function()
    package.loaded.cmp = nil
    assert.is_false(nvim_cmp.confirm_selected())
  end)
end)
