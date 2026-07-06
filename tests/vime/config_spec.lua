local config = require("vime.config")

describe("vime.config.merge", function()
  it("returns defaults when user opts is nil", function()
    local c = config.merge(nil)
    assert.are.equal("<C-j>", c.keymaps.toggle)
    assert.are.equal("<Space>", c.keymaps.convert)
    assert.are.equal("<C-n>", c.keymaps.next_candidate)
    assert.are.equal("<F10>", c.keymaps.alphabet)
    assert.are.equal(";", c.keymaps.ascii_toggle)
    assert.are.equal("<C-r>", c.keymaps.register_word) -- 辞書登録キーの既定
  end)

  it("overrides only the specified keys and keeps the rest", function()
    local c = config.merge({
      keymaps = { toggle = "<C-l>" },
    })
    assert.are.equal("<C-l>", c.keymaps.toggle)
    assert.are.equal("<Space>", c.keymaps.convert) -- 既定維持
    assert.are.equal("<C-p>", c.keymaps.prev_candidate) -- 既定維持(deep merge)
  end)

  it("defaults mode_notify to enabled with built-in labels", function()
    local c = config.merge(nil)
    assert.is_true(c.mode_notify.enabled)
    assert.are.equal(1000, c.mode_notify.duration)
    assert.are.equal("直", c.mode_notify.labels.direct)
    assert.are.equal("あ", c.mode_notify.labels.hiragana)
    assert.are.equal("A", c.mode_notify.labels.ascii)
    assert.is_nil(c.mode_notify.labels.converting) -- converting は外向きの mode に出さない
    -- highlight は既定 nil(ui 側の緑デフォルトを使う)
    assert.is_nil(c.mode_notify.highlight)
  end)

  it("passes through a custom mode_notify highlight table", function()
    local c = config.merge({
      mode_notify = { highlight = { bg = "#ff0000", fg = "#000000" } },
    })
    assert.are.same({ bg = "#ff0000", fg = "#000000" }, c.mode_notify.highlight)
  end)

  it("merges only the overridden mode_notify labels", function()
    local c = config.merge({
      mode_notify = { enabled = false, labels = { hiragana = "HIRA" } },
    })
    assert.is_false(c.mode_notify.enabled)
    assert.are.equal("HIRA", c.mode_notify.labels.hiragana)
    assert.are.equal("直", c.mode_notify.labels.direct) -- 既定維持
    assert.are.equal(1000, c.mode_notify.duration) -- 既定維持
  end)

  it("defaults integrations to all disabled", function()
    -- 外部プラグイン連携は opt-in。既定は無効。
    local c = config.merge(nil)
    assert.is_false(c.integrations.nvim_cmp)
  end)

  it("turns on nvim_cmp integration when requested", function()
    local c = config.merge({ integrations = { nvim_cmp = true } })
    assert.is_true(c.integrations.nvim_cmp)
  end)

  it("defaults romaji.table to nil (use built-in wapuro table)", function()
    local c = config.merge(nil)
    assert.is_nil(c.romaji.table)
  end)

  it("replaces (not merges) romaji.table when provided", function()
    -- romaji.table は完全置換ポリシー。既定は nil なのでユーザ値がそのまま入る。
    local user_table = { a = "ア", ka = "カ" }
    local c = config.merge({ romaji = { table = user_table } })
    assert.are.equal(user_table, c.romaji.table)
  end)
end)

describe("vime.config.find_anthy_lib", function()
  it("returns the first existing path from candidates", function()
    local existing = vim.fn.tempname()
    vim.fn.writefile({}, existing)
    assert.are.equal(existing, config.find_anthy_lib({ "/nonexistent.dylib", existing }))
    vim.fn.delete(existing)
  end)

  it("returns nil when no candidate exists", function()
    assert.is_nil(config.find_anthy_lib({ "/nope1.dylib", "/nope2.dylib" }))
  end)

  it("prefers VIME_ANTHY_LIB over the default candidates", function()
    local existing = vim.fn.tempname()
    vim.fn.writefile({}, existing)
    local saved = vim.env.VIME_ANTHY_LIB
    vim.env.VIME_ANTHY_LIB = existing
    assert.are.equal(existing, config.find_anthy_lib()) -- 既定探索でも環境変数が最優先
    vim.env.VIME_ANTHY_LIB = saved
    vim.fn.delete(existing)
  end)

  it("auto-discovers an installed libanthy on this machine", function()
    local found = config.find_anthy_lib()
    assert.is_not_nil(found)
    assert.are.equal(1, vim.fn.filereadable(found))
  end)
end)

describe("vime.config.find_anthy_dic_lib", function()
  it("prefers VIME_ANTHY_DIC_LIB when set and readable", function()
    local existing = vim.fn.tempname()
    vim.fn.writefile({}, existing)
    local saved = vim.env.VIME_ANTHY_DIC_LIB
    vim.env.VIME_ANTHY_DIC_LIB = existing
    assert.are.equal(existing, config.find_anthy_dic_lib("/whatever/libanthy.dylib"))
    vim.env.VIME_ANTHY_DIC_LIB = saved
    vim.fn.delete(existing)
  end)

  it("derives the dic library next to the main library", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local main = dir .. "/libanthy.dylib"
    local dic = dir .. "/libanthydic.dylib"
    vim.fn.writefile({}, main)
    vim.fn.writefile({}, dic)
    assert.are.equal(dic, config.find_anthy_dic_lib(main))
    vim.fn.delete(dir, "rf")
  end)

  it("returns nil when neither env nor a derived dic library exists", function()
    local saved = vim.env.VIME_ANTHY_DIC_LIB
    vim.env.VIME_ANTHY_DIC_LIB = nil
    assert.is_nil(config.find_anthy_dic_lib("/nonexistent/libanthy.dylib"))
    vim.env.VIME_ANTHY_DIC_LIB = saved
  end)
end)
