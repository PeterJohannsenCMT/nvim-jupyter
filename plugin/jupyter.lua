-- Autoload entry for nvim-jupyter
if vim.g.loaded_nvim_jupyter then
  return
end
vim.g.loaded_nvim_jupyter = true

-- Load the module that defines user commands and keymaps.
-- If you want to pass options, call require('jupyter').setup(...) in your init.
pcall(require, "jupyter.init")
pcall(require, "jupyter.diagnostics")

-- Kill the bridge/kernel when Neovim exits
vim.api.nvim_create_autocmd({ "VimLeavePre", "ExitPre" }, {
  callback = function()
    pcall(function() require("jupyter.kernel").stop() end)
  end,
})
