-- vime: 英字→日本語変換 IME プラグインのエントリ。
-- session(状態)・ui(描画)・anthy(変換)・keymap(キー)を結線し、
-- 挿入モードのバッファに未確定テキストを書きながら IME 操作を提供する。
local config = require("vime.config")
local anthy = require("vime.anthy")
local session = require("vime.session")
local ui = require("vime.ui")
local keymap = require("vime.keymap")
local mode = require("vime.mode")
local backend_buffer = require("vime.backend.buffer")
local backend_terminal = require("vime.backend.terminal")
local backend_cmdline = require("vime.backend.cmdline")

-- cmdline backend を張ってよい cmdtype("/" "?" 検索、":" Ex コマンド)。
-- "@"(input())・"="(式レジスタ)等は対象外(vim.ui.input の入れ子等を避けるため)。
local CMDLINE_TYPES = { [":"] = true, ["/"] = true, ["?"] = true }

local api = vim.api
local M = {}

-- libanthy 未検出時の OS 別導入案内メッセージ。os 省略時は実行環境を使う。
-- 推奨は現役保守の anthy-unicode(ABI 互換)。
function M.install_hint(os)
  os = os or jit.os
  local tail =
    "導入後に自動検出されない場合は setup({ anthy = { lib = ... } }) か環境変数 $VIME_ANTHY_LIB でパス指定"
  if os == "OSX" then
    return table.concat({
      "vime: libanthy が見つかりません。anthy-unicode の導入を推奨します(macOS):",
      "  git clone https://github.com/fujiwarat/anthy-unicode && cd anthy-unicode",
      "  meson setup build --prefix=$HOME/.local --sysconfdir=$HOME/.local/etc -Demacs=disabled",
      "  meson compile -C build && meson install -C build   # ~/.local/lib/libanthy-unicode.dylib を自動検出",
      "  ※ --sysconfdir は絶対パス必須(相対だと anthy_init 失敗)。meson/ninja は nix shell 等で用意",
      "  簡易には nix profile install nixpkgs#anthy も可(9100h・ABI 互換)",
      "  " .. tail,
    }, "\n")
  end
  return table.concat({
    "vime: libanthy が見つかりません。anthy-unicode の導入を推奨します(Linux):",
    "  Fedora: sudo dnf install anthy-unicode",
    "  Debian/Ubuntu: sudo apt install libanthy-dev",
    "  Arch(AUR): anthy-unicode",
    "  " .. tail,
  }, "\n")
end

-- コントローラの状態
local st = {
  cfg = nil,
  anthy_ok = false,
  enabled = false,
  session = nil,
  ---@type vime.BufferBackend|vime.TerminalBackend|vime.CmdlineBackend|nil
  backend = nil, -- 書込先 backend(buffer/terminal/cmdline)。buf と keymap_mode を持つ
  ---@type vime.BufferBackend|vime.TerminalBackend|nil
  saved_backend = nil, -- cmdline backend が一時的に割り込む前の backend(CmdlineLeave で復元)
  popup_open = false,
  last_mode_name = "direct", -- 直近通知したモード名(変化検出に使う)
  last_preedit_key = nil, -- 直近通知した preedit の状態キー(VimePreeditChanged の変化検出)
  -- 自前自動補完の状態。items ~= nil が popup 表示中。index は選択位置(0=未選択・読みのまま)。
  -- 選択中は未確定領域の表示を候補テキストへインライン置換する(session は読みを保持)。
  completion = { items = nil, index = 0 },
  converting_keys_attached = false, -- converting 限定キーマップの現状(変化時のみ keymap を触る)
  completion_keys_attached = false, -- 補完限定キーマップ(C-n/C-p)の現状
}

-- handlers() ローカルテーブル生成関数の forward declare。
-- render()/finalize() から converting 限定キーマップ attach のために参照する。
local handlers

-- converting 限定キーマップ(C-f/C-b/C-n/C-p/C-o/C-i)を session の state に追従させる。
-- state 変化時のみ buffer-local mapping を attach/detach する(冪等)。
-- render() の末尾と finalize() の末尾(commit/確定パス)から呼ぶ。
local function sync_converting_keymap()
  if not st.enabled then
    return
  end
  local converting = st.session and st.session:state() == "converting"
  if converting and not st.converting_keys_attached then
    keymap.attach_converting(st.backend.buf, st.cfg, handlers(), st.backend.keymap_mode)
    st.converting_keys_attached = true
  elseif not converting and st.converting_keys_attached then
    keymap.detach_converting(st.backend.buf, st.backend.keymap_mode)
    st.converting_keys_attached = false
  end
