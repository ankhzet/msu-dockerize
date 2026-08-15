# Operations - common workflows

## Day-to-day

Use the wrapper scripts:

```powershell
# Initialize the stack (one-time)
.\scripts\mangos.ps1 init
.\scripts\mangos.ps1 cache
.\scripts\mangos.ps1 build

# Bring it up
.\scripts\mangos.ps1 up

# Watch logs
.\scripts\mangos.ps1 logs
.\scripts\mangos.ps1 logs -Service superui
.\scripts\mangos.ps1 logs -Service mangosd

# Status
.\scripts\mangos.ps1 status

# Restart just one service (after editing a config)
docker compose --profile core restart superui

# Shell into a container
.\scripts\mangos.ps1 shell -Service superui
```

## Database operations

```powershell
# Status check
.\scripts\mangos.ps1 db-status

# Replace the world DB
.\scripts\mangos.ps1 down
.\scripts\mangos.ps1 db-std   # or db-full / db-from C:\path\to\world.7z
.\scripts\mangos.ps1 up
```

## Backups

All backups go to `./backups/` (mapped to `/var/mangossuperui/backups` in the UI container).

The UI's **Backup & Restore** page creates one-click snapshots of:
- Game World databases (the `mangos` schema)
- Characters (`characters` schema)
- Core Source (the server binaries)

For manual backups:

```bash
# From the host, while the stack is running
docker compose exec mariadb \
    sh -c 'exec mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" mangos' \
    > backups/mangos-$(date +%Y%m%d-%H%M%S).sql
```

## Upgrading

```powershell
# 1. Pull new artifacts
.\scripts\download-artifacts.ps1 -Force

# 2. Pin the new version in .env
notepad .env   # set MANGOS_SUPER_UI_VERSION=v1.3

# 3. Rebuild and restart
.\scripts\mangos.ps1 build
.\scripts\mangos.ps1 up
```

## Memory tuning

If your DB grows large, the default `innodb-buffer-pool-size=512M` may be too small. Edit `docker-compose.yml`:

```yaml
mariadb:
  command:
    - --innodb-buffer-pool-size=2G
```

Restart: `docker compose --profile core restart mariadb`.

## Network access

The UI is exposed on `${UI_HTTP_PORT}` (default 5000). To put it behind a reverse proxy:

```yaml
# Add to docker-compose.yml
nginx:
  image: nginx:alpine
  ports:
    - "80:80"
    - "443:443"
  volumes:
    - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    - ./certs:/etc/nginx/certs:ro
  depends_on:
    - superui
  networks:
    - superui-net
```

## Public exposure

**Do not expose the RA port (3443) publicly.** It's an admin console with
insecure plaintext auth. The compose file binds it to `127.0.0.1` only.

If you must expose the UI to the internet, **definitely** put it behind a
TLS-terminating proxy and add authentication (the upstream UI has no auth).

## Reset

```powershell
# Stops containers AND deletes all volumes (mangos DB, server data, UI cache)
.\scripts\mangos.ps1 reset
```

## Custom world DB

If you have a custom world DB SQL file (e.g. a community fork):

```bash
./scripts/init-database.sh --from /path/to/custom-world.sql
```

You can also point at a URL:

```bash
# In .env
WORLD_DB_MODE=https://example.com/my-custom-world.sql
```

## Common issues

### "Cannot connect to mangosd" in the UI

Check whether mangosd is actually running:

```bash
docker compose --profile core logs mangosd | tail -n 50
```

Most common cause: the world DB is empty. Run `init-database.sh --standard`.

### "vmangos_admin access denied"

```bash
./scripts/init-database.sh --bare   # re-grants privileges
docker compose --profile core restart superui
```

### UI shows red for "DBC" / "Maps"

Mount your WoW 1.12.1 client data. Set `WOW_CLIENT_DATA` in `.env` to the
host path containing `dbc/`, `maps/`, `vmaps/`, `mmaps/`, then restart:

```bash
docker compose --profile core up -d
```

### Slowdowns / lag

In `.env`, increase MariaDB buffer pool:

```yaml
# Edit docker-compose.yml -> mariadb.command
- --innodb-buffer-pool-size=2G
```

For the world server, drop the `cap_add: SYS_NICE` line if the host
doesn't support it (it gives mangosd a higher process priority).

## MCP server (LLM agent surface)

The MSUI web app exposes a stateless Streamable HTTP MCP server on the
existing UI port at `http://localhost:5000/mcp`. Any MCP-compatible
client (Claude Desktop, VS Code Copilot, Cursor, Zed, Claude Code CLI)
can connect — see `docs/examples/` for copy-paste mcp.json configs.

```powershell
# Smoke-test the live endpoint with your bearer token
$env:MCP_TOKEN = (Get-Content .env | Select-String '^MCP_AUTH_TOKEN=' | ForEach-Object { $_.ToString().Split('=', 2)[1] })
.\scripts\test-mcp.ps1

# Assert the per-class tool catalogue matches what shipped (215 tools)
.\scripts\audit-mcp.ps1

# Call a tool directly from a Python client
$env:MSUI_TOKEN = $env:MCP_TOKEN
python scripts/mcp-client.py home_status
python scripts/mcp-client.py ra_list_online
```

### Token capabilities

`MCP_TOKENS_JSON` (preferred) accepts a JSON array of `{token, label, capabilities[]}`
to mint scoped tokens. See [`MCP.md`](MCP.md#capability-matrix) for the
10-tag grid (`read`, `ra`, `process`, `write_db`, `worlds`, `bots`, `patches`,
`baseline`, `lootifier`, `retexture`).

### Common operations

- "What just happened on the server?" → call `home_status` + `home_db_health` + `home_diagnose`.
- "Is bot X questing properly?" → call `bot_state <guid>` + `bot_live_state <guid>`.
- "What spells did player Y edit?" → `audit_target_history` with `targetType="player"`, `targetName="Y"`.
- "Revert last 24h of item edits" → `changegraph_overview` (filter `Days=1`, `Show="revertable"`) → `changegraph_revert_batch`.
