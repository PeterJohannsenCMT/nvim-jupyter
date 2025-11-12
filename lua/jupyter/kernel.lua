-- lua/jupyter/kernel.lua
local transport = require "jupyter.transport"
local ui        = require "jupyter.ui"
local out       = require "jupyter.outbuf"
local throttle = require("jupyter.throttle")
local utils = require "jupyter.utils"

local M = { bridge = nil, owner_buf = nil }

-- execution bookkeeping
local seq          = 0
local pending      = {}   -- seq -> { row = last line (0-based), start_row = first line, bufnr = originating buffer }
local queue        = {}   -- FIFO of {seq, code}
local inflight     = false
local ready        = false
local had_error    = {}   -- seq -> true if an error was seen before 'done'
local stream_queue = {}
local stream_flushing = false
local last_handle_log = 0
local handle_log_path = nil

-- inline preview rate-limiter: collapse multiple updates per row into <= ~25 Hz
local _inline_rl = {
  entries = {},
  pending = {},
  timer = nil,
  armed = false,
}

function _inline_rl:_ensure_timer()
  local timer = self.timer
  if timer and not timer:is_closing() then return timer end
  local ok, new_timer = pcall(vim.loop.new_timer)
  if not ok then return nil end
  self.timer = new_timer
  return new_timer
end

function _inline_rl:_dispatch(batch)
  vim.schedule(function()
    for key in pairs(batch) do
      local ent = _inline_rl.entries[key]
      if ent then
        local bufnr, row = ent.bufnr, ent.row
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          ui.show_inline(bufnr, row, ent.text or "", { error = ent.err })
        end
      end
    end
  end)
end

function _inline_rl:_arm()
  if self.armed or not next(self.pending) then return end
  local timer = self:_ensure_timer()
  if not timer then return end
  self.armed = true
  timer:start(40, 0, function()
    timer:stop()
    self.armed = false
    local batch = self.pending
    self.pending = {}
    if next(batch) then
      self:_dispatch(batch)
    end
    if next(self.pending) then
      self:_arm()
    end
  end)
end

function _inline_rl:push(bufnr, row, text, is_err)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  local key = tostring(bufnr) .. ":" .. tostring(row)
  local ent = self.entries[key]
  if not ent then ent = {}; self.entries[key] = ent end
  ent.bufnr, ent.row, ent.err = bufnr, row, is_err
  ent.text = text
  self.pending[key] = true
  self:_arm()
end

function _inline_rl:reset()
  self.entries = {}
  self.pending = {}
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  self.timer = nil
  self.armed = false
end

