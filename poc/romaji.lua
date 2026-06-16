-- ローマ字 → かな 変換モジュール (wapuro ローマ字)
-- PoC 用。to_kana(romaji) -> hiragana を返す。
local M = {}

local T = {
  a = "あ", i = "い", u = "う", e = "え", o = "お",
  ka = "か", ki = "き", ku = "く", ke = "け", ko = "こ",
  ga = "が", gi = "ぎ", gu = "ぐ", ge = "げ", go = "ご",
  sa = "さ", si = "し", shi = "し", su = "す", se = "せ", so = "そ",
  za = "ざ", zi = "じ", ji = "じ", zu = "ず", ze = "ぜ", zo = "ぞ",
  ta = "た", ti = "ち", chi = "ち", tu = "つ", tsu = "つ", te = "て", to = "と",
  da = "だ", di = "ぢ", du = "づ", de = "で", ["do"] = "ど",
  na = "な", ni = "に", nu = "ぬ", ne = "ね", no = "の",
  ha = "は", hi = "ひ", hu = "ふ", fu = "ふ", he = "へ", ho = "ほ",
  ba = "ば", bi = "び", bu = "ぶ", be = "べ", bo = "ぼ",
  pa = "ぱ", pi = "ぴ", pu = "ぷ", pe = "ぺ", po = "ぽ",
  ma = "ま", mi = "み", mu = "む", me = "め", mo = "も",
  ya = "や", yu = "ゆ", yo = "よ",
  ra = "ら", ri = "り", ru = "る", re = "れ", ro = "ろ",
  wa = "わ", wo = "を", wi = "うぃ", we = "うぇ",
  kya = "きゃ", kyu = "きゅ", kyo = "きょ",
  gya = "ぎゃ", gyu = "ぎゅ", gyo = "ぎょ",
  sya = "しゃ", syu = "しゅ", syo = "しょ",
  sha = "しゃ", shu = "しゅ", sho = "しょ", she = "しぇ",
  ja = "じゃ", ju = "じゅ", jo = "じょ", je = "じぇ",
  jya = "じゃ", jyu = "じゅ", jyo = "じょ",
  zya = "じゃ", zyu = "じゅ", zyo = "じょ",
  tya = "ちゃ", tyu = "ちゅ", tyo = "ちょ",
  cha = "ちゃ", chu = "ちゅ", cho = "ちょ", che = "ちぇ",
  cya = "ちゃ", cyu = "ちゅ", cyo = "ちょ",
  dya = "ぢゃ", dyu = "ぢゅ", dyo = "ぢょ",
  nya = "にゃ", nyu = "にゅ", nyo = "にょ",
  hya = "ひゃ", hyu = "ひゅ", hyo = "ひょ",
  bya = "びゃ", byu = "びゅ", byo = "びょ",
  pya = "ぴゃ", pyu = "ぴゅ", pyo = "ぴょ",
  mya = "みゃ", myu = "みゅ", myo = "みょ",
  rya = "りゃ", ryu = "りゅ", ryo = "りょ",
  fa = "ふぁ", fi = "ふぃ", fe = "ふぇ", fo = "ふぉ",
  xa = "ぁ", xi = "ぃ", xu = "ぅ", xe = "ぇ", xo = "ぉ",
  la = "ぁ", li = "ぃ", lu = "ぅ", le = "ぇ", lo = "ぉ",
  xya = "ゃ", xyu = "ゅ", xyo = "ょ",
  xtu = "っ", ltu = "っ",
  ["-"] = "ー",
}

local function is_consonant(ch)
  return ch:match("[bcdfghjkmpqrstvwxyz]") ~= nil
end
local function is_vowel(ch)
  return ch:match("[aeiou]") ~= nil
end

function M.to_kana(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "n" then
      local nx = s:sub(i + 1, i + 1)
      if nx == "'" then
        out[#out + 1] = "ん"; i = i + 2; goto cont
      elseif nx == "n" then
        -- "nn" の曖昧性: 2つ目の n の次を見て分岐 (実IME準拠)
        local nx2 = s:sub(i + 2, i + 2)
        if is_vowel(nx2) or nx2 == "y" then
          -- onna/konnichi: 2つ目の n はな行/にゃを始める → n を1つだけ ん にする
          out[#out + 1] = "ん"; i = i + 1; goto cont
        else
          -- tennki/末尾: nn → ん (子音前 or 末尾)
          out[#out + 1] = "ん"; i = i + 2; goto cont
        end
      elseif nx == "" then
        out[#out + 1] = "ん"; i = i + 1; goto cont
      elseif is_vowel(nx) or nx == "y" then
        -- fall through (na/ni/nya...)
      else
        out[#out + 1] = "ん"; i = i + 1; goto cont
      end
    end
    if is_consonant(c) and c ~= "n" then
      local nx = s:sub(i + 1, i + 1)
      if nx == c then
        out[#out + 1] = "っ"; i = i + 1; goto cont
      end
      if c == "t" and nx == "c" and s:sub(i + 2, i + 2) == "h" then
        out[#out + 1] = "っ"; i = i + 1; goto cont
      end
    end
    do
      local matched = false
      for len = 3, 1, -1 do
        local seg = s:sub(i, i + len - 1)
        if T[seg] then
          out[#out + 1] = T[seg]; i = i + len; matched = true; break
        end
      end
      if not matched then
        out[#out + 1] = c; i = i + 1
      end
    end
    ::cont::
  end
  return table.concat(out)
end

return M
