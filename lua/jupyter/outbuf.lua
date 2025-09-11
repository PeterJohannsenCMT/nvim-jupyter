local api = vim.api
local ui = require "jupyter.ui"
local cfg_out = require"jupyter.config".out or {}

local function get_out_cfg()
  local ok, cfg = pcall(require, "jupyter.config")
  local defaults = {
    split = "bottom", height = 8, width = 60,
    open_on_run = true, focus_on_open = false, auto_scroll = true,
    ansi = { enabled = true },
  }
  local out_cfg = (ok and type(cfg) == "table" and cfg.out) or {}
  local merged = {}; for k,v in pairs(defaults) do merged[k]=v end
  for k,v in pairs(out_cfg or {}) do merged[k]=v end
  return merged
end

local M = {}
local out_bufnr, out_winid = nil, nil
-- local highlight_timer = nil

-- per-seq cell state
-- state[seq] = { opened = bool, row = int|nil, line = string }
local state = {}

local function get_baleia()
  local ok, inst = pcall(function() return vim.g.baleia end)
  if ok and inst then return inst end
  local ok2, mod = pcall(require, "baleia")
  if ok2 then
    local b = mod.setup({})
    vim.g.baleia = vim.g.baleia or b
    return b
  end
  return nil
end

local function set_lines_colored(buf, s, e, lines)
  local baleia = get_baleia()
  if baleia then baleia.buf_set_lines(buf, s, e, false, lines)
  else api.nvim_buf_set_lines(buf, s, e, false, lines) end
end

local function ensure_buf()
  if out_bufnr and api.nvim_buf_is_valid(out_bufnr) then return out_bufnr end

  -- Reset references if buffer was invalid
  out_bufnr = nil
  out_winid = nil

	out_bufnr = api.nvim_create_buf(false, true)
	-- Give outbuf its own background


	api.nvim_buf_set_option(out_bufnr, "buftype", "nofile")
	api.nvim_buf_set_option(out_bufnr, "bufhidden", "hide")
	api.nvim_buf_set_option(out_bufnr, "filetype", "python")
	vim.b[out_bufnr].is_outbuf = true

  -- Set up autocmd to clean up references when buffer is deleted
  api.nvim_create_autocmd({"BufDelete", "BufWipeout"}, {
    buffer = out_bufnr,
    callback = function()
      if out_bufnr then
        -- stop_highlight_timer()
        out_bufnr = nil
        out_winid = nil
      end
    end,
    once = true,
  })

  -- Set up autocmd to maintain highlight for this buffer's window at all times
  api.nvim_create_autocmd({ "BufEnter", "WinEnter", "BufWinEnter", "BufLeave", "WinLeave" }, {
    buffer = out_bufnr,
    callback = function()
      -- Find the window that contains this outbuf, regardless of current window
      local outbuf_win = nil
      for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == out_bufnr then
          outbuf_win = win
          break
        end
      end
      
      if outbuf_win and vim.b[out_bufnr].is_outbuf then
        local cfg = get_out_cfg()
        local grp = (cfg.highlight or vim.g.jupyter_outbuf_hl or "JupyterOutput")
        vim.wo[outbuf_win].winhighlight =
          ("Normal:%s,NormalNC:%s,EndOfBuffer:%s,SignColumn:%s,LineNr:%s,FoldColumn:%s,CursorLine:%s,CursorLineNr:%s")
          :format(grp, grp, grp, grp, grp, grp, grp, grp)
      end

			local p = require"jupyter.ui"
			vim.schedule(p.highlight_cells)
    end
  })

  return out_bufnr
end

local function open_window()
  local cfg = get_out_cfg()
  local prev = api.nvim_get_current_win()
  local buf = ensure_buf()

  if cfg.split == "right" then
    vim.cmd(("botright %dvsplit"):format(tonumber(cfg.width) or 60))
  else
    vim.cmd(("botright %dsplit"):format(tonumber(cfg.height) or 8))
  end

	vim.b[buf].is_outbuf = true
  out_winid = api.nvim_get_current_win()
  api.nvim_win_set_buf(out_winid, buf)

	local cfg = get_out_cfg()
	local grp = (cfg.highlight or vim.g.jupyter_outbuf_hl or "JupyterOutput")
	vim.wo[out_winid].winhighlight =
		("Normal:%s,NormalNC:%s,EndOfBuffer:%s,SignColumn:%s,LineNr:%s,FoldColumn:%s,CursorLine:%s,CursorLineNr:%s")
			:format(grp, grp, grp, grp, grp, grp, grp, grp)

	-- guard against late overrides by other plugins
	vim.schedule(function()
		if vim.api.nvim_win_is_valid(out_winid) then
			vim.wo[out_winid].winhighlight =
				("Normal:%s,NormalNC:%s,EndOfBuffer:%s,SignColumn:%s,LineNr:%s,FoldColumn:%s,CursorLine:%s,CursorLineNr:%s")
					:format(grp, grp, grp, grp, grp, grp, grp, grp)
		end
	end)

  api.nvim_buf_set_option(buf, "modifiable", true)

  if cfg.focus_on_open ~= true and api.nvim_win_is_valid(prev) then
    api.nvim_set_current_win(prev)
  end
  
  -- Start the highlight maintenance timer when window opens
  -- start_highlight_timer()
