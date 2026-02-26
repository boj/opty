# opty

HDC-powered codebase context optimizer for LLMs. Indexes your code using
[Hyperdimensional Computing](https://en.wikipedia.org/wiki/Hyperdimensional_computing)
and produces minimal [TOON-format](https://toonformat.dev/) context for LLM API calls.

**93% token reduction** — measured on opty's own codebase ([see results](#token-savings-experiment)).

## How It Works

1. **Parse** — Scans source files and extracts structural elements (functions, types, imports)
2. **Encode** — Maps each code unit to a 10,000-bit binary hypervector using HDC bind/bundle algebra
3. **Index** — Stores vectors in an in-memory associative memory (the "codebase brain")
4. **Query** — Natural language queries become hypervectors; similarity search finds relevant code in <1ms
5. **Output** — Returns only the relevant code signatures in TOON format (30-60% fewer tokens than JSON)

## Quick Start

```bash
# Build (requires Zig 0.15+)
zig build

# One-shot query (no daemon)
./zig-out/bin/opty oneshot "authentication error handling" --dir /path/to/project

# Or run as a daemon for instant queries
./zig-out/bin/opty daemon /path/to/project &
./zig-out/bin/opty query "functions that handle database errors"
./zig-out/bin/opty status
./zig-out/bin/opty stop
```

On Windows, use `.\zig-out\bin\opty.exe` instead of `./zig-out/bin/opty`.

## Global Multi-Project Daemon (Recommended)

The **global** mode runs a single opty daemon that serves all your projects.
Projects are auto-loaded on first query and stay indexed in memory.

```bash
# Start the global daemon (or use systemd — see below)
opty global --port 7390 &

# Query from any project directory — opty auto-detects the project root
cd ~/projects/myapp
opty query "authentication flow"      # auto-loads myapp

cd ~/projects/api-server
opty query "database connection pool"  # auto-loads api-server separately

# Check all loaded projects
opty status

# Reindex current project
opty reindex
```

**Project root detection** walks up from your CWD looking for these markers:
`.git`, `build.zig`, `Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`,
`Makefile`, `CMakeLists.txt`, `.sln`, `Gemfile`, `pom.xml`, `build.gradle`.
If no marker is found, the CWD itself is used as the project root.

**Auto-loading** means you never need to configure project paths. Just `cd` into
any project and query — opty indexes it on the fly (typically <500ms) and keeps
the index in memory. The file watcher updates all loaded projects every 2 seconds.

## Commands

| Command | Description |
|---|---|
| `opty global [--port N]` | **Global multi-project daemon** — HTTP server, auto-loads projects on demand |
| `opty daemon [dir] [--port N]` | Single-project daemon (HTTP server, default port 7390) |
| `opty mcp [dir]` | Standalone MCP server over stdio (indexes locally) |
| `opty query <text> [--port N]` | Query the running daemon via HTTP |
| `opty status [--port N]` | Show indexed file/unit counts for current project |
| `opty reindex [--port N]` | Force full re-index of current project |
| `opty stop [--port N]` | Shut down the daemon |
| `opty oneshot <query> [--dir D]` | Index + query in one shot (no daemon) |
| `opty version` | Show version |

### HTTP API

The daemon exposes an HTTP API on `http://127.0.0.1:<port>`:

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/query` | `{"cwd": "...", "query": "..."}` | TOON-format results |
| GET | `/status` | query param `?cwd=...` (optional) | Status text |
| POST | `/reindex` | `{"cwd": "..."}` (optional) | Confirmation text |
| POST | `/shutdown` | — | "OK shutting down" |
| POST | `/mcp` | JSON-RPC body | MCP JSON-RPC response |

```bash
# Query directly via curl
curl -X POST http://localhost:7390/query \
  -d '{"cwd":"/path/to/project","query":"error handling"}'

# Check status
curl http://localhost:7390/status

# MCP JSON-RPC
curl -X POST http://localhost:7390/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Example Output (TOON format)

```
functions[3]{name,signature,file,line}:
handleAuth,pub fn handleAuth(req: Request) !Response {,src/auth.zig,42
validateToken,fn validateToken(token: []const u8) !bool {,src/auth.zig,87
refreshSession,pub fn refreshSession(id: SessionId) !Session {,src/session.zig,23
```

Compare to the equivalent JSON (~60% more tokens):
```json
{"functions":[{"name":"handleAuth","signature":"pub fn handleAuth(req: Request) !Response {","file":"src/auth.zig","line":42},{"name":"validateToken","signature":"fn validateToken(token: []const u8) !bool {","file":"src/auth.zig","line":87},{"name":"refreshSession","signature":"pub fn refreshSession(id: SessionId) !Session {","file":"src/session.zig","line":23}]}
```

## Pipe to LLM

```bash
# Use with any LLM CLI
opty query "error handling" | llm "explain the error handling strategy"

# Or programmatically
CONTEXT=$(opty query "database layer")
curl -s https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "{\"model\":\"gpt-4\",\"messages\":[{\"role\":\"system\",\"content\":\"$CONTEXT\"},{\"role\":\"user\",\"content\":\"Explain the database architecture\"}]}"
```

## MCP Server (for AI Coding Agents)

opty exposes an [MCP](https://modelcontextprotocol.io/) server so coding agents
(Claude, Copilot, Cursor, etc.) can automatically query the codebase index
instead of reading every file.

**Tools exposed:**

| Tool | Description |
|---|---|
| `opty_query` | Semantic code search — finds functions/types/imports matching a natural language query |
| `opty_status` | Index statistics — file count, code unit count, memory |
| `opty_reindex` | Force full re-scan of the codebase |

### Adding MCP to Your Project

Drop a `.mcp.json` in your project root. With the **global daemon** running, use the
HTTP MCP endpoint directly (no bridge process needed):

```json
{
  "mcpServers": {
    "opty": {
      "type": "http",
      "url": "http://localhost:7390/mcp"
    }
  }
}
```

Just ensure the global daemon is running (`opty global --port 7390`).

For **standalone** mode (no daemon required — indexes locally in-process via stdio):

```json
{
  "mcpServers": {
    "opty": {
      "command": "/path/to/opty",
      "args": ["mcp", "."]
    }
  }
}
```

### Claude Desktop / Claude Code

Add to `~/.claude/claude_desktop_config.json` (Desktop) or `~/.claude.json` (Code):

```json
{
  "mcpServers": {
    "opty": {
      "type": "http",
      "url": "http://localhost:7390/mcp"
    }
  }
}
```

### VS Code (GitHub Copilot)

Add to `.vscode/mcp.json` in your workspace:

```json
{
  "servers": {
    "opty": {
      "type": "http",
      "url": "http://localhost:7390/mcp"
    }
  }
}
```

### Copilot CLI

Add `.mcp.json` to your project root (see above), then launch `copilot`
from that directory. opty's tools appear automatically. You can also manage
MCP servers with the `/mcp` slash command.

### Generic MCP Client (stdio)

```bash
# opty also speaks JSON-RPC 2.0 over stdio with Content-Length framing
opty mcp /path/to/project
```

The server responds to `initialize`, `tools/list`, `tools/call`, `ping`,
`resources/list`, and `prompts/list`.

## Token Savings Experiment

We audited opty's own codebase (1,728 lines of Zig across 9 source files) using
two approaches and compared the token cost.

**Task:** Comprehensive code audit covering error handling, security/input
validation, memory management, concurrency/thread safety, and network protocol
handling.

### Approach 1: API-only (send all source code)

The LLM reads every source file to perform the audit.

| Component | Chars | Tokens (est.) |
|---|---|---|
| `src/hdc.zig` | 5,679 | ~1,419 |
| `src/parser.zig` | 13,591 | ~3,397 |
| `src/mcp.zig` | 14,718 | ~3,679 |
| `src/main.zig` | 6,941 | ~1,735 |
| `src/daemon.zig` | 6,671 | ~1,667 |
| `src/encoder.zig` | 4,693 | ~1,173 |
| `src/brain.zig` | 4,266 | ~1,066 |
| `src/toon.zig` | 3,148 | ~787 |
| `src/root.zig` | 362 | ~90 |
| Audit prompt | 282 | ~70 |
| **Total** | **66,699** | **~16,674** |

### Approach 2: opty-assisted (semantic pre-filter)

opty runs 5 targeted queries locally, LLM reads only the relevant TOON results.

| Query | Chars | Tokens (est.) |
|---|---|---|
| "error handling patterns" | 1,841 | ~460 |
| "security input validation" | 1,495 | ~373 |
| "memory allocation free leak" | 1,418 | ~354 |
| "concurrency thread mutex lock" | 1,458 | ~364 |
| "network TCP socket protocol" | 1,351 | ~337 |
| Deduplicated union of all 5 | 4,171 | ~1,042 |
| Audit prompt | 282 | ~70 |
| **Total** | **4,453** | **~1,113** |

### Results

| Metric | API-only | opty-assisted |
|---|---|---|
| Input tokens | ~16,674 | ~1,113 |
| Files read by LLM | 9 source + README | 0 (TOON summaries) |
| Lines sent | 1,728 | 59 (deduplicated) |
| **Token reduction** | — | **93%** |

All 5 opty queries executed locally in <1ms each with zero LLM tokens consumed.
The HDC similarity search correctly surfaced the relevant functions for each
audit category (e.g., `callError`, `rpcError` for error handling;
`serveLoop`, `handleClient` for network; `deinit`, `Brain.init` for memory).

## Supported Languages

Zig, TypeScript, JavaScript, Python, Go, Rust, C, C++, Java, Ruby, F#, C#

## Architecture

```
Source Files → Pattern Parse → Skeleton Extract → HDC Encode → Codebase Brain
                                                                      ↓
Query Text  → HDC Encode → Similarity Scan (<1ms) → Top-K → TOON Output → LLM API
```

All indexing and querying happens locally with zero LLM tokens consumed.
The daemon watches files and incrementally re-indexes on changes (<1ms per file).

## Why Hyperdimensional Computing?

[Hyperdimensional Computing](https://en.wikipedia.org/wiki/Hyperdimensional_computing)
(HDC), also called Vector Symbolic Architectures (VSA), encodes information into
very high-dimensional vectors (10,000-bit binary) using three algebraic operations:

- **MAP** — assign a random hypervector to each atomic symbol (deterministic from hash seed)
- **BIND** (⊗) — XOR two vectors to represent an association (e.g., `role_name ⊗ "handleAuth"`)
- **BUNDLE** (+) — majority-vote addition to represent sets/aggregates

Each code unit (function, type, import) becomes a single hypervector that encodes
its name, parameter types, return type, module context, file path, and signature
tokens. Similarity search via Hamming distance (hardware-accelerated `popcount`)
finds semantically related code in microseconds.

### HDC vs. Neural Embeddings

| Property | HDC | Neural Embeddings |
|---|---|---|
| Training needed | None (random projection) | Large corpus + GPU |
| Latency | Microseconds (bit ops) | Milliseconds (matrix multiply) |
| Memory per unit | 1.25 KB (10K bits) | 3–6 KB (768–1536 floats) |
| Compositionality | Native (bind/bundle algebra) | Opaque |
| Update cost | O(1) per changed unit | Re-embed or fine-tune |
| Hardware | CPU only, single binary | GPU preferred |

### How opty Encodes Code

```
function_hv = bundle(
    role_kind   ⊗ atom("function"),
    role_name   ⊗ atom("handleAuth"),
    role_name   ⊗ atom("handle"),       // sub-token from camelCase split
    role_name   ⊗ atom("Auth"),         // sub-token from camelCase split
    role_module ⊗ atom("auth"),
    role_file   ⊗ atom("src"),
    atom("Request"),                     // signature token
    atom("Response"),                    // signature token
)
```

The resulting 10,000-bit vector is similar to any query vector that shares
components — "auth handling functions" will match because it shares the
`atom("auth")`, `atom("handle")`, and `role_kind ⊗ atom("function")` components.

## Building

Requires [Zig 0.15+](https://ziglang.org/download/).

### Linux / macOS

```bash
zig build                    # Debug build
zig build -Doptimize=fast    # Release build
zig build test               # Run tests (11 tests)
```

### Windows

opty builds natively on Windows with the standard Zig toolchain:

```powershell
zig build                    # Debug build
zig build -Doptimize=fast    # Release build
zig build test               # Run tests
```

The binary is output to `zig-out\bin\opty.exe`. All commands work the same:

```powershell
.\zig-out\bin\opty.exe oneshot "error handling" --dir C:\Users\you\projects\myapp
.\zig-out\bin\opty.exe daemon C:\Users\you\projects\myapp
.\zig-out\bin\opty.exe query "database functions"
.\zig-out\bin\opty.exe mcp C:\Users\you\projects\myapp
```

### Windows via WSL

If building on a Windows filesystem from WSL, use a tmpdir-based cache to avoid
filesystem permission issues:

```bash
zig build --cache-dir /tmp/opty-zig-cache --global-cache-dir /tmp/opty-zig-global
```

### Windows Service (Task Scheduler)

On Windows, use Task Scheduler instead of systemd to run opty on login:

```powershell
# Create a scheduled task that starts opty daemon on login
$action = New-ScheduledTaskAction `
    -Execute "$env:USERPROFILE\.local\bin\opty.exe" `
    -Argument "global --port 7390"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "opty-daemon" -Action $action -Trigger $trigger -Settings $settings

# Check status
Get-ScheduledTask -TaskName "opty-daemon"

# Remove
Unregister-ScheduledTask -TaskName "opty-daemon" -Confirm:$false
```

### MCP on Windows

The `.mcp.json` config uses the same format — just ensure the global daemon is running:

```json
{
  "mcpServers": {
    "opty": {
      "type": "http",
      "url": "http://localhost:7390/mcp"
    }
  }
}
```

For standalone stdio mode, adjust paths:

```json
{
  "mcpServers": {
    "opty": {
      "command": "C:\\Users\\you\\.local\\bin\\opty.exe",
      "args": ["mcp", "."]
    }
  }
}
```

## Running as a systemd User Service (Linux)

opty ships with systemd user service files for always-on indexing that survives
reboots and runs in the background.

### Quick Install (Global Daemon — Recommended)

```bash
# Build first, then install binary + services
zig build
./systemd/install.sh

# Start the global daemon (auto-loads projects on demand)
systemctl --user enable --now opty-daemon
```

The default service runs `opty global --port 7390`. All projects are auto-loaded
when first queried — no per-project configuration needed.

### Watch a Specific Project (Template Instance)

If you prefer per-project daemons instead of the global daemon:

The `opty-daemon@.service` template lets you run separate instances per directory:

```bash
# Escape the path: replace '/' with '-', strip leading '-'
# Example: /home/you/projects/myapp → home-you-projects-myapp
systemctl --user enable --now 'opty-daemon@home-you-projects-myapp'
```

### Manual Configuration

If the default service doesn't match your layout, override `ExecStart`:

```bash
systemctl --user edit opty-daemon
```

```ini
[Service]
ExecStart=
ExecStart=%h/.local/bin/opty global --port 7390
```

### Useful Commands

```bash
systemctl --user status opty-daemon       # Check status
systemctl --user restart opty-daemon      # Restart after rebuild
journalctl --user -u opty-daemon -f       # Follow logs
systemctl --user disable --now opty-daemon # Stop and disable
./systemd/install.sh --uninstall          # Full removal
```

## References

### Hyperdimensional Computing / Vector Symbolic Architectures

1. Kanerva, P. (2009). ["Hyperdimensional Computing: An Introduction to Computing in Distributed Representation with High-Dimensional Random Vectors."](https://link.springer.com/article/10.1007/s12559-009-9009-8) *Cognitive Computation*, 1(2), 139–159.
2. Kleyko, D. et al. (2022). ["A Survey on Hyperdimensional Computing: Theory, Implementations, and Applications."](https://dl.acm.org/doi/10.1145/3538531) *ACM Computing Surveys*, 55(6), 1–51.
3. Kleyko, D. et al. (2024). ["Hyperdimensional Computing: Fast, Robust, Interpretable."](https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1012426) *PLOS Computational Biology*.
4. Thomas, A. et al. (2021). ["Theoretical Foundations of Hyperdimensional Computing."](https://jmlr.org/papers/v22/21-0142.html) *Journal of Machine Learning Research*, 22, 1–54.
5. Poduval, P. et al. (2025). ["Efficient Context-Preserving Encoding via Sparse Binary Representations."](https://www.mdpi.com/2079-9292/14/4/681) *MDPI Electronics*.

### LLM Token Optimization

6. Jiang, Q. et al. (2025). ["Optimizing Token Consumption in LLMs: A Nano Surge Approach."](https://arxiv.org/abs/2504.15989) *arXiv:2504.15989*.
7. ["Stop Round-Tripping Your Codebase: Cut LLM Token Usage by 80%."](https://docs.google.com/document/d/1N3i5O-SkuvIJLNzPbD19n15q-1Mu68g2kE0hpTORrDg) Recursive Document Analysis approach.
8. ["Code Maps: Blueprint Your Codebase for LLMs."](https://origo.prose.sh/code-maps) — signature extraction via tree-sitter.
9. ["TOON vs JSON: Stop Token Waste in LLMs."](https://www.codemotion.com/magazine/ai-ml/toon-vs-json-stop-token-waste-in-llms/) *Codemotion Magazine*.
10. ["Tokens, Watts, and Waste: The Hidden Energy Bill of LLM Inference."](https://cognaptus.com/tokens-watts-and-waste/) *Cognaptus*.

### Implementation

11. [TOON Format Specification](https://toonformat.dev/) — Token-Oriented Object Notation.
12. [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) — open standard for AI tool integration.
13. [Zig Programming Language](https://ziglang.org/) — systems language with SIMD intrinsics and comptime.

## License

MIT
