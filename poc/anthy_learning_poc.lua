-- Anthy 学習(commit_segment)の深掘り PoC
-- 目的: 学習が実際に変換結果を矯正できるのか/条件は何かを確定する。
--   - 1回commit / 全文節commit / 反復commit で TOP が変わるかを比較。
-- 実行: nvim --headless -l poc/anthy_learning_poc.lua

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
int anthy_commit_segment(anthy_context_t, int, int);
]])
local anthy = ffi.load(LIB)
assert(anthy.anthy_init() == 0)
local buf = ffi.new("char[1024]")

local function new_ctx()
  local c = anthy.anthy_create_context()
  anthy.anthy_context_set_encoding(c, 2)
  return c
end

local function segs(ctx)
  local st = ffi.new("struct anthy_conv_stat")
  anthy.anthy_get_stat(ctx, st)
  local r = {}
  for i = 0, st.nr_segment - 1 do
    anthy.anthy_get_segment(ctx, i, 0, buf, ffi.sizeof(buf))
    r[#r + 1] = ffi.string(buf)
  end
  return r, st.nr_segment
end

local function find_cand(ctx, nth, target)
  local ss = ffi.new("struct anthy_segment_stat")
  anthy.anthy_get_segment_stat(ctx, nth, ss)
  for j = 0, ss.nr_candidate - 1 do
    anthy.anthy_get_segment(ctx, nth, j, buf, ffi.sizeof(buf))
    if ffi.string(buf) == target then return j end
  end
  return -1
end

local YOMI = "このこーどはばぐがおおい"
local WANT = { "この", "コードは", "バグが", "多い" }

-- 全文節を希望候補で commit する1サイクル
local function commit_all(ctx)
  anthy.anthy_set_string(ctx, YOMI)
  local _, n = segs(ctx)
  for i = 0, n - 1 do
    local want = WANT[i + 1]
    local j = want and find_cand(ctx, i, want) or 0
    if j < 0 then j = 0 end
    anthy.anthy_commit_segment(ctx, i, j)
  end
end

print("=========== 学習サイクル別の TOP 変化 ===========")
print("  目標: 文頭「この」が「子の」にならないこと\n")

-- (a) 学習なし
do
  local ctx = new_ctx()
  anthy.anthy_set_string(ctx, YOMI)
  print("  (a) 学習なし          : " .. table.concat(segs(ctx), " | "))
  anthy.anthy_release_context(ctx)
end

-- (b) 全文節を1回commit → 同contextで再変換
do
  local ctx = new_ctx()
  commit_all(ctx)
  anthy.anthy_set_string(ctx, YOMI)
  print("  (b) 全文節1回commit後 : " .. table.concat(segs(ctx), " | "))
  anthy.anthy_release_context(ctx)
end

-- (c) 全文節commitを5回反復 → 同contextで再変換
do
  local ctx = new_ctx()
  for _ = 1, 5 do commit_all(ctx) end
  anthy.anthy_set_string(ctx, YOMI)
  print("  (c) 全文節5回commit後 : " .. table.concat(segs(ctx), " | "))
  anthy.anthy_release_context(ctx)
end

-- (d) 学習が永続化され新しいcontextでも効くか
do
  local ctx = new_ctx()
  anthy.anthy_set_string(ctx, YOMI)
  print("  (d) 別contextで再確認 : " .. table.concat(segs(ctx), " | "))
  anthy.anthy_release_context(ctx)
end

anthy.anthy_quit()
