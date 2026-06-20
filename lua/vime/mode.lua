-- モード推論: enabled/state/ascii/latin の組み合わせから外向きのモード名を導出する純粋関数。
-- 副作用なし(FFI/Vim API を触らない)。ステータスライン等から `vime.mode()` 経由で参照される。
--
-- 変換中(state="converting")は name に出さず "hiragana" に集約する。候補一覧 popup 側で
-- 変換中を十分シグナルできており、mode notify を追加で出すと邪魔になるため。detail を
-- 見たいユーザは state フィールドで判別できる(name="hiragana" + state="converting")。
local M = {}

-- compute({enabled, state, ascii, latin}) -> mode_table
-- 戻り値: { name, enabled, state, ascii, latin }
--   name: "direct" | "hiragana" | "ascii"
--   state: "composing" | "converting" | nil(direct のとき)
function M.compute(s)
  if not s.enabled then
    return { name = "direct", enabled = false, state = nil, ascii = false, latin = false }
  end
  if s.state == "converting" then
    -- name は hiragana に集約。state だけ "converting" を保持(advanced 用)。
    return { name = "hiragana", enabled = true, state = "converting", ascii = false, latin = false }
  end
  if s.ascii then
    return { name = "ascii", enabled = true, state = "composing", ascii = true, latin = false }
  end
  return {
    name = "hiragana",
    enabled = true,
    state = "composing",
    ascii = false,
    latin = s.latin == true,
  }
end

return M
