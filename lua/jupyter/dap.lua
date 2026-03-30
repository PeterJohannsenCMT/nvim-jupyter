local kernel = require("jupyter.kernel")
local utils = require("jupyter.utils")

local M = {
	adapter_registered = false,
	dapui_initialized = false,
}

local function json_encode(value)
	if vim.json and vim.json.encode then
		return vim.json.encode(value)
	end
	return vim.fn.json_encode(value)
end

local function get_cfg()
	local defaults = {
		enabled = true,
		host = "127.0.0.1",
		port = nil,
		just_my_code = false,
		open_dapui = true,
	}
	local ok, cfg = pcall(require, "jupyter.config")
	local dap_cfg = (ok and type(cfg) == "table" and cfg.dap) or {}
	local merged = {}
	for k, v in pairs(defaults) do
		merged[k] = v
	end
	for k, v in pairs(dap_cfg or {}) do
		merged[k] = v
	end
	return merged
end

local function get_dap()
	local ok, dap = pcall(require, "dap")
	if not ok then
		vim.notify("Jupyter: nvim-dap is not installed", vim.log.levels.ERROR)
		return nil
	end
	return dap
end

local function get_visual_selection()
	local mode = vim.fn.mode()
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
		return nil
	end

	local start_pos = vim.fn.getpos("v")
	local end_pos = vim.fn.getpos(".")
	local start_row, start_col = start_pos[2] - 1, start_pos[3] - 1
	local end_row, end_col = end_pos[2] - 1, end_pos[3] - 1

	if start_row > end_row or (start_row == end_row and start_col > end_col) then
		start_row, end_row = end_row, start_row
		start_col, end_col = end_col, start_col
	end

	local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
	if #lines == 0 then
		return nil
	end

	if #lines == 1 then
		lines[1] = string.sub(lines[1], start_col + 1, end_col + 1)
	else
		lines[1] = string.sub(lines[1], start_col + 1)
		lines[#lines] = string.sub(lines[#lines], 1, end_col + 1)
	end

	return table.concat(lines, "\n")
end

local function get_expr(expr)
	if expr and expr ~= "" then
		return expr
	end
	local visual = get_visual_selection()
	if visual and visual ~= "" then
		return visual
	end
	return nil
end

local function get_current_cell()
	local bufnr = vim.api.nvim_get_current_buf()
	local s, e = utils.find_code_block({ include_subcells = true })
	if not s or not e then
		return nil, "No cell under cursor"
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, s, e + 1, false)
	local empty = true
	for _, line in ipairs(lines) do
		if not line:match("^%s*$") then
			empty = false
			break
		end
	end
	if empty then
		return nil, "Current cell is empty"
	end
	if utils.cell_is_skipped(lines) then
		return nil, "Current cell is marked with '# jupyter: skip'"
	end

	local marker_text = "#%% [debug]"
	if s > 0 then
		local marker_line = vim.api.nvim_buf_get_lines(bufnr, s - 1, s, false)[1]
		if marker_line then
			local marker_type = utils.marker_type(marker_line)
			if marker_type == "sub" then
				local suffix = marker_line:match("^%s*#%s*#%s*%%%%(.*)$") or ""
				marker_text = "##%%" .. suffix .. " [debug]"
			elseif marker_type == "parent" then
				local suffix = marker_line:match("^%s*#%s*%%%%(.*)$") or ""
				marker_text = "#%%" .. suffix .. " [debug]"
			end
		end
	end

	return {
		bufnr = bufnr,
		start_row = s,
		end_row = e,
		code = table.concat(lines, "\n"),
		marker_text = marker_text,
	}
end

local function build_debug_wrapper(source_path, start_row, code)
	local normalized = kernel.normalize_code(code or "")
	local padded = string.rep("\n", start_row) .. normalized
	return table.concat({
		"__nvim_jupyter_debug_globals = globals()",
		"__nvim_jupyter_debug_code = " .. json_encode(padded),
		"__nvim_jupyter_debug_filename = " .. json_encode(source_path),
		"exec(",
		"    compile(__nvim_jupyter_debug_code, __nvim_jupyter_debug_filename, 'exec'),",
		"    __nvim_jupyter_debug_globals,",
		"    __nvim_jupyter_debug_globals",
		")",
	}, "\n")
end

local function maybe_open_dapui()
	local cfg = get_cfg()
	if not cfg.open_dapui then
		return
	end
	local ok, dapui = pcall(require, "dapui")
	if ok and dapui and type(dapui.open) == "function" then
		if not M.dapui_initialized and type(dapui.setup) == "function" then
			pcall(dapui.setup, {
				layouts = {
					{
						position = "left",
						size = 52,
						elements = {
							{ id = "scopes", size = 0.45 },
							{ id = "watches", size = 0.30 },
							{ id = "stacks", size = 0.25 },
						},
					},
					{
						position = "bottom",
						size = 12,
						elements = {
							{ id = "console", size = 0.55 },
							{ id = "repl", size = 0.30 },
							{ id = "breakpoints", size = 0.15 },
						},
					},
				},
			})
			M.dapui_initialized = true
		end
		pcall(dapui.open)
	end
