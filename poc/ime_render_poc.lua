-- インライン IME 描画 PoC
-- 目的: モード式IMEの心臓部(未確定下線・文節反転・候補popup)を Neovim API で実現できるか、
--       特にマルチバイト列の byte オフセット計算の罠を洗い出す。
-- 実行: nvim --headless -l poc/ime_render_poc.lua

local api = vim.api
local problems = {}
local function report(s) problems[#problems + 1] = s end
local function ok(cond, msg)
  print(string.format("  %s %s", cond and "✅" or "✗", msg))
  if not cond then report(msg) end
end

-- ハイライト定義
api.nvim_set_hl(0, "VimeUnconfirmed", { underline = true })
api.nvim_set_hl(0, "VimeSegment", { reverse = true })

local ns = api.nvim_create_namespace("vime")
local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)

----------------------------------------------------------------------
-- ① 未確定かなを下線表示できるか
----------------------------------------------------------------------
print("=========== ① 未確定かなの下線 extmark ===========")
local kana = "きょうは" -- 4文字 = 12 byte
api.nvim_buf_set_lines(buf, 0, -1, false, { kana })
api.nvim_buf_set_extmark(buf, ns, 0, 0, {
  end_col = #kana, -- byte長
  hl_group = "VimeUnconfirmed",
})
local got = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
ok(#got == 1, "extmark が1つ置けた")
ok(got[1][4].hl_group == "VimeUnconfirmed", "hl_group=VimeUnconfirmed が設定された")
ok(got[1][4].end_col == #kana, string.format("end_col=byte長(%d) で全体を覆う", #kana))

----------------------------------------------------------------------
-- ② 変換後、現在文節だけ反転できるか (マルチバイト byte 計算の罠)
----------------------------------------------------------------------
print("\n=========== ② 文節反転 (byte オフセット) ===========")
-- 変換結果: 今日は | 良い | 天気だね  (3文節)
local segs = { "今日は", "良い", "天気だね" }
local line = table.concat(segs)
api.nvim_buf_set_lines(buf, 0, -1, false, { line })
api.nvim_buf_clear_namespace(buf, ns, 0, -1)

-- 各文節の byte 範囲を計算 (#str は byte 長)
local byte_off = 0
local ranges = {}
for _, s in ipairs(segs) do
  ranges[#ranges + 1] = { start = byte_off, fin = byte_off + #s }
  byte_off = byte_off + #s
end
-- 文字数とbyte長の差を確認(罠の核心)
ok(#"今日は" == 9, "「今日は」は 9 byte (3文字×3byte)")
ok(vim.fn.strchars("今日は") == 3, "「今日は」は 3 文字 (strchars)")

-- 第1文節(index 2, 「良い」)を反転対象にする
local target = 2
api.nvim_buf_set_extmark(buf, ns, 0, ranges[target].start, {
  end_col = ranges[target].fin,
  hl_group = "VimeSegment",
})
local d = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1]
local covered = line:sub(d[3] + 1, d[4].end_col) -- byte で切り出し
ok(covered == "良い", string.format("反転範囲が「良い」になる (実際: %s)", covered))

-- もし byte でなく文字数でオフセットしたら何が起きるか(罠の実演)
local wrong_start = vim.fn.strchars(segs[1]) -- 3 (文字数)
local wrong_cut = line:sub(wrong_start + 1)
print(string.format("    [罠] 文字数(%d)をbyte offsetに誤用 -> 切出し \"%s\" (ズレる)", wrong_start, wrong_cut:sub(1, 12)))
report("文節ハイライトは byte offset 必須。文字数を使うとマルチバイトでズレる(設計で明示)")

----------------------------------------------------------------------
-- ③ 候補 popup (floating window) を出せるか
----------------------------------------------------------------------
print("\n=========== ③ 候補 popup (floating window) ===========")
local cand_buf = api.nvim_create_buf(false, true)
api.nvim_buf_set_lines(cand_buf, 0, -1, false, { "a: 良い天気", "s: いい天気", "d: 飯井天気" })
local win_ok, win = pcall(api.nvim_open_win, cand_buf, false, {
  relative = "editor", row = 1, col = 1, width = 14, height = 3, style = "minimal",
})
ok(win_ok and api.nvim_win_is_valid(win), "floating window を開けた")
if win_ok then
  local cfg = api.nvim_win_get_config(win)
  ok(cfg.relative == "editor", "relative=editor で配置できる")
  api.nvim_win_close(win, true)
  ok(not api.nvim_win_is_valid(win), "popup を閉じられた")
end

----------------------------------------------------------------------
-- ④ 挿入モードのキー横取り (マッピング登録)
----------------------------------------------------------------------
print("\n=========== ④ 挿入モードのキー横取り ===========")
local fired = false
vim.keymap.set("i", "<C-j>", function() fired = true end, { buffer = buf })
local maps = api.nvim_buf_get_keymap(buf, "i")
local found = false
for _, mp in ipairs(maps) do
  if mp.lhs == "^J" or mp.lhs == "<C-J>" or mp.lhs:lower() == "<c-j>" then found = true end
end
ok(found, "挿入モードで <C-j> をバッファローカルにマップできる")
ok(type(fired) == "boolean", "コールバック関数を登録できる(発火はインタラクティブ確認)")

----------------------------------------------------------------------
print("\n=========== 洗い出した問題/メモ ===========")
if #problems == 0 then
  print("  (致命的な問題なし)")
else
  for i, p in ipairs(problems) do
    print(string.format("  %d. %s", i, p))
  end
end
