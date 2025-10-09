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
  if opts.ui then
    if not cfg.ui then cfg.ui = {} end
    for k, v in pairs(opts.ui) do cfg.ui[k] = v end
  end
  if opts.fold then
    if not cfg.fold then cfg.fold = {} end
    for k, v in pairs(opts.fold) do cfg.fold[k] = v end
  end
end

---------------------------------------------------------------------
-- folding support for #%% cell markers + treesitter
---------------------------------------------------------------------
local has_cell_markers_cache = {}

local function buffer_has_cell_markers(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Check cache
  if has_cell_markers_cache[bufnr] ~= nil then
    return has_cell_markers_cache[bufnr]
  end

  -- Search for cell markers in buffer
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:match("^#%%") then
      has_cell_markers_cache[bufnr] = true
      return true
    end
  end

  has_cell_markers_cache[bufnr] = false
  return false
end

function M.fold_expr()
  local lnum = vim.v.lnum
  local line = vim.fn.getline(lnum)
  local bufnr = vim.api.nvim_get_current_buf()

  -- Check if buffer has cell markers
  local has_cells = buffer_has_cell_markers(bufnr)

  if has_cells then
    -- Hybrid mode: cell markers + treesitter
    if line:match("^#%%") then
      return ">1"  -- Start a level 1 fold for the cell
    end

    -- Get treesitter fold level and increment it to nest within cells
    local ok, ts_result = pcall(vim.treesitter.foldexpr, lnum)
    if ok and ts_result and ts_result ~= "0" then
      -- Parse the treesitter result and increment fold level
      if type(ts_result) == "string" then
        if ts_result:match("^>") then
          local level = tonumber(ts_result:sub(2))
          return ">" .. (level + 1)
        elseif ts_result == "=" then
          return "="
        else
          local level = tonumber(ts_result)
          if level and level > 0 then
            return tostring(level + 1)
          end
        end
      end
    end

    -- Continue at same level within cell
    return "="
  else
    -- No cell markers: use pure treesitter folding
    local ok, ts_result = pcall(vim.treesitter.foldexpr, lnum)
    if ok and ts_result then
      return ts_result
    end
    return "0"
  end
end

-- Clear cache when buffer changes
vim.api.nvim_create_autocmd({"BufWrite", "TextChanged", "TextChangedI"}, {
  callback = function(ev)
    has_cell_markers_cache[ev.buf] = nil
  end
})

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

vim.api.nvim_create_user_command("JupyterUpdateSigns", function()
  local bufnr = vim.api.nvim_get_current_buf()
  require("jupyter.ui").update_sign_positions(bufnr)
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

		-- Set up folding for #%% cell markers
		vim.opt_local.foldmethod = "expr"
		vim.opt_local.foldexpr = "v:lua.require'jupyter'.fold_expr()"
	end,
})

-- Auto-close folds when opening a Python file with cell markers (if enabled)
vim.api.nvim_create_autocmd("BufReadPost", {
	pattern = { "*.py" },
	callback = function(ev)
		local buf = ev.buf
		local cfg_ok, cfg = pcall(require, "jupyter.config")
		if not cfg_ok or not cfg.fold or not cfg.fold.close_cells_on_open then
			return
		end

		-- Check if the buffer has cell markers
		vim.schedule(function()
			if buffer_has_cell_markers(buf) then
				-- Close all folds
				vim.cmd("normal! zM")
			end
		end)
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

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "python", "julia" },
  callback = function(args)
    vim.api.nvim_create_autocmd(
      { "InsertEnter", "InsertLeave", "BufEnter", "TextChanged", "BufWinEnter" },
      {
        buffer = args.buf,
        callback = function()
					local p = require("jupyter.ui")
          vim.schedule(function()
            p.highlight_cells()
          end)
        end,
      }
    )
    -- Separate autocmd for sign updates (triggered on cursor events and fold operations)
    vim.api.nvim_create_autocmd(
      { "CursorMoved", "CursorMovedI", "CursorHold", "CursorHoldI" },
      {
        buffer = args.buf,
        callback = function()
          local p = require("jupyter.ui")
          vim.schedule(function()
            p.update_sign_positions(args.buf)
          end)
        end,
      }
    )
  end,
})

return M
