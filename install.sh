#!/bin/sh
set -eu

DEST="${RMT_INSTALL_DIR:-$HOME/.local/bin}"
DIR="$(cd "$(dirname "$0")" && pwd)"
SYMLINK=1

for arg in "$@"; do
  case "$arg" in
    --no-symlink) SYMLINK=0 ;;
    -h|--help)
      echo "usage: install.sh [--no-symlink]" >&2
      echo "  --no-symlink  don't create the rm -> rmt symlink" >&2
      exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 1 ;;
  esac
done

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

if [ "$SYMLINK" = 1 ]; then
  # rm -> rmt covers every shell, interactive or not, via PATH resolution.
  # No alias needed (aliases would only apply to interactive shells anyway).
  if [ -e "$DEST/rm" ] && [ "$(readlink "$DEST/rm" || true)" != "rmt" ]; then
    echo "Warning: $DEST/rm exists and is not a symlink to rmt; leaving it alone." >&2
  else
    ln -sf rmt "$DEST/rm"
    echo "Symlinked $DEST/rm -> rmt (delete the link to opt out later)" >&2
  fi
fi

case ":$PATH:" in
  *":$DEST:"*)
    # In PATH, but the symlink only takes effect if DEST precedes /bin.
    if [ "$(command -v rm)" != "$DEST/rm" ] && [ "$SYMLINK" = 1 ]; then
      echo "Note: $DEST is in \$PATH but not ahead of /bin, so 'rm' still" >&2
      echo "resolves to $(command -v rm). Prepend it in your shell profile:" >&2
      echo "  export PATH=\"$DEST:\$PATH\"" >&2
    fi ;;
  *)
    echo "Note: $DEST is not in \$PATH. Prepend it in your shell profile:" >&2
    echo "  export PATH=\"$DEST:\$PATH\"" >&2 ;;
esac
