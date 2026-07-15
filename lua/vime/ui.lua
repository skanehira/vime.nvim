-- 描画: 未確定下線・文節反転(extmark)と候補 popup(floating window)。
-- 文節ハイライトの範囲は byte offset で計算する(日本語1文字=3byte)。
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("vime")
local popup_win = nil
local mode_notify_win = nil
local preedit_float_win = nil

-- float の位置設定を組み立てる。pos(relative/row/col/anchor 等)が与えられればそれを使い、
-- 無ければ従来どおりカーソル直下(相対 row=1)を使う。
local function resolve_pos(pos)
  return pos or { relative = "cursor", row = 1, col = 0 }
end

function M.namespace()
  return ns
end

-- ハイライト群を定義する。ユーザは :highlight で上書き可。
-- opts.mode_notify_highlight に nvim_set_hl 互換テーブルを渡すと VimeModeNotify を明示上書き。
-- 未指定なら IME っぽい緑デフォルト(default=true なので :highlight ... default link でも上書き可)。
function M.setup(opts)
  api.nvim_set_hl(0, "VimeUnconfirmed", { underline = true })
  api.nvim_set_hl(0, "VimeSegment", { reverse = true })
  local custom = opts and opts.mode_notify_highlight
  if custom then
    api.nvim_set_hl(0, "VimeModeNotify", custom)
  else
    api.nvim_set_hl(0, "VimeModeNotify", {
      bg = "#2e7d32",
      fg = "#ffffff",
      bold = true,
      default = true,
    })
  end
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
-- 渡すとその行を選択中として PmenuSel でハイライトする。pos を渡すと配置(relative/row/col
-- 等)を上書きする(省略時は従来どおりカーソル直下)。win id を返す。
function M.show_popup(items, selected, pos)
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
  popup_win = api.nvim_open_win(
    buf,
    false,
    vim.tbl_extend("force", resolve_pos(pos), {
      width = width,
      height = #items,
      style = "minimal",
      focusable = false,
      zindex = math.max(250, host_z + 50),
    })
  )
  vim.wo[popup_win].winhighlight = "Normal:Pmenu" -- 通常のメニュー配色で表示
  -- floating window の open/close は Lua マッピングの callback から呼ぶと自動では
  -- 再描画されないことがある(実機で確認済み。特に cmdline/terminal-job モード中)。
  vim.cmd("redraw")
  return popup_win
end

-- popup を閉じる。
function M.close_popup()
  if popup_win and api.nvim_win_is_valid(popup_win) then
    api.nvim_win_close(popup_win, true)
    vim.cmd("redraw")
  end
  popup_win = nil
end

-- モード切替時に短時間だけ表示する小さな floating window を開く。
-- label はカーソル下に1行で出し、duration_ms 後に自動で閉じる。連続呼出時は前回を即座に閉じる。
-- pos を渡すと配置(relative/row/col 等)を上書きする(省略時は従来どおりカーソル直下)。
-- win id を返す。
function M.show_mode_notify(label, duration_ms, pos)
  M.close_mode_notify()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { label })
  local width = math.max(1, vim.fn.strdisplaywidth(label))
  -- フローティングウィンドウ(AI 入力欄等)の中で開く場合に後ろへ隠れないよう、
  -- ホストの float より前面の zindex を与える。候補 popup よりは 10 低くしてあるので
  -- (理論的に)共存する場合は候補が前面に来る。
  local cur = api.nvim_win_get_config(0)
  local host_z = (cur.relative ~= "" and cur.zindex) or 0
  mode_notify_win = api.nvim_open_win(
    buf,
    false,
    vim.tbl_extend("force", resolve_pos(pos), {
      width = width,
      height = 1,
      style = "minimal",
      focusable = false,
      noautocmd = true,
      zindex = math.max(200, host_z + 40),
    })
  )
  vim.wo[mode_notify_win].winhighlight = "Normal:VimeModeNotify"
  vim.cmd("redraw") -- floating window の open は callback から呼ぶと自動再描画されないことがある
  local opened = mode_notify_win
  vim.defer_fn(function()
    -- defer_fn 発火時に同じ window がまだ生きていれば閉じる。
    -- 連続切替で別 win に置き換わっていれば古い defer は何もしない。
    if mode_notify_win == opened then
      M.close_mode_notify()
    end
  end, duration_ms)
  return mode_notify_win
