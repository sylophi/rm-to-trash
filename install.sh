#!/bin/sh
set -eu

DEST="${RMT_INSTALL_DIR:-$HOME/.local/bin}"
DIR="$(cd "$(dirname "$0")" && pwd)"

OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
  echo "rmt is macOS-only (needs the system Trash APIs), got: $OS" >&2
  exit 1
fi

echo "Building rmt..." >&2
make -s -C "$DIR" rmt

mkdir -p "$DEST"
install -m 755 "$DIR/rmt" "$DEST/rmt"
echo "Installed rmt to $DEST/rmt" >&2

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "Note: $DEST is not in \$PATH. Add it to your shell profile to use rmt." >&2 ;;
esac

echo "To use as rm, add to your shell profile:  alias rm='rmt'" >&2
