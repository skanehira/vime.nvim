-- 通常バッファ + 挿入モード用の backend。
-- 未確定領域をバッファ番号 + (row, start_col, len) の byte 範囲で追跡し、
-- nvim_buf_set_text / nvim_win_set_cursor / nvim_feedkeys で書き込む。
-- 挙動は init.lua の旧実装(set_region_text/sync_anchor/place_cursor/finalize/insert_literal)
-- をそのまま移設したもので、変更は一切ない。
local api = vim.api
local ui = require("vime.ui")

---@class vime.BufferBackend
---@field kind "buffer"
---@field buf integer
---@field row integer
---@field start_col integer
---@field len integer
local M = {}
M.kind = "buffer"

local FEATURES = { completion = true, register_word = true, dot_repeat = true }

function M.supports(feature)
  return FEATURES[feature] == true
end

function M.new(buf)
  local self = setmetatable({}, { __index = M })
  self.buf = buf
  self.row = 0
  self.start_col = 0 -- 未確定領域の開始 byte 列
  self.len = 0 -- 未確定領域の byte 長
  return self
end

-- 未確定が無い(idle)ときは実カーソル位置へ再アンカーする。
-- 確定後やユーザーの直接編集(Backspace 等)でズレた start_col を healing する。
function M:sync_anchor()
  if self.len == 0 then
    local cur = api.nvim_win_get_cursor(0)
    self.row = cur[1] - 1
    self.start_col = cur[2]
  end
end

-- 未確定領域のテキストを置き換える。範囲は行長へクランプし、IME が挿入モードを壊さないようにする。
function M:set_region_text(text)
  if not (self.buf and api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local line = api.nvim_buf_get_lines(self.buf, self.row, self.row + 1, false)[1] or ""
  local s = math.min(self.start_col, #line)
  local e = math.min(self.start_col + self.len, #line)
  api.nvim_buf_set_text(self.buf, self.row, s, self.row, e, { text })
  self.start_col = s
  self.len = #text
end

function M:place_cursor()
  api.nvim_win_set_cursor(0, { self.row + 1, self.start_col + self.len })
end

-- session:preedit_segments() の view をバッファへ描画する。未変換 kana/latin は下線、
-- confirmed はハイライトなし、converting 中の文節列(segments)は注目文節を反転する。
function M:render(view)
  local parts = {}
  for _, seg in ipairs(view) do
    parts[#parts + 1] = (seg.kind == "segments") and table.concat(seg.list) or seg.text
  end
  self:set_region_text(table.concat(parts))
  local off = self.start_col
  for _, seg in ipairs(view) do
    if seg.kind == "kana" or seg.kind == "latin" then
      if #seg.text > 0 then
        ui.highlight_preedit(self.buf, self.row, off, #seg.text)
      end
      off = off + #seg.text
    elseif seg.kind == "confirmed" then
      off = off + #seg.text -- 確定済みはハイライトなし
    elseif seg.kind == "segments" then
      ui.highlight_segments(self.buf, self.row, off, seg.list, seg.current)
      for _, t in ipairs(seg.list) do
        off = off + #t
      end
    end
  end
end

-- 下線/文節反転の extmark と候補 popup を消す。
function M:clear()
  ui.clear(self.buf)
end

-- 挿入モード中か。確定テキストの挿入経路(feedkeys か API か)を分岐するのに使う。
local function in_insert_mode()
  return api.nvim_get_mode().mode:sub(1, 1) == "i"
end

-- 未確定領域を確定テキストで置き換える。
-- 挿入モード中は「preedit を API で消し、確定テキストを feedkeys でタイプ入力として流す」。
-- これで native の redo に確定テキストが載り、dot repeat(`.`)・count(`3.`)・オペレータ合成
-- (`ciw…<Esc>` の `.`)が Vim 本来の動作で効く。挿入経路が非同期になるので start_col は
-- 進めず、place_cursor もしない。fed テキスト挿入後の実カーソル位置へ次のハンドラの
-- sync_anchor が再アンカーする(len==0 なので効く)。
-- 非挿入モード(direct handler 呼び出し・disable 等)は従来どおり API で置換する。
-- 戻り値: 挿入モード中だったか(呼び出し側が clear/popup_open/len/sync_converting_keymap を
-- 揃えるのに使う)。
function M:finalize(text)
  if in_insert_mode() then
    self:set_region_text("") -- preedit を API で削除(redo には載せない)
    self.len = 0
    -- text と <C-G>u を 1 回の feedkeys にまとめて順序を保証する(別々に "i" で feed すると
    -- 後発が前へ割り込み順序が逆転する)。"i"=typeahead 先頭挿入で後続 <Esc> より先に処理、
    -- "n"=remap 無効(確定テキストが ASCII の F10 "foo" 等でも vime マッピングに再入しない)、
    -- escape_ks=true=UTF-8 継続バイト 0x80(「む」等)の K_SPECIAL 衝突回避。
    api.nvim_feedkeys(text .. api.nvim_replace_termcodes("<C-G>u", true, false, true), "in", true)
    return true
  end
  self:set_region_text(text)
  self.start_col = self.start_col + #text
  self.len = 0
  self:place_cursor()
  return false
end

-- 未確定が無いときに通常のスペース/改行をカーソル位置へ挿入する(素通し)。
-- 挿入モード中は feedkeys でタイプ入力として流し(redo に載せて dot repeat に含める)、
-- "n" で Space/CR マッピングへの再入を防ぐ。<C-G>u は積まない(IME 確定ではないので
-- Vim 標準の 1 ブロック挙動を維持する)。非挿入モードは従来どおり API で挿入する。
function M:insert_literal(text)
  if not (self.buf and api.nvim_buf_is_valid(self.buf)) then
    return
  end
  if in_insert_mode() then
    local keys = (text == "\n") and api.nvim_replace_termcodes("<CR>", true, false, true) or text
    api.nvim_feedkeys(keys, "in", true)
    return
  end
  local cur = api.nvim_win_get_cursor(0)
  local row0, col = cur[1] - 1, cur[2]
  if text == "\n" then
    api.nvim_buf_set_text(self.buf, row0, col, row0, col, { "", "" })
    api.nvim_win_set_cursor(0, { cur[1] + 1, 0 })
  else
    api.nvim_buf_set_text(self.buf, row0, col, row0, col, { text })
    api.nvim_win_set_cursor(0, { cur[1], col + #text })
  end
end

-- BS/C-w/C-u/Esc 等のキーをそのまま Vim の既定動作へ流す。
function M:passthrough(key)
  api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "n", false)
end

function M:popup_pos()
  return { relative = "cursor", row = 1, col = 0 }
end

function M:detach() end

return M
