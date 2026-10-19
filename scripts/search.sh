#!/usr/bin/env bash
set -euo pipefail

# Usage: search.sh <team> <keyword> [agent_id] [limit]
# Searches past messages in <team> whose body contains <keyword> (substring
# match; ASCII is case-insensitive). If agent_id given, only that agent's
# messages (sent or received). Shows the newest <limit> matches, oldest first.

TEAM="${1:?Usage: search.sh <team> <keyword> [agent_id] [limit]}"
KEYWORD="${2:?Usage: search.sh <team> <keyword> [agent_id] [limit]}"
AGENT="${3:-}"
LIMIT="${4:-20}"
# A non-numeric limit would otherwise be interpolated straight into the SQL
# text below; fall back to the default rather than passing it through,
# mirroring history.sh (#87).
case "$LIMIT" in ''|*[!0-9]*) LIMIT=20 ;; esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

if [ ! -f "$DB" ]; then
  echo "No messages (DB not initialized)"
  exit 0
fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
# Escape LIKE wildcards (and the escape char itself) so the keyword is matched
# literally: "100%" must not match every body containing "100".
_agmsg_likeesc() { printf %s "$1" | sed -e 's/[\\%_]/\\&/g' -e "s/'/''/g"; }

PATTERN="%$(_agmsg_likeesc "$KEYWORD")%"
WHERE="WHERE team='$(_agmsg_sqlesc "$TEAM")' AND body LIKE '$PATTERN' ESCAPE '\\'"
if [ -n "$AGENT" ]; then
  WHERE="$WHERE AND (from_agent='$(_agmsg_sqlesc "$AGENT")' OR to_agent='$(_agmsg_sqlesc "$AGENT")')"
fi

# Newest <limit> matches, re-sorted oldest first. Escape newlines/tabs in body,
# use unit separator between fields (same record format as history.sh).
RESULT=$(agmsg_sqlite "$DB" "
  SELECT from_agent || char(31) || to_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at || char(31) || CASE WHEN read_at IS NULL THEN '●' ELSE '○' END
  FROM (SELECT * FROM messages $WHERE ORDER BY created_at DESC, id DESC LIMIT $LIMIT)
  ORDER BY created_at ASC, id ASC;
")

if [ -z "$RESULT" ]; then
  echo "No matching messages."
  exit 0
fi

while IFS=$'\x1f' read -r from to body ts status; do
  echo "  $status [$ts] $from → $to: $body"
done <<< "$RESULT"
