#!/usr/bin/env -S nvim -l

-- Add current directory to package path for testing
local current_dir = vim.fn.expand('%:p:h')
package.path = current_dir .. '/lua/?.lua;' .. current_dir .. '/lua/?/init.lua;' .. package.path

vim.notify("Testing nvim-jupyter plugin loading...")
vim.notify("Current directory:", current_dir)
vim.notify("Package path:", package.path)

-- Test loading main module
local main_ok, main_module = pcall(require, "jupyter")
vim.notify("Main module load:", main_ok and "OK" or "FAILED", main_module)

if main_ok then
    vim.notify("Main module type:", type(main_module))
    if type(main_module) == "table" then
        vim.notify("Available functions in main module:")
        for k, v in pairs(main_module) do
            vim.notify("  " .. k .. ": " .. type(v))
        end
    end
end

-- Test loading config
local cfg_ok, cfg = pcall(require, "jupyter.config")
vim.notify("Config module load:", cfg_ok and "OK" or "FAILED")
if cfg_ok then
    vim.notify("Python command:", cfg.python_cmd)
    vim.notify("Kernel name:", cfg.kernel_name)
end

-- Test loading kernel module
local kernel_ok, kernel = pcall(require, "jupyter.kernel")
vim.notify("Kernel module load:", kernel_ok and "OK" or "FAILED")
if kernel_ok and type(kernel) == "table" then
    vim.notify("Available functions in kernel module:")
    for k, v in pairs(kernel) do
        if type(v) == "function" then
            vim.notify("  " .. k .. ": function")
        end
    end
end

-- Test health check
vim.notify("\nTesting health check module...")
local health_ok, health_module = pcall(require, "health.jupyter")
vim.notify("Health module load:", health_ok and "OK" or "FAILED")

if health_ok and health_module.check then
    vim.notify("Running health check...")
    local check_ok, check_error = pcall(health_module.check)
    if not check_ok then
        vim.notify("Health check failed:", check_error)
    else
        vim.notify("Health check completed")
    end
end
