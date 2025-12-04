# Prise

Prise is a terminal multiplexer targeted at modern terminals.

## Goals

1.  **Modern Terminal Features**: This is a core tenet. Terminals that do not
    provide the base level of modern features will not be supported; prise will
refuse to start in such environments.
2.  **High-Performance Community Vibe Coding**: Prise serves as an experiment in
    collaborative, high-performance software development driven by "vibe coding"
and AI assistance. Together, we can vibe code high performance software.
3.  **Extensibility**: Extensibility is at the core of the UI. The user
    interface is designed to be fully replaceable through configuration or by
using a third-party client.

## Vibe Coding

<p align="center">
  <img src="assets/vibe_coding.jpg" alt="Vibe Coding" />
</p>

**Core Thesis**: High-performance software is the result of quality engineering.

Prise is built on a solid foundation of `libghostty`, `libvaxis`, and Lua. While these tools provide an excellent starting point, they do not guarantee success—it is still entirely possible to build bad software with good tools. We believe that **vibe coding**—leveraging AI assistance to amplify engineering capabilities—is capable of consistently producing the quality software we demand.

Prise is a vibe coded project. Contributions are welcome, but preference is given to AI-developed code.

*   Sharing of AI conversation threads is preferred when submitting contributions, even if those threads did not directly result in the final Pull Request.
*   If you cannot afford paid AI tools, check out [Amp's free mode](https://ampcode.com).
*   There are also other free options available, such as OpenCode using compatible models.

## Development Setup

To set up your development environment (installs pre-commit hook):

```bash
zig build setup
```

## Build Instructions

To build the project:

```bash
zig build
```

To run the project:

```bash
zig build run
```

To run tests:

```bash
zig build test
```

To format code:

```bash
zig build fmt
```

## Installation

To install the binary and service files:

```bash
zig build install --prefix ~/.local
```

To enable and start the prise server as a background service:

```bash
zig build enable-service --prefix ~/.local
```

This will:
- **macOS**: Symlink the launchd plist to `~/Library/LaunchAgents/` and load it
- **Linux**: Symlink the systemd unit to `~/.config/systemd/user/` and enable it

### Manual Service Management

**macOS**:
```bash
launchctl unload ~/Library/LaunchAgents/sh.prise.server.plist  # stop
launchctl load ~/Library/LaunchAgents/sh.prise.server.plist    # start
```

**Linux**:
```bash
systemctl --user stop prise     # stop
systemctl --user start prise    # start
systemctl --user status prise   # check status
```

## Configuration

Prise is configured via Lua. Create `~/.config/prise/init.lua` to customize the UI.

### Example Configuration

```lua
-- Use the built-in tiling UI with custom options
local ui = require("prise").tiling()

ui.setup({
    theme = {
        mode_normal = "#7aa2f7",  -- Tokyo Night blue
        mode_command = "#f7768e", -- Tokyo Night red
        bg1 = "#1a1b26",
        bg2 = "#24283b",
        bg3 = "#414868",
        accent = "#7aa2f7",
    },
    keybinds = {
        leader = { key = "a", ctrl = true },  -- Use Ctrl+a as leader (like tmux)
    },
    status_bar = {
        enabled = true,
    },
    tab_bar = {
        show_single_tab = false,
    },
})

return ui
```

### Default Keybinds

The default leader key is `Super+k` (Cmd+k on macOS). After pressing the leader:

| Key | Action |
|-----|--------|
| `v` | Split vertical |
| `s` | Split horizontal |
| `h/j/k/l` | Focus left/down/up/right |
| `w` | Close pane |
| `z` | Toggle zoom |
| `t` | New tab |
| `c` | Close tab |
| `n/p` | Next/previous tab |
| `d` | Detach session |
| `q` | Quit |

Press `Super+p` to open the command palette.

## Lua LSP Setup

Prise installs type definitions to `<prefix>/share/prise/lua/`. To get autocomplete and type checking in your editor, add this path to your Lua language server configuration.

### Neovim (with nvim-lspconfig)

```lua
require("lspconfig").lua_ls.setup({
    settings = {
        Lua = {
            workspace = {
                library = {
                    vim.fn.expand("~/.local/share/prise/lua"),
                },
            },
        },
    },
})
```

### Neovim (with LazyVim)

Add to `lua/plugins/lua_ls.lua`:

```lua
return {
    "neovim/nvim-lspconfig",
    opts = {
        servers = {
            lua_ls = {
                settings = {
                    Lua = {
                        workspace = {
                            library = {
                                vim.fn.expand("~/.local/share/prise/lua"),
                            },
                        },
                    },
                },
            },
        },
    },
}
```

### VS Code

Add to `.vscode/settings.json`:

```json
{
    "Lua.workspace.library": [
        "~/.local/share/prise/lua"
    ]
}
```

### .luarc.json (project-level)

```json
{
    "workspace.library": [
        "~/.local/share/prise/lua"
    ]
}
```

## Requirements

The following binaries are required for development:

*   `stylua` (for Lua formatting)
*   [`zigdoc`](https://github.com/rockorager/zigdoc) (for documentation)
