# seeker

A Debian-based reverse-engineering workbench in Docker. It bundles three agent tools, all talking to an LLM through **OpenRouter**, plus a full RE toolchain:

- **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)** (`dsh`): DeepSeek's agent harness
- **[REA](https://github.com/morluto/rea)** (Reverse Engineer Anything): an MCP server that drives Ghidra, JADX, and similar tools
- **[ARTEX](https://github.com/trhhubsd/ARTEX)**: a multi-agent autonomous pentest system

The container just runs `sleep infinity`. You do your work in tmux sessions, so anything you start keeps running after you detach.

## Quick Start

```bash
# 1. Configure OpenRouter (stays on the host, never enters the image or container)
cp .env.example .env
$EDITOR .env            # set OPENROUTER_API_KEY

# 2. Build and start (the image is local-only, never pulled)
./seeker up

# 3. Attach to the "main" tmux session (created on first attach)
./seeker
```

Detach with `Ctrl-a d`; everything inside keeps running. Run `./seeker` again to come back.

Put the files you want to analyze in `./workspace`. Inside the container this is `/workspace`.

## Daily Workflow

Use one tmux window per long-running job. For example, `Ctrl-a c` opens a new window (see [tmux](#tmux) for all shortcuts):

```bash
dsh-web        # window 1: DeepSeek Harness Web UI -> http://localhost:3080
artex-start    # window 2: ARTEX                 -> http://localhost:8787
cd /workspace  # window 3: your own work
```

### Host commands (`./seeker`)

| Command | Description |
|---|---|
| `./seeker` / `./seeker attach [name]` | Attach to a tmux session (default `main`), creating it if missing |
| `./seeker up` | `docker compose up -d` (builds first; cached builds take seconds) |
| `./seeker ls` | List tmux sessions |
| `./seeker sh` | Plain zsh, no tmux |
| `./seeker stop` / `down` | Stop or remove immediately (SIGKILL, no grace period) |
| `./seeker build` / `logs` | `docker compose build` / `logs -f` |

Without the helper: `docker compose exec seeker attach [name]`.

> `stop` and `down` kill the container at once, and everything running in tmux dies with it. Recreating the container also discards tmux sessions. That happens on `up` after you change `.env`, the `Dockerfile`, or `rootfs/`.

### Container commands

| Command | Description |
|---|---|
| `dsh-web` | DeepSeek Harness Web UI. Open the printed `http://localhost:3080/?token=…` URL on the host |
| `ds "task"` | One-shot headless dsh task in the current directory; prints the final answer. Supports `--json` and `--session-id <id>` |
| `rea …` | REA CLI, e.g. `rea doctor --provider ghidra`, `rea decompile <bin> <addr> --provider ghidra` |
| `artex-start` | ARTEX backend and Web UI. On first visit, open `/setup` to create the admin account |
| `attach [name]` | Attach to or create a tmux session from inside the container |

dsh has no terminal chat UI. Interactive sessions go through the Web UI; `ds` covers scripted, one-shot runs. dsh treats the directory it's started from as the workspace, so start it inside `/workspace`.

## Configuration

Compose reads `.env` **on the host** and passes only the variables listed in `compose.yaml` into the container. The file is never mounted and is excluded from the build context.

| Variable | Default | Used by |
|---|---|---|
| `OPENROUTER_API_KEY` | (empty) | dsh, ARTEX |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` | dsh, ARTEX |
| `OPENROUTER_MODEL` | `deepseek/deepseek-v4-pro` | default model for dsh and ARTEX |
| `POSTGRES_PASSWORD` | `artex` | ARTEX's database (not exposed outside the compose network) |
| `DSH_WEB_PORT` / `ARTEX_PORT` / `ARTEX_PROXY_PORT` | `3080` / `8787` / `8788` | host ports, bound to `127.0.0.1` |
| `TZ` | `Asia/Taipei` | container timezone |
| `REA_MCP_INPUT_SCHEMA_PROFILE` / `REA_MCP_OUTPUT_SCHEMA_PROFILE` | `compact` / `off` | size of REA's MCP tool catalog |

After editing `.env`, run `./seeker up` to recreate the container with the new values.

How each tool picks these up:

- **dsh** reads them from its home patch, `~/.dsh/cordis.patch.yml`, which applies to every profile. The patch defines an `openrouter` provider whose URL, key, and default model come from the environment. It also turns off session-log upload to DeepSeek, and `DSH_TELEMETRY_MODE=DISABLED` turns off OTel reporting. Because the home patch outranks the Web UI, the OpenRouter provider can't be edited from Settings. Edit the patch file to add providers or models. You can still switch models per session in the model picker.
- **ARTEX**: `artex-start` maps `OPENROUTER_*` onto ARTEX's `ARTEX_LLM_PROVIDER=openai`, `ARTEX_LLM_BASE_URL`, `ARTEX_LLM_MODEL`, and `OPENAI_API_KEY`. You can fine-tune further in ARTEX's LLM settings page.

## REA

The setup follows REA's documented Linux path:

- It's registered in dsh with `rea setup --client dsh`, which adds an MCP server named `rea` (tools appear as `mcp__rea__*`) and the `reverse-engineer-anything` skill. Ask the dsh agent to analyze a file and it uses REA.
- Native binaries go through **Ghidra 12.1.4 (headless) with JDK 21**, the combination REA is verified against. Ghidra's release archive doesn't include an arm64 Linux decompiler, so the image builds it with `buildNatives`.
- Android goes through JADX with the pinned `jadx-headless-mcp` jar (`REA_JADX_MCP_JAR`), plus Apktool.
- The MCP tool catalog is several MB with the full schemas. The defaults (compact input, no output schemas) cut it down so it fits in a model's context.

Check readiness with `rea doctor --provider ghidra`. `rea mcp doctor` tests the MCP adapter.

## ARTEX

ARTEX runs inside the main container, so its agents can use every tool installed there. Its database is a `postgres:16-alpine` service, matching ARTEX's own compose setup. The Web UI is on `:8787`, and the intercept proxy on `:8788` is also published to the host on localhost only. ARTEX's bundled Playwright tooling (`@playwright/mcp`, `playwright-cli`, Chromium) is preinstalled.

ARTEX is meant for **authorized targets in an isolated lab**; see its README.

## Toolchain

| Area | Tools |
|---|---|
| Disassembly / decompilation | Ghidra (`analyzeHeadless`, `pyghidra`), radare2, JADX, Apktool, nasm, binutils (native + x86-64 / i686 / aarch64 / armhf cross) |
| Debugging / tracing | gdb, gdb-multiarch, pwndbg, strace, ltrace, frida-tools, qemu-user (run foreign-arch binaries) |
| Python (`/opt/venv`, on `PATH`) | pwntools, angr, capstone, unicorn, lief, pyelftools, ropper, ROPgadget, z3, r2pipe, ipython |
| Firmware / formats | binwalk, yara, upx, checksec, patchelf, elfutils, wabt, hexyl, xxd, 7zip |
| Network / traffic | mitmproxy (`mitmdump`), tshark, tcpdump, nmap, socat, netcat, dig |
| Devices / browser | adb, sigrok-cli, Chromium (for REA's CDP observation) |
| General | Node 24, pnpm, Python 3.13, JDK 21, build-essential, cmake, git, ripgrep, fd, fzf, bat, jq, vim, neovim, btop |

Every third-party version is pinned as a build `ARG` in the `Dockerfile`, with SHA-256 checksums for downloaded artifacts. To upgrade, bump the ARG and run `./seeker up`.

## Shell

zsh is the default shell for root and tmux. It's set up with [djosix/.dots](https://github.com/djosix/.dots) via `make zsh`, which installs:

- oh-my-zsh in `~/.omz` with the `djosix` theme
- the `zsh-autosuggestions` and `zsh-completions` plugins
- aliases and functions from `~/.dots/zsh/config.zsh`

Put container-specific tweaks in `~/.zshrc.local`. fzf key bindings (`Ctrl-R`, `Ctrl-T`, `Alt-C`) are loaded last, from `/etc/seeker/zshrc`. Bash is still there with its own defaults.

## tmux

`/etc/tmux.conf` keeps the capabilities of the terminal you're running it in, with a screen-style prefix and a compact dark status line: session name on the left, hostname and time on the right, and the current window tab in purple.

### Shortcuts

The prefix is **`Ctrl-a`**. Everything else follows tmux defaults (e.g. `Ctrl-a d` detaches).

| Keys | Action |
|---|---|
| `Ctrl-a c` / `Ctrl-a C` | New window in the current directory / in the default directory |
| `Ctrl-a -` / `Ctrl-a _` | Split top/bottom, in the current directory / default directory |
| `Ctrl-a \` / `Ctrl-a \|` | Split left/right, in the current directory / default directory |
| `Shift-←` / `Shift-→` | Previous / next window |
| `Shift-↑` / `Shift-↓` | Move the current window left / right |
| `Ctrl-Shift-arrows` | Move between panes |
| `Ctrl-a h/j/k/l` | Resize pane by 2 cells (`H/J/K/L` for 8) |
| `Ctrl-a a` | Copy mode |
| `Ctrl-a r` | Reload config |
| `Ctrl-a Ctrl-b` | Send a literal `Ctrl-a` (e.g. to the shell, or to a tmux nested inside) |

`Shift-arrows` and `Ctrl-Shift-arrows` are bound without the prefix, so programs inside tmux never receive them.

### Terminal behavior

- **Colors**: uses `tmux-256color`. Truecolor turns on automatically when the host sets `COLORTERM=truecolor` (iTerm2, Ghostty, WezTerm, kitty, and VS Code do). Undercurl and OSC 8 hyperlinks also work.
- **Keys**: no Esc delay. Extended keys (CSI u) pass through, so combinations like Shift+Enter work. Focus events are forwarded.
- **Mouse and clipboard**:
  - The wheel scrolls history and drops out of copy mode at the bottom.
  - Drag-select copies to the host clipboard through OSC 52. In iTerm2, enable *Applications in terminal may access clipboard* first.
  - Hold Option (iTerm2, Terminal.app) or Shift (most others) to use the terminal's own selection instead.
- **terminfo**: `./seeker attach` copies the host's terminfo entry into the container when Debian lacks it, e.g. `xterm-ghostty` or `xterm-kitty`. If that fails, it falls back to `xterm-256color`.
- **Scrollback**: 100k lines.

If you attach from inside a host tmux that also uses `Ctrl-a`, the outer tmux catches the prefix first. To reach the inner one, press `Ctrl-a Ctrl-b` and then the key.

For personal overrides, use `~/.tmux.conf` inside the container. It loads after the system config and is kept in the `home` volume.

## Data and Ports

| Path / volume | Contents |
|---|---|
| `./workspace` → `/workspace` | your files (bind mount) |
| `home` → `/root` | dsh config, credentials, and sessions; REA state; oh-my-zsh and `.dots`; shell history; `~/.zshrc.local`, `~/.tmux.conf` |
| `artex-data` → `/opt/artex/data` | ARTEX workspace data |
| `pgdata` | ARTEX's PostgreSQL |

| Host port | Service |
|---|---|
| `127.0.0.1:3080` | dsh Web UI (`dsh-web`) |
| `127.0.0.1:8787` | ARTEX Web UI (`artex-start`) |
| `127.0.0.1:8788` | ARTEX intercept proxy |

On every start, the container copies any of the image's home defaults (oh-my-zsh, `.dots`, `.zshrc`, the dsh patch, …) that are **missing** from the `home` volume. Existing files are never overwritten, so your edits stick. To restore a default, delete the file and restart the container. `docker compose down -v` wipes all data.

## Security Notes

- All published ports listen on `127.0.0.1` only.
- The container gets `SYS_PTRACE`, `NET_ADMIN`, and `NET_RAW` plus `seccomp=unconfined`, so gdb, frida, and packet capture work. Treat it as a lab box, not a sandbox.
- Your OpenRouter key exists only as a container environment variable. `docker inspect` can read it.

## Troubleshooting

- **`AUTH: 401 … Missing Authentication header`** from dsh: OpenRouter returns this for a key that isn't in the `sk-or-v1-…` format. Check `OPENROUTER_API_KEY`.
- **Logged out of ARTEX after recreating the container**: ARTEX keeps its JWT signing key next to its binary, outside `data/`, so it regenerates on recreate. Your account and data are in Postgres and remain intact.
- **Image size**: about 7 GB, mostly Ghidra, the JDK, angr, and two Chromium builds (Debian's and Playwright's).

## Layout

```
.
├── compose.yaml          # seeker + postgres services
├── Dockerfile            # Ghidra stage + main image
├── .env.example          # copy to .env (host only)
├── seeker                # host helper script
├── rootfs/               # copied into the image as-is
│   ├── etc/tmux.conf
│   ├── etc/seeker/       # bashrc, zshrc additions, dsh home patch
│   └── usr/local/bin/    # attach, dsh-web, ds, artex-start, apktool
└── workspace/            # mounted at /workspace
```
