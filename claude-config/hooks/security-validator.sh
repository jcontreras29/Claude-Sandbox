#!/bin/bash
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Block exfiltration attempts
if echo "$COMMAND" | grep -qE '\b(curl|wget|nc|ncat|scp|rsync|ssh|telnet)\b'; then
  echo "Blocked: Network tool not allowed in bash. Use WebFetch instead." >&2
  exit 2
fi

# Block destructive operations
if echo "$COMMAND" | grep -qE '\brm\b.*-rf\s+/|\bsudo\b|\bchmod\b\s+777|\bmkfs\b|\bdd\b\s+if='; then
  echo "Blocked: Destructive command." >&2
  exit 2
fi

# Block secret reading via bash (defence in depth with Layer 1)
if echo "$COMMAND" | grep -qE '\b(cat|less|more|head|tail|bat)\b.*(\.env\b|credentials|\.pem\b|\.key\b|id_rsa)'; then
  echo "Blocked: Attempt to read secret file via bash." >&2
  exit 2
fi

exit 0
