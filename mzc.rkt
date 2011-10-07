#lang racket/base

;;;; Processing of mzc inliner logs.

(require "utilities.rkt"
         typed-racket/optimizer/logging
         unstable/syntax racket/match racket/list)

(provide log-message-from-mzc-opt?
         mzc-opt-log-message->log-entry
         post-process-inline-log)


;;; Low-level log parsing. Goes from strings to log-entry structs.

(define mzc-optimizer-regexp "^mzc optimizer: ")
(define success-regexp (string-append mzc-optimizer-regexp "inlining: "))
(define failure-regexp (string-append mzc-optimizer-regexp "no inlining: "))
(define out-of-fuel-regexp (string-append mzc-optimizer-regexp
                                          "no inlining, out of fuel: "))

(define (log-message-from-mzc-opt? l)
  (regexp-match mzc-optimizer-regexp l))

;; String (message from the mzc optimizer) -> log-entry
(define (mzc-opt-log-message->log-entry l)
  (define forged-stx (inlining-event->forged-stx l))
  (cond [(regexp-match success-regexp l)
         (inlining-success->log-entry forged-stx)]
        [(regexp-match failure-regexp l)
         (inlining-failure->log-entry forged-stx)]
        [(regexp-match out-of-fuel-regexp l)
         (inlining-out-of-fuel->log-entry forged-stx)]
        [else
         (error "Unknown log message type" l)]))

(define inlining-event-regexp
  ;; Last bit is `generated?'. We don't care about that.
  ;; The middle elements of the vector are numbers of #f.
  "#\\(([^ ]+) #<path:(.+)> ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) [^ ]+\\)")

(define (inlining-event->forged-stx l)
  (match (regexp-match inlining-event-regexp l)
    [`(,all ,name ,path ,line ,col ,pos ,span)
     (datum->syntax #'here (string->symbol name)
                    (list path
                          (string->number line)
                          (string->number col)
                          (string->number pos)
                          (string->number span)))]
    [_ (error "ill-formed inlining log entry" l)]))

(define success-kind     "Inlining")
(define failure-kind     "Failed Inlining")
(define out-of-fuel-kind "Failed Inlining, Out of Fuel")

(define (inlining-success->log-entry forged-stx)
  (opt-log-entry success-kind success-kind
                 forged-stx forged-stx ; stx, located-stx
                 (syntax-position forged-stx)))
(define (inlining-failure->log-entry forged-stx)
  (missed-opt-log-entry failure-kind failure-kind
                        forged-stx forged-stx
                        (syntax-position forged-stx)
                        '() '() 1)) ; irritants, merged-irritants badness
(define (inlining-out-of-fuel->log-entry forged-stx)
  (missed-opt-log-entry out-of-fuel-kind out-of-fuel-kind
                        forged-stx forged-stx
                        (syntax-position forged-stx)
                        '() '() 1))


;;; Log processing. Interprets the log entries, and produces new ones.

;; We aggregate results for each function.
;; Log messages produced by the inliner are very raw, unlike the TR logs,
;; which have gone through some aggregation. We do the aggregation here.
(define (post-process-inline-log log)
  (define-values (inliner-logs tr-logs)
    (partition (lambda (x) (regexp-match "[iI]nlining" (log-entry-kind x)))
               log))
  (define grouped-events
    (group-by (lambda (x y)
                (equal? (log-entry-pos x) ; right file, so that's enough
                        (log-entry-pos y)))
              inliner-logs))
  (define (success?     l) (equal? success-kind     (log-entry-kind l)))
  (define (failure?     l) (equal? failure-kind     (log-entry-kind l)))
  (define (out-of-fuel? l) (equal? out-of-fuel-kind (log-entry-kind l)))
  (define new-inline-log-entries
    (for/list ([group (in-list grouped-events)])
      (define head (car group))
      (match head ; events are grouped, first element is representative
        [(log-entry kind msg stx located-stx pos)
         (define n-successes    (length (filter success?     group)))
         (define n-failures     (length (filter failure?     group)))
         (define n-out-of-fuels (length (filter out-of-fuel? group)))
         ;; If we have any failures at all, we consider it a missed opt.
         (define aggregation-string
           (format "(~a~a~a~a~a~a~a)"
                   (if (> n-successes 0)
                       (format "~a success~a"
                               n-successes
                               (if (> n-successes 1) "es" ""))
                       "")
                   (if (and (> n-successes 0)
                            (or (> n-failures     0)
                                (> n-out-of-fuels 0)))
                       ", " "")
                   (if (> n-failures 0)
                       (format "~a failure~a"
                               n-failures
                               (if (> n-failures 1) "s" ""))
                       "")
                   (if (and (> n-failures     0)
			    (> n-out-of-fuels 0))
                       ", " "")
                   (if (> n-out-of-fuels 0)
                       (format "~a out of fuel~a"
                               n-out-of-fuels
                               (if (> n-out-of-fuels 1) "s" ""))
                       "")))
         ;; This is where the interesting decisions are taken.
         (define counts-as-a-missed-opt?
           (or (> n-failures 0) ; any straight failure is a problem
               (> n-out-of-fuels n-successes) ; we fail more often than not
               ))
         (if counts-as-a-missed-opt?
             (missed-opt-log-entry
              kind
              (format "Missed Inlining ~a" aggregation-string)
              stx located-stx pos
              (missed-opt-log-entry-irritants        head)
              (missed-opt-log-entry-merged-irritants head)
              n-failures) ; badness
             (opt-log-entry
              kind
              (format "Inlining ~a" aggregation-string)
              stx located-stx pos))])))
  (append tr-logs new-inline-log-entries))