end

local function get_dapui()
	local ok, dapui = pcall(require, "dapui")
	if not ok then
		vim.notify("Jupyter: nvim-dap-ui is not installed", vim.log.levels.WARN)
		return nil
	end
	if not M.dapui_initialized and type(dapui.setup) == "function" then
		maybe_open_dapui()
	end
	return dapui
end

function M.register_adapter()
	if M.adapter_registered then
		return true
	end

	local cfg = get_cfg()
	if not cfg.enabled then
		vim.notify("Jupyter: DAP integration is disabled in config", vim.log.levels.WARN)
		return false
	end

	local dap = get_dap()
	if not dap then
		return false
	end

	dap.adapters["jupyter-python"] = function(callback, config)
		local connect = config.connect or {}
		callback({
			type = "server",
			host = connect.host or get_cfg().host or "127.0.0.1",
			port = tonumber(connect.port or config.port),
			options = {
				source_filetype = "python",
			},
		})
	end

	M.adapter_registered = true
	return true
end

local function build_attach_config(state, source_path)
	local cfg = get_cfg()
	return {
		type = "jupyter-python",
		request = "attach",
		name = "Jupyter: attach kernel debugger",
		connect = {
			host = state.host or cfg.host or "127.0.0.1",
			port = tonumber(state.port),
		},
		justMyCode = cfg.just_my_code,
		pathMappings = {
			{
				localRoot = vim.fn.getcwd(),
				remoteRoot = vim.fn.getcwd(),
			},
		},
		__jupyter_source_path = source_path,
	}
end

local function attach_and_run(state, source_path, run_cb)
	local dap = get_dap()
	if not dap or not M.register_adapter() then
		return
	end

	local session = dap.session()
	if
		session
		and session.config
		and session.config.type == "jupyter-python"
		and session.config.connect
		and tonumber(session.config.connect.port) == tonumber(state.port)
	then
		maybe_open_dapui()
		run_cb()
		return
	end

	local listener_key = "nvim-jupyter-" .. tostring(vim.loop.hrtime())
	dap.listeners.after.event_initialized[listener_key] = function()
		dap.listeners.after.event_initialized[listener_key] = nil
		maybe_open_dapui()
		vim.schedule(run_cb)
	end
	dap.listeners.before.event_terminated[listener_key] = function()
		dap.listeners.before.event_terminated[listener_key] = nil
		dap.listeners.before.disconnect[listener_key] = nil
	end
	dap.listeners.before.disconnect[listener_key] = function()
		dap.listeners.after.event_initialized[listener_key] = nil
		dap.listeners.before.event_terminated[listener_key] = nil
		dap.listeners.before.disconnect[listener_key] = nil
	end

	dap.run(build_attach_config(state, source_path))
end

function M.debug_current_cell()
	local cfg = get_cfg()
	if not cfg.enabled then
		vim.notify("Jupyter: DAP integration is disabled in config", vim.log.levels.WARN)
		return
	end

	local cell, err = get_current_cell()
	if not cell then
		vim.notify("Jupyter: " .. err, vim.log.levels.WARN)
		return
	end

	local source_path = vim.api.nvim_buf_get_name(cell.bufnr)
	if not source_path or source_path == "" then
		vim.notify(
			"Jupyter: save the file before debugging a cell so breakpoints have a real path",
			vim.log.levels.WARN
		)
		return
	end
	source_path = vim.fn.fnamemodify(source_path, ":p")

	local debug_code = build_debug_wrapper(source_path, cell.start_row, cell.code)

	kernel.ensure_debugpy(function(state, bootstrap_err)
		if bootstrap_err or not state then
			return
		end

		attach_and_run(state, source_path, function()
			kernel.execute(debug_code, cell.end_row, cell.marker_text, {
				source_path = source_path,
				absolute_lineno = true,
			})
		end)
	end)
end

function M.watch_expression(expr)
	local dapui = get_dapui()
	if not dapui then
		return
	end

	expr = get_expr(expr)
	local watches = dapui.elements and dapui.elements.watches
	if not watches or type(watches.add) ~= "function" then
		vim.notify("Jupyter: nvim-dap-ui watches are unavailable", vim.log.levels.WARN)
		return
	end

	watches.add(expr)
	maybe_open_dapui()
end

function M.eval_expression(expr)
	local dapui = get_dapui()
	if not dapui or type(dapui.eval) ~= "function" then
		return
	end

	dapui.eval(get_expr(expr), { enter = false, context = "repl" })
end

return M
