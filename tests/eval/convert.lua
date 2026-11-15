-- 変換評価: nvim --headless -l tests/eval/convert.lua <corpus.txt> <out.tsv>
--
-- corpus の各行(ひらがなの読み)を anthy で変換し「読み<TAB>先頭候補の連結<TAB>文節を | で区切った先頭候補」
-- を out へ書く。評価したい私的辞書を置いたディレクトリを XDG_CONFIG_HOME で渡し、
-- 辞書の構成を変えた 2 回の出力を行ごとに比べる(例: 私的辞書なし vs いまの私的辞書)。
-- 学習記録(last-record*)を置かなければ、学習の影響を除いた辞書だけの比較になる。
local here = debug.getinfo(1, "S").source:sub(2) -- .../tests/eval/convert.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(here, ":h:h:h"))

local corpus, out_path = arg[1], arg[2]
if not (corpus and out_path) then
  io.stderr:write("usage: nvim --headless -l tests/eval/convert.lua <corpus.txt> <out.tsv>\n")
  os.exit(2)
end

local anthy = require("vime.anthy")
-- HOME を差し替えた後だと ~/.local/lib を展開できず別の libanthy を拾うので、先に解決する
local lib = require("vime.config").find_anthy_lib()
-- anthy-unicode の私的辞書は XDG_CONFIG_HOME で切り替わるが、原 anthy は HOME 配下を読むため
-- HOME も temp にして実環境の辞書・学習が混ざらないようにする
vim.env.HOME = vim.fn.tempname()
if not (lib and anthy.setup(lib)) then
  io.stderr:write("vime: libanthy が見つからないか初期化に失敗しました ($VIME_ANTHY_LIB で指定可)\n")
  os.exit(1)
end
io.stderr:write("lib=" .. lib .. " private_dic=" .. tostring(anthy.private_dic_path()) .. "\n")

local out = assert(io.open(out_path, "w"))
local s = anthy.new_session()
for yomi in io.lines(corpus) do
  if yomi ~= "" then
    local parts = {}
    for i, seg in ipairs(s:convert(yomi)) do
      parts[i] = seg.best
    end
    out:write(yomi, "\t", table.concat(parts), "\t", table.concat(parts, "|"), "\n")
  end
end
s:close()
out:close()
