-- ローマ字 → かな 変換 (wapuro ローマ字)
-- 純粋関数。FFI 非依存。to_kana(romaji) -> ひらがな を返す。
local M = {}

local T = {
  a = "あ",
  i = "い",
  u = "う",
  e = "え",
  o = "お",
  ka = "か",
  ki = "き",
  ku = "く",
  ke = "け",
  ko = "こ",
  ga = "が",
  gi = "ぎ",
  gu = "ぐ",
  ge = "げ",
  go = "ご",
  sa = "さ",
  si = "し",
  shi = "し",
  su = "す",
  se = "せ",
  so = "そ",
  za = "ざ",
  zi = "じ",
  ji = "じ",
  zu = "ず",
  ze = "ぜ",
  zo = "ぞ",
  ta = "た",
  ti = "ち",
  chi = "ち",
  tu = "つ",
  tsu = "つ",
  te = "て",
  to = "と",
  da = "だ",
  di = "ぢ",
  du = "づ",
  de = "で",
  ["do"] = "ど",
  na = "な",
  ni = "に",
  nu = "ぬ",
  ne = "ね",
  no = "の",
  ha = "は",
  hi = "ひ",
  hu = "ふ",
  fu = "ふ",
  he = "へ",
  ho = "ほ",
  ba = "ば",
  bi = "び",
  bu = "ぶ",
  be = "べ",
  bo = "ぼ",
  pa = "ぱ",
  pi = "ぴ",
  pu = "ぷ",
  pe = "ぺ",
  po = "ぽ",
  ma = "ま",
  mi = "み",
  mu = "む",
  me = "め",
  mo = "も",
  ya = "や",
  yu = "ゆ",
  yo = "よ",
  ra = "ら",
  ri = "り",
  ru = "る",
  re = "れ",
  ro = "ろ",
  wa = "わ",
  wo = "を",
  wi = "うぃ",
  wu = "う",
  we = "うぇ",
  kya = "きゃ",
  kyu = "きゅ",
  kyo = "きょ",
  gya = "ぎゃ",
  gyu = "ぎゅ",
  gyo = "ぎょ",
  sya = "しゃ",
  syu = "しゅ",
  syo = "しょ",
  sha = "しゃ",
  shu = "しゅ",
  sho = "しょ",
  she = "しぇ",
  ja = "じゃ",
  ju = "じゅ",
  jo = "じょ",
  je = "じぇ",
  jya = "じゃ",
  jyi = "じぃ",
  jyu = "じゅ",
  jye = "じぇ",
  jyo = "じょ",
  zya = "じゃ",
  zyu = "じゅ",
  zyo = "じょ",
  tya = "ちゃ",
  tyu = "ちゅ",
  tyo = "ちょ",
  tye = "ちぇ",
  cha = "ちゃ",
  chu = "ちゅ",
  cho = "ちょ",
  che = "ちぇ",
  cya = "ちゃ",
  cyu = "ちゅ",
  cyo = "ちょ",
  dya = "ぢゃ",
  dyu = "ぢゅ",
  dyo = "ぢょ",
  nya = "にゃ",
  nyu = "にゅ",
  nyo = "にょ",
  hya = "ひゃ",
  hyu = "ひゅ",
  hyo = "ひょ",
  bya = "びゃ",
  byu = "びゅ",
  byo = "びょ",
  pya = "ぴゃ",
  pyu = "ぴゅ",
  pyo = "ぴょ",
  mya = "みゃ",
  myu = "みゅ",
  myo = "みょ",
  rya = "りゃ",
  ryu = "りゅ",
  ryo = "りょ",
  vu = "ゔ", -- ゔ単体。ふぁ行/ゔ行/外来音/拗音グライドは下部の展開規則(expand)で生成する
  xa = "ぁ",
  xi = "ぃ",
  xu = "ぅ",
  xe = "ぇ",
  xo = "ぉ",
  la = "ぁ",
  li = "ぃ",
  lu = "ぅ",
  le = "ぇ",
  lo = "ぉ",
  xya = "ゃ",
  xyu = "ゅ",
  xyo = "ょ",
  lya = "ゃ",
  lyu = "ゅ",
  lyo = "ょ",
  xtu = "っ",
  ltu = "っ",
  xtsu = "っ",
  ltsu = "っ",
  xwa = "ゎ",
  lwa = "ゎ",
  xn = "ん",
  ye = "いぇ",
  ["-"] = "ー",
  -- 句読点・括弧(日本語IME標準)
  [","] = "、",
  ["."] = "。",
  ["/"] = "・",
  ["["] = "「",
  ["]"] = "」",
  -- Google日本語入力準拠の z+? 記号ショートカット(矢印・特殊記号)
  ["zh"] = "←",
  ["zj"] = "↓",
  ["zk"] = "↑",
  ["zl"] = "→",
  ["z-"] = "〜",
  ["z,"] = "‥",
  ["z."] = "…",
  ["z/"] = "・",
  ["z["] = "『",
  ["z]"] = "』",
}

