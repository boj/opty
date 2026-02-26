# opty

A semantic code search tool built with [Hyperdimensional Computing](https://en.wikipedia.org/wiki/Hyperdimensional_computing) (HDC). It indexes function signatures, type definitions, and imports from your codebase and lets you find them by concept rather than by name.

## What it does

opty extracts **code unit skeletons** — function signatures, type/struct definitions, and import declarations — from source files. It encodes each one into a 10,000-bit binary hypervector, then matches natural language queries against them via Hamming distance.

**What it's good at:**
- **Exploration** — "what handles authentication?" finds `handleAuth`, `validateToken`, `refreshSession` even if your query shares no exact substrings
- **Discovery** — navigating an unfamiliar codebase by concept rather than by name
- **Compact overviews** — results come in [TOON format](https://toonformat.dev/), which uses ~60% fewer tokens than JSON, useful when feeding context to an LLM

**What it doesn't do:**
- Index function bodies, comments, or docstrings — only signatures
- Replace grep for exact string matching or regex patterns
- Understand what code *does* — it matches on names, types, and structural tokens

Think of it as a fast, fuzzy table of contents for your codebase. You still need to read the actual code to understand it.

## How it works

1. **Parse** — Scans source files line-by-line and extracts structural elements (functions, types, imports) via pattern matching
2. **Encode** — Maps each code unit to a 10,000-bit binary hypervector using HDC bind/bundle algebra. Splits identifiers (camelCase, snake_case) into sub-tokens for partial matching
3. **Index** — Stores vectors in an in-memory associative memory
4. **Query** — Your query becomes a hypervector; Hamming distance similarity finds relevant code in <1ms
5. **Output** — Returns matching code signatures in TOON format

All indexing and querying happens locally. No network calls, no LLM inference, no GPU.

## Quick start

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

## Global multi-project daemon

The **global** mode runs a single opty daemon that serves all your projects. Projects are auto-loaded on first query and stay indexed in memory.

```bash
# Start the global daemon
opty global --port 7390 &

# Query from any project directory — opty auto-detects the project root
cd ~/projects/myapp
opty query "authentication flow"

cd ~/projects/api-server
opty query "database connection pool"

# Check all loaded projects
opty status

# Reindex current project
opty reindex
```

**Project root detection** walks up from your CWD looking for:
`.git`, `build.zig`, `Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`,
`Makefile`, `CMakeLists.txt`, `.sln`, `Gemfile`, `pom.xml`, `build.gradle`.

**Auto-loading** means you never need to configure project paths. Just `cd` into any project and query — opty indexes it on the fly (typically <500ms) and keeps the index in memory. The file watcher updates all loaded projects every 2 seconds.

## Commands

| Command | Description |
|---|---|
| `opty global [--port N]` | Global multi-project daemon (HTTP server, auto-loads projects on demand) |
| `opty daemon [dir] [--port N]` | Single-project daemon (HTTP server, default port 7390) |
| `opty mcp [dir]` | Standalone MCP server over stdio (indexes locally) |
| `opty query <text> [--port N]` | Query the running daemon via HTTP |
| `opty status [--port N]` | Show indexed file/unit counts for current project |
| `opty reindex [--port N]` | Force full re-index of current project |
| `opty stop [--port N]` | Shut down the daemon |
| `opty oneshot <query> [--dir D]` | Index + query in one shot (no daemon) |
| `opty version` | Show version |

## HTTP API

The daemon exposes an HTTP API on `http://127.0.0.1:<port>`:

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/query` | `{"cwd": "...", "query": "..."}` | TOON-format results |
| GET | `/status` | query param `?cwd=...` (optional) | Status text |
| POST | `/reindex` | `{"cwd": "..."}` (optional) | Confirmation text |
| POST | `/shutdown` | — | "OK shutting down" |
| POST | `/mcp` | JSON-RPC body | MCP JSON-RPC response |

```bash
curl -X POST http://localhost:7390/query \
  -d '{"cwd":"/path/to/project","query":"error handling"}'

curl http://localhost:7390/status
```

## Example output (TOON format)

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

## MCP server (for AI coding agents)

opty exposes an [MCP](https://modelcontextprotocol.io/) server so coding agents (Claude, Copilot, Cursor, etc.) can query the codebase index as a tool.

This is most useful as an **exploration tool** — helping the agent get oriented in a codebase before it knows what files to read. It doesn't replace the agent reading actual source code.

**Tools exposed:**

| Tool | Description |
|---|---|
| `opty_query` | Semantic code search — finds functions/types/imports matching a natural language query |
| `opty_status` | Index statistics — file count, code unit count, memory |
| `opty_reindex` | Force full re-scan of the codebase |

### Configuration

Drop a `.mcp.json` in your project root. With the global daemon running:

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

For standalone mode (no daemon, indexes in-process via stdio):

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

This works with Claude Desktop (`~/.claude/claude_desktop_config.json`), Claude Code (`~/.claude.json`), VS Code (`.vscode/mcp.json`), and any MCP-compatible client.

## Supported languages

Zig, TypeScript, JavaScript, Python, Go, Rust, C, C++, Java, Ruby, F#, C#

## Limitations

- **Signatures only** — function bodies, comments, and docstrings are not indexed. You can find `handleAuthError` but not the `if err != nil` inside it.
- **Pattern-based parsing** — code units are extracted via line-by-line pattern matching, not AST parsing. Edge cases (multi-line signatures, macros) may be missed.
- **No learned semantics** — HDC uses random projections, not trained embeddings. "database" and "DB" are unrelated vectors. Matching works through shared sub-tokens and structural context, not synonym understanding.
- **Broad results** — similarity search has no hard threshold. Results with low similarity scores may not be relevant. The top-K cutoff is the only filter.

## How HDC encoding works

[Hyperdimensional Computing](https://en.wikipedia.org/wiki/Hyperdimensional_computing) (HDC) encodes information into very high-dimensional binary vectors using three operations:

- **MAP** — assign a random hypervector to each atomic symbol (deterministic from hash)
- **BIND** (XOR) — associate two vectors (e.g., `role_name XOR "handleAuth"`)
- **BUNDLE** (majority vote) — combine multiple signals into one vector

Each code unit becomes a single hypervector encoding its name, sub-tokens, module, file path, and signature tokens:

```
function_hv = bundle(
    role_kind   XOR atom("function"),
    role_name   XOR atom("handleAuth"),
    role_name   XOR atom("handle"),       // camelCase split
    role_name   XOR atom("Auth"),         // camelCase split
    role_module XOR atom("auth"),
    role_file   XOR atom("src"),
    atom("Request"),                       // signature token
    atom("Response"),                      // signature token
)
```

Query matching works because the query vector shares components with relevant code units. "auth handling functions" matches because it shares `atom("auth")`, `atom("handle")`, and `role_kind XOR atom("function")`.

Similarity is computed via Hamming distance (hardware-accelerated `popcount`), which is why queries take microseconds.

### HDC vs. neural embeddings

| Property | HDC | Neural embeddings |
|---|---|---|
| Training needed | None (random projection) | Large corpus + GPU |
| Latency | Microseconds (bit ops) | Milliseconds (matrix multiply) |
| Memory per unit | 1.25 KB (10K bits) | 3-6 KB (768-1536 floats) |
| Compositionality | Native (bind/bundle algebra) | Opaque |
| Update cost | O(1) per changed unit | Re-embed or fine-tune |
| Synonym understanding | None | Yes |
| Hardware | CPU only | GPU preferred |

## Building

Requires [Zig 0.15+](https://ziglang.org/download/).

```bash
zig build                    # Debug build
zig build -Doptimize=fast    # Release build
zig build test               # Run tests
```

### Windows

```powershell
zig build
.\zig-out\bin\opty.exe oneshot "error handling" --dir C:\Users\you\projects\myapp
```

### WSL

If building on a Windows filesystem from WSL, use a tmpdir-based cache:

```bash
zig build --cache-dir /tmp/opty-zig-cache --global-cache-dir /tmp/opty-zig-global
```

## Running as a systemd service (Linux)

```bash
zig build
./systemd/install.sh
systemctl --user enable --now opty-daemon
```

The default service runs `opty global --port 7390`.

### Windows (Task Scheduler)

```powershell
$action = New-ScheduledTaskAction `
    -Execute "$env:USERPROFILE\.local\bin\opty.exe" `
    -Argument "global --port 7390"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "opty-daemon" -Action $action -Trigger $trigger -Settings $settings
```

## References

### Hyperdimensional Computing
1. Kanerva, P. (2009). [Hyperdimensional Computing: An Introduction.](https://link.springer.com/article/10.1007/s12559-009-9009-8) *Cognitive Computation*, 1(2), 139-159.
2. Kleyko, D. et al. (2022). [A Survey on Hyperdimensional Computing.](https://dl.acm.org/doi/10.1145/3538531) *ACM Computing Surveys*, 55(6), 1-51.
3. Kleyko, D. et al. (2024). [Hyperdimensional Computing: Fast, Robust, Interpretable.](https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1012426) *PLOS Computational Biology*.

### Implementation
4. [TOON Format Specification](https://toonformat.dev/)
5. [Model Context Protocol (MCP)](https://modelcontextprotocol.io/)
6. [Zig Programming Language](https://ziglang.org/)

## License

MIT
