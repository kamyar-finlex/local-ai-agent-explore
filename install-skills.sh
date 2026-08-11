#!/usr/bin/env bash
# Install this repo's Hermes skills into the agent's data directory.
#
#   ./install-skills.sh
#
# The agent reads skills from its own data directory, which is a host bind mount
# and is deliberately NOT part of this repository -- it holds the agent's memory
# and sessions. So the skills live here, under version control, and are copied
# into place. Re-run after editing one.
#
# Copying rather than symlinking on purpose: the container sees the data
# directory through a bind mount, and a symlink pointing outside it would dangle
# inside the container.

set -euo pipefail
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE_DIR/local.env" ] && . "$HERE_DIR/local.env"

SRC="$HERE_DIR/hermes-skills"
DEST="${HERMES_DATA:-$HOME/.hermes}/skills"

[ -d "$SRC" ]  || { echo "no hermes-skills/ directory here" >&2; exit 1; }
[ -d "$DEST" ] || { echo "agent skills directory not found: $DEST" >&2; exit 1; }

installed=0
# Skills are grouped one level deep (category/skill-name/SKILL.md), matching the
# layout the agent's bundled skills already use.
while IFS= read -r skill; do
  rel="${skill#"$SRC"/}"
  target="$DEST/$rel"
  mkdir -p "$(dirname "$target")"
  rm -rf "$target"
  cp -R "$skill" "$target"
  echo "  installed  $rel"
  installed=$((installed+1))
done < <(find "$SRC" -mindepth 2 -maxdepth 2 -type d)

echo
echo "$installed skill(s) into $DEST"
echo "Restart the agent so it rescans:  docker compose restart hermes"
