local utils = require("jupyter.utils")

local api = vim.api
local M = {}

local ns_conceal = api.nvim_create_namespace("nvim-jupyter-markdown-cells")
local TEXT_HL = "@jupyter.markdown.text"

local function define_highlights()
	api.nvim_set_hl(0, TEXT_HL, { link = "Normal", default = true })
end

define_highlights()
api.nvim_create_autocmd("ColorScheme", {
	callback = define_highlights,
})

local defaults = {
	enabled = true,
	conceal = true,
	conceallevel = 2,
	concealcursor = "nvic",
}

local function get_cfg()
	local cfg = {}
	for k, v in pairs(defaults) do
		cfg[k] = v
	end

	local ok, jcfg = pcall(require, "jupyter.config")
	local md_cfg = ok and jcfg and jcfg.ui and jcfg.ui.markdown_cells or nil
	if type(md_cfg) == "table" then
		for k, v in pairs(md_cfg) do
			cfg[k] = v
		end
	elseif md_cfg == false then
		cfg.enabled = false
	end

	return cfg
end

local function first_capture_node(match, capture_id)
	local nodes = match and match[capture_id]
	if type(nodes) == "table" then
		return nodes[1]
	end
	return nodes
end

---Treesitter predicate used by queries/python/injections.scm.
---Returns true for Python comment nodes that form the body of a #%% [markdown]
---cell. The marker line itself is excluded.
local function markdown_cell_predicate(match, _, source, predicate)
	local cfg = get_cfg()
	if not cfg.enabled then
		return false
	end
	if type(source) ~= "number" then
		return false
	end

	local capture_id = predicate and predicate[2]
	if type(capture_id) ~= "number" then
		return false
	end

	local node = first_capture_node(match, capture_id)
	if not node then
		return false
	end

	local row = node:range()
	return utils.is_row_in_markdown_cell(source, row)
end

---Directive used by queries/python/injections.scm.
---It trims the Python comment leader from the injected range.  This is a
---custom directive instead of a plain #offset! because we want to strip both
---`#` and one optional padding space; otherwise Markdown/rendering plugins can
---see `# Some text` as a heading rather than `Some text`.
local function markdown_comment_range_directive(match, _, bufnr, predicate, metadata)
	local capture_id = predicate and predicate[2]
	if type(capture_id) ~= "number" then
		return
	end

	local node = first_capture_node(match, capture_id)
	if not node then
		return
	end

	local start_row, start_col, end_row, end_col = node:range()
	local text = type(bufnr) == "number" and vim.treesitter.get_node_text(node, bufnr) or nil
	text = text or ""

	local skip = 0
	local prefix = text:match("^(%s*# ?)")
	if prefix then
		skip = #prefix
	end

	local new_start_col = math.min(start_col + skip, end_col)

	-- Include the line break after each Python comment in the injected range.
	-- Without this, combined markdown injections can concatenate all comment
	-- nodes into one logical line, so an opening `## Heading` can make the whole
	-- cell parse/highlight as one large heading.
	local range_end_row, range_end_col = end_row, end_col
	if type(bufnr) == "number" and end_row == start_row then
		local line_count = api.nvim_buf_line_count(bufnr)
		if start_row + 1 < line_count then
			range_end_row = start_row + 1
			range_end_col = 0
		end
	end

	metadata[capture_id] = metadata[capture_id] or {}
	metadata[capture_id].range = { start_row, new_start_col, range_end_row, range_end_col }
end

function M.register_predicates()
	if M._predicates_registered then
		return
	end
	local pred_ok = pcall(vim.treesitter.query.add_predicate, "jupyter-markdown-cell?", markdown_cell_predicate, { force = true })
	local dir_ok = pcall(
		vim.treesitter.query.add_directive,
		"jupyter-md-comment-range!",
		markdown_comment_range_directive,
		{ force = true }
	)
	M._predicates_registered = pred_ok and dir_ok
end

local function windows_for_buffer(bufnr)
	local wins = {}
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
			table.insert(wins, win)
		end
	end
	return wins
end

local function apply_conceal_options(bufnr, cfg)
	for _, win in ipairs(windows_for_buffer(bufnr)) do
		if cfg.conceallevel ~= nil then
			if vim.w[win].jupyter_markdown_prev_conceallevel == nil then
				vim.w[win].jupyter_markdown_prev_conceallevel = api.nvim_get_option_value("conceallevel", { win = win })
			end
			pcall(api.nvim_set_option_value, "conceallevel", cfg.conceallevel, { scope = "local", win = win })
		end
		if cfg.concealcursor ~= nil then
			if vim.w[win].jupyter_markdown_prev_concealcursor == nil then
				vim.w[win].jupyter_markdown_prev_concealcursor = api.nvim_get_option_value("concealcursor", { win = win })
			end
			pcall(api.nvim_set_option_value, "concealcursor", cfg.concealcursor, { scope = "local", win = win })
		end
	end
end

local function restore_conceal_options(bufnr)
	for _, win in ipairs(windows_for_buffer(bufnr)) do
		local prev_level = vim.w[win].jupyter_markdown_prev_conceallevel
		if prev_level ~= nil then
			pcall(api.nvim_set_option_value, "conceallevel", prev_level, { scope = "local", win = win })
			vim.w[win].jupyter_markdown_prev_conceallevel = nil
		end
		local prev_cursor = vim.w[win].jupyter_markdown_prev_concealcursor
		if prev_cursor ~= nil then
			pcall(api.nvim_set_option_value, "concealcursor", prev_cursor, { scope = "local", win = win })
			vim.w[win].jupyter_markdown_prev_concealcursor = nil
		end
	end
end

local function comment_prefix_range(line)
	if type(line) ~= "string" then
		return nil, nil
	end

	local hash_col1 = line:find("^%s*#")
	if not hash_col1 then
		return nil, nil
	end

	local end_col0 = hash_col1 -- conceal the '#'
	if line:sub(hash_col1 + 1, hash_col1 + 1) == " " then
		end_col0 = end_col0 + 1 -- and one following padding space
	end

	return hash_col1 - 1, end_col0
end

---Conceal leading Python comment markers inside markdown cells so the buffer
---visually reads like inline markdown.
---@param bufnr integer|nil
function M.render(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
		return
	end

	api.nvim_buf_clear_namespace(bufnr, ns_conceal, 0, -1)

	local cfg = get_cfg()
	if not cfg.enabled or not cfg.conceal then
		restore_conceal_options(bufnr)
		return
	end

	local ranges = utils.get_markdown_cell_body_ranges(bufnr)
	if #ranges == 0 then
		restore_conceal_options(bufnr)
		return
	end

	apply_conceal_options(bufnr, cfg)

	for _, range in ipairs(ranges) do
		local start_row = range.start_row
		local end_row = range.end_row
		if start_row and end_row and start_row <= end_row then
			local lines = api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
			for i, line in ipairs(lines) do
				local row = start_row + i - 1
				local start_col, end_col = comment_prefix_range(line)
				if start_col and end_col and end_col > start_col then
					pcall(api.nvim_buf_set_extmark, bufnr, ns_conceal, row, start_col, {
						end_row = row,
						end_col = end_col,
						conceal = "",
						priority = 210,
					})
				end
			end
		end
	end
end

M.register_predicates()

return M
