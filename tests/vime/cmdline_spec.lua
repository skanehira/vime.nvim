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

  describe("popup_pos", function()
    local saved_laststatus

    before_each(function()
      saved_laststatus = vim.o.laststatus
    end)

    after_each(function()
      vim.o.laststatus = saved_laststatus
    end)

    -- 注: anchor="SW" の row は「下エッジ(排他)」を指す。UI 接続の実機実験で確認済み:
    -- {anchor="SW", row=10, height=1} の float は 0-based row 9 を占有する
    -- (screenstring / nvim_win_get_position の両方で確認)。したがって
    -- row = lines - cmdheight を渡すと float は cmdline の直上の行を占有する
    -- (statusline が表示されていればその行と重なるが、それが仕様。float は statusline
    -- より前面に描画されるので隠れない)。headless では float の layout が走らず
    -- nvim_win_get_position が設定値をそのまま返すため、占有行そのものの検証は
    -- headless では不可能(実機の screenstring 検証で裏取りする)。
    it(
      "puts the float bottom edge at the cmdline top row regardless of laststatus (statusline overlap is intended)",
      function()
        for _, ls in ipairs({ 0, 2, 3 }) do
          vim.o.laststatus = ls
          local b = backend_cmdline.new(api.nvim_get_current_buf())
          assert.are.equal(vim.o.lines - vim.o.cmdheight, b:popup_pos().row)
        end
      end
    )

    it("falls back to col=0 when not actually editing the command line", function()
      -- getcmdscreenpos() は cmdline 編集中以外は 0 を返す仕様(:help getcmdscreenpos())。
      local b = backend_cmdline.new(api.nvim_get_current_buf())
      local pos = b:popup_pos()
      assert.are.equal(0, pos.col)
    end)

    -- 注: popup_pos() の col は「未確定領域の先頭(self.anchor)」に揃える必要がある。
    -- カーソル位置(未確定領域の末尾)に揃えると、確定済み前置が無いケース(":これは" 等)で
    -- float が実テキストより右にズレる(実機で発見・報告されたバグ)。
    --
    -- backend は実際の実行時と同じ順序で操作する: ":" を打った直後(まだ何も未確定が無い
    -- 状態、anchor はこの時点のカーソル)に new() し、その後 set_region_text() で未確定を
    -- 書き込む(render() が実際にやっていることと同じ)。テスト構築時に既に文字が入った
    -- 状態で new() すると anchor がカーソル(末尾)に一致してしまい、バグを覆い隠してしまう
    -- (このテストの前身がまさにそれで、実際のバグを検出できていなかった)。
    it(
      "[ground truth] positions the float column at the start of the preedit region, not at the cursor, when there is no confirmed prefix",
      function()
        local col = probe_in_cmdline(":", function()
          local b = backend_cmdline.new(api.nvim_get_current_buf()) -- ":" 直後、anchor=0
          b:set_region_text("これは") -- 未確定を書き込む(anchor は 0 のまま、len が進む)
          return b:popup_pos().col
        end)
        -- ":" (prompt) の表示幅 = 1。"これは" はその直後(col 1)から始まるはず。
        -- カーソル基準の誤った実装だと ":これは" 全体の表示幅(7)になってしまう。
        assert.are.equal(1, col)
      end
    )

    it(
      "[ground truth] positions the float column at the display width of the confirmed prefix before the preedit",
      function()
        local col = probe_in_cmdline(":abc", function()
          local b = backend_cmdline.new(api.nvim_get_current_buf()) -- "abc" 入力済み、anchor はその末尾
          b:set_region_text("これは") -- "abc" の直後に未確定を書き込む(anchor はここに固定)
          return b:popup_pos().col
        end)
        -- ":abc" (prompt + 確定済み前置、すべて ASCII) の表示幅 = 4。
        assert.are.equal(4, col)
      end
    )

    it(
      "anchors from the bottom-left(SW) so a multi-row candidate popup grows upward instead of into the statusline/cmdline",
      function()
        local b = backend_cmdline.new(api.nvim_get_current_buf())
        local pos = b:popup_pos()
        assert.are.equal("SW", pos.anchor)
      end
    )
  end)
end)

describe("vime end-to-end (cmdline)", function()
  before_each(function()
    if vime.is_enabled() then
      vime.toggle()
    end
    vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false }, cmdline = { enabled = true } })
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

  -- モード切替通知も preedit float と同じ位置ルール(cmdline の直上、statusline と
  -- 重なって良い)で出す。既定のカーソル相対のままだと、cmdline モード中はカーソルが
  -- cmdline 上に無いため無関係な場所に表示されてしまう。
  it("places the mode notify at the cmdline popup position when toggled inside the cmdline", function()
    vime.setup({
      anthy = { lib = LIB },
      mode_notify = { duration = 100, labels = { hiragana = "HIRA" } },
      cmdline = { enabled = true },
    })
    local probed = probe_in_cmdline(":", function()
      vime.toggle() -- cmdline セッション中に ON: mode notify が出る
      for _, win in ipairs(api.nvim_list_wins()) do
        local cfg = api.nvim_win_get_config(win)
        if cfg.relative ~= "" then
          local line = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, 1, false)[1]
          if line == "HIRA" then
            return { relative = cfg.relative, row = cfg.row, anchor = cfg.anchor }
          end
        end
      end
      return nil
    end)
    assert.are.same({ relative = "editor", row = vim.o.lines - vim.o.cmdheight, anchor = "SW" }, probed)
    vime.toggle()
  end)

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

  it(
    "detaches the interrupted buffer backend's insert-mode mapping when toggled OFF from inside a cmdline session",
    function()
      vime.setup({ anthy = { lib = LIB }, mode_notify = { enabled = false }, cmdline = { enabled = true } })
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
      assert.is_true(has_a_before, 'toggle ON 直後は "i" マッピングが張られているはず')

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
        'cmdline セッション中に toggle OFF しても、割り込まれていた buffer backend の "i" マッピングが残留してはいけない'
      )

      if vime.is_enabled() then
        vime.toggle()
      end
    end
  )
end)
