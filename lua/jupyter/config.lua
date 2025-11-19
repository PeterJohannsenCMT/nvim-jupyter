local M = {
	python_cmd = (vim.env.CONDA_PREFIX and (vim.env.CONDA_PREFIX .. "/bin/python")) or "python3",
  kernel_name   = "python3",  -- Jupyter kernel to start
  bridge_script = nil,        -- Optional absolute path to python/bridge.py

	out = {
		split       = "bottom",   -- "bottom" or "right"
		height      = 12,         -- rows for bottom split
		width       = 60,         -- cols for right split
		open_on_run = true,       -- auto-open pane on first execution
		auto_scroll = true,
		focus_on_open = false,
		highlight = vim.g.jupyter_outbuf_hl or "JupyterOutput",
	},
	pager = {
		split = "right",        -- where to show pager output
		height = 15,
		width = 60,
		focus_on_open = true,   -- stay in code window by default
		filetype = "markdown",
	},
	interrupt = {
		drop_queue = true,
		timeout_ms = 3000,
		restart_on_timeout = true,
	},
	inline = {
		enabled    = true,        -- set to false to disable inline output
		strip_ansi = true,
		maxlen     = 120,
		prefix     = " ⇒  ",
		hl_normal  = "JupyterInline",
		hl_error   = "ErrorMsg",
	},
	ui = {
		show_cell_borders = true,  -- Show virtual lines above/below #%% markers
		highlight_metadata = true,
		metadata_hl = {
			fg = "#88a0f9",
			bg = "#10101e",
		},
	},
	fold = {
		close_cells_on_open = false,  -- Automatically close all folds when opening a Python file with #%% markers
	},
}
return M
