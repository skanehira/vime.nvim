-- 設定。デフォルトとユーザー設定をマージし、anthy ライブラリのパスを解決する。
local M = {}

M.defaults = {
  anthy = {
    lib = nil, -- 未指定なら既知パスを探索
  },
  romaji = {
    -- ローマ字→かなテーブル。nil なら既定(wapuro / vime.romaji.default_table)。
    -- 非 nil の場合は完全置換(マージしない)。act 等の独自配列を使うときに渡す。
    -- マージしたい場合はユーザ側で vim.tbl_extend("force", require("vime.romaji").default_table, {...}) などを行う。
    table = nil,
  },
  keymaps = {
    toggle = "<C-j>",
    convert = "<Space>",
    commit = "<CR>",
    cancel = "<C-g>",
    next_segment = "<C-f>",
    prev_segment = "<C-b>",
    expand = "<C-o>",
    shrink = "<C-i>",
    next_candidate = "<C-n>",
    prev_candidate = "<C-p>",
    katakana = "<F7>",
    alphabet = "<F10>",
    ascii_toggle = ";", -- ASCII モード入退室(nil で無効化)
    register_word = "<C-r>", -- converting 中に注目文節を辞書登録
  },
  mode_notify = {
    enabled = true, -- モード切替時にカーソル下へ短時間 popup を出す
    duration = 1000, -- ms
    labels = {
      -- 変換中は候補一覧 popup 側でシグナルするので、モード通知ラベルは持たない。
      direct = "直",
      hiragana = "あ",
      ascii = "A",
    },
    -- nil なら ui.lua 側のデフォルト(緑背景・白字・bold)を使う。
    -- nvim_set_hl 互換テーブル({ bg = "#...", fg = "#...", bold = true, ... })で明示上書き可。
    highlight = nil,
  },
  integrations = {
    -- nvim-cmp 連携。true で vime モード ON 中は cmp の補完を抑止する。
    nvim_cmp = false,
  },
}

-- OS ごとの共有ライブラリ拡張子(macOS=dylib / その他=so)。
local function lib_ext()
  return (jit.os == "OSX") and "dylib" or "so"
end

-- anthy 共有ライブラリの既定探索候補を構築する。
-- 推奨の anthy-unicode(別名 libanthy-unicode)を各 dir で優先し、原 anthy(libanthy)も探す。
function M.lib_candidates()
  local ext = lib_ext()
  local names = { "libanthy-unicode." .. ext, "libanthy." .. ext } -- unicode を優先
  local dirs = {
    vim.fn.expand("~/.local/lib"), -- ソースビルド(--prefix=$HOME/.local)
    vim.fn.expand("~/.nix-profile/lib"), -- nix profile install
    "/run/current-system/sw/lib", -- nix-darwin / NixOS
    "/opt/homebrew/lib", -- macOS Homebrew
    "/usr/local/lib", -- ソースビルド既定(prefix=/usr/local)
    "/usr/lib", -- 一般
    "/usr/lib64", -- Fedora
    "/usr/lib/x86_64-linux-gnu", -- Debian/Ubuntu amd64
    "/usr/lib/aarch64-linux-gnu", -- Debian/Ubuntu arm64
  }
  local list = {}
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(names) do
      list[#list + 1] = dir .. "/" .. name
    end
  end
  -- nix ストアはハッシュが変わるので glob で拾う(特定ハッシュに依存しない)。
  for _, name in ipairs(names) do
    for _, hit in ipairs(vim.fn.glob("/nix/store/*-anthy*/lib/" .. name, false, true)) do
      list[#list + 1] = hit
    end
  end
  return list
end

-- defaults へ user を再帰マージした新しいテーブルを返す。
function M.merge(user)
  local function deep(base, over)
    local out = {}
    for k, v in pairs(base) do
      out[k] = v
    end
    if over then
      for k, v in pairs(over) do
        if type(v) == "table" and type(out[k]) == "table" then
          out[k] = deep(out[k], v)
        else
          out[k] = v
        end
      end
    end
    return out
  end
  return deep(M.defaults, user)
end

-- anthy 共有ライブラリのパスを解決する。最初に存在したパスを返し、無ければ nil。
-- candidates 省略時(=既定探索)は環境変数 VIME_ANTHY_LIB → 既定候補の順で探す。
-- candidates 明示時はそのリストのみを走査する(テスト用)。
function M.find_anthy_lib(candidates)
  if candidates == nil then
    local env = vim.env.VIME_ANTHY_LIB
    if env and env ~= "" and vim.fn.filereadable(env) == 1 then
      return env
    end
    candidates = M.lib_candidates()
  end
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
  return nil
end

-- anthy の辞書登録ライブラリ(libanthydic)のパスを解決する。
-- 登録 API(anthy_priv_dic_add_entry 等)は本体 libanthy ではなく libanthydic にある。
-- 環境変数 VIME_ANTHY_DIC_LIB → main lib 名からの導出(libanthy→libanthydic) → nil。
function M.find_anthy_dic_lib(main_lib)
  local env = vim.env.VIME_ANTHY_DIC_LIB
  if env and env ~= "" and vim.fn.filereadable(env) == 1 then
    return env
  end
  if main_lib then
    local derived = main_lib:gsub("libanthy", "libanthydic", 1)
    if derived ~= main_lib and vim.fn.filereadable(derived) == 1 then
      return derived
    end
  end
  return nil
end

return M
