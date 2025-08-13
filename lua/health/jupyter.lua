-- lua/health/jupyter.lua
local health = vim.health or require("health")
local M = {}

function M.check()
  health.start("nvim-jupyter")
  local ok = pcall(function() return require("jupyter").get_config() end)
  if ok then health.ok("config loaded") else health.warn("config not loaded") end

  local cfg = (ok and require("jupyter").get_config()) or {}
  local python = cfg.python_cmd or "python3"
  local cmd = string.format([[%s -c "import jupyter_client; import sys; print(sys.version.split()[0])"]], python)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error == 0 then
    health.ok("python ok: " .. out:gsub("%s+$",""))
  else
    health.error("python/jupyter_client not available for: " .. python)
  end
end

return M
