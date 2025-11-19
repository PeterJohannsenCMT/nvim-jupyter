local api = vim.api
local ui = require "jupyter.ui"
local filetype = require "jupyter.filetype"
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

local function get_pager_cfg()
  local defaults = {
    split = "right",
    height = 15,
    width = 60,
    focus_on_open = false,
    filetype = "markdown",
  }
  local ok, cfg = pcall(require, "jupyter.config")
  local pager_cfg = (ok and type(cfg) == "table" and cfg.pager) or {}
  local merged = {}; for k,v in pairs(defaults) do merged[k]=v end
  for k,v in pairs(pager_cfg or {}) do merged[k]=v end
  return merged
end

local M = {}
local out_bufnr, out_winid = nil, nil
local pager_bufnr, pager_winid = nil, nil
local close_pager_window
-- local highlight_timer = nil

-- per-seq cell state
-- state[seq] = { opened = bool, row = int|nil, line = string }
local state = {}

-- Baleia for ANSI color rendering (only used for errors)
local baleia = nil
local function get_baleia()
  if baleia then return baleia end
  local ok, b = pcall(require, "baleia")
  if ok then
    baleia = b.setup({ line_starts_at = 1 })
  end
  return baleia
end

-- ANSI escape sequence patterns - strip all ANSI codes
local ANSI_CSI = "\27%[[0-?]*[ -/]*[@-~]"  -- CSI sequences
local ANSI_OSC = "\27%].-\7"                -- OSC sequences

local function strip_ansi(text)
  if not text then return "" end
  local cleaned = tostring(text)
  cleaned = cleaned:gsub(ANSI_CSI, "")  -- Remove CSI sequences
  cleaned = cleaned:gsub(ANSI_OSC, "")  -- Remove OSC sequences
  return cleaned
end

local function set_lines_colored(buf, s, e, lines, is_error)
  if is_error then
    -- Use baleia for error messages (infrequent, safe)
    local b = get_baleia()
    if b then
      -- baleia.buf_set_lines sets the lines AND applies colors
      local ok, err = pcall(function()
        b.buf_set_lines(buf, s, e, false, lines)
      end)
      if ok then
        return
      end
      -- Fallback if baleia fails (fall through to strip)
    end
  end

  -- For normal output: strip all ANSI codes
  local stripped = {}
  for i, line in ipairs(lines) do
    stripped[i] = strip_ansi(line)
  end
  api.nvim_buf_set_lines(buf, s, e, false, stripped)
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
	filetype.apply_outbuf(out_bufnr)
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

