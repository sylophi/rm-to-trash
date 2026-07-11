# rm-to-trash

`rm`, but to the Trash.

A drop-in replacement for `rm(1)` on macOS that moves files to the Trash
instead of permanently unlinking them. Built so that an agent (or you)
fat-fingering `rm -rf` costs a trip to the Trash, not your data.

Single Objective-C file, no dependencies, ~50 KB binary.

## Build & install

```sh
./install.sh                 # builds, installs rmt to ~/.local/bin, symlinks rm -> rmt
./install.sh --no-symlink    # same, but skip the rm symlink
```

`RMT_INSTALL_DIR=...` overrides the destination. Or manually:

```sh
make            # native arch
make universal  # fat binary (arm64 + x86_64)
make install    # installs to /usr/local/bin/rmt (PREFIX=... to override)
make test       # test suite
```

The `rm -> rmt` symlink covers every shell that resolves `rm` through
`PATH`: interactive, non-interactive, agents like Claude Code, scripts,
`make`. No alias is needed. For the symlink to take effect, the install
dir must come **before** `/bin` in `PATH`, so make sure your shell
profile *prepends* it (in `~/.zshrc`, and `~/.bashrc` if you use bash):

```sh
export PATH="$HOME/.local/bin:$PATH"   # prepend: must beat /bin
```

`install.sh` warns if `rm` still resolves to `/bin/rm` after installing.
To really delete something, use `/bin/rm` (note that `\rm` and
`command rm` only bypass aliases, not the symlink). To undo the symlink
later, just delete `~/.local/bin/rm`.

## Compatibility

Supports the full BSD `rm` flag surface with matching error messages,
prompts, and exit codes:

| Flag | Behavior |
|------|----------|
| `-f` | ignore missing files, never prompt, exit 0 if operands are missing |
| `-i` | prompt before each removal (later `-i`/`-f` overrides earlier, like rm) |
| `-I` | prompt once when removing >3 files or recursing |
| `-r` / `-R` | required to remove directories |
| `-d` | remove empty directories without `-r` |
| `-v` | print each operand as it is trashed |
| `-P` | accepted, no effect (same as modern rm) |
| `-W` | accepted; fails with "Operation not supported" (no union mounts on macOS) |
| `-x` | accepted (see caveats) |
| `--` | end of flags |

Also mirrored: refusal to remove `/`, `.`, `..`; the write-protected-file
override prompt on interactive stdin; exit status 1 if any operand fails.

Beyond rm, it refuses to remove the Trash itself (`~/.Trash`, any volume's
`.Trashes`) and anything already inside a Trash, since "trashing" those is
self-destructive or a silent no-op. Use `/bin/rm` (or empty the Trash) to
delete such items permanently. A directory merely named `.Trashes` outside
a volume root is not affected.

## Speed

Two paths, per operand:

1. **Fast path**: item is on the same volume as `~/.Trash` and its name is
   free there: one atomic `renamex_np(..., RENAME_EXCL)`. `RENAME_EXCL`
   makes overwriting an existing Trash item impossible.
2. **Fallback**: name collisions, other volumes, and anything unusual go
   through `-[NSFileManager trashItemAtURL:]`, the same API behind the
   system `trash` command. It uniquifies names and uses per-volume
   `.Trashes`.

Measured on an M3 Pro MacBook Pro, 200 small files:

| | 200 files (1 invocation) | 1 file per invocation |
|---|---|---|
| `rmt` | 44 ms | 5.4 ms |
| `/usr/bin/trash` | 118 ms | 18 ms |
| `/bin/rm` | 30 ms | ~4 ms |

## Caveats (vs. real rm)

- **Recursive removal is a move, not a traversal.** `rm -r dir` trashes the
  whole tree in one rename. Consequences: `-i`/`-v` operate on operands, not
  on every file inside; `-x` can't skip nested mount points (a nested mount
  will simply make the move fail with an error rather than be deleted); no
  permission checks happen for files inside the tree.
- **Finder's "Put Back" is not populated**, the same limitation as the system
  `trash` command. Files are in the Trash and recoverable, but you restore
  them by dragging.
- **Volumes without a trash folder** (some network mounts) produce an error
  instead of deleting. Use `/bin/rm` there deliberately.
- The Trash is not emptied, ever. Disk space is only reclaimed when you
  empty it.
