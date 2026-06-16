-- レイテンシ PoC: IME としての応答性を測る
-- 目的: anthy_init(辞書ロード)の一回コストと、1変換あたりの所要時間を測定。
--       IME は1変換 <~30ms 程度でないと体感が悪い。
-- 実行: nvim --headless -l poc/latency_poc.lua

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
local anthy = ffi.load(LIB)

local function ms(ns) return ns / 1e6 end

-- ① anthy_init (辞書ロード) コスト
local t0 = vim.loop.hrtime()
assert(anthy.anthy_init() == 0)
local t1 = vim.loop.hrtime()
print(string.format("① anthy_init (辞書ロード一回): %.2f ms", ms(t1 - t0)))

local ctx = anthy.anthy_create_context()
anthy.anthy_context_set_encoding(ctx, 2)
local buf = ffi.new("char[1024]")

-- 1変換 = set_string + get_stat + 全文節の TOP 取得
local function convert_once(yomi)
  anthy.anthy_set_string(ctx, yomi)
  local st = ffi.new("struct anthy_conv_stat")
  anthy.anthy_get_stat(ctx, st)
  for i = 0, st.nr_segment - 1 do
    anthy.anthy_get_segment(ctx, i, 0, buf, ffi.sizeof(buf))
  end
end

-- ② 1変換のコスト (短文/中文/長文)
local samples = {
  { "短文", "きょうは" },
  { "中文", "きょうはいいてんきだね" },
  { "長文", "あめがふりそうだからかさをもっていこうとおもう" },
}
print("\n② 1変換あたり (各1000回平均):")
for _, s in ipairs(samples) do
  -- ウォームアップ
  convert_once(s[2])
  local n = 1000
  local start = vim.loop.hrtime()
  for _ = 1, n do convert_once(s[2]) end
  local elapsed = vim.loop.hrtime() - start
  print(string.format("  %s (%2d文字): %.3f ms/回", s[1], vim.fn.strchars(s[2]), ms(elapsed) / n))
end

-- ③ 候補一覧の全取得コスト (popup表示時)
print("\n③ 候補一覧の全取得 (popup表示相当):")
do
  anthy.anthy_set_string(ctx, "きょうはいいてんきだね")
  local st = ffi.new("struct anthy_conv_stat"); anthy.anthy_get_stat(ctx, st)
  local start = vim.loop.hrtime()
  local total = 0
  for i = 0, st.nr_segment - 1 do
    local ss = ffi.new("struct anthy_segment_stat")
    anthy.anthy_get_segment_stat(ctx, i, ss)
    for j = 0, ss.nr_candidate - 1 do
      anthy.anthy_get_segment(ctx, i, j, buf, ffi.sizeof(buf))
      total = total + 1
    end
  end
  print(string.format("  全文節の全候補(%d件)取得: %.3f ms", total, ms(vim.loop.hrtime() - start)))
end

anthy.anthy_release_context(ctx)
anthy.anthy_quit()

print("\n判定: 1変換 <30ms なら IME 体感は良好")
