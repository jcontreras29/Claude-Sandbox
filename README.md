# Claude Code Sandbox

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) inside a locked-down Docker container on your Linux machine. Claude can only see the project you give it, can only reach an explicit list of internet domains, and can't turn its own guardrails off.

It's built on the same ideas as Anthropic's official [devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) (the firewall script is adapted from it), but it's packaged for the terminal with plain `docker compose`. You don't need VS Code. It adds a few extra layers on top:

- a read-only container filesystem
- a tamper-proof managed policy with a Bash guard hook
- Plan Mode by default
- secrets pulled from your host keyring instead of `.env` files
- per-project MCP servers

## What's in the box

```
.
├── Dockerfile                 # node:22 + Claude Code + firewall tooling
├── compose.yaml               # hardened container definition
├── start-project.sh           # launcher: loads secrets, picks the project dir
├── claude-config/
│   ├── docker-entrypoint.sh   # sets up firewall as root, then drops to `node`
│   ├── init-firewall.sh       # iptables + ipset egress allowlist
│   ├── managed-settings.json  # baked-in policy (Plan Mode, hook, managed-hooks-only)
│   └── hooks/
│       └── security-validator.sh  # PreToolUse hook for Bash commands
├── workspace/                 # your projects (git-ignored, you create it)
└── claude-home/               # Claude's ~/.claude: login, history (git-ignored)
```

## Security model

The sandbox uses several layers. No single one is perfect, so they're meant to back each other up.