local function maybe_log_handles(tag, force)
  if not vim.g.jupyter_debug_handles then return end
  local now = vim.loop.now()
  if not force and last_handle_log ~= 0 and (now - last_handle_log) < 500 then
    return
  end
  last_handle_log = now

  local counts = {}
  local timer_samples = {}
  local timer_seen = 0
  vim.loop.walk(function(handle)
    local typ_fn = handle and handle.get_type
    local typ = "unknown"
    if type(typ_fn) == "function" then
      local ok, res = pcall(typ_fn, handle)
      if ok and res then typ = res end
    end
    counts[typ] = (counts[typ] or 0) + 1
    if typ == "timer" then
      timer_seen = timer_seen + 1
      if timer_seen <= 5 then
        timer_samples[#timer_samples + 1] = tostring(handle)
      end
    end
  end)

  local parts = {}
  for typ, count in pairs(counts) do
    parts[#parts + 1] = string.format("%s=%d", typ, count)
  end
  table.sort(parts)

  local fd_count = nil
  local scan = vim.loop.fs_scandir and vim.loop.fs_scandir("/dev/fd")
  if scan then
    local c = 0
    while true do
      local name = vim.loop.fs_scandir_next(scan)
      if not name then break end
      c = c + 1
    end
    fd_count = c
  end

  if not handle_log_path then
    local ok, path = pcall(function()
      return vim.fn.stdpath("cache") .. "/nvim-jupyter-fd.log"
    end)
    handle_log_path = ok and path or nil
  end

  local detail = table.concat(parts, " ")
  if fd_count then
    detail = string.format("fd=%d %s", fd_count, detail)
  end
  if timer_seen > 0 and #timer_samples > 0 then
    detail = detail .. " timer_samples=" .. table.concat(timer_samples, ",")
  end
  local line = string.format("%s %s %s", os.date("%H:%M:%S"), tag, detail)
  if handle_log_path then
    pcall(vim.fn.writefile, { line }, handle_log_path, "a")
  end
end

local function flush_stream_queue()
  if stream_flushing then return end
  stream_flushing = true
  while #stream_queue > 0 do
    local queue_copy = stream_queue
    stream_queue = {}

    local merged = {}
    for _, item in ipairs(queue_copy) do
      local text = item.text
      if text and text ~= "" then
        local last = merged[#merged]
        if last and last.seq == item.seq and last.name == item.name then
          last.text = last.text .. text
        else
          merged[#merged + 1] = { seq = item.seq, name = item.name, text = text }
        end
      end
    end

    for _, entry in ipairs(merged) do
      local text = entry.text
      if text and text ~= "" then
        maybe_log_handles(string.format("flush seq=%s len=%d", tostring(entry.seq), #text), false)
        local is_error = (entry.name == "stderr")
        out.append_stream(entry.seq, text, is_error)
        -- DISABLED: inline updates during rapid output can cause EMFILE
        -- local cell  = pending[entry.seq]
        -- local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
        -- local row   = cell and cell.row
        -- if bufnr and row then
        --   _inline_rl:push(bufnr, row, text, is_error)
        -- end
      end
    end
  end
  stream_flushing = false
end

local function enqueue_stream(seq, name, text)
  if not seq or not text or text == "" then return end
  stream_queue[#stream_queue + 1] = { seq = seq, name = name, text = text }
  if vim.g.jupyter_debug_handles and (#stream_queue % 1000 == 0) then
    maybe_log_handles(string.format("enqueue seq=%s name=%s size=%d", tostring(seq), tostring(name), #stream_queue), false)
  end
  flush_stream_queue()
end

local function get_cfg()
  local defaults = {
    kernel_name   = "python3",
    bridge_script = nil,  -- absolute path or nil
    out = { open_on_run = true },
  }
  local ok, cfg = pcall(require, "jupyter.config")
  if ok and type(cfg) == "table" then
    for k, v in pairs(defaults) do if cfg[k] == nil then cfg[k] = v end end
    return cfg
  end
  return defaults
end

local function exists(p) return vim.loop.fs_stat(p) ~= nil end

local function drop_pending_queue_entries()
  if #queue == 0 then return 0 end

  local removed = {}
  if inflight then
    for idx = #queue, 2, -1 do
      local entry = table.remove(queue, idx)
      if entry and entry.seq then
        removed[#removed + 1] = entry.seq
      end
    end
  else
    while #queue > 0 do
      local entry = table.remove(queue)
      if entry and entry.seq then
        removed[#removed + 1] = entry.seq
      end
    end
  end

  local cleared = 0
  for _, seq_id in ipairs(removed) do
    local cell = pending[seq_id]
    if cell and cell.bufnr and vim.api.nvim_buf_is_valid(cell.bufnr) and cell.row ~= nil then
      ui.clear_signs_range(cell.bufnr, cell.row, cell.row)
      cleared = cleared + 1
    end
    pending[seq_id] = nil
    had_error[seq_id] = nil
  end
  return cleared
end

local function find_bridge_script()
  local cfg = get_cfg()
  if cfg.bridge_script and cfg.bridge_script ~= "" then
    return cfg.bridge_script
  end
  -- Try relative to this file: .../lua/jupyter/kernel.lua -> plugin root
  local src = debug.getinfo(1, "S").source
  if src:sub(1,1) == "@" then src = src:sub(2) end
  local base = src:match("^(.*)/lua/jupyter/.*$") or vim.fn.fnamemodify(src, ":h:h:h")
  if base and exists(base .. "/python/bridge.py") then
    return base .. "/python/bridge.py"
  end
  -- Scan runtimepaths
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local p = rtp .. "/python/bridge.py"
    if exists(p) then return p end
  end
  return nil
end

local ANSI_ESCAPE = "\27%[[0-?]*[ -/]*[@-~]"

local function compute_start_row(row, code)
  if type(row) ~= "number" then return row end
  if type(code) ~= "string" then return row end
  local newline_count = 0
  for _ in code:gmatch("\n") do newline_count = newline_count + 1 end
  local start_row = row - newline_count
  if start_row < 0 then start_row = 0 end
  return start_row
end

local function extract_error_lineno(msg)
  local tb = msg and msg.traceback
  if not tb then return nil end

  local lines = {}
  if type(tb) == "table" then
    for _, entry in ipairs(tb) do
      if type(entry) == "string" then
        local pieces = vim.split(entry, "\n", { trimempty = true })
        for _, piece in ipairs(pieces) do
          lines[#lines + 1] = piece
        end
      end
    end
  elseif type(tb) == "string" then
    lines = vim.split(tb, "\n", { trimempty = true })
  else
    return nil
  end

  if #lines == 0 then return nil end

  local preferred = { "Cell In%[", "<ipython%-input", "<stdin>", "<string>" }

  local function clean_line(entry)
    return entry:gsub(ANSI_ESCAPE, "")
  end

  local function match_lineno(entry)
    local clean = clean_line(entry)
    local lineno = clean:match("line%s+(%d+)")
    if lineno then return tonumber(lineno) end
    lineno = clean:match("^%s*[-=]+>%s*(%d+)")
    if lineno then return tonumber(lineno) end
    return nil
  end

  for _, pattern in ipairs(preferred) do
    for i = #lines, 1, -1 do
      local clean = clean_line(lines[i])
      if clean:find(pattern) then
        local lineno = clean:match("line%s+(%d+)")
        if lineno then return tonumber(lineno) end
      end
    end
  end

  for i = #lines, 1, -1 do
    local lineno = match_lineno(lines[i])
    if lineno then return lineno end
  end

  return nil
end

local function ensure_bridge()
  if M.bridge then return true end
  local script = find_bridge_script()
  if not script then
    vim.notify("Jupyter: bridge.py not found on runtimepath; set require('jupyter.config').bridge_script",
      vim.log.levels.ERROR)
    return false
  end
  local br, err = transport.spawn_bridge(script)
  if not br then
    vim.notify(("Jupyter: failed to start bridge\nscript: %s\nerror: %s")
      :format(script, tostring(err)), vim.log.levels.ERROR)
    return false
  end
  M.bridge = br
  ready    = false

  br:on_message(function(msg)
    local t = msg.type

    if t == "ready" then
      ready = true
      if not inflight and #queue > 0 then
        inflight = true
        M.bridge:send({ type = "execute", code = queue[1].code, seq = queue[1].seq })
      end
      return

    elseif t == "stream" then
      enqueue_stream(msg.seq, msg.name, msg.text or "")
      return

    elseif t == "stdin_request" then

      local prompt = msg.prompt or ""

			vim.ui.input({ prompt = prompt }, function(input)
				M.bridge:send({ type = "stdin_reply", text = input or "" })
			end)

      -- end
      return
    elseif t == "result" then
      out.append(msg.seq, msg.value or "")
      return

    elseif t == "markdown" then
      out.append_markdown(msg.seq, msg.value or "")
      return

    elseif t == "image" then
      out.append(msg.seq, ("[image saved: %s]"):format(msg.path or ""))
      return

    elseif t == "error" then
      local s  = msg.seq
      local tb = msg.traceback or ((msg.ename or "Error") .. ": " .. (msg.evalue or ""))
      out.append(s, tb, true)  -- Mark traceback as error for colored output

      -- mark seq as errored so 'done' won't place ✓
      had_error[s] = true

			local cell  = pending[s]
			local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
			local row   = cell and cell.row
			if bufnr and row then
				local diag_row = row
				local err_line = extract_error_lineno(msg)
				if err_line and err_line >= 1 and cell and cell.start_row then
					diag_row = cell.start_row + err_line - 1
				end
				if cell and cell.start_row then
					if diag_row < cell.start_row then diag_row = cell.start_row end
					if diag_row > row then diag_row = row end
				end
				local line_count = vim.api.nvim_buf_line_count(bufnr)
				if line_count > 0 then
					if diag_row < 0 then diag_row = 0 end
					if diag_row >= line_count then diag_row = line_count - 1 end
				else
					diag_row = 0
				end
				-- concise inline error (keep it visible after completion)
				local inline = (msg.ename or "Error") .. (msg.evalue and (": " .. msg.evalue) or "")
				ui.place_sign("err", bufnr, diag_row)
				ui.show_inline(bufnr, diag_row, inline, { error = true })
				local ns = vim.api.nvim_create_namespace("jupyter_exec")
				local line = vim.api.nvim_buf_get_lines(bufnr, diag_row, diag_row + 1, false)[1] or ""
				local col  = #line
				-- Get existing diagnostics and append the new one
				local existing = vim.diagnostic.get(bufnr, { namespace = ns })
				local new_diag = {
					lnum = diag_row,
					col = col,
					end_lnum = diag_row,
					end_col = col,
					severity = vim.diagnostic.severity.ERROR,
					message = "Jupyter Cell exited with error: " .. msg.ename,
					source = "jupyter",
				}
				table.insert(existing, new_diag)
				vim.diagnostic.set(ns, bufnr, existing)
			end

      -- advance queue
      inflight = false
      table.remove(queue, 1)
      if ready and #queue > 0 then
        inflight = true
        M.bridge:send({ type = "execute", code = queue[1].code, seq = queue[1].seq })
      end
      return

    elseif t == "done" then
      local s     = msg.seq
      local cell  = pending[s]
      local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
      local row   = cell and cell.row

      if bufnr and row then
        if had_error[s] then
          -- keep the error sign and the inline error text as-is
          had_error[s] = nil
        else
          -- success path: ✓ and finish_row (clear progress-only inline)
          ui.place_sign("ok", bufnr, row)
          ui.finish_row(bufnr, row)
        end
      end

      pending[s] = nil

      inflight = false
      table.remove(queue, 1)
      if ready and #queue > 0 then
        inflight = true
        M.bridge:send({ type = "execute", code = queue[1].code, seq = queue[1].seq })
      end
      return

    elseif t == "interrupted" then
      local head = queue[1]
      if head then
        local cell  = pending[head.seq]
        local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
        local row   = cell and cell.row
        if bufnr and row then ui.show_inline(bufnr, row, "[interrupt requested]", { error = true }) end
      end
      return

    elseif t == "paused" then
      vim.notify("Jupyter kernel paused", vim.log.levels.INFO)
      return

    elseif t == "resumed" then
      vim.notify("Jupyter kernel resumed", vim.log.levels.INFO)
      return

    elseif t == "pause_failed" or t == "resume_failed" then
      local action = (t == "pause_failed") and "pause" or "resume"
      local detail = msg.message or string.format("Unable to %s kernel", action)
      vim.notify("Jupyter: " .. detail, vim.log.levels.ERROR)
      return

    elseif t == "bye" then
      if M.bridge and M.bridge.close then
        pcall(function() M.bridge:close() end)
      end
      M.bridge = nil; ready = false; inflight = false; queue = {}
      ui.clear_all_signs()
      return
    end
  end)

  -- Start the kernel
  local cfg = get_cfg()
  local cwd = vim.fn.getcwd()
  M.bridge:send({ type = "start", kernel = cfg.kernel_name or "python3", cwd = cwd })
  return true
end

-- Public API ------------------------------------------------------------------

function M.is_running()
  return M.bridge ~= nil
end

function M.stop()
  if not M.bridge then return end
  flush_stream_queue()
  pcall(function() M.bridge:send({ type = "shutdown" }) end)
  if M.bridge.close then pcall(function() M.bridge:close() end) end
  M.bridge = nil
  ready = false
  inflight = false
  queue = {}
  pending = {}
  had_error = {}
  _inline_rl:reset()
  ui.clear_all_signs()
  -- Clean up throttle timers if throttle module is loaded
  local ok, throttle = pcall(require, "jupyter.throttle")
  if ok and throttle and type(throttle.stop) == "function" then
    pcall(throttle.stop)
  end
end

function M.interrupt(opts)
  opts = opts or {}
  if not M.bridge then return end

  local cfg = get_cfg()
  local interrupt_cfg = (cfg and cfg.interrupt) or {}
  local drop_queue = opts.drop_queue
  if drop_queue == nil then
    drop_queue = interrupt_cfg.drop_queue
    if drop_queue == nil then drop_queue = true end
  end

  if drop_queue then
    drop_pending_queue_entries()
  end

  M.bridge:send({ type = "interrupt" })
end

function M.start()
  return ensure_bridge()
end

function M.restart()
  if not M.bridge then return end
  local cfg = get_cfg()
  local cwd = vim.fn.getcwd()
  M.bridge:send({ type = "restart", kernel = cfg.kernel_name or "python3", cwd = cwd })
end

function M.pause()
  if not M.bridge then
    vim.notify("Jupyter: kernel not running", vim.log.levels.WARN)
    return
  end
  M.bridge:send({ type = "pause" })
end

function M.resume()
  if not M.bridge then
    vim.notify("Jupyter: kernel not running", vim.log.levels.WARN)
    return
  end
  M.bridge:send({ type = "resume" })
end

function M.eval_line()
  if not ensure_bridge() then return end
  local line = vim.api.nvim_get_current_line()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-based
  M.execute(line, row)
end

function M.eval_selection()
  if not ensure_bridge() then return end
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2] - 1, start_pos[3] - 1  -- 0-based
  local end_row, end_col = end_pos[2] - 1, end_pos[3] - 1
  
  local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
  if #lines == 0 then return end
  
  -- Handle partial line selection
  if #lines == 1 then
    lines[1] = string.sub(lines[1], start_col + 1, end_col + 1)
  else
    lines[1] = string.sub(lines[1], start_col + 1)
    lines[#lines] = string.sub(lines[#lines], 1, end_col + 1)
  end
  
  local code = table.concat(lines, "\n")
  M.execute(code, end_row)
end

function M.cancel_queue()
  queue = {}
  inflight = false
end

-- Execute code from a given source row (0-based)
function M.execute(code, row, marker_text)
  if not ensure_bridge() then return end

  -- Remember owner buffer to place signs/inline correctly
  M.owner_buf = vim.api.nvim_get_current_buf()
  if vim.g.jupyter_debug_handles then
    maybe_log_handles("before-exec", true)
  end
  local start_row = compute_start_row(row, code)

  ui.clear_diagnostics_range(M.owner_buf, start_row, row)
  -- Clear inline at run start to avoid appending on re-run
  -- ui.clear_row(M.owner_buf, row)
  ui.place_sign("run", M.owner_buf, row)

  seq = seq + 1
  local bufnr = M.owner_buf
  pending[seq] = { row = row, start_row = start_row, bufnr = bufnr }
  had_error[seq] = nil

  out.start_cell(seq, marker_text)  -- open output header now, with optional marker text

  table.insert(queue, { seq = seq, code = code })
  if ready and not inflight then
    inflight = true
    M.bridge:send({ type = "execute", code = code, seq = seq })
  end
end

-- Convenience: run the current cell (expects utils.find_code_block())
function M.eval_current_block()
  local s, e = utils.find_code_block({ include_subcells = true })
  if not s or not e then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, s, e + 1, false)
  local empty = true
  for _, L in ipairs(lines) do if not L:match("^%s*$") then empty = false; break end end
  if empty then return end
  local code = table.concat(lines, "\n")
	ui.clear_range(M.owner_buf, s, e+1)
	ui.clear_signs_range(M.owner_buf, s, e+1)

  -- Extract the cell marker text (if s > 0, the marker is at s-1)
  local marker_text = "#%%"
  if s > 0 then
    local marker_line = vim.api.nvim_buf_get_lines(0, s - 1, s, false)[1]
    if marker_line then
      local mtype = utils.marker_type(marker_line)
      if mtype == "sub" then
        local suffix = marker_line:match("^%s*#%s*#%s*%%%%(.*)$") or ""
        marker_text = "##%%" .. suffix
      elseif mtype == "parent" then
        local suffix = marker_line:match("^%s*#%s*%%%%(.*)$") or ""
        marker_text = "#%%" .. suffix
      end
    end
  end

  M.execute(code, e, marker_text)  -- anchor at end row, pass marker text

	local last_row0 = vim.api.nvim_buf_line_count(0)
	if last_row0 > e+3 then
		vim.api.nvim_win_set_cursor(0, {e+3, 0})
	end
end


-- Convenience: run all above
function M.eval_all_above()
	local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, current_line+1, false)
  local code = table.concat(lines, "\n")
  M.execute(code, current_line - 1)  -- anchor at end row
end

return M
