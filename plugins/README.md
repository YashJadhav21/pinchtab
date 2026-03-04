# PinchTab SMCP Plugins

This directory contains MCP (SMCP) plugins for use with [sanctumos/smcp](https://github.com/sanctumos/smcp) or compatible MCP servers.

## pinchtab

Full SMCP plugin for the PinchTab HTTP API: navigate, snapshot, action, text, screenshot, PDF, instances, tabs, and more.

- **Location:** `pinchtab/`
- **Discovery:** `python cli.py --describe` (JSON with plugin + commands)
- **Tests:** `cd pinchtab && python -m venv .venv && .venv/bin/pip install pytest && .venv/bin/pytest tests/ -v`

See [pinchtab/README.md](pinchtab/README.md) for usage and SMCP compatibility notes.
