-- session テスト用の fake anthy(テストダブル)。
-- 決め打ちの変換結果を返し、resize/commit/close の呼び出しを記録する。
local M = {}

local result = {}
local resized_result = nil

-- テストが事前に変換結果(文節配列)を設定する。
function M.set_result(segs)
  result = segs
  resized_result = nil
end

-- resize 後に返す文節配列を設定する。
function M.set_resized_result(segs)
  resized_result = segs
end

function M.setup()
  return true
end

function M.new_session()
  local s = { log = { resized = {}, committed = nil, closed = false } }

  function s:convert(yomi)
    self.log.yomi = yomi
    self.segments = result
    return self.segments
  end

  function s:resize(seg, delta)
    table.insert(self.log.resized, { seg = seg, delta = delta })
    if resized_result then
      self.segments = resized_result
    end
    return self.segments
  end

  function s:commit(choices)
    self.log.committed = choices
  end

  function s:close()
    self.log.closed = true
  end

  return s
end

return M
