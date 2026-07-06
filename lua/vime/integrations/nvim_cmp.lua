-- nvim-cmp 統合: vime モード ON 中は補完を抑止する。source モード("source")では、
-- 抑止しつつ vime の変換候補を cmp source として提供する。
-- 設計判断:
--   * cmp.setup({ enabled = function() ... end }) を vime 側で上書きすると、cmp 内部の
--     デフォルト判定(prompt buftype/マクロ記録中/マクロ実行中)が消えるので明示的に
--     再現する。ユーザー独自の enabled は尊重しない(順序依存問題と内部 API 依存を避ける)。
--     独自判定と併用したいユーザーは vime.is_enabled() を自分の enabled の中で呼ぶ。
--   * ON 切替時の既存 popup は enabled の上書きだけでは閉じないため、VimeModeChanged
--     autocmd で `cmp.close()` を呼んで確実に閉じる。
--   * source モードでは vime の候補提供中(composing)に cmp を有効へ戻す。CursorMovedI で
--     enabled()==false だと開いたメニューが閉じられるため。VimePreeditChanged autocmd で
--     未確定変化に追従して cmp.complete(vime source のみ)/cmp.close() を切り替える。
--   * nvim-cmp 未ロード/未インストールでも壊れないように pcall で optional に扱う。
--   * cmp 自体が InsertEnter で lazy load される構成(lazy.nvim の event = "InsertEnter")
--     に確実に追従するため、cmp の設定上書きは vime.setup 直後ではなく InsertEnter once
--     のタイミングで行う。vim.schedule では cmp ロード前に上書きが失敗するケースがある。
local M = {}

-- 純粋関数: enabled が返すべき bool を導く。
-- source_completing(vime source が候補提供中)なら true、vime ON なら false、
-- それ以外は cmp デフォルトに従う。
function M.compute_enabled(vime_active, default_enabled, source_completing)
  if source_completing then
    return true
  end
  if vime_active then
    return false
  end
  return default_enabled()
end

-- nvim-cmp のデフォルト enabled 判定を再現する(lua/cmp/config/default.lua 相当)。
-- vime 側で enabled を上書きするとこの判定が消えるので、フォールバックとして使う。
local function default_enabled()
  if vim.api.nvim_get_option_value("buftype", { buf = 0 }) == "prompt" then
    return false
  end
  if vim.fn.reg_recording() ~= "" then
    return false
  end
  if vim.fn.reg_executing() ~= "" then
    return false
  end
  return true
end

-- vime.setup から呼ばれる。`group` は init の "vime" augroup を共有し、setup 再呼出時に
-- 自動 clear されるようにする。get_vime_active は require("vime").is_enabled を渡す想定。
-- source_api(非 nil)で source モード: {completion_active, completion_context, commit_completion}。
-- 最初の InsertEnter で cmp をロードしつつ enabled を上書きする(lazy.nvim 構成に耐える)。
function M.attach(get_vime_active, group, source_api)
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    once = true,
    desc = "vime: nvim-cmp integration",
    callback = function()
      local ok, cmp = pcall(require, "cmp")
      if not ok then
        return
      end
      local source_completing = function()
        return source_api ~= nil and source_api.completion_active()
      end
      if source_api then
        local nvim_cmp_source = require("vime.integrations.nvim_cmp_source")
        cmp.register_source(
          "vime",
          nvim_cmp_source.new({
            active = source_api.completion_active,
            context = source_api.completion_context,
            commit = source_api.commit_completion,
          })
        )
      end
      cmp.setup({
        enabled = function()
          return M.compute_enabled(get_vime_active(), default_enabled, source_completing())
        end,
      })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "VimeModeChanged",
        callback = function(args)
          if args.data and args.data.enabled then
            cmp.close()
          end
        end,
      })
      if source_api then
        -- 未確定の変化に追従して vime source のみの補完を出す/閉じる。
        vim.api.nvim_create_autocmd("User", {
          group = group,
          pattern = "VimePreeditChanged",
          callback = function(args)
            if args.data and args.data.available then
              cmp.complete({ config = { sources = { { name = "vime" } } } })
            else
              cmp.close()
            end
          end,
        })
      end
    end,
  })
end

return M
