local M = {}

-- A cell marker is any line starting with optional spaces, then '#', optional spaces, then '%%'
-- Examples: "#%%", "  # %%", "#%% anything"
local function is_marker_line(s)
  return type(s) == "string" and s:match("^%s*#%s*%%")
end

-- Return 0-based (s, e), inclusive, for the cell that contains the cursor.
-- Policy:
--   • ONLY "#%%" lines delimit cells. Blank lines do not split a cell.
--   • If the cursor is on a marker line, select the cell BELOW that marker.
--   • If the buffer has NO markers, return nil, nil (caller should no-op).
function M.find_code_block()
  local cur  = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-based
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local n = #lines
  if n == 0 then return nil, nil end

  -- collect marker rows (0-based)
  local markers = {}
  for i = 0, n - 1 do
    if is_marker_line(lines[i + 1]) then
      table.insert(markers, i)
    end
  end
  if #markers == 0 then
    return nil, nil
  end

  local function next_marker_after(pos)
    for _, m in ipairs(markers) do
      if m > pos then return m end
    end
    return nil
  end
  local function prev_marker_before(pos)
    local last = nil
    for _, m in ipairs(markers) do
      if m < pos then last = m else break end
    end
    return last
  end

  if is_marker_line(lines[cur + 1]) then
    -- On a marker → cell starts just below it, ends before the next marker.
    local s = math.min(cur + 1, n - 1)
    local nm = next_marker_after(cur)
    local e = nm and (nm - 1) or (n - 1)
    return s, e
  else
    -- Inside a cell → previous marker+1 to next marker-1.
    local pm = prev_marker_before(cur)
    local s = pm and (pm + 1) or 0
    local nm = next_marker_after(cur)
    local e = nm and (nm - 1) or (n - 1)
    return s, e
  end
end

-- Return the 0-based row of the **first code line of the next cell** after `row0` (0-based),
-- or nil if there is no next cell. This is "line after the next marker".
function M.first_line_of_next_cell_from(row0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local n = #lines
  for i = row0 + 1, n - 1 do
    if is_marker_line(lines[i + 1]) then
      local start = math.min(i + 1, n - 1)  -- line just after the marker
      return start
    end
  end
  return nil
end

return M
