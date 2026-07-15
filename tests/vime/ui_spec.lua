local ui = require("vime.ui")

local api = vim.api

local function new_buf(line)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { line or "" })
  return buf
end

local function extmarks(buf)
  return api.nvim_buf_get_extmarks(buf, ui.namespace(), 0, -1, { details = true })
end

describe("vime.ui highlight", function()
  before_each(function()
    ui.setup()
  end)

  it("underlines the preedit over its byte range", function()
    local kana = "きょうは" -- 12 byte
    local buf = new_buf(kana)
    ui.highlight_preedit(buf, 0, 0, #kana)
    local m = extmarks(buf)
    assert.are.equal(1, #m)
    assert.are.equal("VimeUnconfirmed", m[1][4].hl_group)
    assert.are.equal(#kana, m[1][4].end_col)
  end)

  it("reverses the current segment at the correct byte offset (multibyte)", function()
    -- 今日は|いい : 注目=2(いい) は byte 9..15
    local list = { "今日は", "いい" }
    local buf = new_buf(table.concat(list))
    ui.highlight_segments(buf, 0, 0, list, 2)
    local marks = extmarks(buf)
    -- 注目セグメントの reverse マークを探す
    local seg
    for _, m in ipairs(marks) do
      if m[4].hl_group == "VimeSegment" then
        seg = m
      end
    end
    assert.is_not_nil(seg)
    assert.are.equal(9, seg[3]) -- start_col(byte) = #"今日は" = 9
    assert.are.equal(9 + #"いい", seg[4].end_col) -- 9 + 6 = 15
  end)

  it("clears extmarks", function()
    local buf = new_buf("きょうは")
    ui.highlight_preedit(buf, 0, 0, 12)
    ui.clear(buf)
    assert.are.equal(0, #extmarks(buf))
  end)
end)

describe("vime.ui popup", function()
  before_each(function()
    ui.setup()
  end)

  it("opens and closes a candidate popup", function()
    local win = ui.show_popup({ "a: 今日は", "s: きょうは" })
    assert.is_true(api.nvim_win_is_valid(win))
    ui.close_popup()
    assert.is_false(api.nvim_win_is_valid(win))
  end)

  it("highlights the selected candidate line", function()
    local win = ui.show_popup({ "a: 今日は", "s: きょうは", "d: 京" }, 2)
    local buf = api.nvim_win_get_buf(win)
    local marks = api.nvim_buf_get_extmarks(buf, ui.namespace(), 0, -1, { details = true })
    local sel
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == "PmenuSel" then
        sel = m
      end
    end
    assert.is_not_nil(sel)
    assert.are.equal(1, sel[2]) -- 選択中(2番目)= 0-based row 1 をハイライト
    ui.close_popup()
  end)

  it("opens the popup with a high zindex so it stays above other floats", function()
    local win = ui.show_popup({ "今日", "京都" }, 1)
    local z = api.nvim_win_get_config(win).zindex
    assert.is_truthy(z and z >= 200)
    ui.close_popup()
  end)
end)

describe("vime.ui mode notify", function()
  before_each(function()
    ui.setup()
    ui.close_mode_notify() -- 前テストの残骸を掃除
  end)

  it("opens a floating window for the given label", function()
    local win = ui.show_mode_notify("あ", 1000)
    assert.is_true(api.nvim_win_is_valid(win))
    local buf = api.nvim_win_get_buf(win)
    assert.are.equal("あ", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    ui.close_mode_notify()
  end)

  it("closes automatically after the configured duration", function()
    local win = ui.show_mode_notify("A", 30)
    assert.is_true(api.nvim_win_is_valid(win))
    vim.wait(200, function()
      return not api.nvim_win_is_valid(win)
    end)
    assert.is_false(api.nvim_win_is_valid(win))
  end)

  it("replaces the previous popup when called again", function()
    local first = ui.show_mode_notify("あ", 1000)
    local second = ui.show_mode_notify("A", 1000)
    assert.is_false(api.nvim_win_is_valid(first))
    assert.is_true(api.nvim_win_is_valid(second))
    ui.close_mode_notify()
  end)

  it("opens above a host floating window so it is not hidden", function()
    -- フローティングウィンドウ(AI 入力欄など)の中で入力するシナリオ。
    -- mode notify がホストの後ろに隠れないこと。
    local host_buf = api.nvim_create_buf(false, true)
    local host = api.nvim_open_win(host_buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 30,
      height = 6,
    })
    api.nvim_win_set_cursor(host, { 1, 0 })
    local win = ui.show_mode_notify("あ", 1000)
    local host_z = api.nvim_win_get_config(host).zindex
    local notify_z = api.nvim_win_get_config(win).zindex
    assert.is_true(notify_z > host_z)
    ui.close_mode_notify()
    api.nvim_win_close(host, true)
  end)

  it("applies a default green highlight to VimeModeNotify", function()
    ui.setup()
    local hl = api.nvim_get_hl(0, { name = "VimeModeNotify", link = false })
    assert.are.equal(0x2e7d32, hl.bg)
    assert.are.equal(0xffffff, hl.fg)
    assert.is_true(hl.bold == true)
  end)

  it("applies a custom highlight when given in setup opts", function()
    ui.setup({ mode_notify_highlight = { bg = "#123456", fg = "#abcdef" } })
    local hl = api.nvim_get_hl(0, { name = "VimeModeNotify", link = false })
    assert.are.equal(0x123456, hl.bg)
    assert.are.equal(0xabcdef, hl.fg)
    -- ユーザ指定の上書きはデフォルトの bold を継がない
    assert.is_not_true(hl.bold)
  end)

  it("close_mode_notify closes the popup explicitly", function()
    local win = ui.show_mode_notify("あ", 1000)
    ui.close_mode_notify()
    assert.is_false(api.nvim_win_is_valid(win))
  end)
end)

describe("vime.ui popup pos override", function()
  before_each(function()
    ui.setup()
  end)

  it("show_popup defaults to a cursor-relative window when pos is omitted", function()
    local win = ui.show_popup({ "今日" })
    -- relative="cursor" は open 時点のカーソル位置を基準にした win-relative へ
    -- 正規化されて返る(Neovim の floating window API の仕様)。
    local cfg = api.nvim_win_get_config(win)
    assert.are.equal("win", cfg.relative)
    assert.are.equal(api.nvim_get_current_win(), cfg.win)
    ui.close_popup()
  end)

  it("show_popup opens at the given editor-relative pos override", function()
    local win = ui.show_popup({ "今日" }, nil, { relative = "editor", row = 3, col = 5 })
    local cfg = api.nvim_win_get_config(win)
    assert.are.equal("editor", cfg.relative)
    assert.are.equal(3, cfg.row)
    assert.are.equal(5, cfg.col)
    ui.close_popup()
  end)

  it("show_mode_notify opens at the given editor-relative pos override", function()
    local win = ui.show_mode_notify("あ", 1000, { relative = "editor", row = 2, col = 1 })
    local cfg = api.nvim_win_get_config(win)
    assert.are.equal("editor", cfg.relative)
    assert.are.equal(2, cfg.row)
    assert.are.equal(1, cfg.col)
    ui.close_mode_notify()
  end)
end)

describe("vime.ui preedit float", function()
  before_each(function()
    ui.setup()
    ui.close_preedit_float() -- 前テストの残骸を掃除
  end)

  it("draws confirmed text without underline and the trailing kana with underline", function()
    local view = {
      { kind = "confirmed", text = "今日" }, -- 6 byte、ハイライトなし
      { kind = "kana", text = "は" }, -- 3 byte、下線
    }
    local win = ui.show_preedit_float(view, { relative = "editor", row = 0, col = 0 })
    assert.is_true(api.nvim_win_is_valid(win))
    local buf = api.nvim_win_get_buf(win)
    assert.are.equal("今日は", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    local marks = api.nvim_buf_get_extmarks(buf, ui.namespace(), 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.equal("VimeUnconfirmed", marks[1][4].hl_group)
    assert.are.equal(6, marks[1][3]) -- start_col(byte) = #"今日"
    assert.are.equal(9, marks[1][4].end_col) -- end_col = 6 + #"は"
    ui.close_preedit_float()
  end)

  it("draws converting segments with the current one reversed", function()
    local view = {
      { kind = "segments", list = { "今日", "は" }, current = 2 },
    }
    local win = ui.show_preedit_float(view, { relative = "editor", row = 0, col = 0 })
    local buf = api.nvim_win_get_buf(win)
    assert.are.equal("今日は", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    local marks = api.nvim_buf_get_extmarks(buf, ui.namespace(), 0, -1, { details = true })
    local seg
    for _, m in ipairs(marks) do
      if m[4].hl_group == "VimeSegment" then
        seg = m
      end
    end
    assert.is_not_nil(seg)
    assert.are.equal(6, seg[3]) -- start_col(byte) = #"今日"
    assert.are.equal(9, seg[4].end_col)
    ui.close_preedit_float()
  end)

  it("replaces the previous float when called again", function()
    local first = ui.show_preedit_float({ { kind = "kana", text = "あ" } }, { relative = "editor", row = 0, col = 0 })
    local second = ui.show_preedit_float({ { kind = "kana", text = "い" } }, { relative = "editor", row = 0, col = 0 })
    assert.is_false(api.nvim_win_is_valid(first))
    assert.is_true(api.nvim_win_is_valid(second))
    ui.close_preedit_float()
  end)

  it("close_preedit_float closes the window and is a no-op when nothing is open", function()
    local win = ui.show_preedit_float({ { kind = "kana", text = "あ" } }, { relative = "editor", row = 0, col = 0 })
    ui.close_preedit_float()
    assert.is_false(api.nvim_win_is_valid(win))
    ui.close_preedit_float() -- 二度目は no-op(エラーにならない)
  end)
end)
