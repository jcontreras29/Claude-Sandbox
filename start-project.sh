#!/usr/bin/env bash
# Launch the sandbox rooted at a specific project under workspace/,
# so that project's .mcp.json and .claude/settings.local.json are
# discovered correctly (Claude Code only looks at its cwd and ancestors,
# never subdirectories, for .mcp.json).
#
# Any extra arguments are forwarded to the `claude` binary, e.g. to
# resume a previous session:
#
# Usage:
#   ./start-project.sh                          # general mode, lands at /workspace
#   ./start-project.sh <project>                 # project mode, lands at /workspace/<project>
#   ./start-project.sh <project> --resume        # project mode, resume a past session
#   ./start-project.sh <project> --continue      # project mode, continue the most recent session
#   ./start-project.sh --resume                  # general mode, resume a past session

set -euo pipefail
cd "$(dirname "$0")"

# Pull secrets from the host keyring into this shell only; compose passes
# them through by name. Empty if not stored, so the MCP server just fails auth.
SUPABASE_ACCESS_TOKEN="$(secret-tool lookup service supabase account claude-sandbox || true)"
export SUPABASE_ACCESS_TOKEN

GITHUB_PERSONAL_ACCESS_TOKEN="$(secret-tool lookup service github account claude-sandbox || true)"
export GITHUB_PERSONAL_ACCESS_TOKEN


if [ $# -eq 0 ]; then
  exec docker compose run --rm claude
fi

if [ -d "workspace/$1" ]; then
  project="$1"
  shift
  exec docker compose run --rm --workdir "/workspace/$project" claude "$@"
fi

case "$1" in
  -*)
    # Looks like a flag, not a project name - general mode.
    exec docker compose run --rm claude "$@"
    ;;
  *)
    echo "Error: workspace/$1 does not exist." >&2
    echo "Available projects:" >&2
    find workspace -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' >&2
    exit 1
    ;;
esac

