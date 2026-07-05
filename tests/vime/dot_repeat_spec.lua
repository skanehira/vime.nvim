local vime = require("vime")

local api = vim.api
local LIB = assert(require("vime.config").find_anthy_lib(), "libanthy not found; set $VIME_ANTHY_LIB")

-- dot repeat (`.`) は「確定テキストを feedkeys でタイプ入力として流し、native の redo に
-- 載せる」ことで成立する。ここでは実キーマップ経由(挿入モード)でシナリオを打ち、
-- ノーマルモードの `.` が直前の確定挿入を再現することを検証する。
-- 確定は変換を伴わない「ひらがな確定(CR で読みをそのまま確定)」を使い、辞書バージョン
-- 依存を避ける(きょう/あいうえお 等は anthy を通さないので分割・候補に左右されない)。
describe("vime dot repeat", function()
  -- 実ユーザのキー入力相当を keymap 経由で送る("x" で typeahead 同期消化、"t" で typed key 扱い)。
  local function feed(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "tx", false)
  end

  local function fresh_buf(lines)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "", "" })
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

  it("replays a hiragana commit with dot on another line", function()
    local buf = fresh_buf()
    vime.toggle()

    feed("ikyou<CR><Esc>") -- CR でひらがな確定 → "きょう"(変換なし)
    assert.are.equal("きょう", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    feed("j0.") -- 2 行目の先頭で dot repeat
    assert.are.equal("きょう", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("composes with the ciw operator so dot replaces another word", function()
    local buf = fresh_buf({ "foo bar" })
    vime.toggle()

    feed("ciwkyou<CR><Esc>") -- "foo" を消して きょう を確定挿入
    assert.are.equal("きょう bar", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    feed("w.") -- "bar" 上で dot → ciw ごと再現して置換
    assert.are.equal("きょう きょう", api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("replays multiple commits in one insert session together", function()
    local buf = fresh_buf()
    vime.toggle()

    feed("iaiueo<CR>kaki<CR><Esc>") -- 2 回の確定を 1 挿入セッションで
    assert.are.equal("あいうえおかき", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    feed("j0.")
    assert.are.equal("あいうえおかき", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("includes literal spaces (insert_literal) in the replayed insert", function()
    local buf = fresh_buf()
    vime.toggle()

    -- か → 未確定なしスペース → き。スペースも redo に載る。
    feed("ika<CR> ki<CR><Esc>")
    assert.are.equal("か き", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    feed("j0.")
    assert.are.equal("か き", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("repeats the commit count times with 3.", function()
    local buf = fresh_buf()
    vime.toggle()

    feed("ikyou<CR><Esc>")
    feed("j0")
    feed("3.") -- 3 回分
    assert.are.equal("きょうきょうきょう", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("keeps multibyte 0x80 bytes intact (escape_ks) when replaying", function()
    -- "む"(U+3080) の UTF-8 は E3 82 80 で末尾に 0x80(K_SPECIAL の先頭バイト)を含む。
    -- escape_ks なしで feed するとこのバイトが化けるが、escape_ks=true なら保たれる。
    local buf = fresh_buf()
    vime.toggle()

    feed("imura<CR><Esc>") -- むら
    assert.are.equal("むら", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    feed("j0.")
    assert.are.equal("むら", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("replays a katakana (F7) commit with dot", function()
    local buf = fresh_buf()
    vime.toggle()

    feed("ikyou<F7><Esc>") -- F7: カタカナ確定 → キョウ
    assert.are.equal("キョウ", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    feed("j0.")
    assert.are.equal("キョウ", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("replays an alphabet (F10) commit without re-entering IME maps", function()
    -- F10 確定の "foo" は ASCII。feedkeys が noremap("n") でないと f/o/o マッピングに
    -- 再入して "ふぉお" に戻ってしまう。noremap ならそのまま "foo" が redo に載る。
    local buf = fresh_buf()
    vime.toggle()

    feed("ifoo<F10><Esc>") -- ふぉお → foo
    assert.are.equal("foo", api.nvim_buf_get_lines(buf, 0, 1, false)[1])

    feed("j0.")
    assert.are.equal("foo", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it("does not interfere with native dot repeat when IME is OFF", function()
    local buf = fresh_buf()
    vime.toggle() -- ON
    vime.toggle() -- OFF(マッピングを外す)
    assert.is_false(vime.is_enabled())

    feed("ifoo<Esc>") -- 素の Vim 挿入
    feed("j0.")
    assert.are.equal("foo", api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)
end)
