-- nvim-cmp の source 実装。cmp 本体には依存せず、provider(active/context/commit)を DI で受ける。
-- 依存方向を片方向に保つため、cmp 側の register_source に渡すオブジェクトだけをここで組み立てる。
-- provider:
--   active():bool             補完が出しうる状態か(init.M.completion_active)
--   context():table|nil       { row, start_col, len, yomi, items }(init.M.completion_context)
--   commit(item_data)         確定した候補 data で学習 commit(init.M.commit_completion)
--
-- cmp は source のメソッドを self 付き(コロン呼び出し)で起動するため、各メソッドは
-- 第1引数に source 自身を受ける。ここでは使わないので _ で受ける。
local M = {}

function M.new(provider)
  local source = {}

  function source.is_available()
    return provider.active()
  end

  function source.get_debug_name()
    return "vime"
  end

  -- textEdit の character を byte 単位で解釈させる。vime の start_col/len は byte なので、
  -- utf-8 を宣言すれば cmp の既定(utf-16)への変換を挟まず byte 列がそのまま通る。
  function source.get_position_encoding_kind()
    return "utf-8"
  end

  function source.get_keyword_pattern()
    return [[\%(\k\|[぀-ヿー]\)\+]]
  end

  -- 候補を返す。未確定領域を textEdit で丸ごと候補テキストへ置換し、filterText=読みで
  -- cmp のフィルタ(offset..cursor=読み全体)から外れないようにする。読みが伸びるたび
  -- 候補集合を全入れ替えするため isIncomplete=true にする。context が無ければ空で返す。
  function source.complete(_, _, callback)
    local ctx = provider.context()
    if not ctx then
      callback({ items = {}, isIncomplete = true })
      return
    end
    local items = {}
    for i, cand in ipairs(ctx.items) do
      items[i] = {
        label = cand.text,
        filterText = ctx.yomi,
        sortText = string.format("%04d", i),
        textEdit = {
          range = {
            start = { line = ctx.row, character = ctx.start_col },
            ["end"] = { line = ctx.row, character = ctx.start_col + ctx.len },
          },
          newText = cand.text,
        },
        data = cand,
      }
    end
    callback({ items = items, isIncomplete = true })
  end

  -- 確定後(cmp が textEdit でバッファを置換済み)に呼ばれる。data で学習 commit を差し戻す。
  function source.execute(_, completion_item, callback)
    provider.commit(completion_item.data)
    callback(completion_item)
  end

  return source
end

return M
