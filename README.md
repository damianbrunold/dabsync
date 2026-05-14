# dabsync

A small Python utility for recursively copying or synchronizing directory trees. Single file, standard library only, no install step.

## Why

We needed a simple, consistent way to copy and sync data that behaves the same on both Linux and Windows. Platform-native tools differ (`rsync` is awkward on Windows; `robocopy` doesn't exist on Linux; GUI sync tools introduce their own conventions and dependencies), and most full-featured alternatives bring install requirements that are inconvenient on locked-down or minimal machines. dabsync is a single Python file with no dependencies beyond the standard library, so the same script and the same flags work the same way wherever Python runs.

## Modes

- **`copy`** — additive. Copies files that are missing in the destination, or whose size/mtime differs. Never deletes anything in the destination.
- **`sync`** — mirrors source into destination. Files or directories present in the destination but absent in the source are deleted. After running, source and destination contain the same tree.

## Usage

```
python dabsync.py <copy|sync> <src> <dest> [options]
```

### Options

| Option | Description |
| --- | --- |
| `--dry-run` | Print what would happen without changing the filesystem. |
| `--log-file PATH` | Append output to a log file (line-buffered). |
| `--verbosity N` | `0` silent, `1` per-file (default), `2` also list directories and excluded entries. |
| `--silent` | Shortcut for `--verbosity 0`. |
| `--verbose` | Shortcut for `--verbosity 2`. |
| `--force` | Re-copy every file even if size and mtime match. |
| `--src-newer` | Only overwrite a destination file when the source is strictly newer (1s tolerance). Works in both `copy` and `sync` modes. Adds, deletions (sync), and type-mismatch handling are unaffected. |
| `--exclude PATTERN` | Skip entries whose basename matches the fnmatch pattern. Repeatable. |
| `--` | Stop option parsing (anything after is treated as a positional). |

Unknown long-options exit with status 2.

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
python dabsync.py copy ~/projects /mnt/backup/projects
```

Mirror a folder onto a USB stick, deleting anything on the stick that's no longer in the source:

```
python dabsync.py sync ~/music /media/usb/music
```

Preview what a sync would do without touching anything:

```
python dabsync.py sync --dry-run ~/music /media/usb/music
```

Skip Python build artifacts and VCS metadata:

```
python dabsync.py sync --exclude '__pycache__' --exclude '*.pyc' --exclude '.git' \
    ~/code/myapp /mnt/backup/myapp
```

Quiet run that appends to a log file (handy for cron):

```
python dabsync.py sync --silent --log-file ~/.dabsync.log ~/Documents /mnt/backup/Documents
```

Force a full re-copy regardless of timestamps (e.g. after a filesystem repair):

```
python dabsync.py copy --force ~/photos /mnt/backup/photos
```

Merge an older snapshot into a working folder without clobbering newer edits:

```
python dabsync.py copy --src-newer /mnt/snapshot/notes ~/notes
```

Use `--` when a path begins with `--`:

```
python dabsync.py copy -- --weird-dirname /mnt/backup/weird
```

## Behavior notes

- Change detection compares file size, then mtime with a 1-second tolerance (covers ext4 ↔ FAT/SMB drift). No content hashing.
- Symlinks are preserved (not followed). A symlink in the source is replicated as a symlink in the destination with the same target. Symlink loops therefore do not cause infinite recursion.
- `--dry-run` is safe even when the destination doesn't exist yet — the recursion tolerates missing destination directories instead of crashing.
- By default `copy` and `sync` overwrite whenever source and destination differ, regardless of which is newer. Pass `--src-newer` to restrict overwrites to cases where the source mtime is strictly newer than the destination's.
- **Directory metadata** (mode bits, mtime; ownership when running as root on POSIX) is preserved on newly created destination directories via `shutil.copystat`. Failures are logged and skipped, not fatal.
- **Windows long paths** (>260 chars) are handled by transparently prefixing absolute paths with `\\?\` (or `\\?\UNC\` for UNC paths). No-op on non-Windows.
- **Unicode filenames**: a name that is valid on the source filesystem but cannot be encoded on the destination (e.g. a Linux filename with non-UTF-8 bytes copied to NTFS) is logged and skipped per-entry; the rest of the run continues. There is no fully reliable cross-platform fix — surrogate / non-Unicode bytes simply cannot exist on Windows. If this matters to you, normalize names on the source side first (e.g. `convmv`).

## Tests

```
python -m unittest test_dabsync
```

## License

See [LICENSE](LICENSE).
