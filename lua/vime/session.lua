-- 変換セッションの状態機械(COMPOSING / CONVERTING)。
-- プリエディットは「セグメント列」(kana/latin の並び)で保持し、preedit は都度連結で導出する。
-- anthy への依存はインターフェース(convert/resize/commit/close)越し(DIP)。テストは実 anthy を注入する(差し替えも可能)。
local romaji = require("vime.romaji")

local M = {}

local Session = {}
Session.__index = Session

-- anthy_module: setup 済みの anthy(.new_session() を持つ)。テストでも同じ実 anthy を渡す(DIP で差し替え可能)。
-- opts.ascii_toggle: ASCII モード入退室文字(既定 ";"、nil で無効化)。
-- opts.romaji_table: ローマ字→かなのカスタムテーブル。nil なら romaji モジュールの既定(wapuro)。
function M.new(anthy_module, opts)
  opts = opts or {}
  local toggle = opts.ascii_toggle
  if toggle == nil then
    toggle = ";"
  end
  return setmetatable({
    _anthy = anthy_module, -- anthy セッションを生成するモジュール
    anthy = nil, -- 生成した anthy セッション(変換中に再利用)
    _romaji_table = opts.romaji_table, -- nil なら romaji.default_table が使われる
    _state = "composing",
    _buf = {}, -- セグメント配列。各要素: {kind="kana", romaji=...} or {kind="latin", text=...}
    _ascii_toggle = toggle, -- ASCII モード入退室文字
    _ascii_mode = false, -- ASCII モード中(latin セグメントへの直入力)
    _segments = nil,
    seg_index = 1,
    choices = {},
  }, Session)
end

function Session:state()
  return self._state
end

