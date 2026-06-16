-- ローマ字→かな 変換 PoC (+ end-to-end: ローマ字→かな→Anthy→漢字)
-- 目的: ①ローマ字→かな(拗音/促音/撥音/外来音)の精度を測る。
--       さらに kyouhaiitenkidane → 今日は… まで end-to-end で通るか検証する。
-- 実行: nvim --headless -l poc/romaji_poc.lua

local to_kana = dofile("poc/romaji.lua").to_kana

----------------------------------------------------------------------
-- ① かな精度テスト
----------------------------------------------------------------------
local kana_cases = {
  { "kyou", "きょう" },
  { "iitenki", "いいてんき" },
  { "iitennki", "いいてんき" },
  { "dane", "だね" },
  { "kanji", "かんじ" },
  { "gakkou", "がっこう" },
  { "matte", "まって" },
  { "chotto", "ちょっと" },
  { "kippu", "きっぷ" },
  { "shinbun", "しんぶん" },
  { "kon'nichiha", "こんにちは" },
  { "konnichiha", "こんにちは" },
  { "jugyou", "じゅぎょう" },
  { "tukatte", "つかって" },
  { "fairu", "ふぁいる" },
  { "puroguramingu", "ぷろぐらみんぐ" },
  { "watashihagakuseidesu", "わたしはがくせいです" },
  { "kyouhaiitenkidane", "きょうはいいてんきだね" },
}

print("=========== ① ローマ字→かな 精度 ===========")
local ok = 0
for _, c in ipairs(kana_cases) do
  local got = to_kana(c[1])
  local mark = (got == c[2]) and "✅" or "✗"
  if got == c[2] then ok = ok + 1 end
  print(string.format("  %s %-22s -> %s  (期待: %s)", mark, c[1], got, c[2]))
end
print(string.format("  かな変換 正解: %d/%d", ok, #kana_cases))

----------------------------------------------------------------------
-- ② end-to-end: ローマ字 → かな → Anthy → 漢字
----------------------------------------------------------------------
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
void anthy_get_stat(anthy_context_t, struct anthy_conv_stat *);
int anthy_get_segment(anthy_context_t, int, int, char *, int);
]])
local anthy = ffi.load(LIB)
assert(anthy.anthy_init() == 0)
local ctx = anthy.anthy_create_context()
anthy.anthy_context_set_encoding(ctx, 2)
local buf = ffi.new("char[1024]")

local function anthy_top(yomi)
  anthy.anthy_set_string(ctx, yomi)
  local st = ffi.new("struct anthy_conv_stat")
  anthy.anthy_get_stat(ctx, st)
  local segs = {}
  for i = 0, st.nr_segment - 1 do
    anthy.anthy_get_segment(ctx, i, 0, buf, ffi.sizeof(buf))
    segs[#segs + 1] = ffi.string(buf)
  end
  return table.concat(segs)
end

local e2e = {
  "kyouhaiitenkidane",
  "watashihagakuseidesu",
  "kanjihenkannoseidowokenshousuru",
  "denshaninotteodekakesuru",
  "kyoutoniittemitai",
}

print("\n=========== ② end-to-end: ローマ字→かな→Anthy→漢字 ===========")
for _, romaji in ipairs(e2e) do
  local kana = to_kana(romaji)
  local kanji = anthy_top(kana)
  print(string.format("  %s\n    -> かな: %s\n    -> 変換: %s\n", romaji, kana, kanji))
end

anthy.anthy_release_context(ctx)
anthy.anthy_quit()
