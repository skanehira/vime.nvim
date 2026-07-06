local source_mod = require("vime.integrations.nvim_cmp_source")

-- cmp source 実装は nvim-cmp 本体に依存せず、provider(active/context/commit)を DI で受ける。
-- テストは fake provider を注入し、cmp を起動せず純粋ロジックとして検証する。
local function fake_provider(overrides)
  local base = {
    active = function()
      return true
    end,
    context = function()
      return {
        row = 0,
        start_col = 3,
        len = 9, -- "あいう" 相当の byte 長(3文字×3byte)
        yomi = "あいう",
        items = {
          { text = "愛", yomi = "あいう", single = false },
          { text = "藍", yomi = "あいう", single = true },
        },
      }
    end,
    commit = function() end,
  }
  return vim.tbl_extend("force", base, overrides or {})
end

describe("vime.integrations.nvim_cmp_source", function()
  it("is_available follows the provider active state", function()
    assert.is_true(source_mod.new(fake_provider()).is_available())
    assert.is_false(source_mod.new(fake_provider({
      active = function()
        return false
      end,
    })).is_available())
  end)

  it("declares utf-8 position encoding so byte offsets are used verbatim", function()
    assert.are.equal("utf-8", source_mod.new(fake_provider()).get_position_encoding_kind())
  end)

  it("complete returns items whose textEdit replaces the whole preedit region", function()
    local src = source_mod.new(fake_provider())
    local captured
    src.complete(src, {}, function(res)
      captured = res
    end)
    assert.is_true(captured.isIncomplete) -- 読みが伸びるたび全入れ替え
    assert.are.equal(2, #captured.items)

    local first = captured.items[1]
    assert.are.equal("愛", first.label)
    assert.are.equal("あいう", first.filterText) -- 読みでフィルタ(前方一致で消えない)
    assert.are.equal("愛", first.textEdit.newText)
    assert.are.same({ line = 0, character = 3 }, first.textEdit.range.start)
    assert.are.same({ line = 0, character = 12 }, first.textEdit.range["end"]) -- start_col + len
    assert.is_true(captured.items[1].sortText < captured.items[2].sortText) -- 入力順を保存
  end)

  it("complete returns an empty item list when no context is available", function()
    local src = source_mod.new(fake_provider({
      context = function()
        return nil
      end,
    }))
    local called = false
    src.complete(src, {}, function(res)
      called = true
      assert.are.same({}, res.items)
    end)
    assert.is_true(called) -- callback は必ず呼ぶ
  end)

  it("execute commits the item through the provider and always calls back", function()
    local committed
    local src = source_mod.new(fake_provider({
      commit = function(data)
        committed = data
      end,
    }))
    local item = { data = { text = "藍", yomi = "あいう", single = true } }
    local called = false
    src.execute(src, item, function()
      called = true
    end)
    assert.are.same(item.data, committed) -- data を provider.commit へ渡す
    assert.is_true(called)
  end)
end)
