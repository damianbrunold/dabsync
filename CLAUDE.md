# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

dabsync is a single-file Python utility (`dabsync.py`) for recursively copying or synchronizing directory trees. No dependencies beyond the Python standard library. Tests live in `test_dabsync.py`.

## Running

```
python dabsync.py <copy|sync> <src> <target> [options]
```

Options (parsed by `_parse_argv`): `--dry-run`, `--log-file <path>`, `--verbosity <0|1|2>`, `--silent`, `--verbose`, `--force`, `--exclude <pattern>` (repeatable, fnmatch on basename), `--` (stop option parsing). Unknown `--foo` flags exit with status 2.

## Tests

```
python -m unittest test_dabsync
```

## Architecture

Two top-level operations, both recursive over directory contents:

- `copy(src, dest, options)` — additive only. Copies files that are missing in dest, or whose size/mtime differ. Never deletes.
- `sync(src, dest, options)` — makes dest mirror src. Walks the union of entries in both sides; deletes anything in dest not present in src, and handles file↔directory type mismatches by removing the dest entry and recreating.

File-change detection in both modes compares `st_size`, then `st_mtime` with a 1-second tolerance via `_needs_copy` (covers ext4↔FAT/SMB drift). `--force` forces overwrite regardless. `shutil.copy2` preserves mtime so subsequent runs are idempotent.

Symlinks are preserved (not followed): `_copy_symlink` replicates them via `os.readlink`/`os.symlink`. Type-mismatched dest entries are removed before recreation.

`_list_dir_safe` returns `[]` when the path is missing under `--dry-run`, which is what makes dry-run safe against trees where dest doesn't exist yet.

Output convention via `printlog`: `+` added, `-` deleted, `*` updated (copy mode), `x` type-mismatch replacement (sync mode), `=` excluded (verbosity 2); plain path = updated file in sync mode or directory traversal at verbosity 2.

The module-level `log` global is assigned only inside `__main__` — `printlog` reads it but never rebinds it, so importing this module as a library will not log to a file.