end

-- モード通知 popup を閉じる。
function M.close_mode_notify()
  if mode_notify_win and api.nvim_win_is_valid(mode_notify_win) then
    api.nvim_win_close(mode_notify_win, true)
    vim.cmd("redraw")
  end
  mode_notify_win = nil
end

-- session:preedit_segments() の view からプリエディット表示用テキストと
-- ハイライト適用処理を組み立てる。init.lua の render() が実バッファへ描くのと同じ規則:
-- kana/latin は下線(highlight_preedit)、confirmed はハイライトなし、
-- segments(変換中)は文節反転(highlight_segments)。buf/row は描画先。
local function draw_preedit_view(buf, row, view)
  local parts = {}
  for _, seg in ipairs(view) do
    parts[#parts + 1] = (seg.kind == "segments") and table.concat(seg.list) or seg.text
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, { table.concat(parts) })
  local off = 0
  for _, seg in ipairs(view) do
    if seg.kind == "kana" or seg.kind == "latin" then
      if #seg.text > 0 then
        M.highlight_preedit(buf, row, off, #seg.text)
      end
      off = off + #seg.text
    elseif seg.kind == "confirmed" then
      off = off + #seg.text -- 確定済みはハイライトなし
    elseif seg.kind == "segments" then
      M.highlight_segments(buf, row, off, seg.list, seg.current)
      for _, t in ipairs(seg.list) do
        off = off + #t
      end
    end
  end
end

-- terminal backend が使う inline preedit。terminal buffer は直接編集できないため、
-- カーソル位置(row/col は 0-based byte)に inline virtual text の extmark を 1 つ置いて
-- 未確定を表示する(通常バッファと同じ下線・文節反転の見た目。virt_text は PTY へ
-- 送られない)。view が空になったら extmark を消す。呼ぶたびに前回の extmark を消して
-- 置き直す。
function M.show_inline_preedit(buf, row, col, view)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local chunks = {}
  for _, seg in ipairs(view) do
    if seg.kind == "segments" then
      for i, text in ipairs(seg.list) do
        chunks[#chunks + 1] = { text, (i == seg.current) and "VimeSegment" or "VimeUnconfirmed" }
      end
    elseif seg.kind == "confirmed" then
      if #seg.text > 0 then
        chunks[#chunks + 1] = { seg.text }
      end
    else -- kana / latin
      if #seg.text > 0 then
        chunks[#chunks + 1] = { seg.text, "VimeUnconfirmed" }
      end
    end
  end
  if #chunks > 0 then
    -- strict=false: PTY 出力とタイミングが競合して col が行末を超えても
    -- エラーにせずクランプする("Vim を壊さない"方針)。
    api.nvim_buf_set_extmark(buf, ns, row, col, {
      virt_text = chunks,
      virt_text_pos = "inline",
      strict = false,
    })
  end
  vim.cmd("redraw") -- terminal-job モードのマッピング callback からは自動再描画されないことがある
end

-- cmdline backend が使う preedit float。session:preedit_segments() の
-- view をそのまま渡すと、下線・文節反転込みで 1 行の floating window に描画する。
-- pos で配置(relative/row/col 等)を指定する(cmdline 行の直上を想定)。
-- 呼ぶたびに前回の float を閉じて開き直す。win id を返す。
function M.show_preedit_float(view, pos)
  M.close_preedit_float()
  local buf = api.nvim_create_buf(false, true)
  draw_preedit_view(buf, 0, view)
  preedit_float_win = api.nvim_open_win(
    buf,
    false,
    vim.tbl_extend("force", resolve_pos(pos), {
      width = math.max(1, vim.fn.strdisplaywidth(api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")),
      height = 1,
      style = "minimal",
      focusable = false,
      noautocmd = true,
      zindex = 220,
    })
  )
  vim.cmd("redraw") -- floating window の open は callback から呼ぶと自動再描画されないことがある
  return preedit_float_win
end

-- preedit float を閉じる。未表示なら no-op。
function M.close_preedit_float()
  if preedit_float_win and api.nvim_win_is_valid(preedit_float_win) then
    api.nvim_win_close(preedit_float_win, true)
    vim.cmd("redraw")
  end
  preedit_float_win = nil
end

return M
