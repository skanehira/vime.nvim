-- 変換タイミング比較 PoC: 「一括変換」 vs 「ユーザー分割変換(IME的)」
-- 目的: kyouha / iitennki / dane のようにユーザーが文節を区切って逐次変換する方式が
--       実用上問題ないか(精度が落ちないか / 区切りミスが消えるか)を実測で比較する。
-- 実行: nvim --headless -l poc/ffi_chunk_poc.lua

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
assert(anthy.anthy_init() == 0, "anthy_init failed")
local ctx = anthy.anthy_create_context()
anthy.anthy_context_set_encoding(ctx, ANTHY_UTF8_ENCODING)
local buf = ffi.new("char[1024]")

local function convert(yomi)
  anthy.anthy_set_string(ctx, yomi)
  local st = ffi.new("struct anthy_conv_stat")
  anthy.anthy_get_stat(ctx, st)
  local segs, allcands = {}, {}
  for i = 0, st.nr_segment - 1 do
    local ss = ffi.new("struct anthy_segment_stat")
    anthy.anthy_get_segment_stat(ctx, i, ss)
    local cands = {}
    for j = 0, ss.nr_candidate - 1 do
      anthy.anthy_get_segment(ctx, i, j, buf, ffi.sizeof(buf))
      cands[#cands + 1] = ffi.string(buf)
    end
    segs[#segs + 1] = cands[1]
    allcands[i + 1] = cands
  end
  return segs, allcands, table.concat(segs)
end

-- expected が現区切りのまま候補選択で到達可能か(全候補を貪欲前方一致)
local function reachable(allcands, segs, expected)
  local rest = expected
  for i = 1, #segs do
    local matched = false
    for _, c in ipairs(allcands[i]) do
      if c ~= "" and rest:sub(1, #c) == c then
        rest = rest:sub(#c + 1)
        matched = true
        break
      end
    end
    if not matched then return false end
  end
  return rest == ""
end

local function mark(exact, reach)
  return exact and "✅" or (reach and "△" or "✗")
end

-- 各ケース: { ラベル, { {chunk読み, chunk期待}, ... } }
-- ユーザーが区切るであろう文節単位を chunk とする。
local cases = {
  { "今日はいい天気だね", { { "きょうは", "今日は" }, { "いいてんき", "いい天気" }, { "だね", "だね" } } },
  { "電車に乗ってお出かけする(一括ではresize必要)",
    { { "でんしゃに", "電車に" }, { "のって", "乗って" }, { "おでかけする", "お出かけする" } } },
  { "雨が降ったので傘をさした(一括ではresize必要)",
    { { "あめが", "雨が" }, { "ふったので", "降ったので" }, { "かさを", "傘を" }, { "さした", "さした" } } },
  { "雨が降りそうだから傘を持っていこう(一括ではresize必要)",
    { { "あめが", "雨が" }, { "ふりそうだから", "降りそうだから" }, { "かさを", "傘を" }, { "もっていこう", "持っていこう" } } },
  { "漢字変換の精度を検証する",
    { { "かんじへんかんの", "漢字変換の" }, { "せいどを", "精度を" }, { "けんしょうする", "検証する" } } },
  { "記者の汽車が貴社で帰社した(同音異義4連)",
    { { "きしゃの", "記者の" }, { "きしゃが", "汽車が" }, { "きしゃで", "貴社で" }, { "きしゃした", "帰社した" } } },
  { "彼女は美しい人だ(一括では日とだ)",
    { { "かのじょは", "彼女は" }, { "うつくしい", "美しい" }, { "ひとだ", "人だ" } } },
  { "このコードはバグが多い(一括では子の)",
    { { "この", "この" }, { "こーどは", "コードは" }, { "ばぐが", "バグが" }, { "おおい", "多い" } } },
  { "今年の夏は暑い",
    { { "ことしの", "今年の" }, { "なつは", "夏は" }, { "あつい", "暑い" } } },
  { "体温を測る",
    { { "たいおんを", "体温を" }, { "はかる", "測る" } } },
  { "日本語の入力は難しい",
    { { "にほんごの", "日本語の" }, { "にゅうりょくは", "入力は" }, { "むずかしい", "難しい" } } },
}

local tot = 0
local whole_exact, whole_reach = 0, 0
local chunk_exact, chunk_reach = 0, 0

print("=========== 一括変換 vs ユーザー分割変換 (IME的) ===========")
for _, case in ipairs(cases) do
  local label, chunks = case[1], case[2]
  tot = tot + 1

  -- 一括: chunk読みを連結して一気に変換
  local whole_yomi, whole_expected = "", ""
  for _, ch in ipairs(chunks) do
    whole_yomi = whole_yomi .. ch[1]
    whole_expected = whole_expected .. ch[2]
  end
  local wsegs, wcands, wtop = convert(whole_yomi)
  local we = (wtop == whole_expected)
  local wr = we or reachable(wcands, wsegs, whole_expected)
  if we then whole_exact = whole_exact + 1 end
  if wr then whole_reach = whole_reach + 1 end

  -- 分割: 各 chunk を個別に変換し連結
  local ctops, c_all_exact, c_all_reach = {}, true, true
  for _, ch in ipairs(chunks) do
    local csegs, ccands, ctop = convert(ch[1])
    local ce = (ctop == ch[2])
    local cr = ce or reachable(ccands, csegs, ch[2])
    if not ce then c_all_exact = false end
    if not cr then c_all_reach = false end
    ctops[#ctops + 1] = ctop .. (ce and "" or (cr and "△" or "✗"))
  end
  if c_all_exact then chunk_exact = chunk_exact + 1 end
  if c_all_reach then chunk_reach = chunk_reach + 1 end

  print(string.format("\n■ %s", label))
  print(string.format("  期待   : %s", whole_expected))
  print(string.format("  一括 %s : %s", mark(we, wr), wtop))
  print(string.format("  分割 %s : %s", mark(c_all_exact, c_all_reach), table.concat(ctops, " | ")))
end

print("\n=========== サマリ ===========")
print(string.format("一括変換  TOP一発: %d/%d (%.0f%%) / 候補選択到達: %d/%d (%.0f%%)",
  whole_exact, tot, whole_exact / tot * 100, whole_reach, tot, whole_reach / tot * 100))
print(string.format("分割変換  TOP一発: %d/%d (%.0f%%) / 候補選択到達: %d/%d (%.0f%%)",
  chunk_exact, tot, chunk_exact / tot * 100, chunk_reach, tot, chunk_reach / tot * 100))
print("\n注: 分割の各文節の ✅省略/△候補選択/✗到達不可 は文節末尾の記号で表示")

anthy.anthy_release_context(ctx)
anthy.anthy_quit()
