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
  "register_word",
}

-- composing 中の補完 popup 表示中のみバッファに張るキー(config.keymaps 上の名前)。
-- converting 限定キーと同じ lhs(C-n/C-p)だが、状態が排他なので同時には張られない。
local COMPLETION_ONLY = {
  "next_candidate",
  "prev_candidate",
  "completion_cancel",
}

-- cmdline("c")はバッファローカルにできない(:cnoremap は常にグローバル)ため、
-- このモードだけグローバルスコープで attach/detach する。
local GLOBAL_MODES = { c = true }

local registered = {} -- "mode:buf" -> {lhs,...} (常時マッピング)
local registered_converting = {} -- "mode:buf" -> {{lhs=,saved=},...} (converting 限定マッピング)
local registered_completion = {} -- "mode:buf" -> {{lhs=,saved=},...} (補完 popup 表示中限定マッピング)

local function store_key(mode, buf)
  return mode .. ":" .. (GLOBAL_MODES[mode] and "global" or buf)
end

-- maparg/mapset はグローバルスコープでは buf 引数を取らないので、モードに応じて
-- nvim_buf_call で包むかどうかを切り替える。
local function with_scope(mode, buf, fn)
  if GLOBAL_MODES[mode] then
    return fn()
  end
  return vim.api.nvim_buf_call(buf, fn)
end

-- 一時的に奪うキー(converting/補完限定)を張る。上書き前にそのバッファ(またはグローバル)へ
-- 既に張られていたマッピングがあれば保存し、detach_transient() で復元できるようにする。
-- 同じ mode+buf に対する二重 attach は冪等(2 回目以降は何もしない)。
local function attach_transient(buf, mode, names, config, handlers, store)
  local key = store_key(mode, buf)
  if store[key] then
    return
  end
  local entries = {}
  local km = config.keymaps
  -- "c"(cmdline)だけ silent を付けない: silent=true な "c" マッピングの callback から
  -- vim.fn.setcmdline() を呼ぶと、getcmdline() の内部状態は正しく更新されるのに実機で
  -- 画面が再描画されない(実機検証で確認済みの Neovim の挙動。headless では検知できない)。
  local map_opts = GLOBAL_MODES[mode] and { nowait = true } or { nowait = true, silent = true }
  if not GLOBAL_MODES[mode] then
    map_opts.buffer = buf
  end
  for _, name in ipairs(names) do
    local lhs = km[name]
    local existing = with_scope(mode, buf, function()
      return vim.fn.maparg(lhs, mode, false, true)
    end)
    entries[#entries + 1] = { lhs = lhs, saved = next(existing) ~= nil and existing or nil }
    vim.keymap.set(mode, lhs, handlers[name], map_opts)
  end
  store[key] = entries
end

-- attach_transient() で上書きしたキーを外す。保存済みマッピングがあれば復元し、
-- なければ削除のみ行う。未 attach なら何もしない(冪等)。
local function detach_transient(buf, mode, store)
  local key = store_key(mode, buf)
  local entries = store[key]
  if not entries then
    return
  end
  local del_opts = GLOBAL_MODES[mode] and {} or { buffer = buf }
  for _, e in ipairs(entries) do
    pcall(vim.keymap.del, mode, e.lhs, del_opts)
    if e.saved then
      with_scope(mode, buf, function()
        vim.fn.mapset(mode, false, e.saved)
      end)
    end
  end
  store[key] = nil
end

-- buf にバッファローカル(mode="c" のときはグローバル)の mode マッピングを張る
-- (mode 省略時は "i")。terminal backend は "t"、cmdline backend は "c" を渡す。
function M.attach(buf, config, handlers, mode)
  mode = mode or "i"
  local lhs_list = {}
  -- "c"(cmdline)だけ silent を付けない: silent=true な "c" マッピングの callback から
  -- vim.fn.setcmdline() を呼ぶと、getcmdline() の内部状態は正しく更新されるのに実機で
  -- 画面が再描画されない(実機検証で確認済みの Neovim の挙動。headless では検知できない)。
  local map_opts = GLOBAL_MODES[mode] and { nowait = true } or { nowait = true, silent = true }
  if not GLOBAL_MODES[mode] then
    map_opts.buffer = buf
  end
  local function map(lhs, fn)
    vim.keymap.set(mode, lhs, fn, map_opts)
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

  registered[store_key(mode, buf)] = lhs_list
end

-- buf のマッピングを外す。converting/補完限定マッピングも合わせて掃除する(mode 省略時は "i")。
function M.detach(buf, mode)
  mode = mode or "i"
  M.detach_converting(buf, mode)
  M.detach_completion(buf, mode)
  local key = store_key(mode, buf)
  local lhs_list = registered[key]
  if not lhs_list then
    return
  end
  local del_opts = GLOBAL_MODES[mode] and {} or { buffer = buf }
  for _, lhs in ipairs(lhs_list) do
    pcall(vim.keymap.del, mode, lhs, del_opts)
  end
  registered[key] = nil
end

-- converting 状態で必要なキーだけを追加でマップする。上書き前に既存のバッファローカル
-- マッピングがあれば保存し、detach_converting() で元に戻す(他プラグインとの共存)。
-- 同じ mode+buf に対する二重 attach は冪等(2 回目以降は何もしない)。mode 省略時は "i"。
function M.attach_converting(buf, config, handlers, mode)
  attach_transient(buf, mode or "i", CONVERTING_ONLY, config, handlers, registered_converting)
end

-- converting 限定のマッピングだけを外す。上書き前に別のマッピングがあれば復元する。
-- 未 attach なら何もしない(冪等)。mode 省略時は "i"。
function M.detach_converting(buf, mode)
  detach_transient(buf, mode or "i", registered_converting)
end

-- 補完 popup 表示中に必要なキー(候補選択)だけを追加でマップする。上書き前に既存の
-- バッファローカルマッピングがあれば保存し、detach_completion() で元に戻す。
-- 同じ mode+buf に対する二重 attach は冪等(2 回目以降は何もしない)。mode 省略時は "i"。
function M.attach_completion(buf, config, handlers, mode)
  attach_transient(buf, mode or "i", COMPLETION_ONLY, config, handlers, registered_completion)
end

-- 補完限定のマッピングだけを外す。上書き前に別のマッピングがあれば復元する。
-- 未 attach なら何もしない(冪等)。mode 省略時は "i"。
function M.detach_completion(buf, mode)
  detach_transient(buf, mode or "i", registered_completion)
end

return M
