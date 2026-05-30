;; test-dabsync.scm — white-box tests for the dabscm port of dabsync.
;;
;; Run with either interpreter from the dabsync project root:
;;   scm  test-dabsync.scm
;;   scmj test-dabsync.scm   (java)
;;
;; Mirrors test_dabsync.py: it calls copy/sync directly with an options alist.

(import (scheme base)
        (scheme write)
        (scheme file)
        (srfi 1)
        (srfi 13)
        (srfi 132)
        (scm test)
        (scm fs)
        (scm glob))

(include "dabsync-impl.scm")

(test-runner-factory scm-test-runner)

;; ---- test helpers ----

(define (write-file path content)
  (let ((p (open-output-file path)))
    (display content p)
    (close-output-port p)))

(define (read-file path)
  (let ((p (open-input-file path))
        (o (open-output-string)))
    (let loop ()
      (let ((c (read-char p)))
        (if (eof-object? c)
            (begin (close-input-port p) (get-output-string o))
            (begin (write-char c o) (loop)))))))

;; Create a file, making intermediate directories as needed.
(define (make-file path content)
  (make-directory (directory-name path))
  (write-file path content))

;; Quiet options (verbosity 0) so the test run stays readable.
(define (topts)
  (options-set (default-options) 'verbosity 0))

;; Run thunk with a fresh temp base containing empty src/ and dst/.
(define (with-dirs proc)
  (let* ((base (mktempdir '(prefix . "dabsync-test")))
         (src (join-path base "src"))
         (dst (join-path base "dst")))
    (make-directory src)
    (make-directory dst)
    (proc src dst)
    (delete-directory base)))

;; Probe whether this platform/user can create symlinks.
(define symlink-ok?
  (let* ((base (mktempdir '(prefix . "dabsync-symprobe")))
         (link (join-path base "l")))
    (make-symlink "target" link)
    (let ((ok (file-symlink? link)))
      (delete-directory base)
      ok)))

(test-begin "dabsync")

;; ===================== copy mode =====================

(test-group "copy: copies new file"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (copy src dst (topts))
    (test-equal "hello" (read-file (join-path dst "a.txt"))))))

(test-group "copy: idempotent on unchanged file"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (copy src dst (topts))
    (copy src dst (topts))
    (test-equal "hello" (read-file (join-path dst "a.txt"))))))

(test-group "copy: updates changed file"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (copy src dst (topts))
    (write-file (join-path src "a.txt") "goodbye")
    (set-file-modification-time! (join-path src "a.txt") 1000000100000)
    (copy src dst (topts))
    (test-equal "goodbye" (read-file (join-path dst "a.txt"))))))

