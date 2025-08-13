#!/usr/bin/env -S nvim -l

-- Add current directory to package path for testing
local current_dir = vim.fn.expand('%:p:h')
package.path = current_dir .. '/lua/?.lua;' .. current_dir .. '/lua/?/init.lua;' .. package.path

print("Testing nvim-jupyter plugin loading...")
print("Current directory:", current_dir)
print("Package path:", package.path)

-- Test loading main module
local main_ok, main_module = pcall(require, "jupyter")
print("Main module load:", main_ok and "OK" or "FAILED", main_module)

if main_ok then
    print("Main module type:", type(main_module))
    if type(main_module) == "table" then
        print("Available functions in main module:")
        for k, v in pairs(main_module) do
            print("  " .. k .. ": " .. type(v))
        end
    end
end

-- Test loading config
local cfg_ok, cfg = pcall(require, "jupyter.config")
print("Config module load:", cfg_ok and "OK" or "FAILED")
if cfg_ok then
    print("Python command:", cfg.python_cmd)
    print("Kernel name:", cfg.kernel_name)
end

-- Test loading kernel module
local kernel_ok, kernel = pcall(require, "jupyter.kernel")
print("Kernel module load:", kernel_ok and "OK" or "FAILED")
if kernel_ok and type(kernel) == "table" then
    print("Available functions in kernel module:")
    for k, v in pairs(kernel) do
        if type(v) == "function" then
            print("  " .. k .. ": function")
        end
    end
end

-- Test health check
print("\nTesting health check module...")
local health_ok, health_module = pcall(require, "health.jupyter")
print("Health module load:", health_ok and "OK" or "FAILED")

if health_ok and health_module.check then
    print("Running health check...")
    local check_ok, check_error = pcall(health_module.check)
    if not check_ok then
        print("Health check failed:", check_error)
    else
        print("Health check completed")
    end
end
