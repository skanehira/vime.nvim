local vime = require("vime")

local api = vim.api
local LIB = assert(require("vime.config").find_anthy_lib(), "libanthy not found; set $VIME_ANTHY_LIB")

describe("vime end-to-end", function()
  -- テスト独立性: 各テスト開始時は日本語入力 OFF にしておく
  before_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
  end)

  it("converts typed romaji into Japanese in the buffer", function()
    vime.setup({ anthy = { lib = LIB } })

    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    vime.toggle() -- 日本語入力 ON
    assert.is_true(vime.is_enabled())

    -- 注: 巨大な private_words_default 環境では長い読みで anthy が SIGSEGV することが
    -- あるため、確実に動く短めの読みを使う。
    for ch in ("kyouhaii"):gmatch(".") do
      vime.on_input(ch)
    end
    -- 変換前: 未確定かなが入っている
    assert.are.equal("きょうはいい", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    vime.on_convert() -- Space → 変換
    vime.on_commit() -- Enter → 確定

    -- 変換された(生かなのまま残らない)ことを検証する。
    -- 先頭候補・文節境界は anthy の辞書バージョン依存なので絶対値では検証しない。
    local result = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are_not.equal("きょうはいい", result)
    assert.is_not_nil(result, "確定結果がバッファに残る")

    vime.toggle() -- OFF
    assert.is_false(vime.is_enabled())
  end)

  it("recovers when the user deletes committed text with backspace then types again", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    if vime.is_enabled() then
      vime.toggle()
    end

    vime.toggle()
    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_commit() -- バッファ "か"、未確定なし
    assert.are.equal("か", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    -- ユーザーが Backspace で "か" を実削除した状況(管理外のバッファ変更)
    api.nvim_buf_set_text(buf, 0, 0, 0, #"か", { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })

    -- 再入力してもクラッシュせず、正しい位置に入る
    assert.has_no.errors(function()
      for ch in ("ki"):gmatch(".") do
        vime.on_input(ch)
      end
    end)
    assert.are.equal("き", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("inserts a literal space when there is no preedit", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    vime.toggle()

    vime.on_convert() -- 未確定なし → スペース挿入
    assert.are.equal(" ", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("inserts a newline when there is no preedit", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    vime.toggle()

    vime.on_commit() -- 未確定なし → 改行挿入
    assert.are.equal(2, api.nvim_buf_line_count(buf))
  end)

  it("routes symbols through the IME without stranding them", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    vime.toggle()

    for ch in ("supe-"):gmatch(".") do
      vime.on_input(ch)
    end
    -- 記号 "-" も未確定に取り込まれ、取り残されない
    assert.are.equal("すぺー", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("commits the preedit and clears IME state when leaving insert mode", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    vime.toggle()

    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_insert_leave() -- Esc 相当: 未確定を確定して掃除

    -- 確定済みテキストが残り、装飾(extmark)は消えている
    assert.are.equal("か", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    local ns = require("vime.ui").namespace()
    assert.are.equal(0, #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  end)

  it("clears the composition on C-w/C-u while composing", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    vime.toggle()

    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_kill("<C-u>") -- 未確定があるのでキャンセル
    assert.are.equal("", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("gives OS-specific install guidance when anthy is missing", function()
    local mac = vime.install_hint("OSX")
    assert.is_truthy(mac:find("anthy%-unicode"))
    assert.is_truthy(mac:find("meson"))
    local linux = vime.install_hint("Linux")
    assert.is_truthy(linux:find("anthy%-unicode"))
    assert.is_truthy(linux:find("dnf"))
  end)

  it("toggles off cleanly and leaves committed text", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    vime.toggle()
    for ch in ("watashi"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.toggle() -- OFF 時に未確定かなを確定する

    assert.is_false(vime.is_enabled())
    assert.are.equal("わたし", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("steps through mixed kana segments via ASCII mode (; toggle)", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    vime.toggle()
    -- kyouha は anthy で「今日は」に安定的に変わる(kyou 単独だと「きょう」のままになる)
    for ch in ("kyouha;A;wo"):gmatch(".") do
      vime.on_input(ch)
    end
    -- preedit: kana(きょうは) + latin(A) + kana(を)
    assert.are.equal("きょうはAを", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    vime.on_convert() -- 先頭 kana(きょうは) を変換
    vime.on_commit() -- 1段目: きょうは 確定 → 次の kana(を) を自動 converting
    vime.on_commit() -- 2段目: を 確定 → 全終了

    local result = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    -- 文節候補は辞書バージョン依存なので絶対値では検証しない。
    -- 「変換された(生かなのまま残らない)」「latin A はリテラルで残る」が要点。
    assert.are_not.equal("きょうはAを", result)
    assert.is_not_nil(result:find("A", 1, true), "latin A はリテラルで残る")

    vime.toggle()
  end)

  it("exposes the current mode via vime.mode()", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    -- IME OFF: direct
    assert.are.same({ name = "direct", enabled = false, state = nil, ascii = false, latin = false }, vime.mode())

    vime.toggle() -- ON
    assert.are.same(
      { name = "hiragana", enabled = true, state = "composing", ascii = false, latin = false },
      vime.mode()
    )

    -- ASCII モード突入
    vime.on_input(";")
    assert.are.same({ name = "ascii", enabled = true, state = "composing", ascii = true, latin = false }, vime.mode())

    -- ASCII モード解除して変換中へ
    vime.on_input(";")
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert()
    -- 変換中は name に出さず hiragana のまま(候補 popup 側でシグナル)。
    -- state フィールドだけが "converting" を保持する。
    assert.are.same(
      { name = "hiragana", enabled = true, state = "converting", ascii = false, latin = false },
      vime.mode()
    )

    vime.on_cancel()
    vime.toggle() -- OFF
  end)

  it("fires User VimeModeChanged when the mode name changes", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    local events = {}
    local id = api.nvim_create_autocmd("User", {
      pattern = "VimeModeChanged",
      callback = function(args)
        events[#events + 1] = args.data
      end,
    })

    vime.toggle() -- direct → hiragana
    vime.on_input("k") -- hiragana → hiragana (no event)
    vime.on_input(";") -- hiragana → ascii
    vime.on_input(";") -- ascii → hiragana
    vime.on_cancel()
    vime.toggle() -- hiragana → direct

    api.nvim_del_autocmd(id)

    local names = {}
    for _, ev in ipairs(events) do
      names[#names + 1] = ev.name
    end
    assert.are.same({ "hiragana", "ascii", "hiragana", "direct" }, names)

    -- data には mode テーブル全体が乗る
    assert.are.same({ name = "hiragana", enabled = true, state = "composing", ascii = false, latin = false }, events[1])
    assert.are.same({ name = "ascii", enabled = true, state = "composing", ascii = true, latin = false }, events[2])
  end)

  it("shows a mode notify popup with the configured label on mode change", function()
    vime.setup({
      anthy = { lib = LIB },
      mode_notify = { duration = 100, labels = { hiragana = "HIRA" } },
    })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    vime.toggle() -- direct → hiragana
    -- 直前に開かれた mode notify window を探す(buf 1行目がラベル)
    local found
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(w).relative ~= "" then
        local b = api.nvim_win_get_buf(w)
        local line = api.nvim_buf_get_lines(b, 0, 1, false)[1]
        if line == "HIRA" then
          found = w
        end
      end
    end
    assert.is_not_nil(found)

    -- duration 経過で自動的に閉じる
    vime.toggle() -- OFF (popup は別の direct ラベルへ置換 → 元の HIRA は閉じている)
    require("vime.ui").close_mode_notify() -- 後続テストへの影響を防ぐ
  end)

  it("does not show the mode notify popup when disabled in config", function()
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    local before = #api.nvim_list_wins()
    vime.toggle() -- direct → hiragana
    local after = #api.nvim_list_wins()
    assert.are.equal(before, after)
    vime.toggle() -- OFF
  end)

  it("converts the preedit to lowercase letters on F10", function()
    vime.setup({ anthy = { lib = LIB } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    vime.toggle()
    for ch in ("foo"):gmatch(".") do
      vime.on_input(ch)
    end
    assert.are.equal("ふぉお", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    vime.on_alphabet() -- F10: 入力したローマ字(英小文字)で確定
    assert.are.equal("foo", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    vime.toggle()
  end)
end)

describe("vime candidate popup", function()
  -- 現在のタブページに開いているフローティング window(候補 popup)の数。
  local function floating_win_count()
    local n = 0
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(w).relative ~= "" then
        n = n + 1
      end
    end
    return n
  end

  local function fresh_buf()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })
    return buf
  end

  before_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
    -- 候補 popup の検証に集中するためモード通知 popup は無効化(floating window 数を乱さない)
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false } })
    -- 前テストの mode notify popup が残っていれば確実に閉じる
    require("vime.ui").close_mode_notify()
  end)

  after_each(function()
    if vime.is_enabled() then
      vime.toggle() -- popup を確実に閉じてテスト間を隔離
    end
  end)

  it("does not show the popup on the first Space (conversion start)", function()
    fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 1回目: 変換開始のみ。候補一覧は出さない
    assert.are.equal(0, floating_win_count())
  end)

  it("shows the popup on the second Space (candidate cycling)", function()
    fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 1回目: 変換開始
    vime.on_convert() -- 2回目: 候補巡回 → popup 表示
    assert.are.equal(1, floating_win_count())
  end)

  it("shows the popup when navigating candidates with C-n", function()
    fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 変換開始(popup なし)
    vime.on_next_candidate() -- C-n → popup 表示
    assert.are.equal(1, floating_win_count())
  end)

  it("keeps the popup on the focused segment when moving or resizing segments", function()
    fresh_buf()
    vime.toggle()
    -- 短い読みで複数文節(きょう|はいい 等)を作る(長い読みは SIGSEGV を避ける)
    for ch in ("kyouhaii"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 変換開始
    vime.on_convert() -- 巡回 → popup 表示
    assert.are.equal(1, floating_win_count())
    vime.on_next_segment() -- 注目文節を移動 → popup が追従
    assert.are.equal(1, floating_win_count())
    vime.on_expand() -- 文節を伸長 → popup が追従
    assert.are.equal(1, floating_win_count())
  end)

  it("closes the popup after committing", function()
    fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 変換開始
    vime.on_convert() -- 巡回 → popup 表示
    assert.are.equal(1, floating_win_count())
    vime.on_commit()
    assert.are.equal(0, floating_win_count())
  end)

  it("closes the popup when leaving insert mode", function()
    fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 変換開始
    vime.on_convert() -- 巡回 → popup 表示
    assert.are.equal(1, floating_win_count())
    vime.on_insert_leave()
    assert.are.equal(0, floating_win_count())
  end)

  it("commits the conversion when more input is typed during selection", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 変換開始
    vime.on_convert() -- 巡回(popup 表示)
    assert.are.equal(1, floating_win_count())
    -- 旧ラベル文字 "k" を入力 → ラベル選択ではなく確定して新規入力に回る
    vime.on_input("k")
    local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are.equal("k", line:sub(-1)) -- 末尾は新規入力の k
    assert.are.equal(0, floating_win_count()) -- 確定で popup は閉じる
  end)

  it("shows the candidate popup above a host floating window", function()
    -- フローティングウィンドウ(AI 入力欄など)の中で入力するシナリオ
    local host_buf = api.nvim_create_buf(false, true)
    local host = api.nvim_open_win(host_buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 30,
      height = 6,
    })
    api.nvim_win_set_cursor(host, { 1, 0 })
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- 変換開始
    vime.on_convert() -- 巡回 → popup 表示

    -- ホスト以外のフローティング(=vime の候補 popup)を探す
    local popup
    for _, w in ipairs(api.nvim_list_wins()) do
      if w ~= host and api.nvim_win_get_config(w).relative ~= "" then
        popup = w
      end
    end
    assert.is_not_nil(popup) -- ホスト float の中でも候補 popup が開く
    local host_z = api.nvim_win_get_config(host).zindex
    local popup_z = api.nvim_win_get_config(popup).zindex
    assert.is_true(popup_z > host_z) -- ホストより前面に出る(後ろに隠れない)

    api.nvim_win_close(host, true)
  end)
end)

describe("vime converting-only keymaps follow state transitions", function()
  -- converting 状態でのみ vime が文節操作系キー(C-f/C-b/C-n/C-p/C-o/C-i)を奪い、
  -- composing / ASCII 直入力 / direct ではユーザの insert マッピングを生かす。
  local CONVERTING_KEYS = { "<C-F>", "<C-B>", "<C-N>", "<C-P>", "<C-O>", "<C-I>" }

  local function any_mapped(buf)
    for _, lhs in ipairs(CONVERTING_KEYS) do
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, "i")) do
        if m.lhs == lhs or m.lhs == lhs:lower() then
          return true
        end
      end
    end
    return false
  end

  local function fresh_buf()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })
    return buf
  end

  before_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false } })
  end)

  after_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
  end)

  it("does not map converting keys while composing", function()
    local buf = fresh_buf()
    vime.toggle() -- ON, state="composing"
    assert.is_false(any_mapped(buf))

    -- composing で未確定が残っている状態でもマップしない
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    assert.is_false(any_mapped(buf))
  end)

  it("maps converting keys upon entering converting and unmaps on commit", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end

    vime.on_convert() -- composing → converting
    assert.is_true(any_mapped(buf))

    vime.on_commit() -- converting → composing
    assert.is_false(any_mapped(buf))
  end)

  it("unmaps converting keys on cancel", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- converting
    assert.is_true(any_mapped(buf))

    vime.on_cancel()
    assert.is_false(any_mapped(buf))
  end)

  it("unmaps converting keys when killed during conversion", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert()
    assert.is_true(any_mapped(buf))

    vime.on_kill("<C-u>")
    assert.is_false(any_mapped(buf))
  end)

  it("unmaps converting keys when toggling OFF mid-conversion", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert()
    assert.is_true(any_mapped(buf))

    vime.toggle() -- OFF
    assert.is_false(any_mapped(buf))
  end)
end)

describe("vime undo blocks", function()
  -- 実ユーザのキー入力相当を keymap 経由で送る。"x" で typeahead 同期消化、
  -- "t" で typed key 扱い(undo の判断・マッピング解釈を実環境と揃える)。
  local function feed(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "tx", false)
  end

  local function fresh_buf()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    return buf
  end

  before_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false } })
  end)

  after_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
  end)

  it("breaks the undo block at each commit so u restores one commit at a time", function()
    local buf = fresh_buf()
    vime.toggle()

    -- 挿入モードに入り「あいうえお<CR>かきくけこ<CR><Esc>」を実キーで打つ。
    -- CR ごとに finalize → <C-G>u で undo ブロックが区切られる。
    feed("iaiueo<CR>kakikukeko<CR><Esc>")
    assert.are.equal("あいうえおかきくけこ", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    -- 1回目 undo: 直近確定の「かきくけこ」だけが消える
    vim.cmd("undo")
    assert.are.equal("あいうえお", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    -- 2回目 undo: その前の確定の「あいうえお」が消える
    vim.cmd("undo")
    assert.are.equal("", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("breaks the undo block on katakana (F7) commit too", function()
    local buf = fresh_buf()
    vime.toggle()

    feed("iaiueo<F7>kakiku<F7><Esc>")
    assert.are.equal("アイウエオカキク", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    vim.cmd("undo")
    assert.are.equal("アイウエオ", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    vim.cmd("undo")
    assert.are.equal("", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("does not break the undo block for literal spaces inserted without preedit", function()
    local buf = fresh_buf()
    vime.toggle()

    -- 未確定なしで Space を 3 回 → insert_literal で素通し挿入(IME 確定ではない)
    feed("i   <Esc>")
    assert.are.equal("   ", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    -- IME 確定経由ではないので Vim 標準どおり 1 ブロック扱い: 1 回 undo で全部消える
    vim.cmd("undo")
    assert.are.equal("", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)
end)

describe("vime integrations wiring", function()
  local function vime_insert_enter_autocmds()
    return vim.api.nvim_get_autocmds({ group = "vime", event = "InsertEnter" })
  end

  it("does not register the nvim_cmp InsertEnter autocmd by default", function()
    -- 既定では integrations.nvim_cmp = false なので結線しない。
    vime.setup({ anthy = { lib = LIB } })
    assert.are.equal(0, #vime_insert_enter_autocmds())
  end)

  it("registers an InsertEnter autocmd when integrations.nvim_cmp is enabled", function()
    -- integrations.nvim_cmp = true で attach が走り、cmp 上書き用の InsertEnter
    -- (once) autocmd が "vime" augroup に登録される。
    vime.setup({ anthy = { lib = LIB }, integrations = { nvim_cmp = true } })
    assert.are.equal(1, #vime_insert_enter_autocmds())
    -- 後続テストへ漏れないよう既定構成で setup し直して augroup を clear する。
    vime.setup({ anthy = { lib = LIB } })
  end)
end)