end

-- 未確定が無い(idle)ときは実カーソル位置へ再アンカーする。
-- 確定後やユーザーの直接編集(Backspace 等)でズレた start_col を healing する。
local function sync_anchor()
  st.backend:sync_anchor()
end

-- 未確定領域のテキストを置き換える。範囲は行長へクランプし、IME が挿入モードを壊さないようにする。
local function set_region_text(text)
  st.backend:set_region_text(text)
end

local function place_cursor()
  st.backend:place_cursor()
end

-- 候補一覧 popup を(再)表示する。選択中(sel、nil なら先頭基準・ハイライトなし)を含む
-- 最大 POPUP_MAX 件の窓を出す。変換中の文節候補と composing 中の補完候補で共用する。
local POPUP_MAX = 9
local function show_candidate_window(cands, sel)
  local n = #cands
  if n == 0 then
    return
  end
  local anchor = sel or 1
  local first = 1
  if n > POPUP_MAX then -- 選択中を含む窓へスクロール
    first = math.min(math.max(anchor - math.floor(POPUP_MAX / 2), 1), n - POPUP_MAX + 1)
  end
  local items, rel = {}, nil
  for i = first, math.min(first + POPUP_MAX - 1, n) do
    items[#items + 1] = cands[i]
    if i == sel then
      rel = #items
    end
  end
  ui.show_popup(items, rel, st.backend:popup_pos())
end

-- 注目文節の候補一覧 popup を(再)表示する(変換中のみ)。
local function open_popup_window()
  if st.session:state() ~= "converting" then
    return
  end
  show_candidate_window(st.session:candidates(), st.session:current_candidate_index() or 1)
end

----------------------------------------------------------------------
-- 自前自動補完(composing 中の候補 popup とインライン選択)
----------------------------------------------------------------------

-- 補完限定キーマップ(C-n/C-p)を popup の表示状態に追従させる(冪等)。
-- converting 限定キーと同じ lhs だが、composing/converting は排他なので衝突しない。
local function sync_completion_keymap()
  if not st.enabled then
    return
  end
  local open = st.completion.items ~= nil
  if open and not st.completion_keys_attached then
    keymap.attach_completion(st.backend.buf, st.cfg, handlers(), st.backend.keymap_mode)
    st.completion_keys_attached = true
  elseif not open and st.completion_keys_attached then
    keymap.detach_completion(st.backend.buf, st.backend.keymap_mode)
    st.completion_keys_attached = false
  end
end

-- 補完状態を破棄して popup を閉じる。未確定領域のテキストは触らない
-- (必要なら呼び出し側が描画し直す)。
local function reset_completion()
  st.completion.items = nil
  st.completion.index = 0
  ui.close_popup()
  sync_completion_keymap()
end

local function completion_texts()
  local texts = {}
  for i, item in ipairs(st.completion.items) do
    texts[i] = item.text
  end
  return texts
end

-- composing 中の未確定に対する補完候補を(再)計算して popup を出す。
-- 候補が無い状態(未確定なし・英字ラン・変換中など)なら閉じる。backend が completion に
-- 対応しない(terminal/cmdline)場合は常に閉じる(vim.ui.input の入れ子等を避けるため)。
local function refresh_completion()
  if not st.cfg.completion.enabled then
    return
  end
  local items = (st.enabled and st.backend.supports("completion") and st.session:state() == "composing")
      and st.session:completion_candidates()
    or {}
  if #items == 0 then
    reset_completion()
    return
  end
  st.completion.items = items
  st.completion.index = 0
  show_candidate_window(completion_texts(), nil)
  sync_completion_keymap()
end

-- 補完候補の選択を delta(+1/-1)方向へ動かす。index 0(読みのまま)も循環に含める。
-- 選択中は未確定領域の表示を候補テキストへインライン置換する(session は読みを保持)。
local function select_completion(delta)
  local items = st.completion.items
  if not items then
    return
  end
  st.completion.index = (st.completion.index + delta) % (#items + 1)
  local idx = st.completion.index
  local text = idx == 0 and st.session:preedit() or items[idx].text
  st.backend:clear() -- 旧範囲の下線と popup を消す(popup は直後に開き直す)
  set_region_text(text)
  ui.highlight_preedit(st.backend.buf, st.backend.row, st.backend.start_col, #text)
  show_candidate_window(completion_texts(), idx ~= 0 and idx or nil)
  place_cursor()
end

-- 選択中の補完候補を確定する(anthy へ学習 + 空 composing へ)。確定したら true。
-- 未確定領域は選択時に候補テキストへ置換済みなので、領域を確定分だけ進めるだけでよい。
local function commit_completion_selection()
  local items = st.completion.items
  if not (items and st.completion.index > 0) then
    return false
  end
  st.session:commit_completion(items[st.completion.index])
  st.backend:clear() -- 下線と popup を消す(確定テキストはインライン置換済みのまま残す)
  st.backend.start_col = st.backend.start_col + st.backend.len
  st.backend.len = 0
  reset_completion()
  place_cursor()
  return true
end

-- 現在の session 状態を backend の描画先(バッファ or preedit float)へ反映する。
-- popup は開いていれば追従表示する。
local function render()
  st.backend:clear()
  st.backend:render(st.session:preedit_segments())
  if st.popup_open then
    open_popup_window()
  end
  place_cursor()
  sync_converting_keymap()
end

-- 未確定領域を確定テキストで置き換える。実際の挿入経路(feedkeys か API か)は
-- backend:finalize() が判断する(buffer backend は挿入モード中なら native の redo に
-- 確定テキストを載せる feedkeys 経路、それ以外は API 置換経路)。ここでは
-- どの経路でも共通の UI 掃除(popup/completion/ハイライト)だけを行う。
local function finalize(text)
  reset_completion() -- 補完 popup と選択状態はどの確定経路でも破棄する
  st.backend:finalize(text)
  st.backend:clear()
  st.popup_open = false
  sync_converting_keymap()
end

-- 未確定が無いときに通常のスペース/改行をカーソル位置へ挿入する(素通し)。
local function insert_literal(text)
  st.backend:insert_literal(text)
end

----------------------------------------------------------------------
-- ハンドラ(keymap からディスパッチされる)
----------------------------------------------------------------------

-- 挿入モード中か。on_input の feedkeys 経路分岐に使う(backend:finalize 内の分岐と同じ判定)。
local function in_insert_mode()
  return api.nvim_get_mode().mode:sub(1, 1) == "i"
end

-- ch を session:input に流すと確定が起きるか。
-- converting 中は任意の文字が現在の変換を確定させる。composing 中は「大文字始まりで
-- 既存のかな未確定を英字ランへ切り替える」ときだけ確定する(ASCII モード中・英字ラン中は追記)。
local function input_commits(s, ch)
  if s:state() == "converting" then
    return true
  end
  return ch:match("%u") ~= nil and s:preedit() ~= "" and not s:is_ascii() and not s:is_latin()
end

function M.on_input(ch)
  if not st.enabled then
    return
  end
  sync_anchor()
  -- 補完候補を選択したまま次の文字を打ったら、先に選択候補を確定する(Google 日本語入力風)。
  -- 確定は同期なので、ch はそのまま新しい読みの 1 文字目として続けて処理される。
  commit_completion_selection()
  -- 挿入モードで確定が起きる場合は feedkeys 経路にする。session:input(ch) は確定と ch の
  -- 取り込みを同時に行い render も同期に走るが、finalize の fed テキスト挿入は非同期なので
  -- 位置がズレる。代わりに commit だけ先に済ませて確定テキストを feed し、ch を後段へ
  -- 再投入する(fed テキストの後で on_input へ戻り、sync_anchor が正しい位置へ再アンカー)。
  if in_insert_mode() and input_commits(st.session, ch) then
    local confirmed = st.session:commit()
    -- ch を先に typeahead 先頭へ積み(remap 許可で自マッピングへ戻す)、その前に確定テキストを
    -- 積むことで [確定テキスト][<C-G>u][ch][後続キー] の順序を保証する。
    api.nvim_feedkeys(ch, "i", true)
    finalize(confirmed)
    return
  end
  local confirmed = st.session:input(ch)
  if confirmed ~= "" then
    finalize(confirmed)
  end
  render()
  refresh_completion()
end

function M.on_convert()
  if not st.enabled then
    return
  end
  sync_anchor()
  if st.session:state() == "composing" then
    if st.session:is_latin() then
      st.session:input(" ") -- 英字ラン中はスペースも英字の一部(確定は Enter のみ)
      render()
      return
    end
    if st.session:preedit() == "" then
      insert_literal(" ") -- 未確定なし: 通常のスペース
      return
    end
    -- 補完の選択中でも <Space> は読みの通常変換に入る(session は読みを保持している)。
    reset_completion()
    st.session:start_conversion()
    st.popup_open = false -- 1回目の Space は変換開始のみ(候補一覧は出さない)
    render()
  else
    st.session:next_candidate()
    st.popup_open = true -- 2回目以降の Space で候補一覧を表示
    render()
  end
end

function M.on_commit()
  if not st.enabled then
    return
  end
  sync_anchor()
  -- 補完候補が選択されていれば、それを <CR> で確定する(Google 日本語入力風)。
  if commit_completion_selection() then
    return
  end
  if st.session:state() == "composing" and st.session:preedit() == "" then
    insert_literal("\n") -- 未確定なし: 通常の改行
    return
  end
  -- 混在変換: CR ごとに次 kana セグメントへ進行。継続中(nil)なら描画し直す。
  local text = st.session:commit_step()
  if text == nil then
    render()
  else
    finalize(text)
  end
end

function M.on_cancel()
  if not st.enabled then
    return
  end
  st.session:cancel()
  render()
  refresh_completion() -- 変換取消で読みへ戻ったら補完を出し直す(未確定なしなら閉じる)
end

-- Esc(補完 popup 表示中のみマップ): 候補の選択中は cancel(<C-g>)と同じく未確定を破棄する。
-- 未選択(読みのまま)なら通常の Esc として素通しし、InsertLeave の確定フローに任せる。
function M.on_completion_cancel()
  if st.enabled and st.completion.items and st.completion.index > 0 then
    M.on_cancel()
    return
  end
  st.backend:passthrough("<Esc>")
end

function M.on_backspace()
  if not st.enabled then
    return
  end
  -- 補完候補の選択中は、まず選択を解除して読みへ戻す(削除はしない)。
  if st.completion.items and st.completion.index > 0 then
    select_completion(-st.completion.index) -- index 0(読み)へ
    return
  end
  if st.session:state() == "composing" and st.session:preedit() == "" then
    -- 未確定なし: 通常の BS として素通し
    st.backend:passthrough("<BS>")
    return
  end
  st.session:backspace()
  render()
  refresh_completion()
end

-- F7: 現在の読みをカタカナに変換して確定する。
function M.on_katakana()
  if not st.enabled then
    return
  end
  sync_anchor()
  local kata = st.session:commit_katakana()
  if kata ~= "" then
    finalize(kata)
  end
end

-- F10: 入力したローマ字を英小文字として確定する(例: ふぉお → foo)。
function M.on_alphabet()
  if not st.enabled then
    return
  end
  sync_anchor()
  local letters = st.session:commit_alphabet()
  if letters ~= "" then
    finalize(letters)
  end
end

-- C-w(単語削除)/C-u(行削除)。未確定があれば IME のキャンセル、無ければ素通し。
function M.on_kill(key)
  if not st.enabled then
    return
  end
  sync_anchor()
  if st.session:state() == "converting" or st.session:preedit() ~= "" then
    st.session:clear()
    reset_completion()
    render() -- 未確定を消す
  else
    st.backend:passthrough(key)
  end
end

-- 挿入モードを抜けるとき: 未確定/変換中を確定して IME 状態を掃除する。
-- これにより、抜けた後のノーマルモード編集(オペレータ/テキストオブジェクト/undo 等)が
-- 確定済みのプレーンテキストに対して安全に効く。
function M.on_insert_leave()
  if not st.enabled then
    return
  end
  if
    not (
      st.backend
      and st.backend.kind == "buffer" -- terminal-job モードは InsertLeave ではなく TermLeave(on_term_leave)で扱う
      and api.nvim_buf_is_valid(st.backend.buf)
      and api.nvim_get_current_buf() == st.backend.buf
    )
  then
    return
  end
  -- 補完候補の選択中は選択候補で確定する(学習も走る)。
  if commit_completion_selection() then
    st.popup_open = false
    return
  end
  reset_completion()
  local s = st.session
  if s and (s:state() == "converting" or s:preedit() ~= "") then
    s:commit() -- 変換中なら学習。確定テキストは既にバッファにあるので残す
    st.backend:clear()
    st.backend.len = 0
  end
  st.popup_open = false
end

-- terminal-job モードを抜けるとき: 未確定/変換中を「破棄」する(commit しない)。
-- on_insert_leave とは非対称にあえてこうしている: leave しただけで確定テキストが
-- PTY(シェル)へ送られてしまうのを避けるため。
function M.on_term_leave()
  if not st.enabled then
    return
  end
  if
    not (
      st.backend
      and st.backend.kind == "terminal"
      and api.nvim_buf_is_valid(st.backend.buf)
      and api.nvim_get_current_buf() == st.backend.buf
    )
  then
    return
  end
  reset_completion()
  st.session:clear()
  st.backend:clear()
  st.popup_open = false
  sync_converting_keymap() -- converting 限定キーが張られていれば外す
end

function M.on_next_segment()
  if st.enabled then
    st.session:next_segment()
    render() -- popup が開いていれば render が追従表示
  end
end

function M.on_prev_segment()
  if st.enabled then
    st.session:prev_segment()
    render() -- popup が開いていれば render が追従表示
  end
end

function M.on_expand()
  if st.enabled then
    st.session:expand()
    render() -- popup が開いていれば render が追従表示
  end
end

function M.on_shrink()
  if st.enabled then
    st.session:shrink()
    render() -- popup が開いていれば render が追従表示
  end
end

-- 変換中は文節候補を、composing の補完 popup 表示中は補完候補を次/前へ送る。
function M.on_next_candidate()
  if not st.enabled then
    return
  end
  if st.session:state() == "converting" then
    st.session:next_candidate()
    st.popup_open = true
    render()
  elseif st.completion.items then
    select_completion(1)
  end
end

function M.on_prev_candidate()
  if not st.enabled then
    return
  end
  if st.session:state() == "converting" then
    st.session:prev_candidate()
    st.popup_open = true
    render()
  elseif st.completion.items then
    select_completion(-1)
  end
end

-- C-r: 注目文節の読みをユーザ入力の単語で辞書登録し、その単語で確定挿入する。
-- converting 中のみ動作。プロンプトの cancel(nil) や空入力では未確定を維持する。
function M.on_register_word()
  if not st.enabled or st.session:state() ~= "converting" then
    return
  end
  if not st.backend.supports("register_word") then
    return -- terminal/cmdline: vim.ui.input の入れ子を避けるため対応しない
  end
  local yomi = st.session:current_segment_yomi()
  if not yomi or yomi == "" then
    return
  end
  vim.ui.input({ prompt = string.format("「%s」に登録する単語: ", yomi) }, function(word)
    if word == nil then
      return -- ユーザがキャンセル
    end
    word = vim.trim(word)
    if word == "" then
      return
    end
    if not anthy.register_word(yomi, word) then
      vim.notify("vime: 辞書登録に失敗しました(libanthydic 未検出?)", vim.log.levels.WARN)
      return
    end
    -- プロンプト中に状態が変わっていないか保護
    if not st.enabled or not (st.backend and api.nvim_buf_is_valid(st.backend.buf)) then
      return
    end
    if st.session:state() ~= "converting" then
      return
    end
    finalize(st.session:commit_with_replacement(word))
  end)
end

----------------------------------------------------------------------
-- モード制御
----------------------------------------------------------------------

-- 現モードが直近通知した name と変わっていれば User VimeModeChanged を発火。
-- 副作用: st.last_mode_name を更新。設定で有効ならカーソル下に短時間ラベルも表示する。
-- 公開ハンドラ(M.on_xxx)・toggle・on_insert_leave の末尾でラップ越しに呼ばれる。
local function notify_mode_change_if_needed()
  local current = M.mode()
  if st.last_mode_name == current.name then
    return
  end
  st.last_mode_name = current.name
  api.nvim_exec_autocmds("User", { pattern = "VimeModeChanged", data = current })
  local cfg = st.cfg and st.cfg.mode_notify
  if cfg and cfg.enabled then
    local label = (cfg.labels and cfg.labels[current.name]) or current.name
    ui.show_mode_notify(label, cfg.duration or 1000)
  end
end

-- 補完(nvim-cmp)が候補を出しうる状態か。enabled かつ composing かつ未確定がある。
-- enabled() から高頻度で呼ばれうるため、候補生成はせず軽量に判定する。
function M.completion_active()
  local s = st.session
  return st.enabled
    and s ~= nil
    and st.backend ~= nil
    and st.backend.supports("completion")
    and s:state() == "composing"
    and s:preedit() ~= ""
end

-- 補完コンテキスト。候補が無ければ nil。cmp source の complete から呼ばれる(候補生成を伴う重い経路)。
-- 未確定領域の byte 位置(row/start_col/len)と読み yomi・候補 items を返す。
function M.completion_context()
  if not M.completion_active() then
    return nil
  end
  local items = st.session:completion_candidates()
  if #items == 0 then
    return nil
  end
  return {
    row = st.backend.row,
    start_col = st.backend.start_col,
    len = st.backend.len,
    yomi = items[1].yomi,
    items = items,
  }
end

-- cmp が textEdit で未確定領域を候補テキストへ置換した後に呼ばれる。session を学習 commit し、
-- IME 状態(extmark・未確定領域長・popup)を掃除する。バッファ操作は cmp が済ませているので行わない。
-- 次のハンドラの sync_anchor が len==0 で実カーソル位置へ再アンカーする。
function M.commit_completion(item)
  if not (st.enabled and st.session and st.backend and api.nvim_buf_is_valid(st.backend.buf)) then
    return
  end
  st.session:commit_completion(item)
  st.backend:clear()
  st.backend.len = 0
  st.popup_open = false
  st.last_preedit_key = nil -- 同じ読みを再入力したときに再通知されるようリセット
  sync_converting_keymap()
end

-- 未確定文字列が直近通知から変わっていれば User VimePreeditChanged を発火する。
-- data = { state, preedit, available }。integration 側が available で cmp.complete/close を切り替える。
-- 公開ハンドラ・toggle・on_insert_leave の末尾でラップ越しに呼ばれる。
local function notify_preedit_change_if_needed()
  local s = st.enabled and st.session or nil
  local state = s and s:state() or "direct"
  local preedit = s and s:preedit() or ""
  local key = state .. "\0" .. preedit
  if st.last_preedit_key == key then
    return
  end
  st.last_preedit_key = key
  api.nvim_exec_autocmds("User", {
    pattern = "VimePreeditChanged",
    data = { state = state, preedit = preedit, available = M.completion_active() },
  })
end

handlers = function()
  return {
    input = M.on_input,
    convert = M.on_convert,
    commit = M.on_commit,
    cancel = M.on_cancel,
    backspace = M.on_backspace,
    next_segment = M.on_next_segment,
    prev_segment = M.on_prev_segment,
    expand = M.on_expand,
    shrink = M.on_shrink,
    next_candidate = M.on_next_candidate,
    prev_candidate = M.on_prev_candidate,
    completion_cancel = M.on_completion_cancel,
    katakana = M.on_katakana,
    alphabet = M.on_alphabet,
    kill = M.on_kill,
    register_word = M.on_register_word,
  }
end

-- IME ターゲットを new_backend に切り替える。旧 backend のマッピング・描画を掃除し、
-- new_backend の keymap を attach する。attach_to_current_buf()/attach_to_terminal_buf()
-- の共通処理。
local function switch_backend(new_backend)
  if st.backend and st.backend.buf ~= new_backend.buf then
    -- 旧バッファが wipe 済みなら Vim 側で buffer-local maps は既に消えているので
    -- detach を呼ばない(~104 回の vim.keymap.del を節約)。
    if api.nvim_buf_is_valid(st.backend.buf) then
      st.backend:clear()
      keymap.detach(st.backend.buf, st.backend.keymap_mode)
    end
    st.converting_keys_attached = false
    st.completion_keys_attached = false
  end
  st.backend = new_backend
  st.popup_open = false
  st.completion.items = nil
  st.completion.index = 0
  keymap.attach(st.backend.buf, st.cfg, handlers(), st.backend.keymap_mode)
end

-- IME ターゲットを現在のバッファ(通常バッファ + 挿入モード)に合わせる。
-- enable() と InsertEnter autocmd の両方から呼ばれる。
local function attach_to_current_buf()
  local new_buf = api.nvim_get_current_buf()
  local b = backend_buffer.new(new_buf)
  local cur = api.nvim_win_get_cursor(0)
  b.row = cur[1] - 1
  b.start_col = cur[2]
  switch_backend(b)
end

-- IME ターゲットを terminal バッファ(terminal-job モード)に合わせる。
-- enable() と TermEnter autocmd の両方から呼ばれる。
local function attach_to_terminal_buf(buf)
  switch_backend(backend_terminal.new(buf))
end

-- cmdline backend を割り込ませる。switch_backend() は使わない: cmdline は特定のバッファに
-- 紐付く永続的な backend ではなく、":"/"?"/"?" の間だけ既存の backend(buffer/terminal)に
-- 割り込む一時的なものなので、現在の backend を st.saved_backend に退避して
-- CmdlineLeave(detach_cmdline_backend)で復元する。"c" のキーマップはグローバルなので
-- 既存 backend のキーマップは detach しない(モードが違うので衝突しない)。
local function attach_cmdline_backend()
  st.saved_backend = st.backend
  st.backend = backend_cmdline.new(api.nvim_get_current_buf())
  st.popup_open = false
  st.completion.items = nil
  st.completion.index = 0
  keymap.attach(st.backend.buf, st.cfg, handlers(), st.backend.keymap_mode)
end

-- cmdline backend を外し、割り込む前の backend へ戻す(CmdlineLeave から呼ぶ)。
-- 退避先が無かった場合(enable 直後に cmdline から始まった等)は現在バッファへ再アンカーする。
local function detach_cmdline_backend()
  keymap.detach(st.backend.buf, st.backend.keymap_mode)
  st.backend:clear()
  st.converting_keys_attached = false
  st.completion_keys_attached = false
  if st.saved_backend then
    st.backend = st.saved_backend
    st.saved_backend = nil
  else
    attach_to_current_buf()
  end
end

-- 現在のコンテキストに応じて backend を選ぶ: cmdline セッション中なら cmdline backend、
-- terminal バッファなら terminal backend、それ以外は buffer backend。terminal-job モードへ
-- 実際に入っていなくても(Normal モードで terminal バッファ上にいるだけでも)terminal
-- backend を張ってよい: "t" モードのキーマップは実際に terminal-job モードへ入って
-- 初めて効くので害はない。
local function attach_to_current_context()
  local cmdtype = vim.fn.getcmdtype()
  if st.cfg.cmdline.enabled and CMDLINE_TYPES[cmdtype] then
    attach_cmdline_backend()
    return
  end
  local cur_buf = api.nvim_get_current_buf()
  if st.cfg.terminal.enabled and vim.bo[cur_buf].buftype == "terminal" then
    attach_to_terminal_buf(cur_buf)
  else
    attach_to_current_buf()
  end
end

local function enable()
  st.enabled = true
  st.session = session.new(anthy, {
    ascii_toggle = st.cfg.keymaps.ascii_toggle,
    romaji_table = st.cfg.romaji.table,
  })
  attach_to_current_context()
end

local function disable()
  local valid = st.backend and api.nvim_buf_is_valid(st.backend.buf)
  -- 補完候補の選択中は選択候補で確定してから OFF(学習も走る)
  if valid and commit_completion_selection() then
    st.popup_open = false
  end
  -- 未確定/変換中があれば確定してから OFF
  local s = st.session
  if s and valid and (s:state() == "converting" or s:preedit() ~= "") then
    finalize(s:commit())
  end
  if valid then
    st.backend:clear()
    keymap.detach(st.backend.buf, st.backend.keymap_mode) -- 共通・converting/補完限定マップをすべて掃除する
  end
  -- cmdline backend が割り込み中に OFF された場合、退避していた元 backend(buffer/terminal)
  -- のキーマップも掃除する。st.backend(cmdline の "c" グローバルマッピング)を detach しても
  -- 割り込まれた側の "i"/"t" バッファローカルマッピングは残ってしまうため。
  if st.saved_backend and api.nvim_buf_is_valid(st.saved_backend.buf) then
    keymap.detach(st.saved_backend.buf, st.saved_backend.keymap_mode)
  end
  st.saved_backend = nil
  st.enabled = false
  st.session = nil
  st.converting_keys_attached = false
  st.completion_keys_attached = false
  st.completion.items = nil
  st.completion.index = 0
end

-- 日本語入力 ON/OFF をトグルする。
function M.toggle()
  if not st.anthy_ok then
    vim.notify(M.install_hint(), vim.log.levels.WARN)
    return
  end
  if st.enabled then
    disable()
  else
    enable()
  end
end

-- 状態確認(テスト/デバッグ用)。
function M.is_enabled()
  return st.enabled
end

-- 現在のモードを返す。ステータスライン等から参照する公開 API。
-- 戻り値: { name, enabled, state, ascii, latin }
--   name: "direct" | "hiragana" | "ascii"
-- 変換中も name は "hiragana" のまま(候補 popup でシグナルされる)。state で区別可。
function M.mode()
  local s = st.session
  return mode.compute({
    enabled = st.enabled,
    state = s and s:state() or nil,
    ascii = s and s:is_ascii() or false,
    latin = s and s:is_latin() or false,
  })
end

-- 公開ハンドラ・toggle・on_insert_leave をモード変化通知付きに置換する。
-- 直接呼出(`vime.on_xxx()`/`vime.toggle()`)経路と keymap 経路の両方で通知が走る。
local NOTIFY_TARGETS = {
  "on_input",
  "on_convert",
  "on_commit",
  "on_cancel",
  "on_backspace",
  "on_next_segment",
  "on_prev_segment",
  "on_expand",
  "on_shrink",
  "on_next_candidate",
  "on_prev_candidate",
  "on_katakana",
  "on_alphabet",
  "on_kill",
  "on_register_word",
  "on_insert_leave",
  "on_term_leave",
  "toggle",
}
for _, name in ipairs(NOTIFY_TARGETS) do
  local fn = M[name]
  M[name] = function(...)
    local r = fn(...)
    notify_mode_change_if_needed()
    notify_preedit_change_if_needed()
    return r
  end
end

function M.setup(opts)
  st.cfg = config.merge(opts)
  ui.setup({ mode_notify_highlight = st.cfg.mode_notify.highlight })
  local lib = st.cfg.anthy.lib or config.find_anthy_lib()
  st.anthy_ok = lib ~= nil and anthy.setup(lib)
  if not st.anthy_ok then
    vim.notify(M.install_hint(), vim.log.levels.WARN)
  end
  vim.keymap.set("i", st.cfg.keymaps.toggle, M.toggle, { desc = "vime: toggle japanese input" })
  vim.keymap.set("t", st.cfg.keymaps.toggle, M.toggle, { desc = "vime: toggle japanese input (terminal)" })
  vim.keymap.set("c", st.cfg.keymaps.toggle, M.toggle, { desc = "vime: toggle japanese input (cmdline)" })

  -- 挿入モードを抜けたら未確定を確定する(ノーマルモード編集を安全にする)
  local group = api.nvim_create_augroup("vime", { clear = true })
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      M.on_insert_leave()
    end,
  })

  -- IME ON のままユーザーが別バッファで挿入モードに入ったら、IME ターゲットを
  -- その新バッファへ追従させる。BufEnter は telescope プレビュー等で大量発火する
  -- ため避け、本当に編集を開始する瞬間(InsertEnter)に絞っている。
  -- terminal バッファは InsertEnter ではなく TermEnter(terminal-job モード)で扱う。
  -- prompt buftype は IME が握ると UX が壊れるので除外する。
  api.nvim_create_autocmd("InsertEnter", {
    group = group,
    desc = "vime: follow buffer switches",
    callback = function(args)
      if not st.enabled then
        return
      end
      if st.backend and args.buf == st.backend.buf then
        return
      end
      local bt = vim.bo[args.buf].buftype
      if bt == "terminal" or bt == "prompt" then
        return
      end
      attach_to_current_buf()
    end,
  })

  -- IME ON のまま terminal-job モードへ入ったら、IME ターゲットをその terminal バッファへ
  -- 追従させる(InsertEnter の terminal 版)。
  api.nvim_create_autocmd("TermEnter", {
    group = group,
    desc = "vime: follow terminal-job mode",
    callback = function(args)
      if not st.enabled or not st.cfg.terminal.enabled then
        return
      end
      if st.backend and args.buf == st.backend.buf then
        return
      end
      attach_to_terminal_buf(args.buf)
    end,
  })

  -- terminal-job モードを抜けたら未確定を破棄する(InsertLeave とは非対称。M.on_term_leave 参照)。
  api.nvim_create_autocmd("TermLeave", {
    group = group,
    callback = function()
      M.on_term_leave()
    end,
  })

  -- IME ON のまま ":"/"/"/"?" の cmdline に入ったら、既存の backend(buffer/terminal)に
  -- cmdline backend を割り込ませる。"@"(input())・"="(式レジスタ)等は対象外。
  api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    desc = "vime: attach cmdline backend",
    callback = function()
      if not st.enabled or not st.cfg.cmdline.enabled or not CMDLINE_TYPES[vim.fn.getcmdtype()] then
        return
      end
      attach_cmdline_backend()
    end,
  })

  -- cmdline を抜けたら cmdline backend を外し、割り込む前の backend へ戻す。
  -- Esc/C-c(v:event.abort)は未確定を破棄、<CR> 実行や他コマンドでの正常終了は学習だけ行う
  -- (確定テキストは commit_step/finalize で既に setcmdline 済みなのでここでは書き込まない)。
  api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    desc = "vime: detach cmdline backend",
    callback = function()
      if not (st.enabled and st.backend and st.backend.kind == "cmdline") then
        return
      end
      reset_completion()
      if vim.v.event.abort then
        st.session:clear()
      elseif st.session:state() == "converting" or st.session:preedit() ~= "" then
        st.session:commit()
      end
      detach_cmdline_backend()
    end,
  })

  if st.cfg.integrations.nvim_cmp then
    require("vime.integrations.nvim_cmp").attach(M.is_enabled, group)
  end
end

return M
