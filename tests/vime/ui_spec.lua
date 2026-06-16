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
      if m[4].hl_group == "VimeSegment" then seg = m end
    end
    assert.is_not_nil(seg)
    assert.are.equal(9, seg[3])           -- start_col(byte) = #"今日は" = 9
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
      if m[4].line_hl_group == "PmenuSel" then sel = m end
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