-- 外来音・拗音の系統的な展開を機械生成する(穴を手追加し続けないため)。
-- 「子音グライド + 母音」→「ベースかな + 小書き母音」。skip の母音はベース音が別にあるので生成しない。
local SMALL_A = { a = "ぁ", i = "ぃ", u = "ぅ", e = "ぇ", o = "ぉ" } -- 小書きあ行 (ふぁ/つぁ/くぁ…)
local SMALL_Y = { a = "ゃ", i = "ぃ", u = "ゅ", e = "ぇ", o = "ょ" } -- 拗音 (てゃ/でゃ/ふゃ…)

local function expand(prefix, base, small, skip)
  for _, v in ipairs({ "a", "i", "u", "e", "o" }) do
    if not (skip and skip[v]) then
      T[prefix .. v] = base .. small[v]
    end
  end
end

-- 小書きあ行系(外来音)。f/v/ts は u スロットがベース音(ふ/ゔ/つ)なので skip。
expand("f", "ふ", SMALL_A, { u = true })
expand("v", "ゔ", SMALL_A, { u = true })
expand("ts", "つ", SMALL_A, { u = true })
expand("wh", "う", SMALL_A, { u = true })
expand("kw", "く", SMALL_A)
expand("gw", "ぐ", SMALL_A)
expand("tw", "と", SMALL_A)
expand("dw", "ど", SMALL_A)
expand("q", "く", SMALL_A)
expand("qw", "く", SMALL_A)
-- 拗音系(小書きや行)
expand("th", "て", SMALL_Y)
expand("dh", "で", SMALL_Y)
expand("fy", "ふ", SMALL_Y)
expand("vy", "ゔ", SMALL_Y)

local function is_consonant(ch)
  return ch:match("[bcdfghjkmpqrstvwxyz]") ~= nil
end
local function is_vowel(ch)
  return ch:match("[aeiou]") ~= nil
end

-- ローマ字列をひらがなへ変換する。大文字は小文字化して扱う。
function M.to_kana(s)
  s = s:lower()
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    -- 撥音 ん
    if c == "n" then
      local nx = s:sub(i + 1, i + 1)
      if nx == "'" then
        out[#out + 1] = "ん"
        i = i + 2
        goto cont
      elseif nx == "n" then
        -- "nn" の曖昧性: 2つ目の n の次を見て分岐 (実IME準拠)
        local nx2 = s:sub(i + 2, i + 2)
        if is_vowel(nx2) or nx2 == "y" then
          -- onna/konnichi: 2つ目の n はな行/にゃを始める → n を1つだけ ん にする
          out[#out + 1] = "ん"
          i = i + 1
          goto cont
        else
          -- tennki/末尾: nn → ん (子音前 or 末尾)
          out[#out + 1] = "ん"
          i = i + 2
          goto cont
        end
      elseif nx == "" then
        out[#out + 1] = "ん"
        i = i + 1
        goto cont
      elseif is_vowel(nx) or nx == "y" then
        -- fall through (na/ni/nya...)
      else
        out[#out + 1] = "ん"
        i = i + 1
        goto cont
      end
    end
    -- 促音 っ (同子音の連続 / tch)
    if is_consonant(c) and c ~= "n" then
      local nx = s:sub(i + 1, i + 1)
      if nx == c then
        out[#out + 1] = "っ"
        i = i + 1
        goto cont
      end
      if c == "t" and nx == "c" and s:sub(i + 2, i + 2) == "h" then
        out[#out + 1] = "っ"
        i = i + 1
        goto cont
      end
    end
    -- テーブル最長一致 (4→1。4 は xtsu/ltsu のみ)
    do
      local matched = false
      for len = 4, 1, -1 do
        local seg = s:sub(i, i + len - 1)
        if T[seg] then
          out[#out + 1] = T[seg]
          i = i + len
          matched = true
          break
        end
      end
      if not matched then
        out[#out + 1] = c
        i = i + 1 -- 未知文字はそのまま
      end
    end
    ::cont::
  end
  return table.concat(out)
end

-- ひらがな(U+3041-U+3096)をカタカナ(+0x60)へ変換する。それ以外の文字はそのまま。
function M.to_katakana(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b1 = s:byte(i)
    if b1 >= 0xE0 and b1 < 0xF0 and i + 2 <= n then
      local b2, b3 = s:byte(i + 1), s:byte(i + 2)
      local cp = (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
      if cp >= 0x3041 and cp <= 0x3096 then
        cp = cp + 0x60
        out[#out + 1] =
          string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
      else
        out[#out + 1] = s:sub(i, i + 2)
      end
      i = i + 3
    else
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

return M
