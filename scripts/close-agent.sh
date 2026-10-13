#!/bin/sh
# Close the focused pane, but only when it hosts a coding agent, so the same
# key is harmless on the editor or a plain shell. Bound from Herdr's config as
# a plugin action; the Neovim side has close() for the other direction.
set -eu

herdr="${HERDR_BIN_PATH:-herdr}"
pane="${HERDR_PANE_ID:-}"

if [ -z "$pane" ]; then
  echo "close-agent: no focused pane in the invocation context" >&2
  exit 0
fi

if ! "$herdr" agent get "$pane" >/dev/null 2>&1; then
  echo "close-agent: pane $pane is not an agent pane; leaving it open" >&2
  exit 0
fi

exec "$herdr" pane close "$pane"