end

-- Function to ensure outbuf window always has correct highlight
local function maintain_outbuf_highlight()
  if out_bufnr and api.nvim_buf_is_valid(out_bufnr) then
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == out_bufnr then
        local cfg = get_out_cfg()
        local grp = (cfg.highlight or vim.g.jupyter_outbuf_hl or "JupyterOutput")
        vim.wo[win].winhighlight =
          ("Normal:%s,NormalNC:%s,EndOfBuffer:%s,SignColumn:%s,LineNr:%s,FoldColumn:%s,CursorLine:%s,CursorLineNr:%s")
          :format(grp, grp, grp, grp, grp, grp, grp, grp)
        break
      end
    end
  end
end

-- Start timer to maintain highlight
-- local function start_highlight_timer()
--   if highlight_timer then return end -- Already running
--   highlight_timer = vim.loop.new_timer()
--   if highlight_timer then
--     highlight_timer:start(100, 500, vim.schedule_wrap(maintain_outbuf_highlight)) -- Check every 500ms
--   end
-- end
--
-- -- Stop the highlight maintenance timer
-- local function stop_highlight_timer()
--   if highlight_timer then
--     highlight_timer:stop()
--     highlight_timer:close()
--     highlight_timer = nil
--   end
-- end

-- local function scroll_to_bottom()
--   local cfg = get_out_cfg()
--   if not cfg.auto_scroll then return end
--   if out_winid and api.nvim_win_is_valid(out_winid) and out_bufnr and api.nvim_buf_is_valid(out_bufnr) then
--     local last = api.nvim_buf_line_count(out_bufnr)
--     api.nvim_win_call(out_winid, function()
--       api.nvim_win_set_cursor(out_winid, { last, 0 })
--     end)
--   end
-- end

local OUT_PAD_NS = api.nvim_create_namespace('outbuf_pad')

local function scroll_to_bottom()
  local cfg = get_out_cfg()
  if not cfg.auto_scroll then return end
  if out_winid and api.nvim_win_is_valid(out_winid) and out_bufnr and api.nvim_buf_is_valid(out_bufnr) then
    -- clear any previous padding
    api.nvim_buf_clear_namespace(out_bufnr, OUT_PAD_NS, 0, -1)

    local last = api.nvim_buf_line_count(out_bufnr)

    -- add one virtual line *below* the last line
    -- requires Neovim ≥ 0.9 (virt_lines)
    -- api.nvim_buf_set_extmark(out_bufnr, OUT_PAD_NS, last - 1, 0, {
    --   virt_lines = { { { " ", "Normal" } } },  -- one blank virtual line
    --   virt_lines_above = false,                 -- place below the line
    -- })

    api.nvim_win_call(out_winid, function()
      api.nvim_win_set_cursor(out_winid, { last, 0 })
      -- optional: keep a bit of context too
      -- vim.wo.scrolloff = math.max(vim.wo.scrolloff, 1)
    end)
  end
end

function M.is_visible() return out_winid and api.nvim_win_is_valid(out_winid) end
function M.open() if not M.is_visible() then open_window() end end
function M.toggle()
  if M.is_visible() then 
    pcall(api.nvim_win_close, out_winid, true)
    out_winid = nil
  else 
    open_window()
  end
end

function M.clear()
  local buf = ensure_buf()
  api.nvim_buf_set_option(buf, "modifiable", true)
  set_lines_colored(buf, 0, -1, {})
  api.nvim_buf_set_option(buf, "modifiable", false)
  state = {}
  scroll_to_bottom()
end

local function append_lines(lines)
  local buf  = ensure_buf()
  local last = api.nvim_buf_line_count(buf)
  local last_line = api.nvim_buf_get_lines(buf, last - 1, last, false)[1]

  api.nvim_buf_set_option(buf, "modifiable", true)
  if last == 1 and (last_line == nil or last_line == "") then
    -- Buffer is "empty": replace that first blank line
    set_lines_colored(buf, 0, 1, lines)
  else
    -- Real content exists: append after last line
    set_lines_colored(buf, last, last, lines)
  end
  api.nvim_buf_set_option(buf, "modifiable", false)
  scroll_to_bottom()
end

-- Lazy header: only print "#%%" when we actually have content to show
local function ensure_started(seq)
  local st = state[seq]
  if st and st.opened then return st end
  M.open()
  local buf = ensure_buf()
  append_lines({("#%%"), ""})
  st = st or {}
  st.opened = true
  st.row = api.nvim_buf_line_count(buf) - 1
  st.line = st.line or ""
  state[seq] = st
  return st
end

function M.start_cell(seq)
  -- register the cell but DO NOT open or print header yet
  state[seq] = { opened = false, row = nil, line = "" }
end

-- helpers to decide if a segment has visible content
local ANSI_CSI = "\27%[[0-?]*[ -/]*[@-~]"
local function is_effectively_empty(s)
  if not s or s == "" then return true end
  s = tostring(s)
  -- remove CR, ANSI, backspace, newlines, then trim
  s = s:gsub("\r", "")
       :gsub(ANSI_CSI, "")
       :gsub("\b", "")
       :gsub("\n", "")
  return s:match("^%s*$") ~= nil
