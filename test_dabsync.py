import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import dabsync


HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "dabsync.py")


def make_tree(root, spec):
    """spec: {relpath: str (file content) | None (dir) | ('symlink', target)}"""
    for rel, value in spec.items():
        path = os.path.join(root, rel)
        if value is None:
            os.makedirs(path, exist_ok=True)
        elif isinstance(value, tuple) and value[0] == "symlink":
            os.makedirs(os.path.dirname(path), exist_ok=True) if os.path.dirname(rel) else None
            os.symlink(value[1], path)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True) if os.path.dirname(rel) else None
            with open(path, "w") as f:
                f.write(value)


def snapshot(root):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        for d in dirnames:
            full = os.path.join(dirpath, d)
            rel = os.path.normpath(os.path.join(rel_dir, d))
            if os.path.islink(full):
                out[rel] = ("symlink", os.readlink(full))
            else:
                out[rel] = ("dir",)
        for f in filenames:
            full = os.path.join(dirpath, f)
            rel = os.path.normpath(os.path.join(rel_dir, f))
            if os.path.islink(full):
                out[rel] = ("symlink", os.readlink(full))
            else:
                with open(full) as fh:
                    out[rel] = ("file", fh.read())
    return out


def default_options(**overrides):
    opts = {
        "dry-run": False,
        "log-file": None,
        "verbosity": 0,
        "force": False,
        "exclude": [],
    }
    opts.update(overrides)
    return opts


class TempTreeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dabsync-test-")
        self.src = os.path.join(self.tmp, "src")
        self.dest = os.path.join(self.tmp, "dest")
        os.mkdir(self.src)
        os.mkdir(self.dest)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class TestCopy(TempTreeCase):
    def test_adds_missing_files(self):
        make_tree(self.src, {"a.txt": "hello", "sub": None, "sub/b.txt": "world"})
        dabsync.copy(self.src, self.dest, default_options())
        self.assertEqual(snapshot(self.dest), {
            "a.txt": ("file", "hello"),
            "sub": ("dir",),
            os.path.join("sub", "b.txt"): ("file", "world"),
        })

    def test_overwrites_on_size_diff(self):
        make_tree(self.src, {"a.txt": "longer content"})
        make_tree(self.dest, {"a.txt": "x"})
        dabsync.copy(self.src, self.dest, default_options())
        with open(os.path.join(self.dest, "a.txt")) as f:
            self.assertEqual(f.read(), "longer content")

    def test_overwrites_on_mtime_diff(self):
        make_tree(self.src, {"a.txt": "AAAA"})
        make_tree(self.dest, {"a.txt": "BBBB"})  # same size
        old = time.time() - 10000
        os.utime(os.path.join(self.dest, "a.txt"), (old, old))
        dabsync.copy(self.src, self.dest, default_options())
        with open(os.path.join(self.dest, "a.txt")) as f:
            self.assertEqual(f.read(), "AAAA")

    def test_never_deletes(self):
        make_tree(self.src, {"a.txt": "hi"})
        make_tree(self.dest, {"keep.txt": "stay"})
        dabsync.copy(self.src, self.dest, default_options())
        self.assertTrue(os.path.exists(os.path.join(self.dest, "keep.txt")))


class TestSync(TempTreeCase):
    def test_mirrors_src(self):
        make_tree(self.src, {"a.txt": "hi"})
        make_tree(self.dest, {"old.txt": "remove"})
        dabsync.sync(self.src, self.dest, default_options())
        self.assertEqual(snapshot(self.dest), {"a.txt": ("file", "hi")})

    def test_file_replaced_by_dir(self):
        make_tree(self.src, {"x": None, "x/inner.txt": "I"})
        make_tree(self.dest, {"x": "was a file"})
        dabsync.sync(self.src, self.dest, default_options())
        self.assertEqual(snapshot(self.dest), {
            "x": ("dir",),
            os.path.join("x", "inner.txt"): ("file", "I"),
        })

    def test_dir_replaced_by_file(self):
        make_tree(self.src, {"x": "now a file"})
        make_tree(self.dest, {"x": None, "x/old.txt": "gone"})
        dabsync.sync(self.src, self.dest, default_options())
        self.assertEqual(snapshot(self.dest), {"x": ("file", "now a file")})


