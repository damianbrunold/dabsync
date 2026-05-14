import datetime
import fnmatch
import os
import shutil
import sys
import time


log = None


def printlog(*args):
    msg = " ".join([str(s) for s in args])
    print(msg)
    if log:
        print(msg, file=log)


def _excluded(name, options):
    return any(fnmatch.fnmatch(name, pat) for pat in options.get("exclude", []))


def _wlp(path):
    """On Windows, prefix absolute paths with \\\\?\\ so they bypass MAX_PATH."""
    if os.name != "nt":
        return path
    if not path:
        return path
    if path.startswith("\\\\?\\"):
        return path
    abs_path = os.path.abspath(path)
    if abs_path.startswith("\\\\"):
        return "\\\\?\\UNC\\" + abs_path[2:]
    return "\\\\?\\" + abs_path


def _copystat_safe(srcpath, destpath):
    """Best-effort copy of mode/mtime/owner from src dir to dest dir."""
    try:
        shutil.copystat(srcpath, destpath)
    except OSError as e:
        printlog(f"copystat {destpath} failed: {e}")
    if hasattr(os, "chown") and os.geteuid() == 0:
        try:
            st = os.stat(srcpath)
            os.chown(destpath, st.st_uid, st.st_gid)
        except OSError as e:
            printlog(f"chown {destpath} failed: {e}")


def _list_dir_safe(path, options):
    """os.listdir, but tolerates missing path under --dry-run."""
    try:
        return os.listdir(path)
    except (FileNotFoundError, NotADirectoryError):
        if options["dry-run"]:
            return []
        raise


def _needs_copy(srcstat, deststat, src_newer_only=False):
    if src_newer_only:
        # only overwrite when src is strictly newer (1s tolerance)
        return (srcstat.st_mtime - deststat.st_mtime) >= 1.0
    if srcstat.st_size != deststat.st_size:
        return True
    # 1s tolerance covers ext4↔FAT/SMB mtime resolution differences
    if abs(srcstat.st_mtime - deststat.st_mtime) >= 1.0:
        return True
    return False


def _copy_symlink(srcpath, destpath, options):
    """Replicate a symlink at destpath, replacing any existing entry."""
    target = os.readlink(srcpath)
    if os.path.islink(destpath):
        if os.readlink(destpath) == target:
            return
        if not options["dry-run"]:
            os.remove(destpath)
    elif os.path.lexists(destpath):
        if not options["dry-run"]:
            if os.path.isdir(destpath) and not os.path.islink(destpath):
                shutil.rmtree(destpath)
            else:
                os.remove(destpath)
    if not options["dry-run"]:
        os.symlink(target, destpath)


"""
Copy recursively from src to dest.

This copies all new or changed (according to differing
modification time and/or file size) files. It never
deletes files in the destination, but may overwrite
files, if the source file is changed (mtime/size).
"""
def copy(src, dest, options):
    src = _wlp(src)
    dest = _wlp(dest)
    if options["verbosity"] >= 2 and os.path.isdir(src):
        printlog(src)
    for path in sorted(_list_dir_safe(src, options)):
        if _excluded(path, options):
            if options["verbosity"] >= 2:
                printlog("=", os.path.join(src, path))
            continue
        srcpath = os.path.join(src, path)
        destpath = os.path.join(dest, path)
        try:
            if os.path.islink(srcpath):
                if options["verbosity"] >= 1:
                    printlog("+" if not os.path.lexists(destpath) else "*", srcpath)
                try:
                    _copy_symlink(srcpath, destpath, options)
                except OSError as e:
                    printlog(str(e))
                continue
            if not os.path.lexists(destpath):
                if os.path.isdir(srcpath):
                    if options["verbosity"] >= 1:
                        printlog("+", srcpath)
                    if not options["dry-run"]:
                        os.mkdir(destpath)
                        _copystat_safe(srcpath, destpath)
                    copy(srcpath, destpath, options)
                else:
                    if options["verbosity"] >= 1:
                        printlog("+", srcpath)
                    if not options["dry-run"]:
                        try:
                            shutil.copy2(srcpath, destpath)
                        except OSError as e:
                            printlog(str(e))
            else:
                if os.path.isdir(srcpath):
                    copy(srcpath, destpath, options)
                else:
                    srcstat = os.stat(srcpath)
                    deststat = os.stat(destpath)
                    if _needs_copy(srcstat, deststat, options["src-newer"]) or options["force"]:
                        if options["verbosity"] >= 1:
                            printlog("*", srcpath)
                        if not options["dry-run"]:
                            try:
                                shutil.copy2(srcpath, destpath)
                            except OSError as e:
                                printlog(str(e))
        except UnicodeEncodeError as e:
            printlog(f"skipping {path!r}: name not encodable on destination filesystem ({e})")


def _remove_dest(destpath):
    """Best-effort recursive remove with one retry, logging the cause."""
    try:
        if os.path.islink(destpath) or not os.path.isdir(destpath):
            os.remove(destpath)
        else:
            shutil.rmtree(destpath)
        return
    except OSError as e:
        printlog(f"remove {destpath} failed: {e}; retrying")
        time.sleep(0.1)
    try:
        if os.path.islink(destpath) or not os.path.isdir(destpath):
            os.remove(destpath)
        else:
            shutil.rmtree(destpath)
    except OSError as e:
        printlog(f"failed to delete {destpath}: {e}")


