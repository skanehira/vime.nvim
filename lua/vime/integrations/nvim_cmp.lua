-- nvim-cmp 統合: vime モード ON 中は補完を抑止する。
-- 設計判断:
--   * cmp.setup({ enabled = function() ... end }) を vime 側で上書きすると、cmp 内部の
--     デフォルト判定(prompt buftype/マクロ記録中/マクロ実行中)が消えるので明示的に
--     再現する。ユーザー独自の enabled は尊重しない(順序依存問題と内部 API 依存を避ける)。
--     独自判定と併用したいユーザーは vime.is_enabled() を自分の enabled の中で呼ぶ。
--   * ON 切替時の既存 popup は enabled の上書きだけでは閉じないため、VimeModeChanged
--     autocmd で `cmp.close()` を呼んで確実に閉じる。
--   * nvim-cmp 未ロード/未インストールでも壊れないように pcall で optional に扱う。
--   * cmp 自体が InsertEnter で lazy load される構成(lazy.nvim の event = "InsertEnter")
--     に確実に追従するため、cmp の設定上書きは vime.setup 直後ではなく InsertEnter once
--     のタイミングで行う。vim.schedule では cmp ロード前に上書きが失敗するケースがある。
local M = {}

-- 純粋関数: vime の active 状態と cmp デフォルト判定から、enabled が返すべき bool を導く。
-- vime ON なら無条件で false、それ以外は cmp デフォルトに従う。
function M.compute_enabled(vime_active, default_enabled)
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
-- 最初の InsertEnter で cmp をロードしつつ enabled を上書きする(lazy.nvim 構成に耐える)。
function M.attach(get_vime_active, group)
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    once = true,
    desc = "vime: nvim-cmp integration",
    callback = function()
      local ok, cmp = pcall(require, "cmp")
      if not ok then
        return
      end
      cmp.setup({
        enabled = function()
          return M.compute_enabled(get_vime_active(), default_enabled)
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
    end,
  })
end

return M
