local vime = require("vime")
local backend_cmdline = require("vime.backend.cmdline")

local api = vim.api
local LIB = assert(require("vime.config").find_anthy_lib(), "libanthy not found; set $VIME_ANTHY_LIB")

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "tx", false)
end

-- cmdline セッションを開いたまま任意の Lua コードを実行し、結果を返す。
-- 実際に ":"/"/"/"?" で入って所定のキーを打ち、<F12> に一時マッピングしたプローブで
-- getcmdline()/getcmdpos() 等を読み取ってから <C-c> で抜ける。
local function probe_in_cmdline(open_keys, fn)
  local result
  vim.keymap.set("c", "<F12>", function()
    result = fn()
  end)
  feed(open_keys .. "<F12><C-c>")
  pcall(vim.keymap.del, "c", "<F12>")
  return result
end

describe("vime.backend.cmdline", function()
  it("does not support completion/register_word/dot_repeat", function()
    assert.is_false(backend_cmdline.supports("completion"))
    assert.is_false(backend_cmdline.supports("register_word"))
    assert.is_false(backend_cmdline.supports("dot_repeat"))
  end)

  it("sync_anchor anchors to the current cmdpos (0-based) when len is 0", function()
    local anchor = probe_in_cmdline(":ab", function()
      local b = backend_cmdline.new(api.nvim_get_current_buf())
      b:sync_anchor()
      return b.anchor
    end)
    assert.are.equal(2, anchor) -- "ab" の直後 = byte 2
  end)

  it("set_region_text replaces the tracked region and updates anchor/len", function()
    local line = probe_in_cmdline(":ab", function()
      local b = backend_cmdline.new(api.nvim_get_current_buf())
      b:sync_anchor()
      b:set_region_text("きょう")
      return vim.fn.getcmdline()
    end)
    assert.are.equal("abきょう", line)
  end)

  it("finalize writes the confirmed text and resets len to 0", function()
    local result = probe_in_cmdline(":ab", function()
      local b = backend_cmdline.new(api.nvim_get_current_buf())
      b:sync_anchor()
      b:set_region_text("きょう") -- 未確定として書く
      b:finalize("今日")
      return { line = vim.fn.getcmdline(), len = b.len }
    end)
    assert.are.equal("ab今日", result.line)
    assert.are.equal(0, result.len)
  end)
end)

