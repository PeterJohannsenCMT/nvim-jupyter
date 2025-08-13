-- lua/health/jupyter.lua
local health = vim.health or require("health")
local M = {}

function M.check()
  health.start("nvim-jupyter")
  
  -- Check if main module can be loaded
  local main_ok, main_module = pcall(require, "jupyter")
  if main_ok then 
    health.ok("Main module loaded successfully")
  else 
    health.error("Failed to load main module: " .. tostring(main_module))
    return
  end
  
  -- Check if config module can be loaded
  local cfg_ok, cfg = pcall(require, "jupyter.config")
  if cfg_ok then 
    health.ok("Configuration module loaded")
  else 
    health.warn("Configuration module not found, using defaults")
    cfg = { python_cmd = "python3", kernel_name = "python3" }
  end
  
  -- Check Python and jupyter-client availability
  local python = cfg.python_cmd or "python3"
  health.info("Using Python command: " .. python)
  
  -- Test Python availability
  local python_test_cmd = string.format('%s -c "import sys; print(sys.version.split()[0])"', python)
  local python_out = vim.fn.system(python_test_cmd)
  if vim.v.shell_error == 0 then
    health.ok("Python available: " .. python_out:gsub("%s+$", ""))
  else
    health.error("Python not available at: " .. python)
    return
  end
  
  -- Test jupyter-client availability
  local jupyter_test_cmd = string.format('%s -c "import jupyter_client; print(jupyter_client.__version__)"', python)
  local jupyter_out = vim.fn.system(jupyter_test_cmd)
  if vim.v.shell_error == 0 then
    health.ok("jupyter-client available: " .. jupyter_out:gsub("%s+$", ""))
  else
    health.error("jupyter-client not available. Install with: pip install jupyter-client")
  end
  
  -- Check bridge script availability
  local kernel_module_ok, kernel_module = pcall(require, "jupyter.kernel")
  if kernel_module_ok then
    health.ok("Kernel module loaded successfully")
    
    -- Try to find bridge script (using the same logic as kernel.lua)
    local src = debug.getinfo(1, "S").source
    if src:sub(1,1) == "@" then src = src:sub(2) end
    local base = src:match("^(.*)/lua/health/.*$") or vim.fn.fnamemodify(src, ":h:h")
    local bridge_path = base and (base .. "/python/bridge.py")
    
    if bridge_path and vim.loop.fs_stat(bridge_path) then
      health.ok("Bridge script found: " .. bridge_path)
    else
      health.warn("Bridge script not found at expected location")
      -- Check runtime paths
      local found_bridge = false
      for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
        local p = rtp .. "/python/bridge.py"
        if vim.loop.fs_stat(p) then
          health.ok("Bridge script found in runtimepath: " .. p)
          found_bridge = true
          break
        end
      end
      if not found_bridge then
        health.error("Bridge script not found in any runtime path")
      end
    end
  else
    health.error("Kernel module failed to load: " .. tostring(kernel_module))
  end
  
  -- Check if kernel is currently running
  if kernel_module_ok and kernel_module.is_running then
    if kernel_module.is_running() then
      health.info("Kernel is currently running")
    else
      health.info("Kernel is not running (use :JupyterStart to start)")
    end
  end
  
  -- Check other utility modules
  local utils_ok = pcall(require, "jupyter.utils")
  if utils_ok then
    health.ok("Utils module loaded")
  else
    health.warn("Utils module failed to load")
  end
  
  local ui_ok = pcall(require, "jupyter.ui")
  if ui_ok then
    health.ok("UI module loaded")
  else
    health.warn("UI module failed to load")
  end
  
  local transport_ok = pcall(require, "jupyter.transport")
  if transport_ok then
    health.ok("Transport module loaded")
  else
    health.warn("Transport module failed to load")
  end
end

return M
