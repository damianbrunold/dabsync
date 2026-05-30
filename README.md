# dabsync

A small utility for recursively copying or synchronizing directory trees. Single file, no install step. Written in Scheme and run with the [dabscm](https://github.com/dab/dabscm) interpreter (`scm`, or `scmj` for the Java build).

## Why

We needed a simple, consistent way to copy and sync data that behaves the same on Linux, Windows and macOS. Platform-native tools differ (`rsync` is awkward on Windows; `robocopy` doesn't exist on Linux; GUI sync tools introduce their own conventions and dependencies), and most full-featured alternatives bring install requirements that are inconvenient on locked-down or minimal machines. dabsync is a single self-contained script, so the same script and the same flags work the same way wherever dabscm runs.

> A Python version of this tool lived on `main` until the Scheme port replaced it. The last Python-only state is preserved on the `legacy-python` branch.

## Modes

- **`copy`** — additive. Copies files that are missing in the destination, or whose size/mtime differs. Never deletes anything in the destination.
- **`sync`** — mirrors source into destination. Files or directories present in the destination but absent in the source are deleted. After running, source and destination contain the same tree.

## Usage

```
scm dabsync.scm <copy|sync> <src> <dest> [options]
```

The destination's parent must exist; dabsync creates the destination subtree, not arbitrary leading directories.

### Options

| Option | Description |
| --- | --- |
| `--dry-run` | Print what would happen without changing the filesystem. |
| `--log-file PATH` | Append output to a log file. |
| `--verbosity N` | `0` silent, `1` per-file (default), `2` also list directories and excluded entries. |
| `--silent` | Shortcut for `--verbosity 0`. |
| `--verbose` | Shortcut for `--verbosity 2`. |
| `--force` | Re-copy every file even if size and mtime match. |
| `--src-newer` | Only overwrite a destination file when the source is strictly newer (1s tolerance). Works in both `copy` and `sync` modes. Adds, deletions (sync), and type-mismatch handling are unaffected. |
| `--exclude PATTERN` | Skip entries whose basename matches the glob pattern. Repeatable. |
| `--` | Stop option parsing (anything after is treated as a positional). |

Unknown long-options exit with status 2; an unknown mode exits 2; too few positional arguments prints usage and exits 1.

### Output markers

Per-file lines are prefixed:

- `+` added
- `-` deleted (sync only)
- `*` updated (copy mode)
- `x` type-mismatch replacement (sync mode: file ↔ directory)
- `=` excluded (only at verbosity 2)

A bare path (no prefix) is an updated file in sync mode, or a directory being traversed at verbosity 2.

## Examples

Copy a project into a backup folder, only adding new or changed files:

```
scm dabsync.scm copy ~/projects /mnt/backup/projects
```

Mirror a folder onto a USB stick, deleting anything on the stick that's no longer in the source:

```
scm dabsync.scm sync ~/music /media/usb/music
```

Preview what a sync would do without touching anything:

```
scm dabsync.scm sync --dry-run ~/music /media/usb/music
```

Skip build artifacts and VCS metadata:

```
scm dabsync.scm sync --exclude '__pycache__' --exclude '*.pyc' --exclude '.git' \
    ~/code/myapp /mnt/backup/myapp
```

Quiet run that appends to a log file (handy for cron):

```
scm dabsync.scm sync --silent --log-file ~/.dabsync.log ~/Documents /mnt/backup/Documents
```

Force a full re-copy regardless of timestamps (e.g. after a filesystem repair):

```
scm dabsync.scm copy --force ~/photos /mnt/backup/photos
```

Merge an older snapshot into a working folder without clobbering newer edits:

```
scm dabsync.scm copy --src-newer /mnt/snapshot/notes ~/notes
```

Use `--` when a path begins with `--`:

```
scm dabsync.scm copy -- --weird-dirname /mnt/backup/weird
```

## Behavior notes

- Change detection compares file size, then mtime with a 1-second tolerance (covers ext4 ↔ FAT/SMB drift). No content hashing.
- Symlinks are preserved (not followed). A symlink in the source is replicated as a symlink in the destination with the same target. Symlink loops therefore do not cause infinite recursion.
- `--dry-run` is safe even when the destination doesn't exist yet — the recursion tolerates missing destination directories instead of crashing.
- By default `copy` and `sync` overwrite whenever source and destination differ, regardless of which is newer. Pass `--src-newer` to restrict overwrites to cases where the source mtime is strictly newer than the destination's.
- **Directory metadata** (mtime) is propagated to newly created destination directories. Failures are best-effort, not fatal.
- **Windows long paths** (>260 chars) are handled transparently inside the dabscm filesystem primitives. No-op on non-Windows.
- Per-entry errors (an unreadable file, a name the destination filesystem cannot represent) are logged and skipped; the rest of the run continues.

## Tests

The test suite is black-box: it invokes `dabsync.scm` as a subprocess and checks the resulting filesystem, exit codes and output. Run it from the project root with either interpreter:

```
scm  test-dabsync.scm
scmj test-dabsync.scm
```

## License

See [LICENSE](LICENSE).