describe("vime end-to-end (cmdline)", function()
  before_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false } })
  end)

  it("converts typed romaji into hiragana inline in the cmdline", function()
    vime.toggle()
    local line = probe_in_cmdline(":kyou", function()
      return vim.fn.getcmdline()
    end)
    assert.are.equal("きょう", line)
    vime.toggle()
  end)

  -- cmdline はプレーン文字列のインライン表示だけでは下線が付けられない(extmark 不可)ため、
  -- 変換前(composing)でも共有 preedit float に同じ内容を下線付きで併記し、通常バッファ/
  -- terminal と同じ視認性を持たせる。
  local function find_editor_relative_float()
    for _, win in ipairs(api.nvim_list_wins()) do
      local cfg = api.nvim_win_get_config(win)
      if cfg.relative == "editor" then
        return win
      end
    end
    return nil
  end

  it("shows the shared preedit float with an underline while composing (before <Space>)", function()
    vime.toggle()
    local probed = probe_in_cmdline(":kyou", function()
      local win = find_editor_relative_float()
      if not win then
        return { found = false }
      end
      local buf = api.nvim_win_get_buf(win)
      local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      local marks = api.nvim_buf_get_extmarks(buf, require("vime.ui").namespace(), 0, -1, { details = true })
      return { found = true, line = line, marks = marks }
    end)
    assert.is_true(probed.found, "変換前でも preedit float が出ているはず")
    assert.are.equal("きょう", probed.line)
    assert.are.equal(1, #probed.marks)
    assert.are.equal("VimeUnconfirmed", probed.marks[1][4].hl_group)
    vime.toggle()
  end)

  it("closes the preedit float once the preedit becomes empty (e.g. after backspacing it all)", function()
    vime.toggle()
    local probed = probe_in_cmdline(":k<BS>", function()
      return { line = vim.fn.getcmdline(), float = find_editor_relative_float() }
    end)
    assert.are.equal("", probed.line)
    assert.is_nil(probed.float, "未確定が空になったら preedit float も閉じるはず")
    vime.toggle()
  end)

  it("does not intercept the : / ? prefix, only what is typed after it", function()
    vime.toggle()
    local line = probe_in_cmdline("/kyou", function()
      return vim.fn.getcmdline()
    end)
    assert.are.equal("きょう", line)
    vime.toggle()
  end)

  -- 注: nvim_feedkeys(..., "x", ...) はタイプアヘッドが尽きた時点で cmdline がまだ開いて
  -- いると自動的にキャンセルしてしまう(headless テスト環境の制約)。そのため「1回目の <CR> の
  -- 直後もまだ cmdline が開いている」ことを検証するには、同じ feed() 呼び出しの中で
  -- プローブキー(<F12>)を使って状態を捕まえる必要がある。
  it("finalizes the conversion into the cmdline on the first <CR> without executing it", function()
    vime.toggle()
    local probed = probe_in_cmdline(":kyouhaii<Space><CR>", function()
      return { mode = vim.fn.mode(), line = vim.fn.getcmdline() }
    end)
    assert.are.equal("c", probed.mode) -- 1回目の <CR> ではまだ実行されていない
    assert.are_not.equal("きょうはいい", probed.line) -- 生かなのままではない(変換された)
    vime.toggle()
  end)

  it("executes the command on the second <CR> after the conversion is confirmed", function()
    vime.toggle()
    feed(":kyouhaii<Space><CR><CR>") -- 1回目: 確定のみ、2回目: 実行
    assert.are.equal("n", vim.fn.mode())
    vime.toggle()
  end)

  it("discards the preedit on <C-c> so the next cmdline session starts fresh", function()
    vime.toggle()
    feed(":kyou")
    feed("<C-c>")
    assert.are.equal("n", vim.fn.mode())

    -- 破棄されていれば、次の cmdline セッションは "きょう" を引き継がず空から始まる。
    local line = probe_in_cmdline(":", function()
      return vim.fn.getcmdline()
    end)
    assert.are.equal("", line)
    vime.toggle()
  end)

  it("restores a pre-existing global cmap after leaving the cmdline", function()
    vim.keymap.set("c", "<C-r>", function() end)

    vime.toggle()
    feed(":ab") -- CmdlineEnter で vime の "c" マッピングが張られる(<C-r> は converting 限定なので、
    -- ここでは変換状態にしてから確認する)
    feed("<C-c>")
    vime.toggle()

    -- vime の attach/detach を経てもグローバル <C-r> は残っている(壊されていない)
    local m = vim.fn.maparg("<C-r>", "c", false, true)
    assert.is_true(next(m) ~= nil)

    pcall(vim.keymap.del, "c", "<C-r>")
  end)

  it("does not attach vime's cmap while IME is disabled", function()
    -- before_each で OFF 済み
    feed(":ab<C-c>")
    local m = vim.fn.maparg("a", "c", false, true)
    assert.are.same({}, m)
  end)

  it("does not attach vime's cmap when cmdline.enabled is false", function()
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false }, cmdline = { enabled = false } })
    vime.toggle()
    -- CmdlineLeave は cmdline backend が張られていれば無条件に detach するため、leave 後の
    -- maparg 確認では「そもそも attach されなかった」ことを区別できない。session 内で確認する。
    local probed = probe_in_cmdline(":ab", function()
      return { maparg_a = vim.fn.maparg("a", "c", false, true), line = vim.fn.getcmdline() }
    end)
    assert.are.same({}, probed.maparg_a)
    -- typed ローマ字がそのまま cmdline へ残る(vime が横取りしていない)ことも確認する。
    assert.are.equal("ab", probed.line)
    vime.toggle()
  end)

  it("detaches the interrupted buffer backend's insert-mode mapping when toggled OFF from inside a cmdline session", function()
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false } })
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    vime.toggle() -- buffer backend が "i" マッピングを張る

    local mapped_before = api.nvim_buf_get_keymap(buf, "i")
    local has_a_before = false
    for _, m in ipairs(mapped_before) do
      if m.lhs == "a" then
        has_a_before = true
      end
    end
    assert.is_true(has_a_before, "toggle ON 直後は \"i\" マッピングが張られているはず")

    -- cmdline backend が buffer backend に割り込んだ状態のまま toggle OFF する。
    probe_in_cmdline(":ab", function()
      vime.toggle()
    end)

    local mapped_after = api.nvim_buf_get_keymap(buf, "i")
    local has_a_after = false
    for _, m in ipairs(mapped_after) do
      if m.lhs == "a" then
        has_a_after = true
      end
    end
    assert.is_false(
      has_a_after,
      "cmdline セッション中に toggle OFF しても、割り込まれていた buffer backend の \"i\" マッピングが残留してはいけない"
    )

    if vime.is_enabled() then
      vime.toggle()
    end
  end)
end)
