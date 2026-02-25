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

## Commands

| Command | Description |
|---|---|
| `opty daemon [dir] [--port N]` | Start the daemon (foreground, default port 7390) |
| `opty mcp [dir]` | MCP server over stdio (for AI coding agents) |
| `opty query <text> [--port N]` | Query the running daemon |
| `opty status [--port N]` | Show indexed file/unit counts |
| `opty reindex [--port N]` | Force full re-index |
| `opty stop [--port N]` | Shut down the daemon |
| `opty oneshot <query> [--dir D]` | Index + query in one shot (no daemon) |
| `opty version` | Show version |

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

Drop a `.mcp.json` in your project root:

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

This is picked up automatically by Copilot CLI, Claude Code, Cursor, and other
MCP-aware agents when they open the project. The path `.` means opty indexes
the project directory it's launched from.

For absolute paths (useful when opty is installed globally):

```json
{
  "mcpServers": {
    "opty": {
      "command": "opty",
      "args": ["mcp", "/home/you/projects/myapp"]
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
      "command": "/path/to/opty",
      "args": ["mcp", "/path/to/your/project"]
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
      "command": "/path/to/opty",
      "args": ["mcp", "."]
    }
  }
}
```

### Copilot CLI

Add `.mcp.json` to your project root (see above), then launch `copilot`
from that directory. opty's tools appear automatically. You can also manage
MCP servers with the `/mcp` slash command.

### Generic MCP Client

```bash
# opty speaks JSON-RPC 2.0 over stdio with Content-Length framing
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

Requires Zig 0.15+.

```bash
zig build                    # Debug build
zig build -Doptimize=fast    # Release build
zig build test               # Run tests (11 tests)
```

## Running as a systemd User Service

opty ships with systemd user service files for always-on indexing that survives
reboots and runs in the background.

### Quick Install

```bash
# Build first, then install binary + services
zig build
./systemd/install.sh

# Start watching your default dev directory
systemctl --user enable --now opty-daemon
```

### Watch a Specific Project (Template Instance)

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
ExecStart=%h/.local/bin/opty daemon /path/to/your/project --port 7390
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
