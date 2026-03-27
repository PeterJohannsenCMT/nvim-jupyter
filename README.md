# nvim-jupyter

A modern Neovim plugin that enables seamless interaction with Jupyter kernels directly from your editor. Execute Python code cells and maintain a live connection to your Jupyter kernel—all without leaving Neovim.

## ✨ Features

- **Live Jupyter Integration**: Connect to and control Jupyter kernels from within Neovim
- **Cell-based Execution**: Support for `#%%` cell markers (Jupyter/VSCode style)
- **Rich Output Support**: Handle text, markdown, and ANSI-colored output
- **Visual Feedback**: Smart signs and indicators show execution status (running/success/error)
- **Queue Management**: Execute multiple cells with proper queuing and interruption support
- **Python**: Uses your env's python instance.
- **Split Pane Output**: (Optional) dedicated output buffer for detailed results
- **Non-blocking**: Asynchronous execution keeps Neovim responsive
- **IPython niceties**: Inline `?` / `??` doc lookups open in a pager split, and `%` line magics are expanded automatically

## 📋 Requirements

- Neovim 0.8+
- Python 3.7+
- `ipykernel` python package
- `debugpy` in the kernel environment for `:JupyterDebugCell`
- [`mfussenegger/nvim-dap`](https://github.com/mfussenegger/nvim-dap) for editor-side debugging

### Minimal conda environment

```env.yaml
name: jupytertest
dependencies:
  - python=3.13
  - ipykernel=6.30
```

Create the environment using 

```bash
conda create -f env.yaml
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

## 🚀 Quick Start

1. **Create a Python file** with cell markers:
   ```python
   #%% Cell 1
   import numpy as np
   import matplotlib as mpl
   mpl.use("Qt5Agg")
   import matplotlib.pyplot as plt
   #%% Cell 2
   fig = plt.figure()
   plt.show(block=False)
   #%% Cell 2
   plt.clf()
   x = np.linspace(0, 10, 100)
   y = np.sin(x)
   plt.plot(x, y)
   plt.draw()
   #%% Cell 3
   print("Hello from Jupyter!")
   ```

2. **Start the Jupyter kernel**:
   ```vim
   :JupyterStart
   ```

3. **Execute cells**:
   - Place cursor in a cell and press `<leader>jx` (normal mode)
   - Or use `:JupyterRunCell`

4. **View results**:
   - `<leader>jo` toggles the output-buffer, which prints outputs (and full error messages, with ANSI-colours.
   - Signs in the gutter indicate execution status

## ⌨️ Default Keybindings

The plugin automatically sets up these keybindings for Python files:

| Key | Mode | Command | Description |
|-----|------|---------|-------------|
| `<leader>jx` | Normal | `:JupyterRunCellSmart` | Execute current cell (advance or stay based on flag) |
| `<leader>jd` | Normal | `:JupyterDebugCell` | Debug current cell in the live kernel |
| `<leader>jw` | Normal/Visual | `:JupyterDebugWatch` | Add the symbol or selection to the watches pane |
| `<leader>je` | Normal/Visual | `:JupyterDebugEval` | Evaluate the symbol or selection in a popup |
| `<leader>jC` | Normal | `:JupyterRunCellStay` | Execute cell without moving cursor |
| `<leader>jl` | Normal | `:JupyterRunLine` | Execute current line |
| `<leader>js` | Visual | `:JupyterRunSelection` | Execute selected text |
| `<leader>ja` | Normal | `:JupyterRunAbove` | Execute all cells above cursor |
| `<leader>jr` | Normal | `:JupyterStart` | Start Jupyter kernel |
| `<leader>js` | Normal | `:JupyterStop` | Stop Jupyter kernel |
| `<leader>ji` | Normal | `:JupyterInterrupt` | Interrupt execution |
| `<leader>jo` | Normal | `:JupyterToggleOut` | Toggle output pane |
| `<leader>jc` | Normal | `:JupyterClearAll` | Clear all virtual text |
| `<leader>jt` | Normal | `:JupyterRunCellAdvance toggle` | Toggle whether smart run advances to next cell |

## 🎛️ Commands

### Kernel Management
- `:JupyterStart` - Start a new Jupyter kernel
- `:JupyterStartOptimized` - Start a new Jupyter kernel with Python `-OO` semantics
- `:JupyterRestart` - Restart the current kernel
- `:JupyterPause` - Pause the kernel process (Unix only, uses `SIGSTOP`)
- `:JupyterResume` - Resume a paused kernel (Unix only, uses `SIGCONT`)
- `:JupyterStop` - Stop the kernel and close connection
- `:JupyterInterrupt` - Interrupt current execution
- `:JupyterInterruptKeep` - Interrupt without dropping execution queue
- `:JupyterCancelQueue` - Cancel all queued executions

> Pause/Resume rely on POSIX signals and are not available on Windows.

### Code Execution
- `:JupyterRunLine` - Execute the current line
- `:JupyterRunSelection` - Execute visually selected text
- `:JupyterRunCell` - Execute the current cell (defined by `#%%` markers)
- `:JupyterDebugCell` - Attach `nvim-dap` to the live kernel and run the current cell under `debugpy`
- `:JupyterDebugWatch [expr]` - Add an expression, current symbol, or visual selection to the `dap-ui` watches pane
- `:JupyterDebugEval [expr]` - Evaluate an expression, current symbol, or visual selection in a `dap-ui` popup
- `:JupyterRunCellStay` - Execute cell without moving cursor
- `:JupyterRunCellSmart` - Execute cell; optionally advance to the next one based on the run-advance flag
- `:JupyterRunCellAdvance [on|off|toggle]` - Configure or toggle whether smart run moves to the next cell
- `:JupyterRunAbove` - Execute all code from start to cursor
- `:JupyterRunCells <indices>` - Run multiple cells by index (e.g., `:JupyterRunCells 1,2,4` or `:JupyterRunCells 1-5` or `:JupyterRunCells 1,3-5,7`)

### Output Management
- `:JupyterToggleOut` - Toggle the output split pane
- `:JupyterClearAll` - Clear all virtual text output
- `:JupyterToggleInlineOutput` - Toggle inline virtual-text output on/off

### Docs
- `:JupyterDoc` - Show documentation for the object under cursor (uses Jupyter inspect; tries control channel so it works even while a cell is running)

### Navigation
- `:JupyterCellToc[!]` - Populate quickfix with all cell/subcell titles (bang to avoid opening quickfix)
- `:JupyterGotoRunningCell` - Jump the cursor to the cell that is currently executing

### Utility
- `:JupyterUpdateSigns` - Recompute gutter sign positions (useful after manually opening/closing folds)

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

  -- Extra environment for the bridge/kernel (e.g. keep PATH from your login shell)
  env = {
    -- PATH = vim.env.PATH,
  },
  
  -- Output pane settings
  out = {
    split = "bottom",        -- "bottom" or "right"
    height = 12,             -- rows for bottom split
    width = 60,              -- columns for right split
    open_on_run = true,      -- auto-open on first execution
    auto_scroll = true,      -- scroll to latest output
    focus_on_open = false,   -- don't steal focus when opening
  },

  -- IPython pager output (e.g. function? / function??)
  pager = {
    split = "right",       -- "bottom" or "right" split for pager text
    height = 15,
    width = 30,
    focus_on_open = false,  -- show docs without moving cursor
    filetype = "markdown", -- syntax highlight inside pager split
  },

  -- Interrupt behavior
  interrupt = {
    drop_queue = true,        -- drop pending executions on interrupt
    timeout_ms = 1000,        -- ms to wait for kernel to acknowledge interrupt before forcing restart
    restart_on_timeout = true,-- restart kernel if interrupt times out
  },

  -- Smart-run advance behavior (<leader>jx / :JupyterRunCellSmart)
  run = {
    advance_to_next_cell = true, -- true: move cursor to next cell after execution
  },

  dap = {
    enabled = true,
    host = "127.0.0.1",
    port = nil,             -- nil = choose a free port inside the kernel
    just_my_code = false,
    open_dapui = true,      -- lazily setup/open dap-ui with a Jupyter-friendly layout
  },

  -- Cell UI decorations
  ui = {
    show_cell_borders = true,    -- virtual lines drawn above/below each cell's content
    highlight_metadata = true,   -- highlight `#:: metadata ::` comment lines
    metadata_hl = {              -- colors for metadata virtual text (or a highlight group name)
      fg = "#88a0f9",
      bg = "#10101e",
    },
  },

  -- Fold behavior
  fold = {
    close_cells_on_open = false, -- auto-close all cell folds when opening a Python file
  },

  -- Inline virtual-text output (shown below the last line of the current cell)
  inline = {
    enabled   = false,           -- opt-in; toggle at runtime with :JupyterToggleInlineOutput
    max_lines = 20,              -- max output lines shown inline; first N lines kept, remainder summarized
    maxlen    = 300,             -- max characters per line before truncation
    strip_ansi = true,           -- strip ANSI escape codes before display
    prefix    = " ⟶ ",          -- prefix for the first output line
    hl_normal = "MoltenOutputWin", -- highlight group for normal output
    hl_error  = "DiagnosticError", -- highlight group for error output
  },
})
```

### Debugging Cells With nvim-dap

`JupyterDebugCell` keeps the current Jupyter kernel state and runs the selected cell through `debugpy` inside that same kernel. Breakpoints set in your Python buffer through `nvim-dap` can bind to the cell because the plugin compiles the cell against the original buffer path and line numbers before executing it.

Requirements:
- Save the file before debugging, so the debugger has a stable source path.
- Install `debugpy` in the same Python environment as the running kernel.
- Install `nvim-dap` so `require("dap")` works in Neovim.

Typical flow:
1. Start the kernel with `:JupyterStart`.
2. Set breakpoints in the Python buffer using your normal `nvim-dap` mappings.
3. Run `:JupyterDebugCell` or press `<leader>jd`.
4. Use `<leader>jw` to pin important expressions into the watches pane and `<leader>je` for a quick popup evaluation.
5. Use your normal `nvim-dap` continue/step/evaluate commands.

The plugin’s fallback `dap-ui` layout is tuned for notebook debugging:
- Left sidebar: `Scopes`, `Watches`, then `Stacks`
- Bottom tray: `Console`, `REPL`, then `Breakpoints`

This keeps frequently inspected values visible without dedicating a large panel to thread noise from the Jupyter kernel process.

### Python Environment Detection

The plugin automatically detects your Python environment:
1. **Conda**: Uses `$CONDA_PREFIX/bin/python` if available
2. **Fallback**: Uses `python3` from PATH
3. **Override**: Set `python_cmd` in configuration
4. **Optional optimization**: `:JupyterStartOptimized` starts the Jupyter kernel with `PYTHONOPTIMIZE=2` (`sys.flags.optimize == 2`)

## 🎨 Cell Markers

The plugin recognizes Jupyter-style cell markers:

```python
#%% cell title
print("This is a cell")

