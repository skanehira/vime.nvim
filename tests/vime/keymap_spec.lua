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

  it("attach does not map converting-only keys (C-f/C-b/C-n/C-p/C-o/C-i/C-r)", function()
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
      register_word = noop,
    }
    keymap.attach(buf, config.merge(nil), handlers)

    for _, lhs in ipairs({ "<C-F>", "<C-B>", "<C-N>", "<C-P>", "<C-O>", "<C-I>", "<C-R>" }) do
      assert.is_nil(
        find_map(buf, lhs) or find_map(buf, lhs:lower()),
        lhs .. " should not be mapped by attach() (only by attach_converting())"
      )
    end
  end)

  it("attach_converting maps converting-only keys to handlers", function()
    local buf = api.nvim_create_buf(false, true)
    local calls = {}
    local handlers = {
      next_segment = function()
        calls.next_segment = true
      end,
      prev_segment = function()
        calls.prev_segment = true
      end,
      next_candidate = function()
        calls.next_candidate = true
      end,
      prev_candidate = function()
        calls.prev_candidate = true
      end,
      expand = function()
        calls.expand = true
      end,
      shrink = function()
        calls.shrink = true
      end,
      register_word = function()
        calls.register_word = true
      end,
    }
    keymap.attach_converting(buf, config.merge(nil), handlers)

    for _, case in ipairs({
      { upper = "<C-F>", lower = "<C-f>", call = "next_segment" },
      { upper = "<C-B>", lower = "<C-b>", call = "prev_segment" },
      { upper = "<C-N>", lower = "<C-n>", call = "next_candidate" },
      { upper = "<C-P>", lower = "<C-p>", call = "prev_candidate" },
      { upper = "<C-O>", lower = "<C-o>", call = "expand" },
      { upper = "<C-I>", lower = "<C-i>", call = "shrink" },
      { upper = "<C-R>", lower = "<C-r>", call = "register_word" },
    }) do
      local m = find_map(buf, case.upper) or find_map(buf, case.lower)
      assert.is_not_nil(m, case.lower .. " should be mapped")
      m.callback()
      assert.is_true(calls[case.call], case.call .. " handler should be called")
    end
  end)

  it("attach_converting is idempotent", function()
    local buf = api.nvim_create_buf(false, true)
    local handlers = {
      next_segment = function() end,
      prev_segment = function() end,
      next_candidate = function() end,
      prev_candidate = function() end,
      expand = function() end,
      shrink = function() end,
      register_word = function() end,
    }
    keymap.attach_converting(buf, config.merge(nil), handlers)
    keymap.attach_converting(buf, config.merge(nil), handlers) -- 2回目も例外を出さない

    keymap.detach_converting(buf)
    assert.is_nil(find_map(buf, "<C-F>") or find_map(buf, "<C-f>"))
  end)

  it("detach_converting removes only converting-only keys", function()
    local buf = api.nvim_create_buf(false, true)
    local function noop() end
    local common_handlers = {
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
      register_word = noop,
    }
    keymap.attach(buf, config.merge(nil), common_handlers)
    keymap.attach_converting(buf, config.merge(nil), {
      next_segment = noop,
      prev_segment = noop,
      next_candidate = noop,
      prev_candidate = noop,
      expand = noop,
      shrink = noop,
      register_word = noop,
    })
    keymap.detach_converting(buf)

    -- 共通キーは残る
    assert.is_not_nil(find_map(buf, "a"))
    assert.is_not_nil(find_map(buf, "<CR>"))
    assert.is_not_nil(find_map(buf, "<C-G>") or find_map(buf, "<C-g>"))
    -- converting 限定キーは消える
    assert.is_nil(find_map(buf, "<C-F>") or find_map(buf, "<C-f>"))
    assert.is_nil(find_map(buf, "<C-O>") or find_map(buf, "<C-o>"))
    assert.is_nil(find_map(buf, "<C-R>") or find_map(buf, "<C-r>"))
  end)

  it("detach_converting is idempotent when called without attach", function()
    local buf = api.nvim_create_buf(false, true)
    keymap.detach_converting(buf) -- attach 前でも例外を出さない
    keymap.detach_converting(buf) -- 二度呼んでも安全
  end)

  it("detach also removes converting-only keys", function()
    local buf = api.nvim_create_buf(false, true)
    local function noop() end
    local common_handlers = {
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
      register_word = noop,
    }
    keymap.attach(buf, config.merge(nil), common_handlers)
    keymap.attach_converting(buf, config.merge(nil), {
      next_segment = noop,
      prev_segment = noop,
      next_candidate = noop,
      prev_candidate = noop,
      expand = noop,
      shrink = noop,
      register_word = noop,
    })
    keymap.detach(buf)

    assert.is_nil(find_map(buf, "a"))
    assert.is_nil(find_map(buf, "<C-F>") or find_map(buf, "<C-f>"))
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
