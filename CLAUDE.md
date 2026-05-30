# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

dabsync is a single-file Scheme utility (`dabsync.scm`) for recursively copying or synchronizing directory trees. It runs under the dabscm interpreter (`scm`, or `scmj` for the Java build) and uses only that runtime's standard libraries. Tests live in `test-dabsync.scm`.

The tool was originally a Python script. The Scheme port replaced it on `main`; the last Python-only state is preserved on the `legacy-python` branch.

## Running

```
scm dabsync.scm <copy|sync> <src> <target> [options]
```

Options (parsed by `parse-argv`): `--dry-run`, `--log-file <path>`, `--verbosity <0|1|2>`, `--silent`, `--verbose`, `--force`, `--src-newer`, `--exclude <pattern>` (repeatable, glob on basename), `--` (stop option parsing). Unknown `--foo` flags exit with status 2; an unknown mode exits 2; fewer than three positionals prints usage and exits 1.

## Tests

The suite is **black-box**: it invokes `dabsync.scm` as a subprocess (via `run-program/capture` from `(scm system)`) and asserts on the resulting filesystem, exit codes and captured output — it does not import dabsync's internals. The interpreter is chosen to match the one running the tests (`sys-scm-technology`), overridable with `DABSYNC_SCM` / `DABSYNC_SCRIPT`.

```
scm  test-dabsync.scm
scmj test-dabsync.scm
```

## Architecture

`dabsync.scm` is self-contained: core logic (logging, options, copy/sync) followed by the CLI (`usage`, `parse-argv`, `main`), which runs on load via `(main (cdr (command-line)))`.

Two top-level operations, both recursive over directory contents:

- `copy(src, dest, options)` — additive only. Copies files that are missing in dest, or whose size/mtime differ. Never deletes.
- `sync(src, dest, options)` — makes dest mirror src. Walks the union of entries in both sides; deletes anything in dest not present in src, and handles file↔directory type mismatches by removing the dest entry and recreating.

File-change detection in both modes compares size, then mtime with a 1000ms tolerance via `needs-copy?` (covers ext4↔FAT/SMB drift). `--force` forces overwrite; `--src-newer` restricts overwrite to a strictly-newer source. `copy-file` preserves mtime so subsequent runs are idempotent.

Symlinks are preserved (not followed): `copy-symlink` replicates them via `read-symlink`/`make-symlink`. Type-mismatched dest entries are removed before recreation.

`entries-safe` returns `'()` when the path is missing, which is what makes dry-run safe against trees where dest doesn't exist yet.

Options are an alist with symbol keys; `options-set` conses a fresh shadowing pair (no mutation). Long paths on Windows are handled inside the `(scm fs)` primitives, so there is no `_wlp` equivalent.

Output convention via `printlog`: `+` added, `-` deleted, `*` updated (copy mode), `x` type-mismatch replacement (sync mode), `=` excluded (verbosity 2); plain path = updated file in sync mode or directory traversal at verbosity 2.

The module-level `*log-port*` global is set only inside `main` when `--log-file` is given; `printlog` reads it but never rebinds it.
