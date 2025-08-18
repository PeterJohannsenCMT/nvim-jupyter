# nvim-jupyter

A modern Neovim plugin that enables seamless interaction with Jupyter kernels directly from your editor. Execute Python code cells, view outputs inline, and maintain a live connection to your Jupyter kernel—all without leaving Neovim.

## ✨ Features

- **Live Jupyter Integration**: Connect to and control Jupyter kernels from within Neovim
- **Cell-based Execution**: Support for `#%%` cell markers (Jupyter/VSCode style)
- **Inline Output Display**: View execution results directly in your buffer with virtual text
- **Rich Output Support**: Handle text, markdown, images (PNG/SVG), and ANSI-colored output
- **Visual Feedback**: Smart signs and indicators show execution status (running/success/error)
- **Queue Management**: Execute multiple cells with proper queuing and interruption support
- **Auto-detection**: Automatically finds Python environments (conda/virtualenv)
- **Split Pane Output**: Optional dedicated output buffer for detailed results
- **Non-blocking**: Asynchronous execution keeps Neovim responsive

## 📋 Requirements

- Neovim 0.8+
- Python 3.7+
- `jupyter-client` Python package
- A Jupyter kernel (typically `python3` or `ipython`)

### Installation of Python Dependencies

```bash
# Using pip
pip install jupyter-client

# Using conda
conda install jupyter-client
```

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "nvim-jupyter",
  ft = "python",
  config = function()
    require("jupyter").setup({
      -- Optional configuration (see Configuration section)
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "nvim-jupyter",
  ft = "python",
  config = function()
    require("jupyter").setup()
  end
}
```

### Manual Installation

Add the plugin directory to your Neovim runtime path:

```lua
vim.opt.rtp:prepend("/path/to/nvim-jupyter")
require("jupyter").setup()
```

## 🚀 Quick Start

1. **Create a Python file** with cell markers:
   ```python
   #%% Cell 1
   import numpy as np
   import matplotlib.pyplot as plt
   
   #%% Cell 2
   x = np.linspace(0, 10, 100)
   y = np.sin(x)
   plt.plot(x, y)
   plt.show()
   
   #%% Cell 3
   print("Hello from Jupyter!")
   ```

2. **Start the Jupyter kernel**:
   ```vim
   :JupyterStart
   ```

3. **Execute cells**:
   - Place cursor in a cell and press `<Enter>` (normal mode)
   - Or use `:JupyterRunCell`

4. **View results**:
   - Inline virtual text shows outputs
   - Signs in the gutter indicate execution status
   - Optional split pane for detailed output

## ⌨️ Default Keybindings

The plugin automatically sets up these keybindings for Python files:

| Key | Mode | Command | Description |
|-----|------|---------|-------------|
| `<CR>` | Normal | `:JupyterRunCell` | Execute current cell |
| `<leader>jC` | Normal | `:JupyterRunCellStay` | Execute cell without moving cursor |
| `<leader>jl` | Normal | `:JupyterRunLine` | Execute current line |
| `<leader>js` | Visual | `:JupyterRunSelection` | Execute selected text |
| `<leader>ja` | Normal | `:JupyterRunAbove` | Execute all cells above cursor |
| `<leader>jr` | Normal | `:JupyterStart` | Start Jupyter kernel |
| `<leader>js` | Normal | `:JupyterStop` | Stop Jupyter kernel |
| `<leader>ji` | Normal | `:JupyterInterrupt` | Interrupt execution |
| `<leader>jo` | Normal | `:JupyterToggleOut` | Toggle output pane |
| `<leader>jc` | Normal | `:JupyterClearAll` | Clear all virtual text |

## 🎛️ Commands

### Kernel Management
- `:JupyterStart` - Start a new Jupyter kernel
- `:JupyterRestart` - Restart the current kernel
- `:JupyterStop` - Stop the kernel and close connection
- `:JupyterInterrupt` - Interrupt current execution
- `:JupyterInterruptKeep` - Interrupt without dropping execution queue
- `:JupyterCancelQueue` - Cancel all queued executions

### Code Execution
- `:JupyterRunLine` - Execute the current line
- `:JupyterRunSelection` - Execute visually selected text
- `:JupyterRunCell` - Execute the current cell (defined by `#%%` markers)
- `:JupyterRunCellStay` - Execute cell without moving cursor
- `:JupyterRunAbove` - Execute all code from start to cursor

### Output Management
- `:JupyterToggleOut` - Toggle the output split pane
- `:JupyterClearAll` - Clear all inline virtual text output

## ⚙️ Configuration

The plugin works out of the box, but you can customize it:

```lua
require("jupyter").setup({
  -- Python command (auto-detects conda/virtualenv)
  python_cmd = "python3",
  
  -- Jupyter kernel name
  kernel_name = "python3",
  
  -- Absolute path to bridge.py (usually auto-detected)
  bridge_script = nil,
  
  -- Output pane settings
  out = {
    split = "bottom",        -- "bottom" or "right"
    height = 12,             -- rows for bottom split
    width = 60,              -- columns for right split
    open_on_run = true,      -- auto-open on first execution
    auto_scroll = true,      -- scroll to latest output
    focus_on_open = false,   -- don't steal focus when opening
  },
  
  -- Interrupt behavior
  interrupt = {
    drop_queue = true,        -- drop pending executions on interrupt
    timeout_ms = 3000,        -- timeout before forcing restart
    restart_on_timeout = true,-- restart kernel if interrupt times out
  },
  
  -- Inline output display
  inline = {
    strip_ansi = true,        -- remove ANSI color codes from inline text
    maxlen = 120,             -- max length of inline output
    prefix = " ⇒ ",           -- prefix for inline output
    hl_normal = "JupyterInline", -- highlight group for normal output
    hl_error = "ErrorMsg",    -- highlight group for errors
  },
})
```

### Python Environment Detection

The plugin automatically detects your Python environment:
1. **Conda**: Uses `$CONDA_PREFIX/bin/python` if available
2. **Fallback**: Uses `python3` from PATH
3. **Override**: Set `python_cmd` in configuration

## 🎨 Cell Markers

The plugin recognizes Jupyter-style cell markers:

```python
#%%
# This is a cell

# %% This is also valid

  #   %%   With spaces too

#%% You can add titles
# This is the cell content
```

**Cell Behavior:**
- Cells are delimited by lines starting with `#%%` (with optional whitespace)
- When cursor is on a marker line, execution includes the cell **below** that marker
- When cursor is inside a cell, that entire cell is executed
- Files without any markers will show a warning

## 🔍 Output Display

### Inline Virtual Text
- **Success**: Shows `✓` sign and result preview
- **Error**: Shows `✗` sign and error message
- **Running**: Shows `▶` sign and "running..." indicator
- **Results**: Truncated output appears as virtual text

### Split Pane Output
- **Detailed Output**: Full results, including rich content
- **ANSI Colors**: Preserved for proper syntax highlighting
- **Images**: Saved to temp files with path displayed
- **Markdown**: Rendered appropriately
- **Scrolling**: Auto-scrolls to latest output

## 🏗️ Architecture

### Components
- **Bridge (`bridge.py`)**: Python process managing Jupyter kernel communication
- **Transport**: Handles stdin/stdout JSON communication with bridge
- **Kernel**: Manages execution queue and message handling
- **UI**: Handles signs, virtual text, and output display
- **Utils**: Cell detection and buffer manipulation

### Communication Flow
1. Neovim sends execute requests to Python bridge via JSON
2. Bridge forwards to Jupyter kernel and streams results back
3. Neovim receives streaming output and updates UI in real-time
4. Multiple executions are queued and processed sequentially

## 🚨 Troubleshooting

### Common Issues

**"Jupyter: kernel not running"**
- Run `:JupyterStart` first
- Check that `jupyter-client` is installed: `pip list | grep jupyter`

**"bridge.py not found"**
- Plugin installation issue. Ensure the full plugin directory is in your runtime path
- Set `bridge_script` to absolute path in configuration

**"No #%% cell markers found"**
- Add `#%%` markers to define cells in your Python file
- Or use `:JupyterRunLine` / `:JupyterRunSelection` instead

**Execution hangs or no output**
- Try `:JupyterInterrupt` to cancel current execution
- Use `:JupyterRestart` to restart the kernel
- Check Python environment has required packages

**Wrong Python environment**
- Activate your desired environment before starting Neovim
- Or set `python_cmd` in configuration to specific Python path

### Debug Mode

To debug issues, you can:
1. Check kernel status: `:lua print(require('jupyter.kernel').is_running())`
2. View messages: `:messages`
3. Check bridge process: Look for `python bridge.py` in process list

## 🤝 Contributing

Contributions welcome! Areas for improvement:
- Support for other languages (R, Julia, Scala)
- Enhanced output formatting
- Better error handling and recovery
- Integration with notebook formats
- Performance optimizations

## 📄 License

This plugin is provided as-is for personal use.

## 🔗 Related Projects

- [jupytext](https://github.com/mwouts/jupytext) - Convert between notebook and script formats
- [iron.nvim](https://github.com/hkupty/iron.nvim) - Interactive REPL over Neovim
- [vim-slime](https://github.com/jpalardy/vim-slime) - Send code to terminal/tmux
- [baleia.nvim](https://github.com/m00qek/baleia.nvim) - ANSI color support (recommended companion)

# Known Issues

- [ ] Multiple buffers with each their own kernel is not supported - currently, all buffers send the code to a single kernel, which means that they share variables (not ideal, I know).
- [ ] Currently can't toggle output. Additionally, if you close the output window, nvim-jupyter doesn't know what to do with output, and stops working...
