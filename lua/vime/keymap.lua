-- 挿入モードのキーを session/ui 操作へディスパッチする。
-- 日本語入力 ON の間だけバッファローカルにマッピングを張り、OFF で外す。
local M = {}

-- 印字可能 ASCII(0x21-0x7e、空白を除く)を返す。記号・数字も IME に通す。
local function printable_chars()
  local cs = {}
  for c = 0x21, 0x7e do
    cs[#cs + 1] = string.char(c)
  end
  return cs
end

-- lhs として特別扱いが要る文字のエスケープ。
local SPECIAL_LHS = { ["<"] = "<lt>", ["|"] = "<Bar>", ["\\"] = "<Bslash>" }

local registered = {} -- buf -> {lhs,...}

-- buf にバッファローカルの挿入モードマッピングを張る。
function M.attach(buf, config, handlers)
  local lhs_list = {}
  local function map(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = buf, nowait = true, silent = true })
    lhs_list[#lhs_list + 1] = lhs
  end

  for _, ch in ipairs(printable_chars()) do
    map(SPECIAL_LHS[ch] or ch, function() handlers.input(ch) end)
  end

  local km = config.keymaps
  map(km.convert, handlers.convert)
  map(km.commit, handlers.commit)
  map(km.cancel, handlers.cancel)
  map(km.next_segment, handlers.next_segment)
  map(km.prev_segment, handlers.prev_segment)
  map(km.expand, handlers.expand)
  map(km.shrink, handlers.shrink)
  map(km.next_candidate, handlers.next_candidate)
  map(km.prev_candidate, handlers.prev_candidate)
  map(km.katakana, handlers.katakana)
  map("<BS>", handlers.backspace)
  map("<C-h>", handlers.backspace) -- 端末によっては Backspace が C-h
  map("<C-w>", function() handlers.kill("<C-w>") end) -- 単語削除
  map("<C-u>", function() handlers.kill("<C-u>") end) -- 行削除

  registered[buf] = lhs_list
end

-- buf のマッピングを外す。
function M.detach(buf)
  local lhs_list = registered[buf]
  if not lhs_list then
    return
  end
  for _, lhs in ipairs(lhs_list) do
    pcall(vim.keymap.del, "i", lhs, { buffer = buf })
  end
  registered[buf] = nil
end

return M