-- 末尾セグメント(無ければ nil)。
local function tail(self)
  return self._buf[#self._buf]
end

-- 末尾が latin セグメントか。
local function is_latin_tail(self)
  local t = tail(self)
  return t ~= nil and t.kind == "latin"
end

-- 英字ラン中か(末尾が latin セグメントなら true)。
-- controller が確定の仕方を変えるのに使う(英字ラン中は Space を文字として扱う等)。
-- ASCII モードでも末尾は latin になるので true を返す(Space を latin に追加する等の同じ挙動でよい)。
function Session:is_latin()
  return is_latin_tail(self)
end

-- ASCII モード中か(ascii_toggle で入退室・kana 未確定は保留)。
function Session:is_ascii()
  return self._ascii_mode
end

-- 描画用セグメントビュー(ui に渡す)。
-- 各要素: {kind="kana"|"latin"|"confirmed", text=...}
-- ただし converting 中の注目 kana 位置は {kind="segments", list={...}, current=N} を返す。
function Session:preedit_segments()
  local view = {}
  for i, seg in ipairs(self._buf) do
    if self._state == "converting" and i == self._active_kana_idx then
      local segs = self:segments()
      view[#view + 1] = { kind = "segments", list = segs.list, current = segs.current }
    elseif seg.kind == "kana" then
      view[#view + 1] = { kind = "kana", text = romaji.to_kana(seg.romaji, self._romaji_table) }
    else
      view[#view + 1] = { kind = seg.kind, text = seg.text } -- latin / confirmed
    end
  end
  return view
end

-- プリエディット文字列。
-- composing: kana は to_kana、latin/confirmed は text のまま順に連結。
-- converting: 注目 kana の位置は変換中文節列の選択候補を連結、それ以外は同上。
function Session:preedit()
  local parts = {}
  for i, seg in ipairs(self._buf) do
    if self._state == "converting" and i == self._active_kana_idx then
      parts[i] = table.concat(self:segments().list)
    elseif seg.kind == "kana" then
      parts[i] = romaji.to_kana(seg.romaji, self._romaji_table)
    else
      parts[i] = seg.text -- latin / confirmed
    end
  end
  return table.concat(parts)
end

-- composing 状態へ戻す(確定/取消後)。
local function reset_composing(self)
  self._state = "composing"
  self._buf = {}
  self._ascii_mode = false
  self._segments = nil
  self.seg_index = 1
  self.choices = {}
  self._active_kana_idx = nil
end

-- 末尾の kana セグメントを返す。無ければ新規作成して末尾に追加する。
local function kana_tail_or_new(self)
  local t = tail(self)
  if t and t.kind == "kana" then
    return t
  end
  local seg = { kind = "kana", romaji = "" }
  self._buf[#self._buf + 1] = seg
  return seg
end

-- 新しい latin セグメントを開始する。ch="" なら空 latin(ASCII モード開始時)。
local function start_latin(self, ch)
  self._buf[#self._buf + 1] = { kind = "latin", text = ch }
end

-- composing 状態で1文字を処理(ASCII トグル分岐を含む)。確定文字列(無ければ "")を返す。
local function input_composing(self, ch)
  -- ASCII トグル: ASCII モード中の toggle は即 OFF(latin セグメントを閉じる)。
  -- ASCII モード外の toggle は ON(空 latin セグメントを開く)。
  -- 他のキーは ASCII モード継続中はすべて latin に追加されるので、OFF にしたい時だけ toggle を押す。
  if ch == self._ascii_toggle then
    if self._ascii_mode then
      self._ascii_mode = false
      local t = tail(self)
      if t and t.kind == "latin" then
        t.closed = true -- 以降の入力は新規 kana セグメントへ
      end
      return ""
    end
    self._ascii_mode = true
    start_latin(self, "")
    return ""
  end
  -- ASCII モード中: 任意のキーは末尾 latin セグメントに追加(大小・記号保持)。
  -- BS で latin を空にした直後など末尾が latin でない場合は新規 latin セグメントを開く(モード継続)。
  if self._ascii_mode then
    local t = tail(self)
    if not (t and t.kind == "latin") then
      start_latin(self, "")
      t = tail(self)
    end
    t.text = t.text .. ch
    return ""
  end
  -- 英字ラン中(未閉の末尾 latin): 末尾 latin セグメントに追加(変換しない)。
  do
    local t = tail(self)
    if t and t.kind == "latin" and not t.closed then
      t.text = t.text .. ch
      return ""
    end
  end
  -- 大文字始まり: かな未確定があれば commit してから新規 latin セグメント開始(英字ラン)。
  if ch:match("%u") then
    if #self._buf > 0 then
      local confirmed = self:commit()
      start_latin(self, ch)
      return confirmed
    end
    start_latin(self, ch)
    return ""
  end
  -- 通常のかな入力: 末尾 kana(無ければ新規作成)に追加。
  local seg = kana_tail_or_new(self)
  seg.romaji = seg.romaji .. ch
  return ""
end

-- 1文字入力。converting 中・かな未確定中に大文字が来た場合は現内容を確定し、確定文字列を返す。
function Session:input(ch)
  if self._state == "converting" then
    local confirmed = self:commit()
    local also = input_composing(self, ch)
    return confirmed .. also
  end
  return input_composing(self, ch)
end

-- UTF-8 文字数を数える(継続バイト 0x80-0xBF を除外)。
local function uchars(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then
      n = n + 1
    end
  end
  return n
end

-- かな単位で1文字削除する。latin セグメントは1byte 削除(英字は1バイト=1文字)。
-- セグメントが空になったら末尾から削除する。
function Session:backspace()
  if self._state ~= "composing" then
    return
  end
  local t = tail(self)
  if not t then
    return
  end
  if t.kind == "latin" then
    t.text = t.text:sub(1, #t.text - 1)
    if t.text == "" then
      table.remove(self._buf)
      -- _ascii_mode は変更しない: ASCII トグルを明示的に押すまでモード継続。
      -- 英字ラン(_ascii_mode=false)も削除挙動は同じで、フラグは元から false なので影響なし。
    end
    return
  end
  -- kana セグメント: ローマ字を末尾から削り、未完成英字で終わらず・かな数が1減るまで戻す。
  local before = uchars(romaji.to_kana(t.romaji, self._romaji_table))
  while #t.romaji > 0 do
    t.romaji = t.romaji:sub(1, #t.romaji - 1)
    local kana = romaji.to_kana(t.romaji, self._romaji_table)
    if not kana:match("[A-Za-z]$") and uchars(kana) < before then
      break
    end
  end
  if t.romaji == "" then
    table.remove(self._buf)
  end
end

-- 全 kana セグメントのローマ字を連結して返す(commit_katakana / commit_alphabet 用)。
local function concat_kana_romaji(self)
  local parts = {}
  for _, seg in ipairs(self._buf) do
    if seg.kind == "kana" then
      parts[#parts + 1] = seg.romaji
    end
  end
  return table.concat(parts)
end

-- 先頭(buf 順)の kana セグメントの index を返す。無ければ nil。
local function first_kana_idx(self)
  for i, seg in ipairs(self._buf) do
    if seg.kind == "kana" then
      return i
    end
  end
  return nil
end

-- idx 番目の kana セグメントを converting にして state を遷移する。
-- 読みが空なら(本来作られないはずだが)何もせず false を返す。
local function start_converting_at(self, idx)
  local seg = self._buf[idx]
  local yomi = romaji.to_kana(seg.romaji, self._romaji_table)
  if yomi == "" then
    return false
  end
  if not self.anthy then
    self.anthy = self._anthy.new_session()
  end
  self._segments = self.anthy:convert(yomi)
  self.seg_index = 1
  self.choices = {}
  for i = 1, #self._segments do
    self.choices[i] = 1
  end
  self._active_kana_idx = idx
  self._state = "converting"
  return true
end

-- 注目 kana を学習 commit して confirmed セグメントに置換し、確定テキストを返す。
local function commit_active_kana(self)
  local text = table.concat(self:segments().list)
  self.anthy:commit(self.choices)
  self._buf[self._active_kana_idx] = { kind = "confirmed", text = text }
  self._active_kana_idx = nil
  self._segments = nil
  self.seg_index = 1
  self.choices = {}
  return text
end

-- buf 全体を確定済みテキストとして連結する(reset 前の最終文字列生成用)。
local function concat_all(self)
  local parts = {}
  for i, seg in ipairs(self._buf) do
    if seg.kind == "kana" then
      parts[i] = romaji.to_kana(seg.romaji, self._romaji_table)
    else
      parts[i] = seg.text -- latin / confirmed
    end
  end
  return table.concat(parts)
end

-- composing(kana セグメントあり) → converting。先頭 kana セグメントから変換開始。
-- ASCII モード中・英字ラン中(末尾が未閉 latin)・kana セグメントなしなら何もしない。
function Session:start_conversion()
  if self._state ~= "composing" then
    return
  end
  if self._ascii_mode then
    return -- ASCII モード中は変換しない(toggle で OFF にしてから)
  end
  do
    local t = tail(self)
    if t and t.kind == "latin" and not t.closed then
      return -- 英字ランは変換しない
    end
  end
  local idx = first_kana_idx(self)
  if not idx then
    return
  end
  start_converting_at(self, idx)
end

-- converting の表示用ビュー: { list = {各文節の選択テキスト}, current = 注目index }
function Session:segments()
  local list = {}
  for i, seg in ipairs(self._segments) do
    list[i] = seg.candidates[self.choices[i]]
  end
  return { list = list, current = self.seg_index }
end

-- 注目文節の全候補リストを返す(popup 表示用)。
function Session:candidates()
  if self._state ~= "converting" then
    return {}
  end
  return self._segments[self.seg_index].candidates
end

-- 注目文節で現在選択中の候補 index(1-based)。converting でなければ nil。
function Session:current_candidate_index()
  if self._state ~= "converting" then
    return nil
  end
  return self.choices[self.seg_index]
end

-- 注目文節の候補を idx(1-based)で選択する。
function Session:select(idx)
  if self._state ~= "converting" then
    return
  end
  local n = #self._segments[self.seg_index].candidates
  self.choices[self.seg_index] = math.max(1, math.min(idx, n))
end

function Session:next_candidate()
  if self._state ~= "converting" then
    return
  end
  local i = self.seg_index
  local n = #self._segments[i].candidates
  self.choices[i] = (self.choices[i] % n) + 1
end

function Session:prev_candidate()
  if self._state ~= "converting" then
    return
  end
  local i = self.seg_index
  local n = #self._segments[i].candidates
  self.choices[i] = (self.choices[i] - 2) % n + 1 -- 1 から前は末尾へ wrap
end

function Session:next_segment()
  if self._state ~= "converting" then
    return
  end
  self.seg_index = math.min(self.seg_index + 1, #self._segments)
end

function Session:prev_segment()
  if self._state ~= "converting" then
    return
  end
  self.seg_index = math.max(self.seg_index - 1, 1)
end

-- 注目文節を delta(+1伸長/-1短縮)して再構成する。
local function resize(self, delta)
  if self._state ~= "converting" then
    return
  end
  self._segments = self.anthy:resize(self.seg_index, delta)
  self.choices = {}
  for i = 1, #self._segments do
    self.choices[i] = 1
  end
  self.seg_index = math.min(self.seg_index, #self._segments)
end

function Session:expand()
  resize(self, 1)
end

function Session:shrink()
  resize(self, -1)
end

-- 一括確定。converting なら注目 kana を学習 commit し、残りの kana も既定候補で順次 convert+commit。
-- 全 buf を連結した最終文字列を返す。composing なら未確定をそのまま連結確定する。
function Session:commit()
  if self._state == "converting" then
    commit_active_kana(self)
    while true do
      local idx = first_kana_idx(self)
      if not idx then
        break
      end
      if not start_converting_at(self, idx) then
        -- 空 kana セグメントが万一あれば confirmed("") に置き換えて進む
        self._buf[idx] = { kind = "confirmed", text = "" }
      else
        commit_active_kana(self)
      end
    end
    local text = concat_all(self)
    reset_composing(self)
    return text
  end
  local text = self:preedit()
  reset_composing(self)
  return text
end

-- ステップ確定(混在変換用)。注目 kana を学習 commit し、次の kana があれば自動で converting 継続。
-- 残りの kana がなければ全 buf を連結して返し composing(空)へ。継続中は nil を返す。
-- composing なら commit と同じ。
function Session:commit_step()
  if self._state == "converting" then
    commit_active_kana(self)
    local next_idx = first_kana_idx(self)
    if next_idx and start_converting_at(self, next_idx) then
      return nil -- 継続
    end
    local text = concat_all(self)
    reset_composing(self)
    return text
  end
  local text = self:preedit()
  reset_composing(self)
  return text
end

-- 未確定・変換中を完全に破棄して空の composing に戻す。
function Session:clear()
  reset_composing(self)
end

-- 現在の読み(かな)をカタカナに変換して確定する文字列を返す。
-- composing/converting どちらでも読み(romaji 由来)で動く。英字ラン/空なら "" を返す。
function Session:commit_katakana()
  if is_latin_tail(self) then
    return ""
  end
  local reading = romaji.to_kana(concat_kana_romaji(self), self._romaji_table)
  if reading == "" then
    return ""
  end
  reset_composing(self)
  return romaji.to_katakana(reading)
end

-- 入力したローマ字(英小文字)をそのまま確定する文字列を返す(例: ふぉお → foo)。
-- composing/converting どちらでも romaji バッファで動く。かな入力中の romaji は常に
-- 小文字なのでそのまま英小文字になる。英字ラン/空なら "" を返す。
function Session:commit_alphabet()
  if is_latin_tail(self) then
    return ""
  end
  local text = concat_kana_romaji(self)
  if text == "" then
    return ""
  end
  reset_composing(self)
  return text
end

-- 注目文節の元読み(yomi)を返す。converting でなければ nil。
-- 辞書登録(register_word)の読み側として使う。
function Session:current_segment_yomi()
  if self._state ~= "converting" then
    return nil
  end
  return self.anthy:segment_yomi(self.seg_index)
end

-- 注目文節の表示候補を word に上書きしてから一括 commit する。
-- 辞書登録した単語で現在の入力を確定させるために使う。converting でなければ通常 commit と同じ。
-- anthy_commit_segment は元の choice 番号で呼ばれるため、内部状態・学習は壊れない。
function Session:commit_with_replacement(word)
  if self._state ~= "converting" then
    return self:commit()
  end
  local i = self.seg_index
  self._segments[i].candidates[self.choices[i]] = word
  return self:commit()
end

-- 取消。converting なら注目 kana の変換を取り消し composing へ戻す(confirmed/latin は保持)。
-- composing なら全未確定(buf)を破棄。
function Session:cancel()
  if self._state == "converting" then
    self._state = "composing"
    self._segments = nil
    self.seg_index = 1
    self.choices = {}
    self._active_kana_idx = nil
  else
    self._buf = {}
    self._ascii_mode = false
  end
end

return M