local function ensure_pager_buf(cfg)
  if pager_bufnr and api.nvim_buf_is_valid(pager_bufnr) then return pager_bufnr end

  pager_bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(pager_bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(pager_bufnr, "bufhidden", "wipe")
  local ft = cfg and cfg.filetype or "markdown"
  if ft and ft ~= "" then
    pcall(api.nvim_buf_set_option, pager_bufnr, "filetype", ft)
  end

  api.nvim_create_autocmd({"BufDelete", "BufWipeout"}, {
    buffer = pager_bufnr,
    callback = function()
      pager_bufnr = nil
      pager_winid = nil
    end,
    once = true,
  })

  vim.keymap.set("n", "q", function()
    close_pager_window()
  end, { buffer = pager_bufnr, silent = true, nowait = true })

  return pager_bufnr
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

local function open_pager_window(cfg)
  local prev = api.nvim_get_current_win()
  local buf = ensure_pager_buf(cfg)

  if cfg.split == "right" then
    vim.cmd(("botright %dvsplit"):format(tonumber(cfg.width) or 60))
  else
    vim.cmd(("botright %dsplit"):format(tonumber(cfg.height) or 15))
  end

  pager_winid = api.nvim_get_current_win()
  api.nvim_win_set_buf(pager_winid, buf)

  if cfg.focus_on_open ~= true and api.nvim_win_is_valid(prev) then
    api.nvim_set_current_win(prev)
  end
end

close_pager_window = function()
  if pager_winid and api.nvim_win_is_valid(pager_winid) then
    pcall(api.nvim_win_close, pager_winid, true)
    pager_winid = nil
    return
  end
  if pager_bufnr and api.nvim_buf_is_valid(pager_bufnr) then
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == pager_bufnr then
        pcall(api.nvim_win_close, win, true)
      end
    end
  end
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
local CELL_MARKER_NS = api.nvim_create_namespace('jupyter_cell_marker')

-- Define highlight for cell markers
vim.api.nvim_set_hl(0, "JupyterCellMarker", {
  fg = "#89b4fa",  -- Bright blue (catppuccin blue)
  bold = true,
  default = true   -- Allow users to override
})

-- Throttle scrolling to prevent EMFILE during rapid output
local last_scroll = 0
local SCROLL_THROTTLE_MS = 100  -- Max 10 scrolls per second

local function scroll_to_bottom(force)
  local cfg = get_out_cfg()
  if not cfg.auto_scroll then return end
  if not (out_winid and api.nvim_win_is_valid(out_winid) and out_bufnr and api.nvim_buf_is_valid(out_bufnr)) then
    return
  end

  -- Throttle: only scroll every 100ms (unless forced)
  if not force then
    local now = vim.loop.now()
    if now - last_scroll < SCROLL_THROTTLE_MS then
      return
    end
    last_scroll = now
  end

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
  set_lines_colored(buf, 0, -1, {}, false)
  api.nvim_buf_set_option(buf, "modifiable", false)
  -- Clear cell marker highlights
  api.nvim_buf_clear_namespace(buf, CELL_MARKER_NS, 0, -1)
  state = {}
  -- Clear any pending buffer updates
  pending_buffer_updates = {}
  scroll_to_bottom()
end

local function append_lines(lines, is_error)
  local buf  = ensure_buf()
  local last = api.nvim_buf_line_count(buf)
  local last_line = api.nvim_buf_get_lines(buf, last - 1, last, false)[1]

  api.nvim_buf_set_option(buf, "modifiable", true)
  if last == 1 and (last_line == nil or last_line == "") then
    -- Buffer is "empty": replace that first blank line
    set_lines_colored(buf, 0, 1, lines, is_error)
  else
    -- Real content exists: append after last line
    set_lines_colored(buf, last, last, lines, is_error)
  end
  api.nvim_buf_set_option(buf, "modifiable", false)
  scroll_to_bottom(is_error)  -- Force scroll on errors
end

-- Lazy header: only print "#%%" when we actually have content to show
local function ensure_started(seq)
  local st = state[seq]
  if st and st.opened then return st end
  M.open()
  local buf = ensure_buf()
  local marker = (st and st.marker_text) or "#%%"

  -- Get the line number where the marker will be inserted BEFORE adding lines
  local line_before = api.nvim_buf_line_count(buf)
  local marker_line = line_before - 1
  if marker_line < 0 then marker_line = 0 end

  -- Check if buffer is empty
  local is_empty = line_before == 1 and (api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "")
  if is_empty then
    marker_line = 0
  else
    marker_line = line_before
  end

  append_lines({marker, ""})

  -- Add extmark highlight to the marker line AFTER it's been added
  pcall(api.nvim_buf_set_extmark, buf, CELL_MARKER_NS, marker_line, 0, {
    end_line = marker_line,
    end_col = #marker,
    hl_group = "JupyterCellMarker",
    priority = 200,  -- Higher priority to override syntax highlighting
    hl_mode = "replace"  -- Replace existing highlights
  })

  st = st or {}
  st.opened = true
  st.row = api.nvim_buf_line_count(buf) - 1
  st.line = st.line or ""
  st.marker_line = marker_line  -- Store marker line for re-highlighting
  state[seq] = st
  return st
end

function M.start_cell(seq, marker_text)
  -- register the cell but DO NOT open or print header yet
  state[seq] = { opened = false, row = nil, line = "", marker_text = marker_text or "#%%" }
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

-- Batch buffer updates to prevent EMFILE
local pending_buffer_updates = {}
local buffer_flush_timer = vim.loop.new_timer()
local BUFFER_FLUSH_MS = 50  -- Flush every 50ms max

local function flush_buffer_updates()
  if #pending_buffer_updates == 0 then return end

  local updates = pending_buffer_updates
  pending_buffer_updates = {}

  vim.schedule(function()
    -- Group by sequence
    local by_seq = {}
    for _, update in ipairs(updates) do
      if not by_seq[update.seq] then by_seq[update.seq] = {} end
      table.insert(by_seq[update.seq], update)
    end

    -- Apply all updates in ONE batch write per sequence
    for seq, seq_updates in pairs(by_seq) do
      local st = ensure_started(seq)
      local buf = ensure_buf()

      -- Collect all lines to write in a single batch
      local all_lines = {}
      local last_was_progress = false
      local has_error = false  -- Track if any line in this batch is an error
      local has_any_lines = false  -- Track if we have complete lines (not just progress)

      for _, update in ipairs(seq_updates) do
        if update.is_error then has_error = true end
        if update.type == "line" then
          table.insert(all_lines, update.text)
          last_was_progress = false
          has_any_lines = true
        elseif update.type == "progress" then
          -- Progress updates overwrite the current line
          if last_was_progress and #all_lines > 0 then
            all_lines[#all_lines] = update.text  -- Replace last line in batch
          else
            table.insert(all_lines, update.text)
          end
          last_was_progress = true
        end
      end

      -- Write ALL lines in ONE call
      if #all_lines > 0 then
        api.nvim_buf_set_option(buf, "modifiable", true)

        local start_pos = st.row
        local end_pos = st.row

        -- If we have a previous progress line in the buffer, replace it
        if st.line and st.line ~= "" then
          end_pos = st.row + 1
        end

        set_lines_colored(buf, start_pos, end_pos, all_lines, has_error)
        st.row = start_pos + #all_lines - 1

        -- Update st.line: only keep it if we ended with a progress update
        if last_was_progress then
          st.line = all_lines[#all_lines]
        else
          st.line = ""
        end

        -- Re-apply marker highlight after buffer modifications
        if st.marker_line and st.marker_text then
          pcall(api.nvim_buf_set_extmark, buf, CELL_MARKER_NS, st.marker_line, 0, {
            end_line = st.marker_line,
            end_col = #st.marker_text,
            hl_group = "JupyterCellMarker",
            priority = 200,
            hl_mode = "replace"
          })
        end

        api.nvim_buf_set_option(buf, "modifiable", false)
      end
    end

    scroll_to_bottom()
  end)
end

-- Start the repeating timer
buffer_flush_timer:start(BUFFER_FLUSH_MS, BUFFER_FLUSH_MS, flush_buffer_updates)

-- batched streaming with \r support; only append non-empty visible content
function M.append_stream(seq, text, is_error)
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

  -- completed lines (only when non-empty after CR/ANSI stripping)
  local last_idx = trailing_nl and #segs or (#segs - 1)
  for k = 1, math.max(0, last_idx) do
    local seg = segs[k]
    local vis = seg:match("[^\r]*$") or seg
    if not is_effectively_empty(vis) then
      table.insert(pending_buffer_updates, { seq = seq, type = "line", text = vis, is_error = is_error })
    end
  end

  -- in-place progress frame (no newline): update only if non-empty and changed
  if not trailing_nl then
    local final = (segs[#segs] or ""):match("[^\r]*$") or ""
    if not is_effectively_empty(final) then
      table.insert(pending_buffer_updates, { seq = seq, type = "progress", text = final, is_error = is_error })
    end
  end

  -- Updates will be flushed by the repeating timer (every 50ms)
end

function M.append(seq, text, is_error)
  local s = tostring(text or "")
  if s == "" or s:match("^%s*$") then return end
  ensure_started(seq)
  local lines = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
  if #lines > 0 then append_lines(lines, is_error) end
end

function M.append_markdown(seq, md)
  local s = tostring(md or "")
  if s == "" or s:match("^%s*$") then return end
  ensure_started(seq)
  append_lines({ "", s, "" })
end


function M.show_pager(text)
  local cfg = get_pager_cfg()
  local buf = ensure_pager_buf(cfg)

  if not (pager_winid and api.nvim_win_is_valid(pager_winid)) then
    open_pager_window(cfg)
  end

  local normalized = tostring(text or ""):gsub("\r\n", "\n")
  normalized = strip_ansi(normalized)
  local lines = vim.split(normalized, "\n", { plain = true })
  if #lines == 0 then lines = { "" } end

  api.nvim_buf_set_option(buf, "modifiable", true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_set_option(buf, "modifiable", false)

  if pager_winid and api.nvim_win_is_valid(pager_winid) then
    api.nvim_win_set_cursor(pager_winid, { 1, 0 })
    if cfg.focus_on_open then
      api.nvim_set_current_win(pager_winid)
    end
  end
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
