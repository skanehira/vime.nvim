-- libanthy FFI ラッパ。副作用(FFI / ~/.anthy 学習)をこのモジュールに閉じ込める。
-- 公開 index は Lua 慣習で 1-based。内部で 0-based へ変換して anthy へ渡す。
local ffi = require("ffi")

local M = {}

local ANTHY_UTF8_ENCODING = 2

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
  ]])
  cdef_done = true
end

local lib = nil
local initialized = false

-- ライブラリをロードし anthy を初期化する。成功で true。失敗でも例外を投げず false。
function M.setup(lib_path)
  ensure_cdef()
  local ok, loaded = pcall(ffi.load, lib_path)
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
  lib = loaded
  return true
end

-- 現在の context から全文節の {best, candidates} を読み出す。
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
    segs[#segs + 1] = { best = cands[1], candidates = cands }
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

-- context を解放する。
function Session:close()
  self.lib.anthy_release_context(self.ctx)
  self.ctx = nil
end

return M