##%% subcell title
print("This is a sub-cell")
```

**Cell Behavior:**
- Cells are delimited by lines starting with `#%%` (with optional whitespace)
- When cursor is on a marker line, execution includes the cell **below** that marker
- When cursor is inside a cell, that entire cell is executed
- Put `# jupyter: skip` as the first non-empty line inside a cell to make cell-based commands skip it
- Files without any markers will show a warning

**Highlight Groups:**
- `CellLineBackground` / `CellLineBG` control the header text and borders for parent `#%%` markers
- `CellLineSubBackground` / `CellLineSubBG` apply to `##%%` subcells (Default-linked to the parent groups so you can override them independently)
- Metadata comments in the form `#:: something ::` can be highlighted with virtual text when `ui.highlight_metadata` is `true`; customize the colors with `ui.metadata_hl` (table with `fg`/`bg`) or set it to a highlight group name.

## 🔍 Output Display

### Inline Virtual Text

Inline output is **cursor-aware**: it appears only for the cell the cursor is currently in, and disappears when the cursor moves to a different cell. This keeps the buffer uncluttered while still giving immediate access to the output of whichever cell you are editing.

- **Running**: Animated spinner sign in the gutter while the cell executes
- **Success**: `✓` gutter sign on completion
- **Error**: `✗` gutter sign and the error message shown inline (e.g. `TypeError: …`)
- **Output lines**: All non-empty output lines are shown as virtual lines below the cell's last code line, each prefixed with ` ⟶ `. Lines beyond `max_lines` are summarized as `… (N more lines)`.