end

-- batched streaming with \r support; only append non-empty visible content
function M.append_stream(seq, text)
  if not text or text == "" then return end

  local s = tostring(text):gsub("\r\n", "\n")
  local trailing_nl = s:sub(-1) == "\n"

  -- split into newline-terminated segments + optional final
  local segs, i = {}, 1
  while true do
    local j = s:find("\n", i, true)
    if not j then table.insert(segs, s:sub(i)); break end
    table.insert(segs, s:sub(i, j - 1)); i = j + 1
  end

  local wrote_any = false

  -- completed lines (only when non-empty after CR/ANSI stripping)
  local last_idx = trailing_nl and #segs or (#segs - 1)
  for k = 1, math.max(0, last_idx) do
    local seg = segs[k]
    local vis = seg:match("[^\r]*$") or seg
    if not is_effectively_empty(vis) then
      local st = ensure_started(seq)
      local buf = ensure_buf()
      api.nvim_buf_set_option(buf, "modifiable", true)
      set_lines_colored(buf, st.row, st.row + 1, { vis })
      set_lines_colored(buf, st.row + 1, st.row + 1, { "" })
      api.nvim_buf_set_option(buf, "modifiable", false)
      st.row, st.line = st.row + 1, ""
      wrote_any = true
    end
  end

  -- in-place progress frame (no newline): update only if non-empty and changed
  if not trailing_nl then
    local final = (segs[#segs] or ""):match("[^\r]*$") or ""
    if not is_effectively_empty(final) then
      local st = ensure_started(seq)
      local buf = ensure_buf()
      if final ~= st.line then
        api.nvim_buf_set_option(buf, "modifiable", true)
        set_lines_colored(buf, st.row, st.row + 1, { final })
        api.nvim_buf_set_option(buf, "modifiable", false)
        st.line = final
        wrote_any = true
      end
    end
  end

  if wrote_any then scroll_to_bottom() end
end

function M.append(seq, text)
  local s = tostring(text or "")
  if s == "" or s:match("^%s*$") then return end
  ensure_started(seq)
  local lines = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
  if #lines > 0 then append_lines(lines) end
end

function M.append_markdown(seq, md)
  local s = tostring(md or "")
  if s == "" or s:match("^%s*$") then return end
  ensure_started(seq)
  append_lines({ "", s, "" })
end


-- ===== nvim-jupyter: clear virtlines + outbuf integration =====

--- Clear inline virtual marks in the *current* source buffer.
function M.clear_inline_current()
  pcall(ui.clear_all, 0)
end

--- Clear both: outbuf + inline marks in current buffer.
function M.clear_both()
  -- clear outbuf text
  pcall(M.clear)
  -- clear inline marks in the current buffer (0)
  pcall(ui.clear_all, 0)
end

-- Command(s)
pcall(vim.api.nvim_create_user_command, "JupyterClearOut", function() M.clear() end,
  { desc = "Clear Jupyter outbuf window" })

pcall(vim.api.nvim_create_user_command, "JupyterClearBoth", function() M.clear_both() end,
  { desc = "Clear Jupyter outbuf and inline virtual text (current buffer)" })

-- Keymap for Python buffers: clear both with <leader>j0
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "python" },
  callback = function(ev)
    vim.keymap.set("n", "<leader>j0", function() M.clear_both() end,
      { buffer = ev.buf, silent = true, desc = "Jupyter: clear outbuf + inline" })
  end,
})

-- Reset outbuf automatically when user runs :JupyterStop (wrapper via cmdline abbrev)
pcall(vim.api.nvim_create_user_command, "JupyterStopReset", function(opts)
  -- Call the existing JupyterStop command (defined in jupyter.init) then clear outbuf.
  local bang = opts.bang and "!" or ""
  local args = opts.args or ""
  -- Programmatic call avoids cmdline abbreviation loops.
  pcall(vim.cmd, ("JupyterStop%s %s"):format(bang, args))
  pcall(M.clear)
end, { nargs = "*", bang = true, complete = "command" })

-- Abbreviate typed :JupyterStop to our wrapper; keeps scripting untouched.
vim.cmd([[
  cnoreabbrev <expr> JupyterStop (getcmdtype() == ':' && getcmdline() =~# '^\s*JupyterStop\%($\|\s\)') ? 'JupyterStopReset' : 'JupyterStop'
]])

-- ===== end integration =====
-- Hook kernel.stop() to clear outbuf afterwards (safe monkey-patch).
vim.schedule(function()
  local ok, kernel = pcall(require, "jupyter.kernel")
  if ok and type(kernel) == "table" and type(kernel.stop) == "function" and not kernel._stop_wrapped then
    local orig = kernel.stop
    kernel.stop = function(...)
      local ret = orig(...)
      -- reset the outbuf so next session starts empty
      pcall(M.clear)
      return ret
    end
    kernel._stop_wrapped = true
  end
end)

return M
