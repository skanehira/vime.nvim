-- vime: 英字→日本語変換 IME プラグインのエントリ。
-- session(状態)・ui(描画)・anthy(変換)・keymap(キー)を結線し、
-- 挿入モードのバッファに未確定テキストを書きながら IME 操作を提供する。
local config = require("vime.config")
local anthy = require("vime.anthy")
local session = require("vime.session")
local ui = require("vime.ui")
local keymap = require("vime.keymap")

local api = vim.api
local M = {}

-- コントローラの状態
local st = {
  cfg = nil,
  anthy_ok = false,
  enabled = false,
  session = nil,
  buf = nil,
  row = 0,
  start_col = 0, -- 未確定領域の開始 byte 列
  len = 0,       -- 未確定領域の byte 長
  space_count = 0,
  popup_open = false,
}

-- 未確定が無い(idle)ときは実カーソル位置へ再アンカーする。
-- 確定後やユーザーの直接編集(Backspace 等)でズレた start_col を healing する。
local function sync_anchor()
  if st.len == 0 then
    local cur = api.nvim_win_get_cursor(0)
    st.row = cur[1] - 1
    st.start_col = cur[2]
  end
end

-- 未確定領域のテキストを置き換える。範囲は行長へクランプし、IME が挿入モードを壊さないようにする。
local function set_region_text(text)
  if not (st.buf and api.nvim_buf_is_valid(st.buf)) then
    return
  end
  local line = api.nvim_buf_get_lines(st.buf, st.row, st.row + 1, false)[1] or ""
  local s = math.min(st.start_col, #line)
  local e = math.min(st.start_col + st.len, #line)
  api.nvim_buf_set_text(st.buf, st.row, s, st.row, e, { text })
  st.start_col = s
  st.len = #text
end

local function place_cursor()
  api.nvim_win_set_cursor(0, { st.row + 1, st.start_col + st.len })
end

-- 現在の session 状態をバッファ＋ハイライトへ反映する。
local function render()
  ui.clear(st.buf)
  st.popup_open = false
  local s = st.session
  if s:state() == "converting" then
    local view = s:segments()
    set_region_text(table.concat(view.list))
    ui.highlight_segments(st.buf, st.row, st.start_col, view.list, view.current)
  else
    local kana = s:preedit()
    set_region_text(kana)
    if kana ~= "" then
      ui.highlight_preedit(st.buf, st.row, st.start_col, st.len)
    end
  end
  place_cursor()
end

-- 未確定領域を確定テキストで置き換え、領域を確定後の位置へ進める。
local function finalize(text)
  set_region_text(text)
  ui.clear(st.buf)
  st.popup_open = false
  st.start_col = st.start_col + #text
  st.len = 0
  place_cursor()
end

-- 未確定が無いときに通常のスペース/改行をカーソル位置へ挿入する(素通し)。
local function insert_literal(text)
  if not (st.buf and api.nvim_buf_is_valid(st.buf)) then
    return
  end
  local cur = api.nvim_win_get_cursor(0)
  local row0, col = cur[1] - 1, cur[2]
  if text == "\n" then
    api.nvim_buf_set_text(st.buf, row0, col, row0, col, { "", "" })
    api.nvim_win_set_cursor(0, { cur[1] + 1, 0 })
  else
    api.nvim_buf_set_text(st.buf, row0, col, row0, col, { text })
    api.nvim_win_set_cursor(0, { cur[1], col + #text })
  end
end

-- 注目文節の候補一覧 popup を表示する。
local function show_popup()
  local cands = st.session:candidates()
  local labels = st.cfg.popup.labels
  local items = {}
  for i, c in ipairs(cands) do
    local label = labels:sub(i, i)
    if label == "" then
      break -- ラベル枯渇分は表示しない
    end
    items[#items + 1] = label .. ": " .. c
  end
  ui.show_popup(items)
  st.popup_open = true
end

----------------------------------------------------------------------
-- ハンドラ(keymap からディスパッチされる)
----------------------------------------------------------------------

function M.on_input(ch)
  if not st.enabled then
    return
  end
  sync_anchor()
  -- popup 表示中はラベル選択
  if st.popup_open then
    local idx = st.cfg.popup.labels:find(ch:lower(), 1, true)
    if idx then
      st.session:select(idx)
      st.space_count = 0
      render()
      return
    end
  end
  local confirmed = st.session:input(ch)
  if confirmed ~= "" then
    finalize(confirmed)
  end
  st.space_count = 0
  render()
end

function M.on_convert()
  if not st.enabled then
    return
  end
  sync_anchor()
  if st.session:state() == "composing" then
    if st.session:is_latin() then
      st.session:input(" ") -- 英字ラン中はスペースも英字の一部(確定は Enter のみ)
      render()
      return
    end
    if st.session:preedit() == "" then
      insert_literal(" ") -- 未確定なし: 通常のスペース
      return
    end
    st.session:start_conversion()
    st.space_count = 0
    render()
  else
    st.space_count = st.space_count + 1
    st.session:next_candidate()
    render()
    if st.space_count >= st.cfg.popup.threshold then
      show_popup()
    end
  end
end

function M.on_commit()
  if not st.enabled then
    return
  end
  sync_anchor()
  if st.session:state() == "composing" and st.session:preedit() == "" then
    insert_literal("\n") -- 未確定なし: 通常の改行
    return
  end
  finalize(st.session:commit())
end

function M.on_cancel()
  if not st.enabled then
    return
  end
  st.session:cancel()
  st.space_count = 0
  render()
end

function M.on_backspace()
  if not st.enabled then
    return
  end
  if st.session:state() == "composing" and st.session:preedit() == "" then
    -- 未確定なし: 通常の BS として素通し
    api.nvim_feedkeys(api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
    return
  end
  st.session:backspace()
  render()
end

-- C-w(単語削除)/C-u(行削除)。未確定があれば IME のキャンセル、無ければ素通し。
function M.on_kill(key)
  if not st.enabled then
    return
  end
  sync_anchor()
  if st.session:state() == "converting" or st.session:preedit() ~= "" then
    st.session:clear()
    render() -- 未確定を消す
  else
    api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "n", false)
  end
end

-- 挿入モードを抜けるとき: 未確定/変換中を確定して IME 状態を掃除する。
-- これにより、抜けた後のノーマルモード編集(オペレータ/テキストオブジェクト/undo 等)が
-- 確定済みのプレーンテキストに対して安全に効く。
function M.on_insert_leave()
  if not st.enabled then
    return
  end
  if not (st.buf and api.nvim_buf_is_valid(st.buf) and api.nvim_get_current_buf() == st.buf) then
    return
  end
  local s = st.session
  if s and (s:state() == "converting" or s:preedit() ~= "") then
    s:commit() -- 変換中なら学習。確定テキストは既にバッファにあるので残す
    ui.clear(st.buf)
    st.len = 0
  end
  st.space_count = 0
  st.popup_open = false
end

function M.on_next_segment()
  if st.enabled then
    st.session:next_segment(); render()
  end
end

function M.on_prev_segment()
  if st.enabled then
    st.session:prev_segment(); render()
  end
end

function M.on_expand()
  if st.enabled then
    st.session:expand(); render()
  end
end

function M.on_shrink()
  if st.enabled then
    st.session:shrink(); render()
  end
end

----------------------------------------------------------------------
-- モード制御
----------------------------------------------------------------------

local function handlers()
  return {
    input = M.on_input,
    convert = M.on_convert,
    commit = M.on_commit,
    cancel = M.on_cancel,
    backspace = M.on_backspace,
    next_segment = M.on_next_segment,
    prev_segment = M.on_prev_segment,
    expand = M.on_expand,
    shrink = M.on_shrink,
    kill = M.on_kill,
  }
end

local function enable()
  st.enabled = true
  st.session = session.new(anthy)
  st.buf = api.nvim_get_current_buf()
  local cur = api.nvim_win_get_cursor(0)
  st.row = cur[1] - 1
  st.start_col = cur[2]
  st.len = 0
  st.space_count = 0
  st.popup_open = false
  keymap.attach(st.buf, st.cfg, handlers())
end

local function disable()
  local valid = st.buf and api.nvim_buf_is_valid(st.buf)
  -- 未確定/変換中があれば確定してから OFF
  local s = st.session
  if s and valid and (s:state() == "converting" or s:preedit() ~= "") then
    finalize(s:commit())
  end
  if valid then
    ui.clear(st.buf)
    keymap.detach(st.buf)
  end
  st.enabled = false
  st.session = nil
end

-- 日本語入力 ON/OFF をトグルする。
function M.toggle()
  if not st.anthy_ok then
    vim.notify("vime: libanthy をロードできません。anthy.lib を確認してください", vim.log.levels.WARN)
    return
  end
  if st.enabled then
    disable()
  else
    enable()
  end
end

-- 状態確認(テスト/デバッグ用)。
function M.is_enabled()
  return st.enabled
end

function M.setup(opts)
  st.cfg = config.merge(opts)
  ui.setup()
  local lib = st.cfg.anthy.lib or config.find_anthy_lib()
  st.anthy_ok = lib ~= nil and anthy.setup(lib)
  if not st.anthy_ok then
    vim.notify("vime: libanthy が見つかりません。anthy.lib を設定してください", vim.log.levels.WARN)
  end
  vim.keymap.set("i", st.cfg.keymaps.toggle, M.toggle, { desc = "vime: toggle japanese input" })

  -- 挿入モードを抜けたら未確定を確定する(ノーマルモード編集を安全にする)
  local group = api.nvim_create_augroup("vime", { clear = true })
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      M.on_insert_leave()
    end,
  })
end

return M