class TestDryRun(TempTreeCase):
    def test_copy_into_missing_dest_does_not_crash(self):
        make_tree(self.src, {"sub": None, "sub/deep": None, "sub/deep/f.txt": "x"})
        missing = os.path.join(self.tmp, "missing-dest")
        # must not raise
        dabsync.copy(self.src, missing, default_options(**{"dry-run": True}))
        self.assertFalse(os.path.exists(missing))

    def test_sync_file_to_dir_dryrun_does_not_crash(self):
        make_tree(self.src, {"x": None, "x/inner.txt": "I"})
        make_tree(self.dest, {"x": "was a file"})
        before = snapshot(self.dest)
        dabsync.sync(self.src, self.dest, default_options(**{"dry-run": True}))
        self.assertEqual(snapshot(self.dest), before)

    def test_no_filesystem_changes(self):
        make_tree(self.src, {"a.txt": "hi", "sub": None, "sub/b.txt": "y"})
        make_tree(self.dest, {"old.txt": "stay"})
        before = snapshot(self.dest)
        dabsync.sync(self.src, self.dest, default_options(**{"dry-run": True}))
        self.assertEqual(snapshot(self.dest), before)


class TestMtimeTolerance(TempTreeCase):
    def test_subsecond_drift_not_recopied(self):
        make_tree(self.src, {"a.txt": "AAAA"})
        make_tree(self.dest, {"a.txt": "AAAA"})
        src_stat = os.stat(os.path.join(self.src, "a.txt"))
        dest_path = os.path.join(self.dest, "a.txt")
        # set dest mtime 0.5s off — within tolerance, should NOT recopy
        os.utime(dest_path, (src_stat.st_atime, src_stat.st_mtime + 0.5))
        dest_mtime_before = os.stat(dest_path).st_mtime
        dabsync.sync(self.src, self.dest, default_options())
        dest_mtime_after = os.stat(dest_path).st_mtime
        self.assertEqual(dest_mtime_before, dest_mtime_after)


class TestSymlinks(TempTreeCase):
    def test_symlink_preserved(self):
        target = os.path.join(self.tmp, "target.txt")
        with open(target, "w") as f:
            f.write("T")
        os.symlink(target, os.path.join(self.src, "link"))
        dabsync.copy(self.src, self.dest, default_options())
        link = os.path.join(self.dest, "link")
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.readlink(link), target)

    def test_symlink_loop_terminates(self):
        os.symlink("..", os.path.join(self.src, "loop"))

        def handler(signum, frame):
            raise TimeoutError("recursion did not terminate")

        signal.signal(signal.SIGALRM, handler)
        signal.alarm(5)
        try:
            dabsync.copy(self.src, self.dest, default_options())
        finally:
            signal.alarm(0)

    def test_broken_symlink_preserved(self):
        os.symlink("/nonexistent/path/here", os.path.join(self.src, "broken"))
        dabsync.copy(self.src, self.dest, default_options())
        link = os.path.join(self.dest, "broken")
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.readlink(link), "/nonexistent/path/here")


class TestExcludes(TempTreeCase):
    def test_exclude_skips_matching_names(self):
        make_tree(self.src, {
            "keep.txt": "k",
            "__pycache__": None,
            "__pycache__/x.pyc": "junk",
        })
        dabsync.copy(self.src, self.dest, default_options(exclude=["__pycache__"]))
        self.assertIn("keep.txt", os.listdir(self.dest))
        self.assertNotIn("__pycache__", os.listdir(self.dest))

    def test_exclude_glob(self):
        make_tree(self.src, {"a.py": "src", "a.pyc": "junk"})
        dabsync.sync(self.src, self.dest, default_options(exclude=["*.pyc"]))
        self.assertIn("a.py", os.listdir(self.dest))
        self.assertNotIn("a.pyc", os.listdir(self.dest))


class TestArgvParsing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dabsync-cli-")
        self.src = os.path.join(self.tmp, "src")
        self.dest = os.path.join(self.tmp, "dest")
        os.mkdir(self.src)
        with open(os.path.join(self.src, "a.txt"), "w") as f:
            f.write("hi")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, SCRIPT, *args],
            capture_output=True, text=True,
        )

    def test_options_after_positional(self):
        r = self.run_cli("copy", self.src, self.dest, "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_options_before_positional(self):
        r = self.run_cli("--dry-run", "copy", self.src, self.dest)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_options_between_positionals(self):
        r = self.run_cli("copy", "--dry-run", self.src, self.dest)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_unknown_flag_errors(self):
        r = self.run_cli("--drz-run", "copy", self.src, self.dest)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("drz-run", r.stderr + r.stdout)

    def test_invalid_mode_errors(self):
        r = self.run_cli("wibble", self.src, self.dest)
        self.assertNotEqual(r.returncode, 0)

    def test_usage_string_spelling(self):
        r = self.run_cli()
        out = r.stdout + r.stderr
        self.assertIn("dabsync.py", out)
        self.assertNotIn("dabsys.py", out)


if __name__ == "__main__":
    unittest.main()
