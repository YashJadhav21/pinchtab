# PinchTab SMCP Plugin

SMCP (MCP) plugin for [PinchTab](https://github.com/pinchtab/pinchtab): browser control for AI agents via HTTP API.

## Requirements

- Python 3.9+
- A running PinchTab server (orchestrator on port 9867 or direct instance on 9868+)
- No extra Python dependencies (uses stdlib only)

## SMCP Compatibility

- **Discovery:** `python cli.py --describe` returns JSON with `plugin` and `commands`.
- **Tool names:** SMCP registers tools as `pinchtab__<command>` (e.g. `pinchtab__navigate`, `pinchtab__snapshot`).
- **Execution:** SMCP runs `python cli.py <command> --arg1 val1 ...`; plugin prints a single JSON object to stdout.
- **Parameters:** All options use `--kebab-case`; SMCP maps from tool args to CLI args.

## Commands

| Command | Description |
|--------|-------------|
| `health` | Health check |
| `instances` | List instances (orchestrator) |
| `instance-start` | Start an instance (optional profile-id, mode, port) |
| `instance-stop` | Stop an instance |
| `tabs` | List tabs |
| `navigate` | Navigate to URL |
| `snapshot` | Get accessibility tree (filter, format, selector, max-tokens, diff) |
| `action` | Single action: click, type, press, focus, fill, hover, select, scroll |
| `actions` | Batch actions (JSON array) |
| `text` | Extract page text |
| `screenshot` | Take screenshot |
| `pdf` | Export tab to PDF |
| `evaluate` | Run JavaScript |
| `cookies-get` | Get cookies |
| `stealth-status` | Stealth/fingerprint status |

## Usage

- **Base URL:** `--base-url http://localhost:9867` (default). Use orchestrator URL or direct instance URL.
- **Orchestrator + instance:** When using the orchestrator, pass `--instance-id inst_xxxx` for instance-scoped calls (navigate, snapshot, action, etc.).
- **Token:** `--token YOUR_TOKEN` when PinchTab is protected with `BRIDGE_TOKEN`.

## Example (SMCP tool call)

Agent calls tool `pinchtab__navigate` with args:
`{"base_url": "http://localhost:9867", "instance_id": "inst_0a89a5bb", "url": "https://example.com"}`

SMCP runs:
`python cli.py navigate --base-url http://localhost:9867 --instance-id inst_0a89a5bb --url https://example.com`

Plugin prints to stdout:
`{"status": "success", "data": {...}}`
