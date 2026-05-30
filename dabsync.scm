;; dabsync.scm — recursively copy or synchronize directory trees.
;;
;; A Scheme (dabscm) port of dabsync.py. Runs identically on Linux, Windows and
;; macOS; long paths on Windows are handled inside the (scm fs) primitives.
;;
;; Usage:
;;   scm dabsync.scm <copy|sync> <src> <target> [options]
;; Options:
;;   --dry-run --log-file PATH --verbosity N --silent --verbose
;;   --force --src-newer --exclude PATTERN  (--exclude repeatable; -- stops options)
;;
;; This is a single, self-contained file. Symlinks are preserved (not followed)
;; via file-symlink?, read-symlink and make-symlink. File mtimes are preserved by
;; copy-file; directory mtimes are propagated with set-file-modification-time!.

(import (scheme base)
        (scheme write)
        (scheme file)
        (scheme process-context)
        (scheme time)
        (srfi 1)
        (srfi 13)
        (srfi 132)
        (scm fs)
        (scm glob))

;; ---- logging ----

(define *log-port* #f)

(define (->disp x)
  (if (string? x)
      x
      (let ((p (open-output-string)))
        (display x p)
        (get-output-string p))))

(define (printlog . args)
  (let ((msg (string-join (map ->disp args) " ")))
    (display msg)
    (newline)
    (when *log-port*
      (display msg *log-port*)
      (newline *log-port*))))

;; ---- options (alist with symbol keys) ----

(define (default-options)
  (list (cons 'dry-run #f)
        (cons 'log-file #f)
        (cons 'verbosity 1)
        (cons 'force #f)
        (cons 'src-newer #f)
        (cons 'exclude '())))

;; Returns a new options alist with key bound to val. assq finds the first
;; matching pair, so consing a fresh pair shadows any earlier binding.
(define (options-set options key val)
  (cons (cons key val) options))

(define (opt options key default)
  (let ((p (assq key options)))
    (if p (cdr p) default)))

(define (opt-dry-run o)   (opt o 'dry-run #f))
(define (opt-verbosity o) (opt o 'verbosity 1))
(define (opt-force o)     (opt o 'force #f))
(define (opt-src-newer o) (opt o 'src-newer #f))
(define (opt-exclude o)   (opt o 'exclude '()))
(define (opt-log-file o)  (opt o 'log-file #f))

;; ---- helpers ----

(define (excluded? name options)
  (let loop ((pats (opt-exclude options)))
    (cond ((null? pats) #f)
          ((glob-match? (car pats) name) #t)
          (else (loop (cdr pats))))))

;; List a directory as a sorted list of (name . type) pairs, where type is one
;; of 'file 'directory 'symlink (symlinks are NOT followed). Missing directory
;; yields '() (directory-entries already tolerates that). This is what makes
;; dry-run safe against trees where dest does not exist yet.
(define (entries-safe path)
  (if (directory-exists? path)
      (directory-entries path)
      '()))

(define (sorted-entries path)
  (list-sort (lambda (a b) (string<? (car a) (car b)))
             (entries-safe path)))

(define (entry-type entries name)
  (let ((p (assoc name entries)))
    (and p (cdr p))))

(define (union-names a b)
  (list-sort string<? (delete-duplicates (append a b) string=?)))

;; size-then-mtime change detection, 1000 ms tolerance (covers ext4<->FAT/SMB).
;; mtimes are milliseconds since the epoch (file-modification-timestamp).
(define (needs-copy? srcpath destpath options)
  (let ((ssize (file-size srcpath))
        (smtime (file-modification-timestamp srcpath))
        (dsize (file-size destpath))
        (dmtime (file-modification-timestamp destpath)))
    (cond
      ((opt-src-newer options) (>= (- smtime dmtime) 1000))
      ((not (= ssize dsize)) #t)
      ((>= (abs (- smtime dmtime)) 1000) #t)
      (else #f))))

;; Best-effort propagation of a directory's mtime (caller guards dry-run).
(define (copystat-safe srcpath destpath)
  (set-file-modification-time! destpath (file-modification-timestamp srcpath)))

;; copy-file returns #f on failure (it does not raise); log and continue,
;; matching dabsync.py's per-file `except OSError`.
(define (do-copy srcpath destpath)
  (when (eq? (copy-file srcpath destpath) #f)
    (printlog (string-append "copy " srcpath " failed"))))

;; Replicate a symlink at destpath, replacing any existing entry. The target is
;; copied verbatim (raw link text), never followed.
(define (copy-symlink srcpath destpath options)
  (let ((target (read-symlink srcpath))
        (dry (opt-dry-run options)))
    (unless (and (file-symlink? destpath)
                 (equal? (read-symlink destpath) target))
      (when (path-exists? destpath)
        (unless dry
          (if (and (directory-exists? destpath)
                   (not (file-symlink? destpath)))
              (delete-directory destpath)
              (delete-file destpath))))
      (unless dry
        (when (eq? (make-symlink target destpath) #f)
          (printlog (string-append "symlink " destpath " failed")))))))

;; Best-effort recursive remove with one retry, logging the cause.
(define (remove-dest destpath)
  (define (do-remove)
    (if (or (file-symlink? destpath)
            (not (directory-exists? destpath)))
        (delete-file destpath)
        (delete-directory destpath)))
  (guard (e (#t
             (printlog (string-append "remove " destpath " failed; retrying"))
             (guard (e2 (#t (printlog (string-append "failed to delete " destpath))))
               (do-remove))))
    (do-remove)))

;; ---- copy: additive only, never deletes ----

(define (copy-entry srcpath destpath type options)
  (let ((v (opt-verbosity options))
        (dry (opt-dry-run options)))
    (cond
      ((eq? type 'symlink)
       (when (>= v 1) (printlog (if (path-exists? destpath) "*" "+") srcpath))
       (copy-symlink srcpath destpath options))
      ((not (path-exists? destpath))
       (cond
         ((eq? type 'directory)
          (when (>= v 1) (printlog "+" srcpath))
          (unless dry
            (make-directory destpath)
            (copystat-safe srcpath destpath))
          (copy srcpath destpath options))
         (else
          (when (>= v 1) (printlog "+" srcpath))
          (unless dry (do-copy srcpath destpath)))))
      (else
       (cond
         ((eq? type 'directory)
          (copy srcpath destpath options))
         (else
          (when (or (needs-copy? srcpath destpath options) (opt-force options))
            (when (>= v 1) (printlog "*" srcpath))
            (unless dry (do-copy srcpath destpath)))))))) )

(define (copy src dest options)
  (when (and (>= (opt-verbosity options) 2) (directory-exists? src))
    (printlog src))
  (for-each
    (lambda (entry)
      (let ((name (car entry))
            (type (cdr entry)))
        (let ((srcpath (join-path src name))
              (destpath (join-path dest name)))
          (if (excluded? name options)
              (when (>= (opt-verbosity options) 2)
                (printlog "=" srcpath))
              (guard (e (#t (printlog (string-append "skipping " srcpath))))
                (copy-entry srcpath destpath type options))))))
    (sorted-entries src)))

;; ---- sync: make dest mirror src, deleting extras ----

(define (sync src dest options)
  (let* ((src-entries (entries-safe src))
         (dest-entries (entries-safe dest))
         (names (union-names (map car src-entries) (map car dest-entries)))
         (v (opt-verbosity options))
         (dry (opt-dry-run options)))
    (for-each
      (lambda (name)
        (let ((srcpath (join-path src name))
              (destpath (join-path dest name))
              (stype (entry-type src-entries name))
              (dtype (entry-type dest-entries name)))
          (if (excluded? name options)
              (when (>= v 2) (printlog "=" srcpath))
              (guard (e (#t (printlog (string-append "skipping " srcpath))))
                (when (and (>= v 2) (eq? stype 'directory))
                  (printlog srcpath))
                (cond
                  ;; present only in dest -> delete
                  ((not stype)
                   (when (>= v 1) (printlog "-" srcpath))
                   (unless dry (remove-dest destpath)))
                  ;; symlink in src -> replicate
                  ((eq? stype 'symlink)
                   (when (>= v 1) (printlog (if dtype "*" "+") srcpath))
                   (copy-symlink srcpath destpath options))
                  ;; new in src
                  ((not dtype)
                   (when (>= v 1) (printlog "+" srcpath))
                   (if (eq? stype 'directory)
                       (begin
                         (unless dry
                           (make-directory destpath)
                           (copystat-safe srcpath destpath))
                         (sync srcpath destpath options))
                       (unless dry (do-copy srcpath destpath))))
                  ;; present in both
                  (else
                   (cond
                     ((eq? stype 'directory)
                      ;; dest is a file or symlink where src has a dir -> replace
                      (when (or (eq? dtype 'file) (eq? dtype 'symlink))
                        (when (>= v 1) (printlog "x" srcpath))
                        (unless dry
                          (delete-file destpath)
                          (make-directory destpath)
                          (copystat-safe srcpath destpath)))
                      (sync srcpath destpath options))
                     (else
                      ;; src is a file
                      (if (eq? dtype 'directory)
                          (begin
                            (when (>= v 1) (printlog "x" srcpath))
                            (unless dry
                              (delete-directory destpath)
                              (do-copy srcpath destpath)))
                          (when (or (needs-copy? srcpath destpath options)
                                    (opt-force options))
                            (when (>= v 1) (printlog srcpath))
                            (unless dry (do-copy srcpath destpath))))))))))))
      names)))

;; ---- command-line interface ----

(define (usage)
  (display "scm dabsync.scm <copy|sync> <src> <target> [options]")
  (newline)
  (display "options: --dry-run --log-file PATH --verbosity N --silent --verbose --force --src-newer --exclude PATTERN")
  (newline))

(define (parse-argv argv)
  (let loop ((args argv)
             (options (default-options))
             (positional '())
             (with-options #t))
    (if (null? args)
        (cons options (reverse positional))
        (let ((arg (car args))
              (rest (cdr args)))
          (cond
            ((and with-options (string=? arg "--dry-run"))
             (loop rest (options-set options 'dry-run #t) positional #t))
            ((and with-options (string=? arg "--log-file"))
             (loop (cdr rest) (options-set options 'log-file (car rest)) positional #t))
            ((and with-options (string=? arg "--verbosity"))
             (loop (cdr rest) (options-set options 'verbosity (string->number (car rest))) positional #t))
            ((and with-options (string=? arg "--silent"))
             (loop rest (options-set options 'verbosity 0) positional #t))
            ((and with-options (string=? arg "--verbose"))
             (loop rest (options-set options 'verbosity 2) positional #t))
            ((and with-options (string=? arg "--force"))
             (loop rest (options-set options 'force #t) positional #t))
            ((and with-options (string=? arg "--src-newer"))
             (loop rest (options-set options 'src-newer #t) positional #t))
            ((and with-options (string=? arg "--exclude"))
             (loop (cdr rest)
                   (options-set options 'exclude
                                (append (opt-exclude options) (list (car rest))))
                   positional #t))
            ((string=? arg "--")
             (loop rest options positional #f))
            ((and with-options (string-prefix? "--" arg))
             (display (string-append "error: unknown option " arg) (current-error-port))
             (newline (current-error-port))
             (exit 2))
            (else
             (loop rest options (cons arg positional) with-options)))))))

(define (main argv)
  (let* ((parsed (parse-argv argv))
         (options (car parsed))
         (args (cdr parsed)))
    (when (< (length args) 3)
      (usage)
      (exit 1))
    (let ((mode (list-ref args 0))
          (src (list-ref args 1))
          (dest (list-ref args 2)))
      (unless (or (string=? mode "copy") (string=? mode "sync"))
        (display (string-append "error: unknown mode " mode) (current-error-port))
        (newline (current-error-port))
        (usage)
        (exit 2))
      (when (opt-log-file options)
        (set! *log-port* (open-output-file (opt-log-file options) 'append)))
      (printlog "started")
      (printlog mode src dest)
      (let ((start (current-second)))
        (if (string=? mode "copy")
            (copy src dest options)
            (sync src dest options))
        (let ((elapsed (exact (floor (- (current-second) start)))))
          (printlog "elapsed" (string-append (number->string elapsed) "s"))))
      (printlog "------------------------------")
      (when *log-port*
        (close-output-port *log-port*)))))

(main (cdr (command-line)))
