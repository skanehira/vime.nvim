local keymap = require("vime.keymap")
local config = require("vime.config")

local api = vim.api

local function find_map(buf, lhs)
  for _, m in ipairs(api.nvim_buf_get_keymap(buf, "i")) do
    if m.lhs == lhs then
      return m
    end
  end
  return nil
end

describe("vime.keymap", function()
  it("attaches insert-mode mappings that dispatch to handlers", function()
    local buf = api.nvim_create_buf(false, true)
    local calls = {}
    local function noop() end
    local handlers = {
      input = function(ch)
        calls.input = ch
      end,
      convert = function()
        calls.convert = true
      end,
      commit = noop,
      cancel = noop,
      backspace = noop,
      next_segment = noop,
      prev_segment = noop,
      expand = noop,
      shrink = noop,
      katakana = noop,
      alphabet = noop,
      next_candidate = noop,
      prev_candidate = noop,
    }
    keymap.attach(buf, config.merge(nil), handlers)

    local a = find_map(buf, "a")
    assert.is_not_nil(a)
    a.callback()
    assert.are.equal("a", calls.input)

    local space = find_map(buf, "<Space>") or find_map(buf, " ")
    assert.is_not_nil(space)
    space.callback()
    assert.is_true(calls.convert)
  end)

  it("maps symbol keys to input and C-h to backspace", function()
    local buf = api.nvim_create_buf(false, true)
    local calls = {}
    local function noop() end
    local handlers = {
      input = function(ch)
        calls.input = ch
      end,
      convert = noop,
      commit = noop,
      cancel = noop,
      backspace = function()
        calls.backspace = true
      end,
      next_segment = noop,
      prev_segment = noop,
      expand = noop,
      shrink = noop,
      katakana = noop,
      alphabet = noop,
      next_candidate = noop,
      prev_candidate = noop,
    }
    keymap.attach(buf, config.merge(nil), handlers)

    local hyphen = find_map(buf, "-")
    assert.is_not_nil(hyphen)
    hyphen.callback()
    assert.are.equal("-", calls.input)

    local ch = find_map(buf, "<C-H>") or find_map(buf, "<C-h>")
    assert.is_not_nil(ch)
    ch.callback()
    assert.is_true(calls.backspace)
  end)

  it("detaches the mappings", function()
    local buf = api.nvim_create_buf(false, true)
    local function noop() end
    local handlers = {
      input = noop,
      convert = noop,
      commit = noop,
      cancel = noop,
      backspace = noop,
      next_segment = noop,
      prev_segment = noop,
      expand = noop,
      shrink = noop,
      katakana = noop,
      alphabet = noop,
      next_candidate = noop,
      prev_candidate = noop,
    }
    keymap.attach(buf, config.merge(nil), handlers)
    keymap.detach(buf)
    assert.is_nil(find_map(buf, "a"))
  end)

  it("maps C-n/C-p to candidate navigation", function()
    local buf = api.nvim_create_buf(false, true)
    local calls = {}
    local function noop() end
    local handlers = {
      input = noop,
      convert = noop,
      commit = noop,
      cancel = noop,
      backspace = noop,
      next_segment = noop,
      prev_segment = noop,
      expand = noop,
      shrink = noop,
      katakana = noop,
      alphabet = noop,
      next_candidate = function()
        calls.next = true
      end,
      prev_candidate = function()
        calls.prev = true
      end,
    }
    keymap.attach(buf, config.merge(nil), handlers)

    local cn = find_map(buf, "<C-N>") or find_map(buf, "<C-n>")
    assert.is_not_nil(cn)
    cn.callback()
    assert.is_true(calls.next)

    local cp = find_map(buf, "<C-P>") or find_map(buf, "<C-p>")
    assert.is_not_nil(cp)
    cp.callback()
    assert.is_true(calls.prev)
  end)

  it("maps F10 to alphabet conversion", function()
    local buf = api.nvim_create_buf(false, true)
    local calls = {}
    local function noop() end
    local handlers = {
      input = noop,
      convert = noop,
      commit = noop,
      cancel = noop,
      backspace = noop,
      next_segment = noop,
      prev_segment = noop,
      expand = noop,
      shrink = noop,
      katakana = noop,
      next_candidate = noop,
      prev_candidate = noop,
      alphabet = function()
        calls.alphabet = true
      end,
    }
    keymap.attach(buf, config.merge(nil), handlers)

    local f10 = find_map(buf, "<F10>")
    assert.is_not_nil(f10)
    f10.callback()
    assert.is_true(calls.alphabet)
  end)
end)
