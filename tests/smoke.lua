-- 実キーストローク smoke test: nvim --headless -l tests/smoke.lua
-- 実際のマッピング/autocmd を通して主要シナリオを確認する。
local data = vim.fn.stdpath("data")
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(data .. "/lazy/plenary.nvim")

-- 実 HOME のうちに lib を自動探索する(この後 HOME を temp 化すると ~ 展開が変わるため先に解決)。
local lib = require("vime.config").find_anthy_lib()

-- 学習を汚さないよう HOME と XDG_CONFIG_HOME を一時ディレクトリへ
-- (原 anthy=$HOME/.anthy、anthy-unicode=$XDG_CONFIG_HOME/anthy)
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.HOME = tmp
vim.env.XDG_CONFIG_HOME = tmp .. "/.config"

if not lib then
  print(require("vime").install_hint())
  return
end
require("vime").setup({ anthy = { lib = lib } })

local api = vim.api
local function feed(s)
  api.nvim_feedkeys(api.nvim_replace_termcodes(s, true, false, true), "mx", false)
end
local function reset()
  if require("vime").is_enabled() then
    require("vime").toggle() -- 直前シナリオの ON 状態を確実に解除
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_current_buf(buf)
  return buf
end
local function lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

local results = {}
local function check(name, cond)
  results[#results + 1] = string.format("%s %s", cond and "PASS" or "FAIL", name)
end

-- 1) 基本: ローマ字→変換→確定
do
  local buf = reset()
  feed("i<C-j>kyouhaiitenkidane <CR><Esc>")
  local l = lines(buf)[1] or ""
  -- 先頭「今日」のみ安定検証(文節境界は辞書バージョン依存: 9100h=今日は… / unicode=今日…)
  check("基本変換(今日…)", l ~= "きょうはいいてんきだね" and l:sub(1, #"今日") == "今日")
end

-- 2) スペース(未確定なし)が入力できる
do
  local buf = reset()
  feed("i<C-j>a<CR> b<Esc>") -- あ 確定後にスペース+ b
  local l = lines(buf)[1] or ""
  check("スペース入力", l:find(" ") ~= nil)
end

-- 3) 記号 - が取り残されない(supe- → すぺー)
do
  local buf = reset()
  feed("i<C-j>supe-<Esc>") -- Esc で未確定確定
  local l = lines(buf)[1] or ""
  check("記号-の取り込み(すぺー)", l == "すぺー")
end

-- 4) Esc で確定 → ノーマルモードの x で削除できる
do
  local buf = reset()
  feed("i<C-j>ka<Esc>") -- InsertLeave で か 確定、ノーマルモードへ
  feed("x")             -- ノーマルモードのオペレータで削除
  local l = lines(buf)[1] or ""
  check("Esc確定→ノーマルx削除", l == "")
end

-- 5) Esc で確定 → u(undo) が壊れない
do
  reset()
  feed("i<C-j>ka<Esc>")
  feed("u")
  check("undoが動く(クラッシュなし)", true)
end

-- 6) かな単位 Backspace(すぺ → BS → す)
do
  local buf = reset()
  feed("i<C-j>supe<BS><Esc>")
  check("かな単位BS(す)", (lines(buf)[1] or "") == "す")
end

-- 7) 句読点(a, → あ、)
do
  local buf = reset()
  feed("i<C-j>a,<Esc>")
  check("句読点(あ、)", (lines(buf)[1] or "") == "あ、")
end

-- 8) 大文字は英字のまま(API → API)
do
  local buf = reset()
  feed("i<C-j>API<Esc>")
  check("大文字は英字(API)", (lines(buf)[1] or "") == "API")
end

-- 9) かな+英字の混在(watashiAPI → わたしAPI)
do
  local buf = reset()
  feed("i<C-j>watashiAPI<Esc>")
  check("かな+英字混在(わたしAPI)", (lines(buf)[1] or "") == "わたしAPI")
end

-- 10) 英字ラン中のスペースは確定しない(Chrome devtool → そのまま)
do
  local buf = reset()
  feed("i<C-j>Chrome devtool<CR><Esc>")
  check("英字ラン中スペース(Chrome devtool)", (lines(buf)[1] or "") == "Chrome devtool")
end

-- 11) F7 でカタカナ確定(kyou → キョウ)
do
  local buf = reset()
  feed("i<C-j>kyou<F7><Esc>")
  check("F7カタカナ(キョウ)", (lines(buf)[1] or "") == "キョウ")
end

-- 12) F10 で英小文字確定(foo → ふぉお → foo)
do
  local buf = reset()
  feed("i<C-j>foo<F10><Esc>")
  check("F10英小文字(foo)", (lines(buf)[1] or "") == "foo")
end

print("==== smoke results ====")
for _, r in ipairs(results) do print(r) end
