-- 網羅的 問題発見スイープ
-- 目的: 考えられるあらゆる入力パターンを変換器/Anthy/FFI に投入し、問題を洗い出す。
-- 実行: nvim --headless -l poc/problem_sweep.lua

local romaji = dofile("poc/romaji.lua")
local to_kana = romaji.to_kana

local problems = {}
local function report(cat, detail)
  problems[#problems + 1] = string.format("[%s] %s", cat, detail)
end

----------------------------------------------------------------------
-- A. ローマ字 → かな の問題
----------------------------------------------------------------------
print("=========== A. ローマ字→かな エッジケース ===========")
-- {ローマ字, 期待(IME慣習), 備考}
local rcases = {
  { "konnichiha", "こんにちは", "ん+な行: nを1つ消費すべき" },
  { "onna", "おんな", "ん+な行" },
  { "annai", "あんない", "ん+な行" },
  { "tanni", "たんに", "ん+に" },
  { "honya", "ほんや", "ん+や(本屋)" },
  { "hon'ya", "ほんや", "アポストロフィ分離" },
  { "matcha", "まっちゃ", "tch促音" },
  { "kekka", "けっか", "促音kk" },
  { "issho", "いっしょ", "促音ss+拗音" },
  { "motto", "もっと", "促音tt" },
  { "kitte", "きって", "促音tt" },
  { "happa", "はっぱ", "促音pp" },
  { "di", "でぃ", "外来音di(modern IME)" },
  { "texi", "てぃ", "外来音texi" },
  { "ti", "てぃ", "ti=てぃ?(諸説:ち)" },
  { "va", "ゔぁ", "外来音va" },
  { "tsa", "つぁ", "外来音tsa" },
  { "che", "ちぇ", "ちぇ" },
  { "fe", "ふぇ", "ふぇ" },
  { "Kyou", "きょう", "大文字始まり(SKKは変換境界)" },
  { "KANJI", "かんじ", "全大文字" },
  { "aa", "ああ", "連続母音" },
  { "n", "ん", "単独n" },
  { "nn", "ん", "nn単独" },
  { "namba", "なんば", "ん+ば(難波)" },
  { "wo", "を", "助詞を" },
  { "3ji", "3じ", "数字混在" },
  { "a,b", "あ、 b", "記号混在(未定義)" },
}
for _, c in ipairs(rcases) do
  local got = to_kana(c[1])
  local mark = (got == c[2]) and "✅" or "✗"
  if got ~= c[2] then
    report("A:ローマ字→かな", string.format("%s -> %s (期待 %s / %s)", c[1], got, c[2], c[3]))
  end
  print(string.format("  %s %-12s -> %-10s 期待:%-10s %s", mark, c[1], got, c[2], c[3]))
end

----------------------------------------------------------------------
-- Anthy 準備
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
struct anthy_segment_stat { int nr_candidate; int seg_len; };
void anthy_get_stat(anthy_context_t, struct anthy_conv_stat *);
void anthy_get_segment_stat(anthy_context_t, int, struct anthy_segment_stat *);
int anthy_get_segment(anthy_context_t, int, int, char *, int);
]])
local anthy = ffi.load(LIB)
assert(anthy.anthy_init() == 0)
local ctx = anthy.anthy_create_context()
anthy.anthy_context_set_encoding(ctx, 2)

