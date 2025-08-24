local kernel = require "jupyter.kernel"
local utils  = require "jupyter.utils"
local ui  = require "jupyter.ui"
local out    = require "jupyter.outbuf"
local M      = {}

vim.g.jupyter_outbuf_hl = "JupyterOutput"

-- Define both GUI and cterm background so it works with/without termguicolors
local function define_outbuf_hl()
  vim.api.nvim_set_hl(0, "JupyterOutput", { bg = "#1e1e2e", ctermbg = 235 })
end

define_outbuf_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = define_outbuf_hl,
})
---------------------------------------------------------------------
-- evaluate the current code block
---------------------------------------------------------------------
function M.eval_current_block()
  if not require("jupyter.kernel").is_running() then
    vim.notify("Jupyter: kernel not running (use :JupyterStart)", vim.log.levels.WARN)
    return
  end
  local s, e   = utils.find_code_block()
  -- e is inclusive (0-based) from utils → pass e+1 to buf_get_lines (exclusive)
  local lines  = vim.api.nvim_buf_get_lines(0, s, e + 1, false)
  kernel.execute(table.concat(lines, "\n"), e)   -- place inline output at end line
end

---------------------------------------------------------------------
-- run everything from top to *cursor* (inclusive)
---------------------------------------------------------------------
function M.eval_all_above()
  if not require("jupyter.kernel").is_running() then
    vim.notify("Jupyter: kernel not running (use :JupyterStart)", vim.log.levels.WARN)
    return
  end
  local current_line0 = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-based
  local lines  = vim.api.nvim_buf_get_lines(0, 0, current_line0 + 1, false) -- include cursor line
  kernel.execute(table.concat(lines, "\n"), current_line0)
end

-- Optional setup hook (allows overriding config elsewhere)
function M.setup(opts)
  if not opts then return end
  local cfg_ok, cfg = pcall(require, "jupyter.config")
  if not cfg_ok then return end
  if opts.python_cmd     then cfg.python_cmd    = opts.python_cmd     end
  if opts.kernel_name    then cfg.kernel_name   = opts.kernel_name    end
  if opts.bridge_script  then cfg.bridge_script = opts.bridge_script  end
  if opts.out and type(cfg.out) == "table" then
    for k, v in pairs(opts.out) do cfg.out[k] = v end
  end
end

---------------------------------------------------------------------
-- keymaps & command
---------------------------------------------------------------------
vim.api.nvim_create_user_command("JupyterStart",      function() kernel.start()            end, {})
vim.api.nvim_create_user_command("JupyterRestart",    function() kernel.restart()          end, {})
vim.api.nvim_create_user_command("JupyterInterrupt",  function() kernel.interrupt()        end, {})
vim.api.nvim_create_user_command("JupyterStop",       function() kernel.stop()             end, {})

vim.api.nvim_create_user_command("JupyterRunLine",      function() kernel.eval_line()        end, {})
vim.api.nvim_create_user_command("JupyterRunSelection", function() kernel.eval_selection()   end, {})
vim.api.nvim_create_user_command("JupyterRunCell",      function() kernel.eval_current_block() end, {})
vim.api.nvim_create_user_command("JupyterRunAbove",      function() kernel.eval_all_above() end, {})
vim.api.nvim_create_user_command("JupyterClearAll",      function() ui.clear_all(0) end, {})
vim.api.nvim_create_user_command("JupyterRunCellStay", function()
  local utils = require("jupyter.utils")
  local s, e = utils.find_code_block()
  if not s or not e then return end
  local lines = vim.api.nvim_buf_get_lines(0, s, e + 1, false)
  local empty = true
  for _, L in ipairs(lines) do if not L:match("^%s*$") then empty = false; break end end
  if empty then return end
  require("jupyter.kernel").execute(table.concat(lines, "\n"), e)
end, {})
vim.api.nvim_create_user_command("JupyterToggleOut",  function() out.toggle()              end, {})

vim.api.nvim_create_user_command("JupyterInterrupt", function()
  require("jupyter.kernel").interrupt({})
end, {})

vim.api.nvim_create_user_command("JupyterInterruptKeep", function()
  require("jupyter.kernel").interrupt({ drop_queue = false })
end, {})

vim.api.nvim_create_user_command("JupyterCancelQueue", function()
  require("jupyter.kernel").cancel_queue()
end, {})


-- Default buffer-local keymaps for Python; safe and non-invasive
vim.api.nvim_create_autocmd("FileType", {
	pattern = { "python" },
	callback = function(ev)
		local buf = ev.buf
		vim.keymap.set("n", "<CR>", "<cmd>JupyterRunCell<CR>",     { buffer = buf, desc = "Jupyter: run cell" })
		vim.keymap.set("n", "<leader>jC", "<cmd>JupyterRunCellStay<CR>", { desc = "Jupyter: run cell (stay)" })
		vim.keymap.set("n", "<leader>jl",  "<cmd>JupyterRunLine<CR>",      { buffer = buf, desc = "Jupyter: run line" })
		vim.keymap.set("v", "<leader>js",  "<cmd>JupyterRunSelection<CR>", { buffer = buf, desc = "Jupyter: run selection" })
		vim.keymap.set("n", "<leader>jo",  "<cmd>JupyterToggleOut<CR>",    { buffer = buf, desc = "Jupyter: toggle output" })
		vim.keymap.set("n", "<leader>js",  "<cmd>JupyterStop<CR>",    { buffer = buf, desc = "Jupyter: stop" })
		vim.keymap.set("n", "<leader>jr",  "<cmd>JupyterStart<CR>",    { buffer = buf, desc = "Jupyter: start" })
		vim.keymap.set("n", "<leader>ja",  "<cmd>JupyterRunAbove<CR>",    { buffer = buf, desc = "Jupyter: run all above" })
		vim.keymap.set("n", "<leader>jc",  "<cmd>JupyterClearAll<CR>",    { buffer = buf, desc = "Jupyter: clear virtual text" })
		vim.keymap.set("n", "<leader>ji",  "<cmd>JupyterInterrupt<CR>",    { buffer = buf, desc = "Jupyter: Interrupt" })
	end,
})

vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
  callback = function(ev)
    if vim.b[ev.buf].is_outbuf then
      local win = vim.api.nvim_get_current_win()
      -- Use same config resolution as outbuf.lua
      local function get_out_cfg()
        local ok, cfg = pcall(require, "jupyter.config")
        local defaults = { highlight = "JupyterOutput" }
        local out_cfg = (ok and type(cfg) == "table" and cfg.out) or {}
        local merged = {}; for k,v in pairs(defaults) do merged[k]=v end
        for k,v in pairs(out_cfg or {}) do merged[k]=v end
        return merged
      end
      local grp = (get_out_cfg().highlight or vim.g.jupyter_outbuf_hl or "JupyterOutput")
      vim.wo[win].winhighlight =
        ("Normal:%s,NormalNC:%s,EndOfBuffer:%s,SignColumn:%s,LineNr:%s,FoldColumn:%s,CursorLine:%s,CursorLineNr:%s")
        :format(grp, grp, grp, grp, grp, grp, grp, grp)
    end
  end,
})

return M
