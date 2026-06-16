-- Anthy 上級API PoC: 文節伸縮(resize_segment) と 学習(commit_segment)
-- 目的: 残課題の2機能を実コードで検証する。
--   ① resize_segment: 「電車|仁野って」の区切りミスを伸縮で直せるか
--   ② commit_segment: 「この→子の」等の誤りを学習で矯正できるか
-- 実行: nvim --headless -l poc/anthy_advanced_poc.lua

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
int anthy_resize_segment(anthy_context_t, int, int);
int anthy_commit_segment(anthy_context_t, int, int);
]])
local anthy = ffi.load(LIB)
assert(anthy.anthy_init() == 0)
local ctx = anthy.anthy_create_context()
anthy.anthy_context_set_encoding(ctx, 2)
local buf = ffi.new("char[1024]")

local function seg_best(i)
  anthy.anthy_get_segment(ctx, i, 0, buf, ffi.sizeof(buf))
  return ffi.string(buf)
end

local function segments()
  local st = ffi.new("struct anthy_conv_stat")
  anthy.anthy_get_stat(ctx, st)
  local segs = {}
  for i = 0, st.nr_segment - 1 do
    segs[#segs + 1] = seg_best(i)
  end
  return segs
end

-- nth文節で yomi/表記 が target に一致する候補indexを探す
local function find_cand(nth, target)
  local ss = ffi.new("struct anthy_segment_stat")
  anthy.anthy_get_segment_stat(ctx, nth, ss)
  for j = 0, ss.nr_candidate - 1 do
    anthy.anthy_get_segment(ctx, nth, j, buf, ffi.sizeof(buf))
    if ffi.string(buf) == target then return j end
  end
  return -1
end

----------------------------------------------------------------------
-- ① resize_segment: 文節伸縮で区切りミスを直す
----------------------------------------------------------------------
print("=========== ① resize_segment 文節伸縮 ===========")
anthy.anthy_set_string(ctx, "でんしゃにのっておでかけする")
print("  伸縮前: " .. table.concat(segments(), " | "))

-- 第0文節「電車(でんしゃ)」を +1 伸ばして「でんしゃに」にする
anthy.anthy_resize_segment(ctx, 0, 1)
print("  seg0を+1伸長後: " .. table.concat(segments(), " | "))

----------------------------------------------------------------------
-- ② commit_segment: 学習で誤変換を矯正する
----------------------------------------------------------------------
print("\n=========== ② commit_segment 学習 ===========")
local YOMI = "このこーどはばぐがおおい"

anthy.anthy_set_string(ctx, YOMI)
print("  学習前 TOP: " .. table.concat(segments(), " | "))

-- 第0文節で「この」(ひらがな)の候補indexを探して確定(=学習)
local idx = find_cand(0, "この")
print(string.format("  seg0 の「この」候補index = %d", idx))
if idx >= 0 then
  anthy.anthy_commit_segment(ctx, 0, idx)
  print("  → seg0を「この」で commit (学習)")
end

-- 同じ読みを再変換して TOP が変わるか
anthy.anthy_set_string(ctx, YOMI)
print("  学習後 TOP: " .. table.concat(segments(), " | "))

-- 学習が別の同型文にも効くか(文頭のこの)
anthy.anthy_set_string(ctx, "このひとはやさしい")
print("  別文「このひとはやさしい」: " .. table.concat(segments(), " | "))

anthy.anthy_release_context(ctx)
anthy.anthy_quit()
