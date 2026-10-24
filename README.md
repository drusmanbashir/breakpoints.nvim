# breakpoints.nvim

Save breakpoints and log points in Neovim's gutter without starting a debugger. Breakpoints appear as red ● marks, log points as red ◆ marks, with properties and gutter tooltips. Debugger integrations can subscribe to change events and provide validation, styling and list navigation.

## Requirements

Neovim **0.10.0 or newer**, built with LuaJIT, on Linux or macOS, with Git on `PATH`. The plugin uses `vim.iter`, `vim.keycode`, inline virtual text and extmark invalidation introduced in [Neovim 0.10](https://neovim.io/doc/user/news-0.10/).

**No dependencies** on other Neovim plugins. File locking uses LuaJIT's built-in `ffi` and POSIX `flock`. Git determines project boundaries; files outside a Git project share a separate storage bucket.

## Installation and configuration

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "drusmanbashir/breakpoints.nvim",
  lazy = false,
  opts = {
    signs = {
      breakpoint = { text = "●", color = "DiagnosticError" },
      log_point = { text = "◆", color = "DiagnosticError" },
      muted = { color = "Comment" },
    },
  },
}
```

Other plugin managers: install the plugin, then call `require("breakpoints").setup(opts)`.

The example shows the defaults. `color` accepts a highlight group name or a `#rrggbb` foreground. The plugin defines `BreakpointsBreakpoint`, `BreakpointsLogPoint` and `BreakpointsMuted`; the defaults link them to `DiagnosticError`, `DiagnosticError` and `Comment`. Muting changes the colour while preserving the kind's icon.

The plugin may initialize before its configuration runs. Calling `setup(opts)` later merges the supplied settings and redraws loaded buffers; mappings and autocmds install once.

## Keys

All mappings below are in Normal mode. `<leader>` uses your configured leader.

| Key | Action |
|---|---|
| `<F2>`, `<leader>dt`, `<C-F8>`, `<F32>` | Toggle a breakpoint on the current line. |
| `<S-F2>`, `<F14>` | Clear this file's breakpoints and log points. |
| `<F3>` | Prompt for a log message, remove an existing log point, or convert a breakpoint to a log point. Empty input or cancellation changes nothing. |
| `<leader>dT` | Open properties on a breakpoint; otherwise focus the attached debugger's list, if available. |
| `<C-S-F8>`, `<F44>` | Aliases for properties. |

The properties box edits condition, log message, hit count and removal after the first hit. Enter saves; Esc cancels. A log point cannot also be removed after its first hit. Without a debugger integration, a line with no breakpoint shows "No breakpoint on this line".

## Storage

Records are saved under `stdpath("state")/breakpoints/<language>/breakpoints.json`, grouped by filetype and project. C files use the `cpp` folder; unknown filetypes use `other`. A new store copies an existing `dap-sidecar` language store once. Writes use a lock, temporary files and atomic renames; saving a buffer merges moved marks with the latest disk state by ID.

## API and debugger integration

Use `local bp = require("breakpoints")`. Paths are absolute and line numbers are 1-based. Entries contain `id` and `line`, with optional `condition`, `log_message`, `hit_condition` and `remove_once` properties.

| Functions | Purpose |
|---|---|
| `toggle(path, line, props?)`, `toggle_at(buf, row, props?)` | Toggle a stored breakpoint. |
| `update(id, props)`, `remove_by_id(id)` | Update properties or remove one record by its stable ID. |
| `clear(path)`, `clear_buffer(buf)`, `clear_project(root?)`, `clear_all()` | Clear a file, project or the complete store. |
| `get(path)`, `find_at(path, line)` | Return the file's entries or the entry drawn on a line. |
| `all()` | Return a read-only disk snapshot shaped as `snapshot[project][path] = entries`, plus an unreadable-file reason when needed. |
| `redraw()` | Repaint every loaded buffer using the current configuration and host styling. |

Committed changes emit `User BreakpointsChanged` with `data = { path, lines }`. `lines` contains the complete saved entries for that path, including IDs, and is empty after clearing the file. Integrations can forward this payload to their debugger:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "BreakpointsChanged",
  callback = function(event)
    -- Apply event.data.path and event.data.lines to your debugger.
  end,
})
```

`bp.attach(host)` attaches one optional debugger host, once:

| Host field | Contract |
|---|---|
| `style(path, entry)` | Return optional `{ text, hl, note }` fields merged over the configured style, or nil. To mute a mark, return `{ hl = "BreakpointsMuted", note = "Muted" }` so its icon is retained. |
| `validate(language, props)` | Return a refusal string or nil when validating property updates. `language` is the storage folder name, including `cpp` for C. |
| `focus_list()` | Focus the debugger's breakpoint list. The properties key saves before switching from the box to this list. |

After changing host state, call `bp.redraw()`. Without a host, the plugin uses its default styling and the properties key inside the box only saves. Other sign owners can register tooltip text with `require("breakpoints.ui.gutter_hover").register(namespace_name, describe)`, where `describe(buf, line)` returns a list of tooltip lines or nil.

## Tests

From the repository root, with Git available, run the standalone tests using a private state directory:

```sh
test_root="$(mktemp -d)"
BP_TEST_ROOT="$PWD" \
  XDG_STATE_HOME="$test_root/state" \
  XDG_DATA_HOME="$test_root/data" \
  XDG_CACHE_HOME="$test_root/cache" \
  nvim --clean --headless -u NONE -l tests/breakpoints_test.lua
rm -rf -- "$test_root"
```

Use a fresh directory for each run. Set `BP_TEST_CASE=existing` or `BP_TEST_CASE=copy-failure` on the `nvim` command to exercise the additional migration cases.

## License

[GNU LGPL-3.0](LICENSE).
