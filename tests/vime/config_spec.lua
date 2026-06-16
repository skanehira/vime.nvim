local config = require("vime.config")

describe("vime.config.merge", function()
  it("returns defaults when user opts is nil", function()
    local c = config.merge(nil)
    assert.are.equal("<C-j>", c.keymaps.toggle)
    assert.are.equal("<Space>", c.keymaps.convert)
    assert.are.equal("<C-n>", c.keymaps.next_candidate)
    assert.are.equal("<F10>", c.keymaps.alphabet)
  end)

  it("overrides only the specified keys and keeps the rest", function()
    local c = config.merge({
      keymaps = { toggle = "<C-l>" },
    })
    assert.are.equal("<C-l>", c.keymaps.toggle)
    assert.are.equal("<Space>", c.keymaps.convert) -- 既定維持
    assert.are.equal("<C-p>", c.keymaps.prev_candidate) -- 既定維持(deep merge)
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
