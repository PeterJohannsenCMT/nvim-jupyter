local api = vim.api

local function get_out_cfg()
  local ok, cfg = pcall(require, "jupyter.config")
  local defaults = {
    split = "bottom", height = 12, width = 60,
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
local stream_state = {} -- seq -> { row, line }

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
  out_bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(out_bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(out_bufnr, "bufhidden", "hide")
  api.nvim_buf_set_option(out_bufnr, "filetype", "markdown")
  return out_bufnr
end

local function open_window()
  local cfg = get_out_cfg()
  local prev = api.nvim_get_current_win()
  local buf = ensure_buf()
  if cfg.split == "right" then
    vim.cmd(("botright %dvsplit"):format(tonumber(cfg.width) or 60))
  else
    vim.cmd(("botright %dsplit"):format(tonumber(cfg.height) or 6))
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
  if M.is_visible() then pcall(api.nvim_win_close, out_winid, true); out_winid=nil else open_window() end
end

function M.clear()
  local buf = ensure_buf()
  api.nvim_buf_set_option(buf, "modifiable", true)
  set_lines_colored(buf, 0, -1, {})
  api.nvim_buf_set_option(buf, "modifiable", false)
  stream_state = {}
  scroll_to_bottom()
end

local function append_lines(lines)
  local buf = ensure_buf()
  local last = api.nvim_buf_line_count(buf)
  api.nvim_buf_set_option(buf, "modifiable", true)
  set_lines_colored(buf, last, last, lines)
  api.nvim_buf_set_option(buf, "modifiable", false)
  scroll_to_bottom()
end

function M.start_cell(seq)
  M.open()
  append_lines({ "", ("## In [%d]"):format(seq), "" })
  local buf = ensure_buf()
  stream_state[seq] = { row = api.nvim_buf_line_count(buf) - 1, line = "" }
end

-- batched streaming with \r support
function M.append_stream(seq, text)
  if not text or text == "" then return end
  local buf = ensure_buf()
  local st = stream_state[seq]
  if not st then
    st = { row = api.nvim_buf_line_count(buf) - 1, line = "" }
    stream_state[seq] = st
  end
  local s = tostring(text):gsub("\r\n", "\n")
  local trailing_nl = s:sub(-1) == "\n"

  local segs, i = {}, 1
  while true do
    local j = s:find("\n", i, true)
    if not j then table.insert(segs, s:sub(i)); break end
    table.insert(segs, s:sub(i, j - 1)); i = j + 1
  end

  api.nvim_buf_set_option(buf, "modifiable", true)

  local last_idx = trailing_nl and #segs or (#segs - 1)
  for k = 1, math.max(0, last_idx) do
    local seg = segs[k]
    local vis = seg:match("[^\r]*$") or seg
    set_lines_colored(buf, st.row, st.row + 1, { vis })
    set_lines_colored(buf, st.row + 1, st.row + 1, { "" })
    st.row, st.line = st.row + 1, ""
  end

  if not trailing_nl then
    local final = (segs[#segs] or ""):match("[^\r]*$") or ""
    if final ~= st.line then
      set_lines_colored(buf, st.row, st.row + 1, { final })
      st.line = final
    end
  else
    if st.line ~= "" then
      set_lines_colored(buf, st.row, st.row + 1, { "" })
      st.line = ""
    end
  end

  api.nvim_buf_set_option(buf, "modifiable", false)
  scroll_to_bottom()
end

function M.append(_seq, text)
  local s = tostring(text or ""); if s == "" then return end
  local lines = {}; for line in (s .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
  if #lines > 0 then append_lines(lines) end
end

function M.append_markdown(_seq, md)
  append_lines({ "", tostring(md or ""), "" })
end

return M
