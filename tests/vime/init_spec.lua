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

  it("threads a custom romaji table through setup -> enable -> on_input", function()
    -- 既定では ka="か", ki="き" だが、入れ替えてカスタムが結線されていることを示す。
    -- setup() の romaji.table が enable() 経由で session に届くかの結線回帰テスト。
    local custom = { ka = "き", ki = "か" }
    vime.setup({ anthy = { lib = LIB }, romaji = { table = custom } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })

    vime.toggle()
    for ch in ("kaki"):gmatch(".") do
      vime.on_input(ch)
    end

    -- 未確定 preedit はそのままバッファに反映される(既定なら "かき")
    assert.are.equal("きか", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  -- terminal/cmdline は opt-in(既定 false)。既定の setup() では toggle キーを挿入モードに
  -- しか張らず、コマンドライン/terminal-job モードでの <C-j> 本来の動作を奪わない。
  it("maps the toggle key only in insert mode by default (cmdline/terminal are opt-in)", function()
    vime.setup({ anthy = { lib = LIB } })
    assert.are.equal("vime: toggle japanese input", vim.fn.maparg("<C-j>", "i", false, true).desc)
    assert.are.same({}, vim.fn.maparg("<C-j>", "c", false, true))
    assert.are.same({}, vim.fn.maparg("<C-j>", "t", false, true))
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
  -- 自前補完は composing 中に C-n/C-p を握るため、この describe では無効化して
  -- converting 限定キーの遷移だけを検証する(補完側の attach/detach は built-in
  -- completion の describe で検証する)。
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
    vime.setup({
      anthy = { lib = LIB },
      mode_notify = { enabled = false },
      completion = { enabled = false },
    })
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

describe("vime register_word (C-r)", function()
  local anthy = require("vime.anthy")

  local function fresh_buf()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })
    return buf
  end

  -- vim.ui.input を answer を返すコールバックでモックして本処理を実行する。
  local function with_ui_input(answer, fn)
    local saved = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm(answer)
    end
    local ok, err = pcall(fn)
    vim.ui.input = saved
    assert(ok, err)
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

  it("commits the focused segment with the user-entered word while converting", function()
    -- 辞書登録 API が無い環境(libanthy-dev 等)では検証不能なのでスキップ。
    if not anthy.register_word("ぶいめてすとa", "ignore") then
      return
    end
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- converting へ

    with_ui_input("テスト語", function()
      vime.on_register_word()
    end)

    assert.are.equal("テスト語", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.are.equal("composing", vime.mode().state) -- 確定後は composing に戻る
  end)

  it("leaves the preedit unchanged when the prompt is canceled", function()
    if not anthy.register_word("ぶいめてすとb", "ignore") then
      return
    end
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert()
    local before = api.nvim_buf_get_lines(buf, 0, 1, false)[1]

    with_ui_input(nil, function()
      vime.on_register_word()
    end)

    assert.are.equal(before, api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.are.equal("converting", vime.mode().state) -- converting のまま
  end)

  it("leaves the preedit unchanged when the entered word is blank", function()
    if not anthy.register_word("ぶいめてすとc", "ignore") then
      return
    end
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert()
    local before = api.nvim_buf_get_lines(buf, 0, 1, false)[1]

    with_ui_input("   ", function() -- 空白のみ
      vime.on_register_word()
    end)

    assert.are.equal(before, api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.are.equal("converting", vime.mode().state)
  end)

  it("does nothing while composing (not converting)", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    -- composing のまま on_register_word を呼ぶ。vim.ui.input は呼ばれない想定。
    local prompted = false
    local saved = vim.ui.input
    vim.ui.input = function(_, _)
      prompted = true
    end
    vime.on_register_word()
    vim.ui.input = saved

    assert.is_false(prompted)
    assert.are.equal("きょう", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.are.equal("composing", vime.mode().state)
  end)
end)

describe("vime follows buffer switches", function()
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

  it("keeps hiragana input working in another buffer entered while ON", function()
    -- バッファ A でひらがな入力できることを確認しておく。
    local buf_a = fresh_buf()
    vime.toggle()
    feed("iaiueo<Esc>")
    assert.are.equal("あいうえお", api.nvim_buf_get_lines(buf_a, 0, 1, false)[1])

    -- IME ON のまま別バッファ B に移動 → 挿入モードでローマ字を打つ。
    local buf_b = fresh_buf()
    assert.is_true(vime.is_enabled())
    feed("ikakikukeko<Esc>")

    -- B にひらがなが入る(現状は ASCII の "kakikukeko" がそのまま残ってしまう)。
    assert.are.equal("かきくけこ", api.nvim_buf_get_lines(buf_b, 0, 1, false)[1])
    -- 旧バッファ A は影響を受けない。
    assert.are.equal("あいうえお", api.nvim_buf_get_lines(buf_a, 0, 1, false)[1])
  end)
end)

describe("vime integrations wiring", function()
  -- "vime" augroup の InsertEnter のうち、nvim-cmp 連携用のものだけを数える
  -- (常駐の buffer-follow autocmd は除外する)。
  local function nvim_cmp_insert_enter_autocmds()
    local result = {}
    for _, cmd in ipairs(vim.api.nvim_get_autocmds({ group = "vime", event = "InsertEnter" })) do
      if cmd.desc == "vime: nvim-cmp integration" then
        result[#result + 1] = cmd
      end
    end
    return result
  end

  it("does not register the nvim_cmp InsertEnter autocmd by default", function()
    -- 既定では integrations.nvim_cmp = false なので結線しない。
    vime.setup({ anthy = { lib = LIB } })
    assert.are.equal(0, #nvim_cmp_insert_enter_autocmds())
  end)

  it("registers an InsertEnter autocmd when integrations.nvim_cmp is enabled", function()
    -- integrations.nvim_cmp = true で attach が走り、cmp 上書き用の InsertEnter
    -- (once) autocmd が "vime" augroup に登録される。
    vime.setup({ anthy = { lib = LIB }, integrations = { nvim_cmp = true } })
    assert.are.equal(1, #nvim_cmp_insert_enter_autocmds())
    -- 後続テストへ漏れないよう既定構成で setup し直して augroup を clear する。
    vime.setup({ anthy = { lib = LIB } })
  end)
end)

describe("vime completion integration", function()
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

  -- User VimePreeditChanged を購読して data を順に集める。返り値の autocmd id は呼び出し側で del する。
  local function collect_preedit_events()
    local events = {}
    local id = api.nvim_create_autocmd("User", {
      pattern = "VimePreeditChanged",
      callback = function(args)
        events[#events + 1] = args.data
      end,
    })
    return events, id
  end

  it("fires User VimePreeditChanged as the preedit changes", function()
    fresh_buf()
    vime.toggle()
    local events, id = collect_preedit_events()
    vime.on_input("k")
    vime.on_input("a")
    api.nvim_del_autocmd(id)
    assert.are.equal(2, #events) -- キー入力ごとに1回
    assert.are.equal("か", events[#events].preedit)
    assert.is_true(events[#events].available)
  end)

  it("fires VimePreeditChanged with an empty preedit after commit", function()
    fresh_buf()
    vime.toggle()
    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    local events, id = collect_preedit_events()
    vime.on_commit() -- 確定 → 未確定が空に
    api.nvim_del_autocmd(id)
    assert.is_true(#events >= 1)
    assert.are.equal("", events[#events].preedit)
    assert.is_false(events[#events].available)
  end)

  it("does not refire VimePreeditChanged when the preedit is unchanged", function()
    fresh_buf()
    vime.toggle()
    local events, id = collect_preedit_events()
    vime.on_convert() -- 未確定なし → スペース挿入。session の preedit は "" のまま
    api.nvim_del_autocmd(id)
    assert.are.equal(0, #events)
  end)

  it("exposes completion_active only while composing with a preedit", function()
    fresh_buf()
    assert.is_false(vime.completion_active()) -- OFF
    vime.toggle()
    assert.is_false(vime.completion_active()) -- ON だが未確定なし
    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    assert.is_true(vime.completion_active()) -- composing + 未確定あり
    vime.on_convert() -- 変換開始 → converting
    assert.is_false(vime.completion_active())
  end)

  it("completion_context returns the preedit byte region and candidate items", function()
    fresh_buf()
    vime.toggle()
    for ch in ("kyouhaii"):gmatch(".") do
      vime.on_input(ch)
    end
    local ctx = vime.completion_context()
    assert.is_not_nil(ctx)
    assert.are.equal(0, ctx.row)
    assert.are.equal(0, ctx.start_col)
    assert.are.equal(#"きょうはいい", ctx.len) -- byte 長
    assert.are.equal("きょうはいい", ctx.yomi)
    assert.is_true(#ctx.items >= 1)
  end)

  it("commit_completion clears IME state after cmp replaced the region", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyouhaii"):gmatch(".") do
      vime.on_input(ch)
    end
    local ctx = vime.completion_context()
    local item = ctx.items[1]
    -- cmp の確定は挿入モードで起こり、カーソルは行末(確定テキストの直後)へ置かれる。
    -- ノーマルモードだと行末のマルチバイト文字手前へクランプされ再現にならないため挿入モードにする。
    vim.cmd("startinsert")
    -- cmp が textEdit で未確定領域を候補テキストへ置換したのを模擬する
    api.nvim_buf_set_text(buf, ctx.row, ctx.start_col, ctx.row, ctx.start_col + ctx.len, { item.text })
    api.nvim_win_set_cursor(0, { ctx.row + 1, ctx.start_col + #item.text })

    vime.commit_completion(item)

    assert.are.equal("composing", vime.mode().state) -- 変換中でなく composing に戻る
    local marks = api.nvim_buf_get_extmarks(buf, require("vime.ui").namespace(), 0, -1, {})
    assert.are.equal(0, #marks) -- 未確定の extmark が掃除されている

    vime.on_input("a") -- 続けて入力すると確定テキストの後ろに入る
    assert.are.equal(item.text .. "あ", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    vim.cmd("stopinsert")
  end)
end)

describe("vime built-in completion", function()
  local function fresh_buf()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    api.nvim_win_set_cursor(0, { 1, 0 })
    return buf
  end

  -- 表示中の floating window を数える(mode_notify は無効化してあるので候補 popup のみ)。
  local function floating_wins()
    local n = 0
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(w).relative ~= "" then
        n = n + 1
      end
    end
    return n
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

  it("shows a candidate popup automatically while composing", function()
    fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    assert.are.equal(1, floating_wins()) -- 読み入力中は候補 popup が自動で出る
    vime.on_commit() -- かな確定
    assert.are.equal(0, floating_wins()) -- 確定で閉じる
  end)

  it("does not show the popup when completion is disabled", function()
    vime.setup({
      anthy = { lib = LIB },
      mode_notify = { enabled = false },
      completion = { enabled = false },
    })
    fresh_buf()
    vime.toggle()
    for ch in ("kyou"):gmatch(".") do
      vime.on_input(ch)
    end
    assert.are.equal(0, floating_wins())
  end)

  it("attaches candidate keys only while the popup is open", function()
    local buf = fresh_buf()
    vime.toggle()
    local function has_cn_map()
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, "i")) do
        if m.lhs == "<C-N>" then
          return true
        end
      end
      return false
    end
    assert.is_false(has_cn_map()) -- 未入力では握らない(ユーザの C-n が生きる)
    for ch in ("sora"):gmatch(".") do
      vime.on_input(ch)
    end
    assert.is_true(has_cn_map()) -- popup 表示中は候補選択キーを握る
    vime.on_commit()
    assert.is_false(has_cn_map()) -- 確定で解放
  end)

  it("selects candidates inline with next/prev and wraps back to the reading", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("sekai"):gmatch(".") do
      vime.on_input(ch)
    end
    local items = vime.completion_context().items

    vime.on_next_candidate()
    assert.are.equal(items[1].text, api.nvim_buf_get_lines(buf, 0, 1, false)[1]) -- インライン置換
    vime.on_next_candidate()
    assert.are.equal(items[2].text, api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    vime.on_prev_candidate()
    assert.are.equal(items[1].text, api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    vime.on_prev_candidate()
    assert.are.equal("せかい", api.nvim_buf_get_lines(buf, 0, 1, false)[1]) -- 読みへ戻る(wrap)
  end)

  it("commits the selected candidate with the commit key", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kikai"):gmatch(".") do
      vime.on_input(ch)
    end
    local items = vime.completion_context().items

    vime.on_next_candidate()
    vime.on_commit()

    assert.are.equal(items[1].text, api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.are.equal("composing", vime.mode().state)
    assert.is_false(vime.completion_active()) -- 未確定は空
    assert.are.equal(0, floating_wins())
  end)

  it("typing while a candidate is selected commits it first", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("hokan"):gmatch(".") do
      vime.on_input(ch)
    end
    local items = vime.completion_context().items

    vime.on_next_candidate()
    vime.on_input("g") -- 選択したまま次の文字

    -- 選択候補が確定され、g は新しい読みの 1 文字目になる
    assert.are.equal(items[1].text .. "g", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("starts conversion from the reading even while a candidate is selected", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("kyouto"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_next_candidate() -- 候補を選択した状態で

    vime.on_convert() -- <Space> は読みの通常変換へ

    assert.are.equal("converting", vime.mode().state)
    -- 変換結果は読み由来(参照用 session の変換と一致)
    local ref = require("vime.session").new(require("vime.anthy"))
    for ch in ("kyouto"):gmatch(".") do
      ref:input(ch)
    end
    ref:start_conversion()
    assert.are.equal(table.concat(ref:segments().list), api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("cancels the selected candidate with Esc discarding the preedit like the cancel key", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("sekai"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_next_candidate() -- 候補を選択した状態で

    vime.on_completion_cancel() -- Esc

    -- <C-g>(on_cancel) と同じく未確定を破棄し、popup も閉じる
    assert.are.equal("", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.are.equal(0, floating_wins())
    assert.is_false(vime.completion_active())
  end)

  it("passes Esc through keeping the preedit when no candidate is selected", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("sekai"):gmatch(".") do
      vime.on_input(ch)
    end

    vime.on_completion_cancel() -- 選択なし(読みのまま)の Esc

    -- 未確定は破棄されない(通常の Esc として素通しし、InsertLeave の確定フローに任せる)
    assert.are.equal("せかい", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("maps Esc only while the completion popup is open", function()
    local buf = fresh_buf()
    vime.toggle()
    local function has_esc_map()
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, "i")) do
        if m.lhs == "<Esc>" then
          return true
        end
      end
      return false
    end
    assert.is_false(has_esc_map()) -- 未入力では握らない(通常の Esc が生きる)
    for ch in ("sora"):gmatch(".") do
      vime.on_input(ch)
    end
    assert.is_true(has_esc_map()) -- popup 表示中は Esc を握る
    vime.on_commit()
    assert.is_false(has_esc_map()) -- 確定で解放
  end)

  it("deselects back to the reading with backspace", function()
    local buf = fresh_buf()
    vime.toggle()
    for ch in ("asita"):gmatch(".") do
      vime.on_input(ch)
    end
    local items = vime.completion_context().items

    vime.on_next_candidate()
    assert.are.equal(items[1].text, api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    vime.on_backspace() -- 1 回目は選択解除のみ
    assert.are.equal("あした", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    vime.on_backspace() -- 2 回目から通常のかな削除
    assert.are.equal("あし", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)
end)
