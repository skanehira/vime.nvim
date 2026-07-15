-- luacheck 設定。Neovim Lua プラグイン向け。
std = "luajit"
-- vim は読み取りに加え vim.env / vim.opt 等への代入もあるため可変グローバルとして扱う。
globals = { "vim" }

-- 行長は stylua(column_width=120)に委ねるため、luacheck では制限しない。
max_line_length = false

-- テストは busted の DSL(describe/it/assert/before_each/after_each)を使う。
files["tests/"] = {
  std = "luajit+busted",
}

-- romaji.lua の撥音処理は意図的な空 if 分岐(母音/y は次へ fall-through)を持つ。
files["lua/vime/romaji.lua"] = {
  ignore = { "542" }, -- empty if branch
}

-- backend/*.lua は buffer/terminal/cmdline が同じメソッドシグネチャを実装する契約
-- (§3.3)なので、実装によっては self を参照しない(no-op や引数だけで完結する)メソッド
-- がある。colon 構文を保つのが呼び出し側との一貫性のため必須なので、self を潰さず
-- 未使用チェックのみ無効化する。
files["lua/vime/backend/"] = {
  self = false,
}
