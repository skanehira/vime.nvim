-- Anthy 変換精度 検証 PoC (多パターン)
-- 目的: 実用ケース 20+ パターンで Anthy の連文節変換精度を測り、
--       「実用精度重視」の前提が成り立つかを判断する。
-- 実行: nvim --headless -l poc/ffi_quality_poc.lua

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
assert(ctx ~= nil, "create_context failed")
anthy.anthy_context_set_encoding(ctx, ANTHY_UTF8_ENCODING)

local buf = ffi.new("char[1024]")

-- 1つの読みを変換し、segs(各文節best), allcands(各文節の全候補), top を返す。
-- 表示用 alts は別途上位4件だけ取り出す。
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

-- expected が「現在の文節区切りのまま」候補選択だけで到達可能かを判定。
-- 各文節の全候補から expected を前方一致で貪欲に消費する。
-- ここで失敗する = 文節区切り自体が誤り = 文節伸縮(resize)が必要、と切り分けられる。
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
    if not matched then
      return false
    end
  end
  return rest == ""
end

-- 検証パターン: {読み, 期待する変換}
local cases = {
  { "きょうはいいてんきだね", "今日はいい天気だね" },
  { "わたしはがくせいです", "私は学生です" },
  { "きしゃのきしゃがきしゃできしゃした", "記者の汽車が貴社で帰社した" },
  { "にほんごのにゅうりょくはむずかしい", "日本語の入力は難しい" },
  { "あしたはあめがふるでしょう", "明日は雨が降るでしょう" },
  { "ぷろぐらみんぐをべんきょうする", "プログラミングを勉強する" },
  { "やまだたろうさんとあいました", "山田太郎さんと会いました" },
  { "かれはとうきょうだいがくにかよっている", "彼は東京大学に通っている" },
  { "でんしゃにのっておでかけする", "電車に乗ってお出かけする" },
  { "ごじゅうおくえんをかせぐ", "五十億円を稼ぐ" },
  { "すうがくのもんだいをとく", "数学の問題を解く" },
  { "かんじへんかんのせいどをけんしょうする", "漢字変換の精度を検証する" },
  { "はしのうえをはしってわたる", "橋の上を走って渡る" },
  { "かのじょはうつくしいひとだ", "彼女は美しい人だ" },
  { "しごとがおわったらかえる", "仕事が終わったら帰る" },
  { "あめがふったのでかさをさした", "雨が降ったので傘をさした" },
  { "このぷろじぇくとはせいこうした", "このプロジェクトは成功した" },
  { "にちようびはやすみです", "日曜日は休みです" },
  { "きょうとにいってみたい", "京都に行ってみたい" },
  { "せんせいにしつもんがあります", "先生に質問があります" },
  { "ばぐをしゅうせいしてりりーすする", "バグを修正してリリースする" },
  { "あたらしいきのうをついかした", "新しい機能を追加した" },
  -- ビジネス・敬語
  { "おせわになっております", "お世話になっております" },
  { "よろしくおねがいします", "よろしくお願いします" },
  { "かいぎはじゅうじからです", "会議は十時からです" },
  { "しりょうをそうふします", "資料を送付します" },
  { "ごかくにんおねがいします", "ご確認お願いします" },
  -- 口語・カジュアル
  { "それめっちゃいいね", "それめっちゃいいね" },
  { "やっぱりそうだよね", "やっぱりそうだよね" },
  { "ちょっとまってね", "ちょっと待ってね" },
  -- 日付・数字
  { "にせんにじゅうろくねんろくがつ", "二千二十六年六月" },
  { "さんじはんにあいましょう", "三時半に会いましょう" },
  { "ひゃくにじゅうさんえん", "百二十三円" },
  -- 同訓異字
  { "みずがあつい", "水が熱い" },
  { "たいおんをはかる", "体温を測る" },
  { "おんがくをきく", "音楽を聞く" },
  { "ことしのなつはあつい", "今年の夏は暑い" },
  -- 技術・外来語多め
  { "でーたべーすにせつぞくする", "データベースに接続する" },
  { "さーばーをさいきどうする", "サーバーを再起動する" },
  { "このこーどはばぐがおおい", "このコードはバグが多い" },
  -- 長文
  { "あめがふりそうだからかさをもっていこう", "雨が降りそうだから傘を持っていこう" },
  { "かれがいったことはほんとうだとおもう", "彼が言ったことは本当だと思う" },
  -- 活用・否定・受身
  { "それはたべられない", "それは食べられない" },
  { "いかなければならない", "行かなければならない" },
}

local n_exact, n_reach, n_total = 0, 0, #cases

print("================ Anthy 変換精度 検証 ================")
for idx, case in ipairs(cases) do
  local yomi, expected = case[1], case[2]
  local segs, allcands, top = convert(yomi)
  local exact = (top == expected)
  local reach = exact or reachable(allcands, segs, expected)
  if exact then
    n_exact = n_exact + 1
  end
  if reach then
    n_reach = n_reach + 1
  end
  -- exact=TOP一発, reach=候補選択のみで到達, それ以外=文節伸縮が必要
  local mark = exact and "✅TOP一発" or (reach and "△候補選択で到達" or "✗文節伸縮が必要")
  print(string.format("\n[%02d] %s", idx, yomi))
  print(string.format("     TOP     = %s", top))
  print(string.format("     expected= %s   %s", expected, mark))
  print(string.format("     文節     = %s", table.concat(segs, " | ")))
  if not exact then
    -- 差分判断用に各文節の候補(上位5件)を表示
    for i = 1, #segs do
      local show = {}
      for j = 2, math.min(#allcands[i], 6) do
        show[#show + 1] = allcands[i][j]
      end
      if #show > 0 then
        print(string.format("       seg[%d] %s (全%d候補)  alts: %s",
          i - 1, segs[i], #allcands[i], table.concat(show, " / ")))
      end
    end
  end
end

print("\n================ サマリ ================")
print(string.format("TOP一発で正解        : %d/%d (%.0f%%)", n_exact, n_total, n_exact / n_total * 100))
print(string.format("候補選択のみで到達可  : %d/%d (%.0f%%)", n_reach, n_total, n_reach / n_total * 100))
print(string.format("文節伸縮が必要        : %d/%d (%.0f%%)", n_total - n_reach, n_total, (n_total - n_reach) / n_total * 100))

anthy.anthy_release_context(ctx)
anthy.anthy_quit()
