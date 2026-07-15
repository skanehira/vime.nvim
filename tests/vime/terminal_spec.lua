local vime = require("vime")
local backend_terminal = require("vime.backend.terminal")

local api = vim.api
local LIB = assert(require("vime.config").find_anthy_lib(), "libanthy not found; set $VIME_ANTHY_LIB")

describe("vime.backend.terminal", function()
  it("does not support completion/register_word/dot_repeat", function()
    assert.is_false(backend_terminal.supports("completion"))
    assert.is_false(backend_terminal.supports("register_word"))
    assert.is_false(backend_terminal.supports("dot_repeat"))
  end)

  it("does not call send while only rendering the preedit", function()
    local sent = {}
    local buf = api.nvim_create_buf(false, true)
    local b = backend_terminal.new(buf, function(_, text)
      sent[#sent + 1] = text
    end)
    b:render({ { kind = "kana", text = "きょう" } })
    assert.are.equal(0, #sent)
    b:clear()
  end)

  it("sends the confirmed text via the injected send function on finalize", function()
    local sent = {}
    local buf = api.nvim_create_buf(false, true)
    local b = backend_terminal.new(buf, function(_, text)
      sent[#sent + 1] = text
    end)
    b:finalize("今日")
    assert.are.same({ "今日" }, sent)
  end)

  it("does not send anything when finalize is called with an empty string", function()
    local sent = {}
    local buf = api.nvim_create_buf(false, true)
    local b = backend_terminal.new(buf, function(_, text)
      sent[#sent + 1] = text
    end)
    b:finalize("")
    assert.are.equal(0, #sent)
  end)

  it("converts a literal newline to CR before sending", function()
    local sent = {}
    local buf = api.nvim_create_buf(false, true)
    local b = backend_terminal.new(buf, function(_, text)
      sent[#sent + 1] = text
    end)
    b:insert_literal("\n")
    assert.are.same({ "\r" }, sent)
  end)

  it("sends a literal space as-is", function()
    local sent = {}
    local buf = api.nvim_create_buf(false, true)
    local b = backend_terminal.new(buf, function(_, text)
      sent[#sent + 1] = text
    end)
    b:insert_literal(" ")
    assert.are.same({ " " }, sent)
  end)

  -- cmdline backend と同じ配置ルール: anchor="SW" の row は下エッジ(排他)なので、
  -- 通常バッファと同じくカーソル直下に出す(未確定は inline virtual text で
  -- カーソル位置に表示されるので、popup をその下に出しても未確定を隠さない)。
  it("places the popup directly below the cursor like the buffer backend", function()
    local buf = api.nvim_create_buf(false, true)
    local b = backend_terminal.new(buf)
    assert.are.same({ relative = "cursor", row = 1, col = 0 }, b:popup_pos())
  end)

  -- 未確定は preedit float ではなく、terminal buffer のカーソル位置に置いた
  -- inline virtual text(extmark)で表示する(通常バッファと同じ見た目にするため。
  -- terminal buffer は直接編集できないので実文字ではなく virt_text を使う。
  -- virt_text は PTY へ送られないため、取り消しも extmark を消すだけで安全)。
  describe("inline preedit (virtual text)", function()
    local ns = require("vime.ui").namespace()

    -- terminal buffer の代役: プロンプト風の1行を持つバッファを current にして
    -- カーソルをプロンプト("$ " = 2 byte)の直後に置く(render はカレントウィンドウの
    -- カーソル位置に描く)。通常モードのカーソルは行末バイトを超えられないため、
    -- 行にはカーソル位置以降の文字も入れておく(実 terminal-job モードでは行末の
    -- 先にカーソルが立つが、ここでは col=2 が取れれば十分)。
    local function setup_prompt_buf()
      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buf, 0, -1, false, { "$ abc" })
      api.nvim_set_current_buf(buf)
      api.nvim_win_set_cursor(0, { 1, 2 })
      return buf
    end

    local function get_extmarks(buf)
      return api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    end

    local function count_floats()
      local n = 0
      for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_config(win).relative ~= "" then
          n = n + 1
        end
      end
      return n
    end

    it("renders the composing preedit as underlined inline virt_text at the cursor, without opening a float", function()
      local buf = setup_prompt_buf()
      local b = backend_terminal.new(buf)
      b:render({ { kind = "kana", text = "これは" } })
      local marks = get_extmarks(buf)
      assert.are.equal(1, #marks)
      assert.are.equal(0, marks[1][2]) -- row 0-based
      assert.are.equal(2, marks[1][3]) -- col byte("$ " の直後)
      assert.are.equal("inline", marks[1][4].virt_text_pos)
      assert.are.same({ { "これは", "VimeUnconfirmed" } }, marks[1][4].virt_text)
      assert.are.equal(0, count_floats())
      b:clear()
    end)

    it("renders converting segments with the focused one reversed and the rest underlined", function()
      local buf = setup_prompt_buf()
      local b = backend_terminal.new(buf)
      b:render({ { kind = "segments", list = { "今日", "は" }, current = 1 } })
      local marks = get_extmarks(buf)
      assert.are.equal(1, #marks)
      assert.are.same({ { "今日", "VimeSegment" }, { "は", "VimeUnconfirmed" } }, marks[1][4].virt_text)
      b:clear()
    end)

    it("replaces the previous inline preedit on re-render instead of accumulating extmarks", function()
      local buf = setup_prompt_buf()
      local b = backend_terminal.new(buf)
      b:render({ { kind = "kana", text = "こ" } })
      b:render({ { kind = "kana", text = "これ" } })
      local marks = get_extmarks(buf)
      assert.are.equal(1, #marks)
      assert.are.same({ { "これ", "VimeUnconfirmed" } }, marks[1][4].virt_text)
      b:clear()
    end)

    it("removes the inline preedit and shows nothing when the view becomes empty", function()
      local buf = setup_prompt_buf()
      local b = backend_terminal.new(buf)
      b:render({ { kind = "kana", text = "こ" } })
      b:render({ { kind = "kana", text = "" } }) -- 全部 backspace した状態
      assert.are.equal(0, #get_extmarks(buf))
      b:clear()
    end)

    it("clear removes the inline preedit extmark", function()
      local buf = setup_prompt_buf()
      local b = backend_terminal.new(buf)
      b:render({ { kind = "kana", text = "これは" } })
      b:clear()
      assert.are.equal(0, #get_extmarks(buf))
    end)
  end)
end)

describe("vime end-to-end (terminal)", function()
  -- テスト独立性: 各テスト開始時は日本語入力 OFF にしておく
  before_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
  end)

  -- 注: headless(UI 未 attach)環境では :startinsert しても実際の terminal-job モード
  -- ("t")には遷移しない(TermEnter も発火しない)。vime の backend 選択は buftype のみで
  -- 判定する設計にしてあるため、ここでは buftype=terminal のバッファを作るだけでよい。
  local function open_cat_terminal()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    vim.fn.jobstart({ "cat" }, { term = true })
    return buf
  end

  local function buf_text(buf)
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  it("sends the committed conversion to the PTY instead of writing it into the buffer", function()
    vime.setup({ anthy = { lib = LIB }, terminal = { enabled = true } })
    local buf = open_cat_terminal()

    vime.toggle() -- 日本語入力 ON(terminal-job モード中なので terminal backend が張られる)
    assert.is_true(vime.is_enabled())

    for ch in ("kyouhaii"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_convert() -- Space → 変換
    vime.on_commit() -- Enter → 確定(PTY へ送出)

    local ok = vim.wait(2000, function()
      return buf_text(buf):find("[^ -~]") ~= nil -- ASCII 範囲外(日本語)の echo を待つ
    end)
    assert.is_true(ok, "cat が確定テキストを echo し、バッファに反映されるはず")

    vime.toggle()
  end)

  it("does not send anything to the PTY while composing", function()
    vime.setup({ anthy = { lib = LIB }, terminal = { enabled = true } })
    local buf = open_cat_terminal()
    vime.toggle()

    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    vim.wait(200) -- 送出されるはずがないので、猶予を置いてから確認する
    assert.are.equal("", buf_text(buf):gsub("%s", ""))

    vime.toggle()
  end)

  it("discards the preedit without sending it when leaving terminal-job mode", function()
    vime.setup({ anthy = { lib = LIB }, terminal = { enabled = true } })
    local buf = open_cat_terminal()
    vime.toggle()

    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_term_leave() -- TermLeave 相当: 未確定を破棄する(commit しない)

    vim.wait(200)
    assert.are.equal("", buf_text(buf):gsub("%s", ""))
    local ns = require("vime.ui").namespace()
    assert.are.equal(0, #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))

    vime.toggle()
  end)

  it("follows the terminal buffer via the TermEnter autocmd when IME stays ON across a buffer switch", function()
    vime.setup({ anthy = { lib = LIB }, terminal = { enabled = true } })
    -- 通常バッファで ON にしておく(buffer backend)。
    local plain_buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(plain_buf)
    vime.toggle()
    assert.is_true(vime.is_enabled())

    -- terminal バッファへ切り替え、TermEnter を直接発火する(headless では実際の
    -- terminal-job モード遷移が起きないため、登録済み autocmd を直接叩いて検証する)。
    local term_buf = open_cat_terminal()
    api.nvim_exec_autocmds("TermEnter", { buffer = term_buf })

    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.on_term_leave()

    vim.wait(200)
    assert.are.equal("", buf_text(term_buf):gsub("%s", ""))

    vime.toggle()
  end)

  it("sends the pending preedit when toggled OFF", function()
    vime.setup({ anthy = { lib = LIB }, terminal = { enabled = true } })
    local buf = open_cat_terminal()
    vime.toggle()

    for ch in ("ka"):gmatch(".") do
      vime.on_input(ch)
    end
    vime.toggle() -- OFF: 未確定を確定して送出

    local ok = vim.wait(2000, function()
      return buf_text(buf):find("[^ -~]") ~= nil
    end)
    assert.is_true(ok, "toggle OFF で確定テキストが PTY へ送られるはず")
  end)

  it("does not attach the terminal backend's 't' mapping when terminal.enabled is false", function()
    vime.setup({ anthy = { lib = LIB }, terminal = { enabled = false } })
    open_cat_terminal()
    vime.toggle()

    local m = vim.fn.maparg("a", "t", false, true)
    assert.are.same({}, m)

    vime.toggle()
  end)
end)
