local config = require("jupyter.config")

local function default_advance_setting()
  if type(config.run) == "table" and type(config.run.advance_to_next_cell) == "boolean" then
    return config.run.advance_to_next_cell
  end
  return true
end

local M = {
  advance_run_cell = default_advance_setting(),
}

function M.should_advance()
  return M.advance_run_cell
end

function M.set_advance(value)
  M.advance_run_cell = not not value
  if type(config.run) ~= "table" then
    config.run = {}
  end
  config.run.advance_to_next_cell = M.advance_run_cell
  return M.advance_run_cell
end

function M.toggle_advance()
  return M.set_advance(not M.advance_run_cell)
end

return M
