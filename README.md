# opty

A code intelligence tool built with [Hyperdimensional Computing](https://en.wikipedia.org/wiki/Hyperdimensional_computing) (HDC). It indexes function signatures, type definitions, and imports from your codebase and provides semantic search, cross-file references, impact analysis, change detection, and functional clustering — all locally, with no network calls or GPU.

## Examples

**Quick start — one-shot query (no daemon):**
```bash
$ opty oneshot "authentication error handling" --dir ~/projects/myapp
# indexed 1,247 units across 89 files
functions[5]{name,signature,file,line}:
handleAuthError,pub fn handleAuthError(err: AuthError) !Response {,src/auth.zig,156
validateTokenOrFail,fn validateTokenOrFail(token: []const u8) !User {,src/auth.zig,203
logAuthFailure,fn logAuthFailure(reason: []const u8, ip: []const u8) void {,src/logging.zig,78
```

**Start daemon for instant queries:**
```bash
$ opty daemon ~/projects/myapp &
opty daemon on http://127.0.0.1:7390

$ opty query "HTTP route handlers"
functions[8]{name,signature,file,line}:
handleGetUser,pub fn handleGetUser(req: *Request, res: *Response) !void {,src/routes/users.zig,12
handleCreatePost,pub fn handleCreatePost(req: *Request, res: *Response) !void {,src/routes/posts.zig,45
handleLogin,pub fn handleLogin(req: *Request, res: *Response) !void {,src/routes/auth.zig,23
...

$ opty query "database connection pooling"
functions[3]{name,signature,file,line}:
initPool,pub fn initPool(alloc: Allocator, config: PoolConfig) !Pool {,src/db/pool.zig,34
acquireConnection,pub fn acquireConnection(pool: *Pool) !*Connection {,src/db/pool.zig,67
releaseConnection,pub fn releaseConnection(pool: *Pool, conn: *Connection) void {,src/db/pool.zig,89
```

**Global daemon — works across all projects:**
```bash
$ opty global --port 7390 &

$ cd ~/projects/api-server
$ opty query "error types"        # auto-indexes api-server

$ cd ~/projects/frontend
$ opty query "React components"   # auto-indexes frontend

$ opty status
Project: /home/you/projects/api-server
  Files: 142  Units: 2,891  Memory: 3.6 MB
Project: /home/you/projects/frontend  
  Files: 203  Units: 4,127  Memory: 5.1 MB
```

**Semantic search finds code by concept, not exact names:**
```bash
# Find authentication logic without knowing function names
$ opty query "user login session management"
→ handleLogin, createSession, validateSession, refreshToken

# Discover error handling patterns
$ opty query "handle failures and errors"  
→ handleError, tryParseOrFail, logFailure, unwrapOrDefault

# Explore data structures
$ opty query "user data models"
→ User struct, UserProfile struct, UserSettings struct
```

## When to use opty vs grep

opty and grep solve different problems. Use the right tool for the job:

| Scenario | opty | grep |
|---|---|---|
| "How does indexing work?" | ✅ Returns `scanAndIndex`, `IgnoreFilter`, `watchLoop` | ❌ What would you grep for? |
| Find all uses of `alloc.free` | ❌ Too syntactic | ✅ `grep "alloc.free"` |
| "What types exist?" | ✅ `opty_ast` gives every type with nesting | ⚠️ `grep "pub const.*struct"` is brittle |
| Find where port 7390 is set | ❌ HDC doesn't index literals | ✅ `grep "7390"` |
| "What's the HTTP API surface?" | ✅ Returns route handlers semantically | ⚠️ `grep "router\."` works but misses context |
| Rename a variable | ❌ Wrong tool entirely | ✅ grep to find, edit to replace |

**Rule of thumb:** opty for *understanding*, grep for *locating*, view for *reading*, edit for *changing*.

- **opty** answers conceptual questions — "what handles authentication?", "show me the error handling patterns", "what's the project structure?" — where you don't know the exact symbol names. It returns results across multiple files from a single natural language query.
- **grep** finds exact text — specific strings, regex patterns, symbol references, configuration values. It's the right tool when you know *what* you're looking for.
- **opty_ast** gives the full structural skeleton of a project or file (all functions, types, imports, fields, variables with nesting depth) in one call — useful for orientation before diving into code.

In practice, opty queries use **88-93% fewer tokens** than reading equivalent source files, making it especially useful when feeding context to an LLM.

## What it does

opty extracts **code unit skeletons** — function signatures, type/struct definitions, and import declarations — from source files. It encodes each one into a 10,000-bit binary hypervector, then uses **hybrid search** (HDC + BM25 via reciprocal rank fusion) to match natural language queries against them.

Beyond search, opty builds a **cross-file reference map** linking imports to definitions, enabling impact analysis, symbol context lookups, and change detection.

**What it's good at:**
- **Exploration** — "what handles authentication?" finds `handleAuth`, `validateToken`, `refreshSession` even if your query shares no exact substrings
- **Discovery** — navigating an unfamiliar codebase by concept rather than by name
- **Impact analysis** — "if I change `handleAuth`, what breaks?" shows downstream dependents with confidence scores
- **Code review** — "what symbols changed in this diff?" maps git changes to affected functions and types
- **Architecture** — "what are the subsystems?" clusters related symbols into functional groups
- **Compact overviews** — results come in [TOON format](https://toonformat.dev/), which uses ~60% fewer tokens than JSON, useful when feeding context to an LLM

**What it doesn't do:**
- Index function bodies, comments, or docstrings — only signatures
- Replace grep for exact string matching or regex patterns
- Understand what code *does* — it matches on names, types, and structural tokens

Think of it as a fast, intelligent table of contents for your codebase. You still need to read the actual code to understand it.

## How it works

1. **Parse** — Scans source files and extracts structural elements (functions, types, imports) via pattern matching or [tree-sitter](#tree-sitter-parsing)
2. **Encode** — Maps each code unit to a 10,000-bit binary hypervector using HDC bind/bundle algebra. Splits identifiers (camelCase, snake_case) into sub-tokens for partial matching
3. **Index** — Stores vectors in an in-memory associative memory, builds a BM25 text index and a cross-file reference map
4. **Query** — Hybrid search combines HDC similarity with BM25 keyword matching via reciprocal rank fusion
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

This is most useful as an **exploration and analysis tool** — helping the agent get oriented in a codebase, understand symbol relationships, and assess impact before making changes.

### Tools

| Tool | Description |
|---|---|
| `opty_query` | **Hybrid semantic search** — finds functions/types/imports matching a natural language query using BM25 + HDC with reciprocal rank fusion |
| `opty_refs` | **Cross-file references** — shows where a symbol is defined and which files import it |
| `opty_impact` | **Blast radius analysis** — shows what code is affected if a symbol changes, with confidence scores by depth |
| `opty_context` | **360° symbol context** — returns definition, callers, dependencies, and siblings in one call |
| `opty_changes` | **Change detection** — maps a git diff to affected code symbols (modified/added/deleted) |
| `opty_clusters` | **Functional clustering** — groups related symbols into subsystems by similarity |
| `opty_ast` | **Depth-aware AST** — returns functions, types, imports, fields, variables, and enum variants with nesting depth and line numbers |
| `opty_status` | Index statistics — file count, code unit count, memory |
| `opty_reindex` | Force full re-scan of the codebase |

**`opty_ast` parameters:**

| Parameter | Type | Description |
|---|---|---|
| `file` | string or string[] | Single file path or array of paths (e.g. `"src/main.zig"` or `["src/brain.zig", "src/encoder.zig"]`) |
| `pattern` | string | Glob pattern to filter files (e.g. `"src/*.zig"`, `"src/**/*.ts"`) |
| `cwd` | string | Project working directory (used by global daemon) |

Omit both `file` and `pattern` to get the full project AST. You can combine `file` and `pattern` — results are the union of both.

### Tool examples

**`opty_refs`** — Find where `handleAuth` is defined and who imports it:
```
definitions[1]{name,kind,file,line}:
handleAuth,fn,src/auth.zig,42
references[2]{import_name,file,line}:
handleAuth,src/login.zig,1
handleAuth,src/middleware.zig,3
```

**`opty_impact`** — What breaks if `handleAuth` changes?
```
impact{source:"handleAuth",affected:4,max_depth:2}
depth_0[1]{name,kind,file,line,confidence}:
handleAuth,fn,src/auth.zig,42,1.000
depth_1[2]{name,kind,file,line,confidence}:
loginUser,fn,src/login.zig,15,0.500
checkMiddleware,fn,src/middleware.zig,33,0.500
depth_2[1]{name,kind,file,line,confidence}:
appMain,fn,src/main.zig,10,0.333
```

**`opty_context`** — Everything about `handleAuth` in one call:
```
symbol{name:"handleAuth",kind:fn,file:"src/auth.zig",line:42}
signature: pub fn handleAuth(req: Request) !Response {
referenced_by[2]{name,kind,file,line}:
handleAuth,import,src/login.zig,1
handleAuth,import,src/middleware.zig,3
references[1]{name,kind,file,line}:
validateToken,fn,src/token.zig,8
siblings[2]{name,kind,line}:
refreshSession,fn,56
AuthError,type,12
```

**`opty_changes`** — What symbols were affected by recent changes?
```
changes[3]{name,kind,file,line,change}:
handleAuth,fn,src/auth.zig,42,modified
UserConfig,type,src/config.zig,10,added
oldHelper,fn,src/utils.zig,88,deleted
```

**`opty_clusters`** — Discover functional subsystems:
```
clusters[3]{id,label,size}:
0,auth-handle-token,5
1,database-query-pool,4
2,config-parse-env,3
cluster_0[5]{name,kind,file,line}:
handleAuth,fn,src/auth.zig,42
validateToken,fn,src/auth.zig,87
refreshSession,fn,src/session.zig,23
AuthError,type,src/auth.zig,12
tokenStore,import,src/auth.zig,1
```

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

## Hybrid search

Queries use **reciprocal rank fusion** (RRF) to combine two search methods:

- **HDC similarity** — fuzzy concept matching via Hamming distance on 10,000-bit hypervectors. Good at finding `handleAuth` when you search for "authentication functions" because sub-tokens like `auth` and `handle` overlap.
- **BM25 keyword search** — exact term matching with TF-IDF weighting. Good at boosting results that contain your exact query terms, and handling cases where HDC alone would miss (e.g., searching for "DB" when the code uses "DB" not "database").

RRF merges both ranked lists with the formula `RRF(d) = Σ 1/(k + rank)` where `k=60`, ensuring results that rank well in both methods appear at the top.

## Tree-sitter parsing

opty includes an optional [tree-sitter](https://tree-sitter.github.io/) parsing backend that provides more accurate code extraction than the default pattern-based parser. Tree-sitter correctly handles multi-line signatures, decorators, and other constructs that line-by-line parsing misses.

Currently supported via tree-sitter: **Zig** and **Python**. All other languages use the pattern-based parser. Adding more languages requires vendoring the grammar's C source into `deps/`.

The tree-sitter runtime and grammars are vendored as C source and compiled by `build.zig` — no system dependencies required.

## Supported languages

Zig, TypeScript, JavaScript, Python, Go, Rust, C, C++, Java, Ruby, F#, C#

## Limitations

- **Signatures only** — function bodies, comments, and docstrings are not indexed. You can find `handleAuthError` but not the `if err != nil` inside it.
- **Pattern-based parsing** — most languages use line-by-line pattern matching (Zig and Python can use tree-sitter for better accuracy). Edge cases like multi-line signatures in non-tree-sitter languages may be missed.
- **No learned semantics** — HDC uses random projections, not trained embeddings. "database" and "DB" are unrelated vectors. BM25 hybrid search mitigates this for exact keyword matches, but true synonym understanding requires neural embeddings.
- **Reference resolution is name-based** — cross-file references match import names to definition names. It doesn't resolve full module paths or handle aliased imports.

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
zig build                           # Debug build
zig build -Doptimize=ReleaseFast    # Release build
zig build test                      # Run tests
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

**WSL:** If the service doesn't auto-start after WSL restarts, ensure systemd is enabled in `/etc/wsl.conf`:
```ini
[boot]
systemd=true
```
Then verify linger is enabled: `loginctl show-user $USER | grep Linger=yes`. The updated service file uses `Restart=always` and waits for network to improve WSL compatibility.

### Windows (Task Scheduler)

```powershell
$action = New-ScheduledTaskAction `
    -Execute "$env:USERPROFILE\.local\bin\opty.exe" `
    -Argument "global --port 7390"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "opty-daemon" -Action $action -Trigger $trigger -Settings $settings
```

## Architecture

```
src/
├── main.zig          CLI entry point and HTTP client
├── daemon.zig        Single-project HTTP daemon
├── global.zig        Multi-project HTTP daemon with auto-loading
├── mcp.zig           MCP JSON-RPC server (9 tools)
├── brain.zig         In-memory index (HDC + BM25 + RefMap)
├── hdc.zig           10,000-bit hypervectors, bind/bundle/similarity
├── encoder.zig       CodeUnit → HyperVector encoding
├── parser.zig        Line-by-line code extraction (12 languages)
├── treesitter.zig    Tree-sitter parsing backend (Zig, Python)
├── bm25.zig          BM25 text search + reciprocal rank fusion
├── refs.zig          Cross-file reference resolution
├── impact.zig        Blast radius analysis (BFS on ref graph)
├── context.zig       360° symbol context
├── changes.zig       Git diff → affected symbols
├── cluster.zig       Functional clustering via HDC similarity
├── toon.zig          TOON output formatting
└── ignore.zig        .gitignore support
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
7. [Tree-sitter](https://tree-sitter.github.io/)

## License

MIT
