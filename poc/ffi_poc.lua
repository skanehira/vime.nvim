-- Neovim 実機 LuaJIT FFI 疎通 PoC
-- 目的: Neovim 内の LuaJIT FFI から libanthy を直叩きし、
--       C PoC と同じ連文節変換・候補取得が得られるかを検証する。
-- 実行: nvim --headless -l poc/ffi_poc.lua

local ffi = require("ffi")

local LIB = "/nix/store/m2z37mlz9rsh2azv9pny1860rpycic54-anthy-9100h/lib/libanthy.dylib"

ffi.cdef([[
typedef void *anthy_context_t;
int anthy_init(void);
void anthy_quit(void);
anthy_context_t anthy_create_context(void);
void anthy_release_context(anthy_context_t);
int anthy_context_set_encoding(anthy_context_t, int);
int anthy_set_string(anthy_context_t, const char *);
struct anthy_conv_stat { int nr_segment; };
struct anthy_segment_stat { int nr_candidate; int seg_len; };
void anthy_get_stat(anthy_context_t, struct anthy_conv_stat *);
void anthy_get_segment_stat(anthy_context_t, int, struct anthy_segment_stat *);
int anthy_get_segment(anthy_context_t, int, int, char *, int);
]])

local ANTHY_UTF8_ENCODING = 2

local anthy = ffi.load(LIB)

local rc = anthy.anthy_init()
print(string.format("anthy_init rc=%d", rc))
if rc ~= 0 then
  print("anthy_init failed")
  return
end

local ctx = anthy.anthy_create_context()
if ctx == nil then
  print("create_context failed")
  return
end

anthy.anthy_context_set_encoding(ctx, ANTHY_UTF8_ENCODING)

local yomi = "きょうはいいてんきだね"
anthy.anthy_set_string(ctx, yomi)

local st = ffi.new("struct anthy_conv_stat")
anthy.anthy_get_stat(ctx, st)
print(string.format("yomi=%s", yomi))
print(string.format("segments=%d", st.nr_segment))

local buf = ffi.new("char[256]")
local top = {}
for i = 0, st.nr_segment - 1 do
  local ss = ffi.new("struct anthy_segment_stat")
  anthy.anthy_get_segment_stat(ctx, i, ss)
  anthy.anthy_get_segment(ctx, i, 0, buf, ffi.sizeof(buf))
  local best = ffi.string(buf)
  print(string.format("seg[%d] cands=%d : %s", i, ss.nr_candidate, best))
  for j = 1, math.min(ss.nr_candidate - 1, 3) do
    anthy.anthy_get_segment(ctx, i, j, buf, ffi.sizeof(buf))
    print(string.format("      alt[%d]=%s", j, ffi.string(buf)))
  end
  top[#top + 1] = best
end

print("TOP=" .. table.concat(top))

anthy.anthy_release_context(ctx)
anthy.anthy_quit()