| Layer | What it does | Where |
|---|---|---|
| **Egress firewall** | Default-deny outbound traffic. Only allowlisted domains, GitHub's published IP ranges, DNS and the Docker host network get through. At startup the script checks that `example.com` is blocked and `api.github.com` is reachable, and the container refuses to start if either check fails. | `claude-config/init-firewall.sh` |
| **Privilege drop** | The entrypoint runs the firewall setup as root, then `setpriv`s to the unprivileged `node` user before it execs `claude`. The agent process ends up with zero capabilities, so it can't change iptables or ipset. | `claude-config/docker-entrypoint.sh` |
| **Read-only filesystem** | `read_only: true`. The only writable places are `/workspace` (your projects), `/home/node/.claude` (Claude's state) and a 1 GB `/tmp` tmpfs. | `compose.yaml` |
| **Container hardening** | `cap_drop: ALL` (only the four capabilities the startup needs are added back), `no-new-privileges`, `pids_limit: 512`, an isolated bridge network. | `compose.yaml` |
| **Managed policy** | `/etc/claude-code/managed-settings.json` is baked into the read-only image and takes precedence over every user or project setting. It starts every session in **Plan Mode** and sets `allowManagedHooksOnly`, so a project can't add or override hooks. | `claude-config/managed-settings.json` |
| **Bash guard hook** | Blocks Bash commands that use network tools (`curl`, `wget`, `nc`, `ssh`, `scp`, `rsync`, `telnet`…), destructive commands (`rm -rf /`, `sudo`, `chmod 777`, `mkfs`, `dd if=`), and attempts to `cat`/`head`/`tail` secret-looking files (`.env`, `.pem`, `.key`, `id_rsa`, `credentials`). | `claude-config/hooks/security-validator.sh` |
| **Secrets from the keyring** | Tokens live in your desktop keyring. `start-project.sh` reads them with `secret-tool` into its own shell only, and compose passes them into the container **by name**. No secret is ever written to a file in this repo. | `start-project.sh`, `compose.yaml` |

## Requirements

- **A Linux host.** The keyring integration uses `secret-tool`, and the firewall relies on Docker's Linux networking. It may work under WSL2 or Docker Desktop, but that hasn't been tested.
- **Docker** with the Compose v2 plugin (`docker compose`).
- **libsecret's CLI** and a running keyring (GNOME Keyring, KWallet, or another Secret Service provider):
  - Debian/Ubuntu: `sudo apt install libsecret-tools`
  - Fedora: `sudo dnf install libsecret`
  - Arch: `sudo pacman -S libsecret`
- A Claude account (Pro/Max/Team/Enterprise) or an Anthropic API key.

## Quick start

```bash
git clone https://github.com/<you>/<this-repo>.git claude-sandbox
cd claude-sandbox
mkdir -p workspace claude-home

docker compose build
./start-project.sh          # general mode, lands in /workspace
```

When you launch it for the first time, Claude Code asks you to log in. Your login and conversation history are saved in `./claude-home`, so they survive container restarts and reboots.

### Launch modes

```bash
./start-project.sh                       # general mode (/workspace)
./start-project.sh my-app                # project mode (/workspace/my-app)
./start-project.sh my-app --resume       # pick a previous session for that project
./start-project.sh my-app --continue     # resume the most recent one
./start-project.sh --resume              # general mode, resume
```

Any arguments after the project name are passed straight to `claude`. Session history is keyed by working directory, so resume with the same project name you used before.

## Adding a project

Put (or clone) the project into `workspace/`:

```bash
git clone https://github.com/you/my-app.git workspace/my-app
./start-project.sh my-app
```

Use **project mode** for anything with its own config. Claude Code only finds `.mcp.json` and `.claude/settings.local.json` in its current directory and the directories above it, never below. So general mode won't load any project's MCP servers.

### Per-project MCP servers with `${VAR}` secrets

Each project defines its MCP servers in its own `.mcp.json`. Reference secrets by environment variable and never paste the token itself:

```json
{
  "mcpServers": {
    "supabase": {
      "command": "npx",
      "args": [
        "-y", "@supabase/mcp-server-supabase@latest",
        "--read-only",
        "--project-ref=<your-project-ref>"
      ],
      "env": {
        "SUPABASE_ACCESS_TOKEN": "${SUPABASE_ACCESS_TOKEN}"
      }
    }
  }
}
```

Claude Code expands `${SUPABASE_ACCESS_TOKEN}` from the container environment when it launches the server.

## Managing secrets

Secrets go from the keyring to `start-project.sh`, then to `docker compose` (by name), then into the container's environment, where `.mcp.json` picks them up with `${VAR}`.

**1. Store the secret** in your keyring once:

```bash
secret-tool store --label="Claude sandbox: GitHub" service github account claude-sandbox
# paste the token when prompted
```

**2. Load it** in `start-project.sh`:

```bash
GITHUB_PERSONAL_ACCESS_TOKEN="$(secret-tool lookup service github account claude-sandbox || true)"
export GITHUB_PERSONAL_ACCESS_TOKEN
```

**3. Pass it through by name** in `compose.yaml`. Use just the variable name, with no `=value`:

```yaml
environment:
  - GITHUB_PERSONAL_ACCESS_TOKEN
```

If a secret isn't stored, the variable comes through empty and only the MCP server that needs it fails to authenticate. Everything else still starts.

> Plain `docker compose run --rm claude` skips the keyring step, so MCP servers that need secrets won't authenticate. Use `start-project.sh`.

## Adding firewall domains

Everything not on the allowlist is rejected. To allow a new domain:

1. Add it to the `for domain in` list in `claude-config/init-firewall.sh`.
2. **Rebuild:** `docker compose build`. The script is baked into the image, so editing the file and restarting isn't enough.
3. Relaunch.

The default allowlist:

| Domain | Why |
|---|---|
| GitHub (published `web`/`api`/`git` IP ranges) | git clone/fetch/push, GitHub API |
| `api.anthropic.com` | Claude Code itself (required) |
| `registry.npmjs.org` | npm / npx installs |
| `sentry.io`, `statsig.com` | Claude Code error reporting and telemetry |
| `api.githubcopilot.com` | GitHub's hosted MCP server (example below) |
| *project examples*: `api.supabase.com`, `supabase.com`, `expo.dev`, `api.expo.dev`, `exp.host`, `developer.repebble.com`, `developer.rebble.io` | Supabase MCP, Expo/EAS, Pebble SDK docs. Remove the ones you don't need. |

To test a host from inside the sandbox (the hook blocks `curl` in Bash, so use Node):

```bash
node -e 'fetch("https://HOST").then(r=>console.log(r.status)).catch(e=>console.error(e))'
```

## Adding an MCP server

Do **both** steps below. If you skip the second, the server will fail without a clear error.

1. **Add it to the project's `.mcp.json`.**
2. **Allowlist every domain its runtime traffic needs**, not just npm and its main API host. Some servers call several unrelated domains. For example, one Supabase MCP tool fetches a GraphQL schema from `supabase.com/docs` even though its API lives at `api.supabase.com`. To find the full list, install the package once and grep its source for hostnames, or drive it through `/mcp` and watch for `fetch failed` errors.
3. `docker compose build`, relaunch in project mode, and check `/mcp`. Make sure it connects *and* that calling a tool works. A server can connect over stdio fine and still fail when a tool makes its first network call.

### Example: GitHub's hosted MCP server, read-only

Store a [fine-grained GitHub token](https://github.com/settings/personal-access-tokens) in the keyring as shown above. Ideally give it read-only scopes on just the repos you need. Then add:

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "headers": {
        "Authorization": "Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}",
        "X-MCP-Readonly": "true"
      }
    }
  }
}
```

`api.githubcopilot.com` is already on the allowlist. The `X-MCP-Readonly` header limits the server to read-only tools, and a read-only token enforces the same limit on GitHub's side.

## Customizing the image

Need a toolchain such as a language server or an SDK? Install it in the `Dockerfile` at **build time**. At runtime the filesystem is read-only, the firewall blocks most download hosts, and the hook blocks `curl | sh` installers. During `docker compose build` none of these are active yet, so downloads work normally. Put heavy installs *above* the `npm install -g @anthropic-ai/claude-code` layer, so updating Claude doesn't redo them.

To update Claude Code itself: `docker compose build --no-cache`.

## Debug shell

```bash
docker compose run --rm --entrypoint bash claude
```

This skips the entrypoint, so it runs **as root with no firewall**. It's meant for a human to troubleshoot with, and the agent can't reach it from inside a session. Don't run Claude from this shell.

## Limitations

This is defense in depth, not a perfect security boundary. Know what it doesn't cover:

- **DNS is open.** UDP 53 is allowed to any destination, so DNS tunneling could leak small amounts of data. The upstream reference firewall makes the same tradeoff.
- **IPs are resolved once at startup.** CDN-backed domains that rotate IPs can fail intermittently until you restart. Some GitHub CDN hosts (`codeload.github.com`, `objects.githubusercontent.com`) may not be covered by the meta ranges. Add them if something breaks.
- **The Bash hook is pattern-based** and easy to get around (for example, `node -e` or `python3 -c` making network calls). It catches casual mistakes. The firewall is what actually stops traffic to other destinations.
- **Allowed domains are still exits.** Anything Claude can reach, such as GitHub, can receive data. Keep tokens scoped (read-only where you can) and don't allowlist domains you don't need.
- **Plan Mode is a default, not a lock.** Launching with `claude --permission-mode bypassPermissions` overrides it. The scripts here never pass that flag.
- **`/workspace` is writable.** Claude can modify or delete anything in your projects. Use git and commit often.
- **Secrets inside the container are visible to the agent.** Any MCP token you pass in can be read by Claude, and it can end up in session transcripts under `claude-home/`. Use scoped tokens, and rotate any token you've ever pasted directly into a file or chat.
- Tested on Linux only. A container is not a VM: a kernel or Docker escape bypasses all of this.

## Credits

The firewall is adapted from Anthropic's reference [`init-firewall.sh`](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh).

## License

MIT. See [LICENSE](LICENSE).