Enable inline output via `:JupyterToggleInlineOutput` or by setting `inline.enabled = true` in the configuration. The `max_lines` limit (default 20) prevents very large outputs from cluttering the buffer; use the split-pane output buffer for full results.

NOTE: Inline output is best for quick feedback on small results or error messages. For larger outputs, rich content, or when you want to preserve ANSI colors, the split pane output is recommended.

### Split Pane Output
- **Detailed Output**: Full results, including rich content
- **ANSI Colors**: Preserved for proper syntax highlighting
- **Images**: Saved to temp files with path displayed
- **Markdown**: Rendered appropriately
- **Scrolling**: Auto-scrolls to latest output

## ❓ IPython Doc Lookups and Magics

- End a symbol with `?` or `??` inside a cell (e.g. `np.linspace?`) to open IPython help in the configured pager split (see `pager` settings in the configuration). These lines are ignored by Pyright and BasedPyright diagnostics so you can keep them in your code without warnings.
- Lines starting with `%` are treated as IPython line magics and expanded to `get_ipython().run_line_magic(...)` before execution, so commands like `%time`, `%pip install ...`, or `%who` run as expected when sent from Neovim.
- Start a cell with `# jupyter: skip` to exclude it from `:JupyterRunCell`, `:JupyterRunCellStay`, `:JupyterRunCells`, `:JupyterRunAbove`, and `:JupyterDebugCell`.

