-- terminal バッファ(terminal-job モード)用の backend。
-- 未確定はバッファへ書かず、カーソル直上の preedit float(ui.show_preedit_float)にのみ表示する。
-- 確定テキストは send(既定は chansend)で PTY へ送る。completion/register_word/dot_repeat は
-- 対応しない(vim.ui.input の入れ子・Vim の insert モード前提の dot repeat が terminal-job
-- モードには存在しないため)。
local ui = require("vime.ui")

---@class vime.TerminalBackend
---@field kind "terminal"
---@field buf integer
---@field keymap_mode "t"
---@field send fun(buf: integer, text: string)
local M = {}
M.kind = "terminal"
M.keymap_mode = "t"

local FEATURES = { completion = false, register_word = false, dot_repeat = false }

function M.supports(feature)
  return FEATURES[feature] == true
end

-- チャネルへ text をそのまま送る既定の送出関数。
local function default_send(buf, text)
  vim.fn.chansend(vim.bo[buf].channel, text)
end

-- send は DI: テストでは spy に差し替える。省略時は既定のチャネル送出を使う。
function M.new(buf, send)
  local self = setmetatable({}, { __index = M })
  self.buf = buf
  self.send = send or default_send
  return self
end

-- preedit はバッファ上に anchor を持たないので no-op。
function M:sync_anchor() end

-- カーソル直上の preedit float へ描画する(実際のバッファへは書かない)。
function M:render(view)
  ui.show_preedit_float(view, self:popup_pos())
end

-- 下線/文節反転は無い(float ごと閉じる)ので popup だけ掃除する。
function M:clear()
  ui.close_preedit_float()
  ui.close_popup()
end

-- 確定テキストを send() で PTY へ送る。空文字は何もしない。
function M:finalize(text)
  if text ~= "" then
    self.send(self.buf, text)
  end
end

-- 未確定が無いときの通常のスペース/改行を PTY へ送る(改行は CR に変換)。
function M:insert_literal(text)
  self.send(self.buf, text == "\n" and "\r" or text)
end

-- BS/C-w/C-u/Esc 等のキーをそのまま Vim の terminal-job モードの既定動作(PTY へ転送)へ流す。
function M:passthrough(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
end

function M:popup_pos()
  return { relative = "cursor", row = 1, col = 0 }
end

-- 実バッファへカーソルを置く概念が無いので no-op。
function M:place_cursor() end

function M:detach()
  ui.close_preedit_float()
end

return M