"""
Synchronizes the src with the dest.

This copies/updates all files from src to dest. Existing
files are overwritten, if the src file has differing
mtime/size. Files or directories in dest, that are not
contained in src, are deleted.

After running this, the src and dest should contain the
same directories and files.
"""
def sync(src, dest, options):
    src = _wlp(src)
    dest = _wlp(dest)
    spaths = _list_dir_safe(src, options)
    dpaths = _list_dir_safe(dest, options)
    paths = list(sorted(set(spaths) | set(dpaths)))
    for path in paths:
        if _excluded(path, options):
            if options["verbosity"] >= 2:
                printlog("=", os.path.join(src, path))
            continue
        srcpath = os.path.join(src, path)
        destpath = os.path.join(dest, path)
        try:
            if options["verbosity"] >= 2 and os.path.isdir(srcpath) and not os.path.islink(srcpath):
                printlog(srcpath)
            if not os.path.lexists(srcpath):
                if options["verbosity"] >= 1:
                    printlog("-", srcpath)
                if not options["dry-run"]:
                    _remove_dest(destpath)
            elif os.path.islink(srcpath):
                if options["verbosity"] >= 1:
                    printlog("+" if not os.path.lexists(destpath) else "*", srcpath)
                try:
                    _copy_symlink(srcpath, destpath, options)
                except OSError as e:
                    printlog(str(e))
            elif not os.path.lexists(destpath):
                if options["verbosity"] >= 1:
                    printlog("+", srcpath)
                if os.path.isdir(srcpath):
                    if not options["dry-run"]:
                        os.mkdir(destpath)
                        _copystat_safe(srcpath, destpath)
                    sync(srcpath, destpath, options)
                else:
                    if not options["dry-run"]:
                        try:
                            shutil.copy2(srcpath, destpath)
                        except OSError as e:
                            printlog(str(e))
            else:
                if os.path.isdir(srcpath) and not os.path.islink(srcpath):
                    if os.path.isfile(destpath) or os.path.islink(destpath):
                        if options["verbosity"] >= 1:
                            printlog("x", srcpath)
                        if not options["dry-run"]:
                            os.remove(destpath)
                            os.mkdir(destpath)
                            _copystat_safe(srcpath, destpath)
                    sync(srcpath, destpath, options)
                else:
                    if os.path.isdir(destpath) and not os.path.islink(destpath):
                        if options["verbosity"] >= 1:
                            printlog("x", srcpath)
                        if not options["dry-run"]:
                            shutil.rmtree(destpath)
                            try:
                                shutil.copy2(srcpath, destpath)
                            except OSError as e:
                                printlog(str(e))
                    else:
                        srcstat = os.stat(srcpath)
                        deststat = os.stat(destpath)
                        if _needs_copy(srcstat, deststat, options["src-newer"]) or options["force"]:
                            if options["verbosity"] >= 1:
                                printlog(srcpath)
                            if not options["dry-run"]:
                                try:
                                    shutil.copy2(srcpath, destpath)
                                except OSError as e:
                                    printlog(str(e))
        except UnicodeEncodeError as e:
            printlog(f"skipping {path!r}: name not encodable on destination filesystem ({e})")


def _usage():
    print("python dabsync.py <copy|sync> <src> <target> [options]")
    print("options: --dry-run --log-file PATH --verbosity N --silent --verbose --force --src-newer --exclude PATTERN")


def _parse_argv(argv):
    options = {
        "dry-run": False,
        "log-file": None,
        "verbosity": 1,
        "force": False,
        "src-newer": False,
        "exclude": [],
    }
    args = []
    idx = 0
    with_options = True
    while idx < len(argv):
        arg = argv[idx]
        if with_options and arg == "--dry-run":
            options["dry-run"] = True
        elif with_options and arg == "--log-file":
            options["log-file"] = argv[idx + 1]
            idx += 1
        elif with_options and arg == "--verbosity":
            options["verbosity"] = int(argv[idx + 1])
            idx += 1
        elif with_options and arg == "--silent":
            options["verbosity"] = 0
        elif with_options and arg == "--verbose":
            options["verbosity"] = 2
        elif with_options and arg == "--force":
            options["force"] = True
        elif with_options and arg == "--src-newer":
            options["src-newer"] = True
        elif with_options and arg == "--exclude":
            options["exclude"].append(argv[idx + 1])
            idx += 1
        elif arg == "--":
            with_options = False
        elif with_options and arg.startswith("--"):
            print(f"error: unknown option {arg}", file=sys.stderr)
            sys.exit(2)
        else:
            args.append(arg)
        idx += 1
    return options, args


if __name__ == "__main__":
    options, args = _parse_argv(sys.argv[1:])
    if len(args) < 3:
        _usage()
        sys.exit(1)
    mode = args[0]
    src = args[1]
    dest = args[2]
    if mode not in ("copy", "sync"):
        print(f"error: unknown mode {mode!r}", file=sys.stderr)
        _usage()
        sys.exit(2)
    if options["log-file"]:
        log = open(options["log-file"], "a", encoding="utf8", buffering=1)
    printlog("started", datetime.datetime.now().isoformat())
    printlog(mode, src, dest)
    printlog(str(options))
    start_time = time.time()
    if mode == "copy":
        copy(src, dest, options)
    elif mode == "sync":
        sync(src, dest, options)
    end_time = time.time()
    printlog("elapsed", str(int(end_time - start_time)) + "s")
    printlog("-" * 30)
    if log:
        log.close()
