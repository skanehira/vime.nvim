-- テスト用 最小 init: plenary とプラグイン本体を runtimepath に追加する
local data = vim.fn.stdpath("data")
local plenary = data .. "/lazy/plenary.nvim"

-- anthy の学習(~/.anthy)をテストごとに隔離して決定的にする。
-- HOME を一時ディレクトリにすると毎回クリーンな学習状態になる。
local tmp_home = vim.fn.tempname()
vim.fn.mkdir(tmp_home, "p")
vim.env.HOME = tmp_home

vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(plenary)

-- テストヘルパ(tests/ 配下)を require できるようにする
package.path = package.path .. ";" .. vim.fn.getcwd() .. "/?.lua"

vim.cmd("runtime plugin/plenary.vim")
