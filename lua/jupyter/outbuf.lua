local api = vim.api

local function get_out_cfg()
  local ok, cfg = pcall(require, "jupyter.config")
  local defaults = {
    split = "bottom", height = 8, width = 60,
    open_on_run = true, focus_on_open = false, autoscroll = true,
    ansi = { enabled = true },
  }
  local out_cfg = (ok and type(cfg) == "table" and cfg.out) or {}
  local merged = {}; for k,v in pairs(defaults) do merged[k]=v end
  for k,v in pairs(out_cfg or {}) do merged[k]=v end
  return merged
end

local M = {}
local out_bufnr, out_winid = nil, nil

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
  api.nvim_buf_set_option(out_bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(out_bufnr, "bufhidden", "hide")
  api.nvim_buf_set_option(out_bufnr, "filetype", "markdown")
  
  -- Set up autocmd to clean up references when buffer is deleted
  api.nvim_create_autocmd({"BufDelete", "BufWipeout"}, {
    buffer = out_bufnr,
    callback = function()
      if out_bufnr then
        out_bufnr = nil
        out_winid = nil
      end
    end,
    once = true,
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
  out_winid = api.nvim_get_current_win()
  api.nvim_win_set_buf(out_winid, buf)
  api.nvim_buf_set_option(buf, "modifiable", false)
  if cfg.focus_on_open ~= true and api.nvim_win_is_valid(prev) then
    api.nvim_set_current_win(prev)
  end
end

local function scroll_to_bottom()
  local cfg = get_out_cfg()
  if not cfg.autoscroll then return end
  if out_winid and api.nvim_win_is_valid(out_winid) and out_bufnr and api.nvim_buf_is_valid(out_bufnr) then
    local last = api.nvim_buf_line_count(out_bufnr)
    api.nvim_win_call(out_winid, function()
      api.nvim_win_set_cursor(out_winid, { last, 0 })
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

-- Lazy header: only print "## In [n]" when we actually have content to show
local function ensure_started(seq)
  local st = state[seq]
  if st and st.opened then return st end
  M.open()
  local buf = ensure_buf()
  append_lines({("## In [%d]"):format(seq), ""})
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

return M
