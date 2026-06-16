-- 描画: 未確定下線・文節反転(extmark)と候補 popup(floating window)。
-- 文節ハイライトの範囲は byte offset で計算する(日本語1文字=3byte)。
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("vime")
local popup_win = nil

function M.namespace()
  return ns
end

-- ハイライト群を定義する。ユーザは :highlight で上書き可。
function M.setup()
  api.nvim_set_hl(0, "VimeUnconfirmed", { underline = true })
  api.nvim_set_hl(0, "VimeSegment", { reverse = true })
end

-- 未確定(composing)の読みに下線を引く。
function M.highlight_preedit(buf, row, col, byte_len)
  api.nvim_buf_set_extmark(buf, ns, row, col, {
    end_col = col + byte_len,
    hl_group = "VimeUnconfirmed",
  })
end

-- 変換中(converting)の文節列を描画する。注目文節は反転、他は下線。
-- list は各文節の表示テキスト、current は注目index(1-based)。
function M.highlight_segments(buf, row, col, list, current)
  local off = col
  for i, text in ipairs(list) do
    local hl = (i == current) and "VimeSegment" or "VimeUnconfirmed"
    api.nvim_buf_set_extmark(buf, ns, row, off, {
      end_col = off + #text, -- byte 長
      hl_group = hl,
    })
    off = off + #text
  end
end

-- このバッファの extmark をすべて消し、popup を閉じる。
function M.clear(buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  M.close_popup()
end

-- 候補一覧 popup を開く。items は表示行(例 "a: 今日は")。selected(1-based)を
-- 渡すとその行を選択中として PmenuSel でハイライトする。win id を返す。
function M.show_popup(items, selected)
  M.close_popup()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, items)
  if selected and items[selected] then
    api.nvim_buf_set_extmark(buf, ns, selected - 1, 0, { line_hl_group = "PmenuSel" })
  end
  local width = 1
  for _, s in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(s))
  end
  -- フローティングウィンドウ(AI 入力欄等)の中で開く場合に後ろへ隠れないよう、
  -- ホストの float より前面の zindex を与える。
  local cur = api.nvim_win_get_config(0)
  local host_z = (cur.relative ~= "" and cur.zindex) or 0
  popup_win = api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = #items,
    style = "minimal",
    focusable = false,
    zindex = math.max(250, host_z + 50),
  })
  vim.wo[popup_win].winhighlight = "Normal:Pmenu" -- 通常のメニュー配色で表示
  return popup_win
end

-- popup を閉じる。
function M.close_popup()
  if popup_win and api.nvim_win_is_valid(popup_win) then
    api.nvim_win_close(popup_win, true)
  end
  popup_win = nil
end

return M
