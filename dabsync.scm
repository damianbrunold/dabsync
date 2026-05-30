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

(include "dabsync-impl.scm")

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