local function top_with_buf(yomi, bufsize)
  local buf = ffi.new("char[?]", bufsize)
  anthy.anthy_set_string(ctx, yomi)
  local st = ffi.new("struct anthy_conv_stat")
  anthy.anthy_get_stat(ctx, st)
  local segs = {}
  local truncated = false
  for i = 0, st.nr_segment - 1 do
    local need = anthy.anthy_get_segment(ctx, i, 0, nil, 0) -- 必要バイト数
    anthy.anthy_get_segment(ctx, i, 0, buf, bufsize)
    if need >= bufsize then truncated = true end
    segs[#segs + 1] = ffi.string(buf)
  end
  return st.nr_segment, table.concat(segs), truncated
end

----------------------------------------------------------------------
-- B. Anthy 変換 エッジケース
----------------------------------------------------------------------
print("\n=========== B. Anthy 変換 エッジケース ===========")
local bcases = {
  { "", "空文字列" },
  { "あ", "1文字" },
  { "ん", "撥音のみ" },
  { "っ", "促音のみ" },
  { "123", "半角数字" },
  { "abc", "英字をそのまま投入" },
  { "あabcい", "かな英字混在" },
  { "aaaaaaaaaa", "ASCII連続" },
  { "ーーー", "長音のみ" },
  { "、。！？", "記号のみ" },
  { "ゔぁいおりん", "外来音(ゔ)を含む読み" },
}
for _, c in ipairs(bcases) do
  local ok, nseg, top = pcall(top_with_buf, c[1], 1024)
  if not ok then
    report("B:Anthy", string.format("%q でクラッシュ: %s", c[1], tostring(nseg)))
    print(string.format("  ✗ %-14q CRASH: %s", c[1], tostring(nseg)))
  else
    print(string.format("  ・%-14q segs=%d -> %s", c[1], nseg, top))
  end
end

----------------------------------------------------------------------
-- C. FFI / 堅牢性
----------------------------------------------------------------------
print("\n=========== C. FFI / 堅牢性 ===========")

-- C1: 超長文 (バッファ長超過の可能性)
do
  local long = string.rep("あいうえお", 200) -- 1000かな=3000byte
  local ok, nseg, _, truncated = pcall(top_with_buf, long, 256)
  if ok then
    print(string.format("  C1 超長文(1000かな) bufsize=256: segs=%d, 切り詰め=%s", nseg, tostring(truncated)))
    if truncated then
      report("C:FFI", "文節がバッファ長(256)を超えると切り詰められる→必要長を取得して動的確保が必要")
    end
  else
    report("C:FFI", "超長文でクラッシュ: " .. tostring(nseg))
    print("  C1 超長文 CRASH: " .. tostring(nseg))
  end
end

-- C2: anthy_get_segment(nil,0) で必要バイト長が取れるか
do
  anthy.anthy_set_string(ctx, "へんかん")
  local need = anthy.anthy_get_segment(ctx, 0, 0, nil, 0)
  print(string.format("  C2 必要バイト長取得 anthy_get_segment(...,nil,0) = %d", need))
  if need <= 0 then
    report("C:FFI", "必要バイト長の事前取得ができない(動的確保の作法に影響)")
  end
end

-- C3: 範囲外セグメント/候補アクセス
do
  anthy.anthy_set_string(ctx, "へんかん")
  local buf = ffi.new("char[256]")
  local ok = pcall(function()
    anthy.anthy_get_segment(ctx, 999, 999, buf, 256) -- 範囲外
  end)
  print(string.format("  C3 範囲外アクセス(seg=999,cand=999): %s", ok and "クラッシュせず" or "クラッシュ"))
  if not ok then
    report("C:FFI", "範囲外セグメント/候補アクセスでクラッシュ→呼び出し側で境界チェック必須")
  end
end

-- C4: 同一contextの連続set_string(状態リセット)
do
  anthy.anthy_set_string(ctx, "あめ")
  local s1 = ffi.new("struct anthy_conv_stat"); anthy.anthy_get_stat(ctx, s1)
  anthy.anthy_set_string(ctx, "きょうはいいてんきだね")
  local s2 = ffi.new("struct anthy_conv_stat"); anthy.anthy_get_stat(ctx, s2)
  print(string.format("  C4 context再利用: 1回目seg=%d -> 2回目seg=%d (リセットされるか)", s1.nr_segment, s2.nr_segment))
  if s2.nr_segment < 2 then
    report("C:FFI", "set_string で前回状態がリセットされない可能性")
  end
end

anthy.anthy_release_context(ctx)
anthy.anthy_quit()

----------------------------------------------------------------------
-- 問題サマリ
----------------------------------------------------------------------
print("\n=========== 洗い出した問題サマリ ===========")
if #problems == 0 then
  print("  (自動検出された問題なし)")
else
  for i, p in ipairs(problems) do
    print(string.format("  %d. %s", i, p))
  end
end
