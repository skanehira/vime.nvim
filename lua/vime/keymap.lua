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

-- converting 状態でのみバッファに張るキー(config.keymaps 上の名前)。
-- composing/ASCII 直入力では vime が握らず、ユーザの insert モードマッピング/Vim 既定が生きる。
local CONVERTING_ONLY = {
  "next_segment",
  "prev_segment",
  "next_candidate",
  "prev_candidate",
  "expand",
  "shrink",
}

local registered = {} -- buf -> {lhs,...} (常時マッピング)
local registered_converting = {} -- buf -> {lhs,...} (converting 限定マッピング)

-- buf にバッファローカルの挿入モードマッピングを張る。
function M.attach(buf, config, handlers)
  local lhs_list = {}
  local function map(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = buf, nowait = true, silent = true })
    lhs_list[#lhs_list + 1] = lhs
  end

  for _, ch in ipairs(printable_chars()) do
    map(SPECIAL_LHS[ch] or ch, function()
      handlers.input(ch)
    end)
  end

  local km = config.keymaps
  map(km.convert, handlers.convert)
  map(km.commit, handlers.commit)
  map(km.cancel, handlers.cancel)
  map(km.katakana, handlers.katakana)
  map(km.alphabet, handlers.alphabet)
  -- 文節操作系(next/prev_segment, next/prev_candidate, expand, shrink)は converting に
  -- 入った瞬間にのみ attach_converting() で張る。composing/ASCII 直入力 では vime が
  -- 握らずユーザの insert マッピング/Vim 既定が生きるようにする。
  map("<BS>", handlers.backspace)
  map("<C-h>", handlers.backspace) -- 端末によっては Backspace が C-h
  map("<C-w>", function()
    handlers.kill("<C-w>")
  end) -- 単語削除
  map("<C-u>", function()
    handlers.kill("<C-u>")
  end) -- 行削除

  registered[buf] = lhs_list
end

-- buf のマッピングを外す。converting 限定マッピングも合わせて掃除する。
function M.detach(buf)
  M.detach_converting(buf)
  local lhs_list = registered[buf]
  if not lhs_list then
    return
  end
  for _, lhs in ipairs(lhs_list) do
    pcall(vim.keymap.del, "i", lhs, { buffer = buf })
  end
  registered[buf] = nil
end

-- converting 状態で必要なキーだけを追加でマップする。
-- 同じ buf に対する二重 attach は冪等(2 回目以降は何もしない)。
function M.attach_converting(buf, config, handlers)
  if registered_converting[buf] then
    return
  end
  local lhs_list = {}
  local km = config.keymaps
  for _, name in ipairs(CONVERTING_ONLY) do
    local lhs = km[name]
    vim.keymap.set("i", lhs, handlers[name], { buffer = buf, nowait = true, silent = true })
    lhs_list[#lhs_list + 1] = lhs
  end
  registered_converting[buf] = lhs_list
end

-- converting 限定のマッピングだけを外す。未 attach なら何もしない(冪等)。
function M.detach_converting(buf)
  local lhs_list = registered_converting[buf]
  if not lhs_list then
    return
  end
  for _, lhs in ipairs(lhs_list) do
    pcall(vim.keymap.del, "i", lhs, { buffer = buf })
  end
  registered_converting[buf] = nil
end

return M