(test-group "copy: never deletes in copy mode"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (make-file (join-path dst "b.txt") "keep")
    (copy src dst (topts))
    (test-equal "keep" (read-file (join-path dst "b.txt")))
    (test-equal #t (file-exists? (join-path dst "a.txt"))))))

(test-group "copy: exclude pattern"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (make-file (join-path src "b.log") "log")
    (copy src dst (options-set (topts) 'exclude '("*.log")))
    (test-equal #t (file-exists? (join-path dst "a.txt")))
    (test-equal #f (file-exists? (join-path dst "b.log"))))))

(test-group "copy: excludes multiple patterns"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "x")
    (make-file (join-path src "b.log") "y")
    (make-file (join-path src "c.tmp") "z")
    (copy src dst (options-set (topts) 'exclude '("*.log" "*.tmp")))
    (test-equal #t (file-exists? (join-path dst "a.txt")))
    (test-equal #f (file-exists? (join-path dst "b.log")))
    (test-equal #f (file-exists? (join-path dst "c.tmp"))))))

(test-group "copy: dry-run makes no changes"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (copy src dst (options-set (topts) 'dry-run #t))
    (test-equal #f (file-exists? (join-path dst "a.txt"))))))

(test-group "copy: nested directories"
  (with-dirs (lambda (src dst)
    (make-file (join-path (join-path src "sub") "c.txt") "deep")
    (copy src dst (topts))
    (test-equal "deep" (read-file (join-path (join-path dst "sub") "c.txt"))))))

(test-group "copy: empty directory"
  (with-dirs (lambda (src dst)
    (make-directory (join-path src "empty"))
    (copy src dst (topts))
    (test-equal #t (directory-exists? (join-path dst "empty"))))))

(test-group "copy: preserves mtime"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (set-file-modification-time! (join-path src "a.txt") 1000000000000)
    (copy src dst (topts))
    (test-assert (< (abs (- (file-modification-timestamp (join-path dst "a.txt"))
                            1000000000000)) 2000)))))

(test-group "copy: force recopies identical"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (copy src dst (topts))
    (copy src dst (options-set (topts) 'force #t))
    (test-equal "hello" (read-file (join-path dst "a.txt"))))))

(test-group "copy: special characters in names"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "file with spaces.txt") "x")
    (copy src dst (topts))
    (test-equal #t (file-exists? (join-path dst "file with spaces.txt"))))))

(test-group "copy: no copy when only mtime differs within tolerance"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (copy src dst (topts))
    (set-file-modification-time!
      (join-path dst "a.txt")
      (+ (file-modification-timestamp (join-path src "a.txt")) 500))
    (copy src dst (topts))
    (test-equal "hello" (read-file (join-path dst "a.txt"))))))

(test-group "copy: src-newer only copies strictly newer"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "old")
    (copy src dst (topts))
    ;; dst newer than src -> src-newer must NOT overwrite
    (set-file-modification-time! (join-path src "a.txt") 1000000000000)
    (set-file-modification-time! (join-path dst "a.txt") 1000000500000)
    (copy src dst (options-set (topts) 'src-newer #t))
    (test-equal "old" (read-file (join-path dst "a.txt")))
    ;; without src-newer, an older but different src DOES overwrite
    (write-file (join-path src "a.txt") "older-content")
    (set-file-modification-time! (join-path src "a.txt") 1000000000000)
    (copy src dst (topts))
    (test-equal "older-content" (read-file (join-path dst "a.txt"))))))

(when symlink-ok?
  (test-group "copy: symlink preserved"
    (with-dirs (lambda (src dst)
      (make-symlink "a.txt" (join-path src "link"))
      (make-file (join-path src "a.txt") "hello")
      (copy src dst (topts))
      (test-equal #t (file-symlink? (join-path dst "link")))
      (test-equal "a.txt" (read-symlink (join-path dst "link"))))))

  (test-group "copy: symlink target changed"
    (with-dirs (lambda (src dst)
      (make-symlink "a.txt" (join-path src "link"))
      (make-file (join-path src "a.txt") "hello")
      (copy src dst (topts))
      (delete-file (join-path src "link"))
      (make-symlink "b.txt" (join-path src "link"))
      (make-file (join-path src "b.txt") "world")
      (copy src dst (topts))
      (test-equal "b.txt" (read-symlink (join-path dst "link")))))))

;; ===================== sync mode =====================

(test-group "sync: deletes extra files"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (make-file (join-path dst "old.txt") "remove me")
    (sync src dst (topts))
    (test-equal #t (file-exists? (join-path dst "a.txt")))
    (test-equal #f (file-exists? (join-path dst "old.txt"))))))

(test-group "sync: makes identical"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "1")
    (make-file (join-path (join-path src "sub") "b.txt") "2")
    (make-file (join-path dst "stale.txt") "x")
    (sync src dst (topts))
    (test-equal "1" (read-file (join-path dst "a.txt")))
    (test-equal "2" (read-file (join-path (join-path dst "sub") "b.txt")))
    (test-equal #f (file-exists? (join-path dst "stale.txt"))))))

(test-group "sync: replaces file with directory"
  (with-dirs (lambda (src dst)
    (make-file (join-path (join-path src "x") "inner.txt") "deep")
    (make-file (join-path dst "x") "i am a file")
    (sync src dst (topts))
    (test-equal #t (directory-exists? (join-path dst "x")))
    (test-equal "deep" (read-file (join-path (join-path dst "x") "inner.txt"))))))

(test-group "sync: replaces directory with file"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "y") "i am a file")
    (make-file (join-path (join-path dst "y") "inner.txt") "deep")
    (sync src dst (topts))
    (test-equal #t (file-exists? (join-path dst "y")))
    (test-equal "i am a file" (read-file (join-path dst "y"))))))

(test-group "sync: dry-run does not delete"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "hello")
    (make-file (join-path dst "extra.txt") "keep")
    (sync src dst (options-set (topts) 'dry-run #t))
    (test-equal #t (file-exists? (join-path dst "extra.txt")))
    (test-equal "keep" (read-file (join-path dst "extra.txt"))))))

(test-group "sync: updates existing (size differs)"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "brand-new-content")
    (make-file (join-path dst "a.txt") "old")
    (sync src dst (topts))
    (test-equal "brand-new-content" (read-file (join-path dst "a.txt"))))))

(test-group "sync: updates existing (same size, newer mtime)"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "new")
    (make-file (join-path dst "a.txt") "old")
    ;; same size, so the only signal is mtime; values are ms since epoch
    (set-file-modification-time! (join-path dst "a.txt") 1000000000000)
    (set-file-modification-time! (join-path src "a.txt") 1000000000900)
    (sync src dst (topts))
    ;; 900ms gap < 1000ms tolerance -> NOT updated
    (test-equal "old" (read-file (join-path dst "a.txt")))
    (set-file-modification-time! (join-path src "a.txt") 1000000005000)
    (sync src dst (topts))
    ;; 5000ms gap > tolerance -> updated
    (test-equal "new" (read-file (join-path dst "a.txt"))))))

(test-group "sync: empty source clears dest"
  (with-dirs (lambda (src dst)
    (make-file (join-path dst "gone.txt") "x")
    (sync src dst (topts))
    (test-equal #f (file-exists? (join-path dst "gone.txt"))))))

(test-group "sync: nested deletion"
  (with-dirs (lambda (src dst)
    (make-file (join-path (join-path (join-path dst "deep") "nested") "file.txt") "x")
    (sync src dst (topts))
    (test-equal #f (directory-exists? (join-path dst "deep"))))))

(test-group "sync: does not touch identical tree"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "same")
    (sync src dst (topts))
    (sync src dst (topts))
    (test-equal "same" (read-file (join-path dst "a.txt"))))))

(test-group "sync: handles deeply nested"
  (with-dirs (lambda (src dst)
    (make-file (join-path (join-path (join-path (join-path src "a") "b") "c") "d.txt") "deep")
    (sync src dst (topts))
    (test-equal "deep"
      (read-file (join-path (join-path (join-path (join-path dst "a") "b") "c") "d.txt"))))))

(test-group "sync: overwrites when size differs"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "longcontent")
    (make-file (join-path dst "a.txt") "short")
    (sync src dst (topts))
    (test-equal "longcontent" (read-file (join-path dst "a.txt"))))))

(test-group "sync: propagates mtime"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "a.txt") "data")
    (set-file-modification-time! (join-path src "a.txt") 1000000000000)
    (sync src dst (topts))
    (test-assert (< (abs (- (file-modification-timestamp (join-path dst "a.txt"))
                            1000000000000)) 2000)))))

(test-group "sync: excluded entry left untouched in both"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "keep.txt") "k")
    (make-file (join-path src "skip.log") "s")
    (make-file (join-path dst "skip.log") "old")
    (sync src dst (options-set (topts) 'exclude '("*.log")))
    (test-equal #t (file-exists? (join-path dst "keep.txt")))
    (test-equal #t (file-exists? (join-path dst "skip.log")))
    (test-equal "old" (read-file (join-path dst "skip.log"))))))

(test-group "sync: does not create excluded"
  (with-dirs (lambda (src dst)
    (make-file (join-path src "data.txt") "d")
    (sync src dst (options-set (topts) 'exclude '("data.txt")))
    (test-equal #f (file-exists? (join-path dst "data.txt"))))))

(when symlink-ok?
  (test-group "sync: preserves symlink"
    (with-dirs (lambda (src dst)
      (make-symlink "target.txt" (join-path src "link"))
      (make-file (join-path src "target.txt") "data")
      (sync src dst (topts))
      (test-equal #t (file-symlink? (join-path dst "link")))))))

(test-end "dabsync")
