-- SKK 辞書(JISYO JSON)の解析と anthy 私的辞書への取り込み。
-- 取り込みは編集中の Vim とは別プロセス(CLI: lua/vime/import.lua)から実行する想定。
-- skk は anthy へ直接依存せず、register コールバック注入で動く(DIP)。
local M = {}

-- SKK 候補1件を anthy 登録用の単語に整形する。整形できない候補は nil を返す。
-- ・先頭 `;` 以降の注釈を除去する(例: 愛知大学;※abbrev → 愛知大学)
-- ・(concat …) の lisp 候補、数値テンプレート # を含む候補、空は取り込まない
-- ・(株)… のような素の括弧は語の一部として残す
function M.clean_candidate(cand)
  if cand:sub(1, 7) == "(concat" then
    return nil
  end
  local word = vim.trim(cand:match("^[^;]*")) -- 先頭 ; までを語とみなす
  if word == "" or word:find("#", 1, true) then
    return nil
  end
  return word
end

-- JISYO JSON 文字列をテーブルへ復号する。不正な JSON は例外を投げず nil。
function M.decode(content)
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

-- SKK の助詞と同じ読みの見出し(例: を → 雄・尾)を名詞として入れると、
-- anthy が文中の助詞を名詞と解釈して誤変換する(例: をしたりすること → 雄したりすること)。
-- これらの読みのよく使う漢字は anthy の基本辞書が既に持つので、取り込まなくても候補は残る。
local PARTICLE_YOMI = {}
for _, p in ipairs({ "を", "は", "が", "に", "で", "と", "へ", "も", "や", "の", "か", "ね", "よ", "な", "さ", "ぞ", "わ" }) do
  PARTICLE_YOMI[p] = true
end

-- decode 済み JISYO テーブルから anthy 登録用の {yomi, word} 配列を作る。
-- okuri_nasi(名詞)のみ対象。okuri_ari(送りあり活用)は anthy 名詞辞書と噛み合わないため無視。
-- 数値テンプレート # を含む読みと、1 文字の助詞の読みは丸ごとスキップする。stats={entries,skipped}。
function M.entries(decoded)
  local list = {}
  local stats = { entries = 0, skipped = 0 }
  for yomi, cands in pairs(decoded.okuri_nasi or {}) do
    if yomi:find("#", 1, true) or PARTICLE_YOMI[yomi] then
      stats.skipped = stats.skipped + #cands
    else
      for _, cand in ipairs(cands) do
        local word = M.clean_candidate(cand)
        if word then
          list[#list + 1] = { yomi = yomi, word = word }
          stats.entries = stats.entries + 1
        else
          stats.skipped = stats.skipped + 1
        end
      end
    end
  end
  return list, stats
end

-- 私的辞書 private_words_default の1行フォーマット用。名詞(#T35)・頻度。
-- freq は低くする: 大辞書(L 等)を高 freq で入れると anthy 既定の変換順・学習を
-- 広く上書きしてしまう(例: さくら→砂倉)。低 freq なら既定順を保ちつつ、anthy に
-- 無い読みでは候補として出る。
local DIC_WTYPE = "#T35"
local DIC_FREQ = 1

-- entries({yomi,word}配列) を private_words_default の行配列へ変換する(純粋)。
-- 形式は「読み #T35*1000 単語」(スペース区切り)。読み/語に空白を含む行は除外。
-- 大量取り込みを per-entry の anthy API ではなく1回のファイル生成で行うために使う。
function M.to_lines(entries)
  local lines = {}
  local skipped = 0
  for _, e in ipairs(entries) do
    if e.yomi:find("%s") or e.word:find("%s") then
      skipped = skipped + 1
    else
      lines[#lines + 1] = e.yomi .. " " .. DIC_WTYPE .. "*" .. DIC_FREQ .. " " .. e.word
    end
  end
  return lines, skipped
end

-- 行配列を重複排除し、バイト順にソートして返す(純粋)。
-- anthy の私的辞書(texttrie)は読みがソート済みであることを要求するため、
-- 直接生成時は必ずこれを通す(未ソートだと一部しか引けない)。
function M.sort_unique(lines)
  local seen = {}
  local out = {}
  for _, l in ipairs(lines) do
    if not seen[l] then
      seen[l] = true
      out[#out + 1] = l
    end
  end
  table.sort(out)
  return out
end

-- path の SKK 辞書(JISYO JSON)を読み、各 okuri_nasi エントリを register(yomi, word) で
-- 登録する。同期処理。読めない/不正 JSON は例外を投げず nil を返す。stats={entries,skipped}。
function M.load(path, register)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  local decoded = M.decode(content)
  if not decoded then
    return nil
  end
  local list, stats = M.entries(decoded)
  for _, e in ipairs(list) do
    register(e.yomi, e.word)
  end
  return stats
end

return M
