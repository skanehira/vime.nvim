-- 実キーストローク smoke test: nvim --headless -l tests/smoke.lua
-- 実際のマッピング/autocmd を通して主要シナリオを確認する。
local data = vim.fn.stdpath("data")
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(data .. "/lazy/plenary.nvim")

-- 学習を汚さないよう HOME を一時ディレクトリへ
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.HOME = tmp

require("vime").setup({
  anthy = { lib = "/nix/store/m2z37mlz9rsh2azv9pny1860rpycic54-anthy-9100h/lib/libanthy.dylib" },
})

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
  check("基本変換(今日は…)", l ~= "きょうはいいてんきだね" and l:sub(1, #"今日は") == "今日は")
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

print("==== smoke results ====")
for _, r in ipairs(results) do print(r) end
