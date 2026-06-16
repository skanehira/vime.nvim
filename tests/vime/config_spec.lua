local config = require("vime.config")

describe("vime.config.merge", function()
  it("returns defaults when user opts is nil", function()
    local c = config.merge(nil)
    assert.are.equal("<C-j>", c.keymaps.toggle)
    assert.are.equal("<Space>", c.keymaps.convert)
    assert.are.equal(3, c.popup.threshold)
  end)

  it("overrides only the specified keys and keeps the rest", function()
    local c = config.merge({
      keymaps = { toggle = "<C-l>" },
      popup = { threshold = 5 },
    })
    assert.are.equal("<C-l>", c.keymaps.toggle)
    assert.are.equal("<Space>", c.keymaps.convert) -- 既定維持
    assert.are.equal(5, c.popup.threshold)
    assert.are.equal("asdfghjkl", c.popup.labels) -- 既定維持
  end)
end)

describe("vime.config.find_anthy_lib", function()
  local LIB = "/nix/store/m2z37mlz9rsh2azv9pny1860rpycic54-anthy-9100h/lib/libanthy.dylib"

  it("returns the first existing path from candidates", function()
    assert.are.equal(LIB, config.find_anthy_lib({ "/nonexistent.dylib", LIB }))
  end)

  it("returns nil when no candidate exists", function()
    assert.is_nil(config.find_anthy_lib({ "/nope1.dylib", "/nope2.dylib" }))
  end)
end)
