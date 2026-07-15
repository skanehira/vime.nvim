-- コマンドライン(: / / / ?)用の backend。
-- 未確定領域は getcmdline() の byte 範囲(anchor/len)として追跡し、getcmdline/setcmdline/
-- getcmdpos で読み書きする(cmdline は extmark が使えないためインライン表示はプレーン
-- 文字列のまま)。未確定が空でない間は常に、cmdline 行の直上に開く共有 preedit float
-- (ui.show_preedit_float)へ同じ内容を下線・文節反転付きで併記する(通常バッファ/
-- terminal と同じ視認性を持たせるため。cmdline 本体の表示と二重になるが、既存の
-- 変換中(converting)表示も元々同じ二重表示だったので一貫している)。
-- completion/register_word/dot_repeat には対応しない(vim.ui.input の入れ子や
-- 挿入モード前提の dot repeat が cmdline には無いため)。
local ui = require("vime.ui")

---@class vime.CmdlineBackend
---@field kind "cmdline"
---@field buf integer
---@field keymap_mode "c"
---@field anchor integer
---@field len integer
local M = {}
M.kind = "cmdline"
M.keymap_mode = "c"

local FEATURES = { completion = false, register_word = false, dot_repeat = false }

function M.supports(feature)
  return FEATURES[feature] == true
end

-- buf は keymap.attach/detach の帳簿づけ用の識別子として保持するだけ(mode="c" は
-- グローバルマッピングなので実際のキー割り当てには使わない)。
function M.new(buf)
  local self = setmetatable({}, { __index = M })
  self.buf = buf
  self.anchor = math.max(0, vim.fn.getcmdpos() - 1) -- 1-based -> 0-based byte
  self.len = 0
  return self
end

-- 未確定が無い(idle)ときは現在の cmdpos へ再アンカーする。
function M:sync_anchor()
  if self.len == 0 then
    self.anchor = math.max(0, vim.fn.getcmdpos() - 1)
  end
end

-- 未確定領域を text に置換する。cmdline 全体を読み直し、anchor/len の範囲だけ
-- 差し替えて setcmdline で書き戻す(カーソルも text の直後へ同時に進める)。
function M:set_region_text(text)
  local line = vim.fn.getcmdline()
  local s = math.min(self.anchor, #line)
  local e = math.min(self.anchor + self.len, #line)
  local new_line = line:sub(1, s) .. text .. line:sub(e + 1)
  vim.fn.setcmdline(new_line, s + #text + 1) -- setcmdline の pos は 1-based
  self.anchor = s
  self.len = #text
end

-- set_region_text が setcmdline の pos 引数でカーソル位置も同時に進めているので no-op。
function M:place_cursor() end

-- session:preedit_segments() の view をインライン表示しつつ、未確定が空でなければ
-- 常に共有 preedit float へ下線(composing)・文節反転(converting)付きで併記する。
function M:render(view)
  local parts = {}
  for _, seg in ipairs(view) do
    parts[#parts + 1] = (seg.kind == "segments") and table.concat(seg.list) or seg.text
  end
  local text = table.concat(parts)
  self:set_region_text(text)
  if #text > 0 then
    ui.show_preedit_float(view, self:popup_pos())
  else
    ui.close_preedit_float()
  end
end

-- 候補 popup と文節状態 float を閉じる(cmdline はインライン装飾を持たない)。
function M:clear()
  ui.close_popup()
  ui.close_preedit_float()
end

-- 未確定領域を確定テキストで置き換える(setcmdline による API 経路のみ。
-- cmdline に「挿入モード」の概念は無いので dot repeat 用の feedkeys 経路は無い)。
function M:finalize(text)
  self:set_region_text(text)
  self.anchor = self.anchor + #text
  self.len = 0
end

-- 未確定が無いときの通常のスペース/改行を cmdline へ素通しする
-- (改行は cmdline 実行のトリガーになる)。
function M:insert_literal(text)
  local keys = (text == "\n") and vim.api.nvim_replace_termcodes("<CR>", true, false, true) or text
  vim.api.nvim_feedkeys(keys, "n", false)
end

-- BS/C-w/C-u/Esc 等のキーをそのまま Vim の cmdline 既定動作へ流す。
function M:passthrough(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
end

-- 候補 popup・文節状態 float は cmdline 行の直上に editor 相対で出す。
function M:popup_pos()
  return { relative = "editor", row = math.max(0, vim.o.lines - vim.o.cmdheight - 1), col = 0, anchor = "NW" }
end

return M
