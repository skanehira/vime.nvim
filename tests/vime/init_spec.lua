local vime = require("vime")

local api = vim.api
local LIB = "/nix/store/m2z37mlz9rsh2azv9pny1860rpycic54-anthy-9100h/lib/libanthy.dylib"

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

    for ch in ("kyouhaiitenkidane"):gmatch(".") do
      vime.on_input(ch)
    end
    -- 変換前: 未確定かなが入っている
    assert.are.equal("きょうはいいてんきだね", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    vime.on_convert() -- Space → 変換
    vime.on_commit() -- Enter → 確定

    -- 変換された(生かなでない)こと・先頭文節が安定して「今日は」になることを検証する。
    -- 末尾候補(良い/いい 等)は anthy の領分なので anthy_spec で担保する。
    local result = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.are_not.equal("きょうはいいてんきだね", result)
    assert.are.equal("今日は", result:sub(1, #"今日は"))

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
end)