## 🏗️ Architecture

### Components
- **Bridge (`bridge.py`)**: Python process managing Jupyter kernel communication
- **Transport**: Handles stdin/stdout JSON communication with bridge
- **Kernel**: Manages execution queue and message handling
- **DAP integration**: Boots `debugpy` inside the live kernel and lets `nvim-dap` attach before a cell runs
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

**"`JupyterDebugCell` says `nvim-dap` is missing"**
- Install [`mfussenegger/nvim-dap`](https://github.com/mfussenegger/nvim-dap)
- Confirm `:lua print(require('dap'))` works in Neovim

**"`JupyterDebugCell` cannot import `debugpy`"**
- Install `debugpy` in the kernel environment, not just the Neovim host Python

**Breakpoints do not bind**
- Save the file before debugging the cell
- Set breakpoints in the `.py` buffer, then run `:JupyterDebugCell`
- Make sure you are debugging the same file you are editing

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
- [molten.nvim](https://github.com/benlubas/molten-nvim) - Interactive REPL over Neovim


# Reporting Bugs/Making Requests

- [ ] Please let me know if you find any issues, or if you have any requests. I'm new to the plugin world, and would be thrilled to hear your feedback.

# Known Issues

- [ ] Multiple buffers with each their own kernel is not supported - currently, all buffers send the code to a single kernel, which means that they share variables (not ideal, I know).
    - Workaround: tmux panes/sessions
