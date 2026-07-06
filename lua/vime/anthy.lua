-- libanthy FFI ラッパ。副作用(FFI / ~/.anthy 学習・私的辞書)をこのモジュールに閉じ込める。
-- 公開 index は Lua 慣習で 1-based。内部で 0-based へ変換して anthy へ渡す。
local ffi = require("ffi")
local config = require("vime.config")

local M = {}

local ANTHY_UTF8_ENCODING = 2
-- anthy_get_segment の第3引数(nth)に渡すと未変換の元読み(yomi)を取得する特殊値。
local NTH_UNCONVERTED_CANDIDATE = -1
-- 私的辞書へ登録する単語の品詞(名詞)と頻度。名詞固定で取り込む。
local DIC_WTYPE = "#T35"
local DIC_FREQ = 1000

local cdef_done = false
local function ensure_cdef()
  if cdef_done then
    return
  end
  ffi.cdef([[
    typedef void *anthy_context_t;
    int anthy_init(void);
    anthy_context_t anthy_create_context(void);
    void anthy_release_context(anthy_context_t);
    int anthy_context_set_encoding(anthy_context_t, int);
    int anthy_set_string(anthy_context_t, const char *);
    struct anthy_conv_stat { int nr_segment; };
    struct anthy_segment_stat { int nr_candidate; int seg_len; };
    void anthy_get_stat(anthy_context_t, struct anthy_conv_stat *);
    void anthy_get_segment_stat(anthy_context_t, int, struct anthy_segment_stat *);
    int anthy_get_segment(anthy_context_t, int, int, char *, int);
    int anthy_resize_segment(anthy_context_t, int, int);
    int anthy_commit_segment(anthy_context_t, int, int);
    void anthy_dic_util_init(void);
    int anthy_dic_util_set_encoding(int);
    int anthy_priv_dic_add_entry(const char *, const char *, const char *, int);
  ]])
  cdef_done = true
end

local lib = nil
local lib_path = nil
local initialized = false
-- 辞書登録ライブラリ(libanthydic)の状態。nil=未試行 / true/false=解決結果。
local dic_lib = nil
local dic_ready = nil

-- ライブラリをロードし anthy を初期化する。成功で true。失敗でも例外を投げず false。
function M.setup(path)
  ensure_cdef()
  local ok, loaded = pcall(ffi.load, path)
  if not ok then
    lib = nil
    return false
  end
  if not initialized then
    ---@diagnostic disable-next-line: undefined-field
    if loaded.anthy_init() ~= 0 then
      lib = nil
      return false
    end
    initialized = true
  end
  if lib_path ~= path then -- lib が変わったら dic の解決をやり直す
    dic_lib = nil
    dic_ready = nil
  end
  lib = loaded
  lib_path = path
  return true
end

-- 辞書登録 API を持つライブラリを用意する。成功で true。失敗でも例外を投げず false。
-- 本体 lib が dic シンボルを持てばそれを使い、無ければ libanthydic を別ロードする。
local function ensure_dic()
  if dic_ready ~= nil then
    return dic_ready
  end
  dic_ready = false
  if not lib then
    return false
  end
  local cand = lib
  if not pcall(function()
    return cand.anthy_dic_util_init
  end) then
    local path = config.find_anthy_dic_lib(lib_path)
    if not path then
      return false
    end
    local ok, loaded = pcall(ffi.load, path)
    if not ok then
      return false
    end
    cand = loaded
  end
  if
    not pcall(function()
      cand.anthy_dic_util_init()
      cand.anthy_dic_util_set_encoding(ANTHY_UTF8_ENCODING)
    end)
  then
    return false
  end
  dic_lib = cand
  dic_ready = true
  return true
end

-- 読み(かな)→単語を私的辞書へ名詞として登録する。成功で true。失敗でも例外を投げず false。
function M.register_word(yomi, word)
  if not ensure_dic() then
    return false
  end
  return pcall(function()
    dic_lib.anthy_priv_dic_add_entry(yomi, word, DIC_WTYPE, DIC_FREQ)
  end)
end

-- 変換が読む私的辞書 private_words_default のパスを返す。setup 済みが前提。失敗で nil。
-- anthy-unicode は $XDG_CONFIG_HOME/anthy(未設定なら ~/.config/anthy)、原 anthy は ~/.anthy。
-- 大量取り込みは per-entry API ではなくこのファイルを直接生成する(CLI から使用)。
function M.private_dic_path()
  if not lib_path then
    return nil
  end
  local home = vim.uv.os_homedir()
  if not home or home == "" then
    return nil
  end
  if lib_path:find("unicode", 1, true) then
    local xdg = vim.env.XDG_CONFIG_HOME
    local base = (xdg and xdg ~= "") and xdg or (home .. "/.config")
    return base .. "/anthy/private_words_default"
  end
  return home .. "/.anthy/private_words_default"
end

-- 現在の context から全文節の {best, candidates, len} を読み出す。len は文節の読み文字数。
local function read_segments(l, ctx)
  local st = ffi.new("struct anthy_conv_stat")
  l.anthy_get_stat(ctx, st)
  local segs = {}
  for i = 0, st.nr_segment - 1 do
    local ss = ffi.new("struct anthy_segment_stat")
    l.anthy_get_segment_stat(ctx, i, ss)
    local cands = {}
    for j = 0, ss.nr_candidate - 1 do
      local need = l.anthy_get_segment(ctx, i, j, nil, 0) -- 必要 byte 長
      local buf = ffi.new("char[?]", need + 1)
      l.anthy_get_segment(ctx, i, j, buf, need + 1)
      cands[#cands + 1] = ffi.string(buf)
    end
    segs[#segs + 1] = { best = cands[1], candidates = cands, len = ss.seg_len }
  end
  return segs
end

local Session = {}
Session.__index = Session

-- 新しい変換セッション(anthy context)を作る。setup 成功が前提。
function M.new_session()
  local l = assert(lib, "vime.anthy: setup() を先に成功させること")
  local ctx = l.anthy_create_context()
  l.anthy_context_set_encoding(ctx, ANTHY_UTF8_ENCODING)
  return setmetatable({ ctx = ctx, lib = l }, Session)
end

-- 読み(かな)を変換し、文節配列を返す。
function Session:convert(yomi)
  self.lib.anthy_set_string(self.ctx, yomi)
  return read_segments(self.lib, self.ctx)
end

-- 第 seg 文節(1-based)を delta(+1伸長/-1短縮)し、再構成した文節配列を返す。
function Session:resize(seg, delta)
  self.lib.anthy_resize_segment(self.ctx, seg - 1, delta)
  return read_segments(self.lib, self.ctx)
end

-- 各文節の選択候補(1-based index 配列)で確定する。全文節 commit で学習される。
function Session:commit(choices)
  for i, cand in ipairs(choices) do
    self.lib.anthy_commit_segment(self.ctx, i - 1, cand - 1)
  end
end

-- 第 seg 文節(1-based)の元読み(yomi)を返す。convert 済みであることが前提。
function Session:segment_yomi(seg)
  local need = self.lib.anthy_get_segment(self.ctx, seg - 1, NTH_UNCONVERTED_CANDIDATE, nil, 0)
  local buf = ffi.new("char[?]", need + 1)
  self.lib.anthy_get_segment(self.ctx, seg - 1, NTH_UNCONVERTED_CANDIDATE, buf, need + 1)
  return ffi.string(buf)
end

-- context を解放する。
function Session:close()
  self.lib.anthy_release_context(self.ctx)
  self.ctx = nil
end

return M
