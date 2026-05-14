import datetime
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


"""
Copy recursively from src to dest.

This copies all new or changed (according to differing
modification time and/or file size) files. It never
deleted files in the destination, but may overwrite
files, if the source file is changed (mtime/size).
"""
def copy(src, dest, options):
    if options["verbosity"] >= 2 and os.path.isdir(src):
        printlog(src)
    for path in sorted(os.listdir(src)):
        srcpath = os.path.join(src, path)
        try:
            destpath = os.path.join(dest, path)
        except FileNotFoundError:
            if not options["dry-run"]:
                raise
        if not os.path.exists(destpath):
            if os.path.isdir(srcpath):
                if options["verbosity"] >= 1:
                    printlog("+", srcpath)
                if not options["dry-run"]:
                    os.mkdir(destpath)
                copy(srcpath, destpath, options)
            else:
                if options["verbosity"] >= 1:
                    printlog("+", srcpath)
                if not options["dry-run"]:
                    try:
                        shutil.copy2(srcpath, destpath)
                    except Exception as e:
                        printlog(str(e))
        else:
            if os.path.isdir(srcpath):
                copy(srcpath, destpath, options)
            else:
                srcstat = os.stat(srcpath)
                deststat = os.stat(destpath)
                copy_needed = False
                if srcstat.st_size != deststat.st_size:
                    copy_needed = True
                elif srcstat.st_mtime != deststat.st_mtime:
                    copy_needed = True
                if copy_needed or options["force"]:
                    if options["verbosity"] >= 1:
                        printlog("*", srcpath)
                    if not options["dry-run"]:
                        try:
                            shutil.copy2(srcpath, destpath)
                        except Exception as e:
                            printlog(str(e))
                

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
    spaths = os.listdir(src)
    try:
        dpaths = os.listdir(dest)
    except FileNotFoundError:
        if not options["dry-run"]:
            raise
        dpaths = []
    paths = list(sorted(set(spaths) | set(dpaths)))
    for path in paths:
        srcpath = os.path.join(src, path)
        destpath = os.path.join(dest, path)
        if options["verbosity"] >= 2 and os.path.isdir(srcpath):
            printlog(srcpath)
        if not os.path.exists(srcpath):
            if options["verbosity"] >= 1:
                printlog("-", srcpath)
            if not options["dry-run"]:
                if os.path.isdir(destpath):
                    try:
                        shutil.rmtree(destpath)
                    except:
                        # retry
                        try:
                            shutil.rmtree(destpath)
                        except:
                            printlog(f"failed to delete {destpath}")                            
                else:
                    try:
                        os.remove(destpath)
                    except:
                        printlog(f"failed to delete {destpath}")
        elif not os.path.exists(destpath):
            if options["verbosity"] >= 1:
                printlog("+", srcpath)
            if os.path.isdir(srcpath):
                if not options["dry-run"]:
                    os.mkdir(destpath)
                sync(srcpath, destpath, options)
            else:
                if not options["dry-run"]:
                    try:
                        shutil.copy2(srcpath, destpath)
                    except Exception as e:
                        printlog(str(e))
        else:
            if os.path.isdir(srcpath):
                if os.path.isfile(destpath):
                    if options["verbosity"] >= 1:
                        printlog("x", srcpath)
                    if not options["dry-run"]:
                        os.remove(destpath) 
                        os.mkdir(destpath)
                sync(srcpath, destpath, options)
            else:
                if os.path.isdir(destpath):
                    if not options["dry-run"]:
                        shutil.rmtree(destpath)
                    if options["verbosity"] >= 1:
                        printlog("x", srcpath)
                    if not options["dry-run"]:
                        try:
                            shutil.copy2(srcpath, destpath)
                        except Exception as e:
                            printlog(str(e))
                else:
                    srcstat = os.stat(srcpath)
                    deststat = os.stat(destpath)
                    copy_needed = False
                    if srcstat.st_size != deststat.st_size:
                        copy_needed = True
                    elif srcstat.st_mtime != deststat.st_mtime:
                        copy_needed = True
                    if copy_needed or options["force"]:
                        if options["verbosity"] >= 1:
                            printlog(srcpath)
                        if not options["dry-run"]:
                            try:
                                shutil.copy2(srcpath, destpath)
                            except Exception as e:
                                printlog(str(e))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("python dabsys.py <copy|sync> <src> <target>")
        exit(1)
    options = {
        "dry-run": False,
        "log-file": None,
        "verbosity": 1,
        "force": False,
    }
    args = []
    idx = 0
    with_options = True
    while idx < len(sys.argv):
        arg = sys.argv[idx]
        if with_options and arg == "--dry-run":
            options["dry-run"] = True
        elif with_options and arg == "--log-file":
            options["log-file"] = sys.argv[idx+1]
            idx += 1
        elif with_options and arg == "--verbosity":
            options["verbosity"] = int(sys.argv[idx+1])
            idx += 1
        elif with_options and arg == "--silent":
            options["verbosity"] = 0
        elif with_options and arg == "--verbose":
            options["verbosity"] = 2
        elif with_options and arg == "--force":
            options["force"] = True
        elif arg == "--":
            with_options = False
        elif with_options and arg.startswith("--"):
            options[arg[2:]] = True
        else:
            args.append(arg)
        idx += 1
    mode = args[1]
    src = args[2]
    dest = args[3]
    if options["log-file"]:
        log = open(options["log-file"], "a", encoding="utf8")
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
