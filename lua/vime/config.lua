-- 設定。デフォルトとユーザー設定をマージし、anthy ライブラリのパスを解決する。
local M = {}

M.defaults = {
  anthy = {
    lib = nil, -- 未指定なら既知パスを探索
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
    vim.fn.expand("~/.local/lib"),       -- ソースビルド(--prefix=$HOME/.local)
    vim.fn.expand("~/.nix-profile/lib"), -- nix profile install
    "/run/current-system/sw/lib",        -- nix-darwin / NixOS
    "/opt/homebrew/lib",                 -- macOS Homebrew
    "/usr/local/lib",                    -- ソースビルド既定(prefix=/usr/local)
    "/usr/lib",                          -- 一般
    "/usr/lib64",                        -- Fedora
    "/usr/lib/x86_64-linux-gnu",         -- Debian/Ubuntu amd64
    "/usr/lib/aarch64-linux-gnu",        -- Debian/Ubuntu arm64
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

return M
