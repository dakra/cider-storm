;;; cider-storm.el --- Cider front-end for the FlowStorm debugger  -*- lexical-binding: t -*-

;; Copyright (c) 2023 Juan Monetta <jpmonettas@gmail.com>

;; Author: Juan Monetta <jpmonettas@gmail.com>
;; URL: https://github.com/jpmonettas/cider-storm
;; Keywords: convenience, tools, debugger, clojure, cider
;; Version: 0.1
;; Package-Requires: ((emacs "26") (cider "1.6.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Cider Storm is an Emacs Cider front-end for the
;; [FlowStorm debugger](https://github.com/jpmonettas/flow-storm-debugger)
;; with support for Clojure and ClojureScript.

;; It brings the time-travel code stepping capabilities of FlowStorm to Emacs,
;; providing an interface similar to the Cider debugger one.

;; Cider Storm isn't trying to re-implement the entire FlowStorm UI, but the
;; most used functionality.  You can always start the full FlowStorm UI if you
;; need the extra tools.

;;; Code:

(require 'cider)

;;(add-to-list 'cider-jack-in-nrepl-middlewares "flow-storm.nrepl.middleware/wrap-flow-storm")

;;;;;;;;;;;;;;;;;;;;
;; Debugger state ;;
;;;;;;;;;;;;;;;;;;;;

(defvar cider-storm-current-flow-id nil
  "The current flow id. Will be a positive number or nil
for the funnel flow")

(defvar cider-storm-current-thread-id nil
  "Always a positive number representing the thread the stepper
is currently on")

(defvar cider-storm-current-entry nil
  "A nrepl dict representing the current entry on the timeline
the stepper is currently in.
The stepper will always be on a fn-call, expr or fn-return
Example :

(dict
    \"type\"        \"expr\"
    \"coord\"       (2 2 1)
    \"fn-call-idx\" 117
    \"idx\"         118
    \"result\"      6)
")

(defvar cider-storm-initial-entry nil
  "The entry point to your recordings. This should be a timeline
entry always of type fn-call.
Example :
(dict
    \"type\"       \"fn-call\"
    \"flow-id\"     nil
    \"thread-id\"   18
    \"fn-args\"     1
    \"fn-call-idx\" 116
    \"fn-name\"     \"boo\"
    \"fn-ns\"       \"dev-tester\"
    \"form-id\"     698052411
    \"idx\"         116
    \"parent-indx\" 115
    \"ret-idx\"     874)
")

(defvar cider-storm-current-frame nil
  "The current fn frame the stepper is in.
Example :

(dict
 \"args-vec\"           2
 \"fn-call-idx\"        117
 \"fn-name\"            \"other-function\"
 \"fn-ns\"              \"dev-tester\"
 \"form-id\"            1451539897
 \"parent-fn-call-idx\" 116
 \"ret\"                5)
")

(defvar cider-storm-current-thread-trace-cnt nil
  "Current thread timeline length")

(defvar cider-storm-disabled-evil-mode-p nil
  "Tracks if we disabled evil-mode when entering the debugger minor-mode
so we know if we need to restore it after.")

;;;;;;;;;;;;;;;;;;;;
;; Middleware api ;;
;;;;;;;;;;;;;;;;;;;;

(defun cider-storm--trace-cnt (flow-id thread-id)
  (thread-first (cider-nrepl-send-sync-request `("op"        "flow-storm-trace-count"
                                                 "flow-id"   ,flow-id
                                                 "thread-id" ,thread-id))
                (nrepl-dict-get "trace-cnt")))

(defun cider-storm--find-fn-call (fq-fn-symb from-idx from-back)
  (thread-first (cider-nrepl-send-sync-request `("op"         "flow-storm-find-fn-call"
                                                 "fq-fn-symb" ,fq-fn-symb
                                                 "from-idx"   ,from-idx
                                                 "from-back"  ,(if from-back "true" "false")))
                (nrepl-dict-get "fn-call")))

(defun cider-storm--get-form (form-id)
  (thread-first (cider-nrepl-send-sync-request `("op"         "flow-storm-get-form"
                                                 "form-id" ,form-id))
                (nrepl-dict-get "form")))

(defun cider-storm--timeline-entry (flow-id thread-id idx drift)
  (thread-first (cider-nrepl-send-sync-request `("op"        "flow-storm-timeline-entry"
                                                 "flow-id"   ,flow-id
                                                 "thread-id" ,thread-id
                                                 "idx"       ,idx
                                                 "drift"     ,drift))
                (nrepl-dict-get "entry")))

(defun cider-storm--frame-data (flow-id thread-id fn-call-idx)
  (thread-first (cider-nrepl-send-sync-request `("op"          "flow-storm-frame-data"
                                                 "flow-id"     ,flow-id
                                                 "thread-id"   ,thread-id
                                                 "fn-call-idx" ,fn-call-idx))
                (nrepl-dict-get "frame")))

(defun cider-storm--pprint-val-ref (v-ref print-length print-level print-meta pprint)
  (thread-first (cider-nrepl-send-sync-request `("op"          "flow-storm-pprint"
                                                 "val-ref"      ,v-ref
                                                 "print-length" ,print-length
                                                 "print-level"  ,print-level
                                                 "print-meta"   ,(if print-meta "true" "false")
                                                 "pprint"       ,(if pprint     "true" "false")))
                (nrepl-dict-get "pprint")))

(defun cider-storm--bindings (flow-id thread-id idx all-frame)
  (thread-first (cider-nrepl-send-sync-request `("op"          "flow-storm-bindings"
                                                 "flow-id"   ,flow-id
                                                 "thread-id" ,thread-id
                                                 "idx"       ,idx
                                                 "all-frame" ,(if all-frame "true" "false")))
                (nrepl-dict-get "bindings")))

(defun cider-storm--clear-recordings ()
  (cider-nrepl-send-sync-request `("op" "flow-storm-clear-recordings")))

(defun cider-storm--recorded-functions ()
  (thread-first (cider-nrepl-send-sync-request `("op" "flow-storm-recorded-functions"))
                (nrepl-dict-get "functions")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Debugger implementation ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun cider-storm--debug-mode-enter ()
  (cider-storm-debugging-mode 1)

  (when (and (boundp 'evil-local-mode)
             evil-local-mode)
    ;; if evil-mode disable evil-mode for the buffer
    (evil-local-mode -1)
    (setq cider-storm-disabled-evil-mode-p t)
    (message "Evil mode disabled for this buffer while the debugger is on")))

(defun cider-storm--debug-mode-quit ()
  (cider--debug-remove-overlays)
  (cider-storm-debugging-mode -1)

  ;; restore evil-mode for the buffer if we disabled it
  (when cider-storm-disabled-evil-mode-p
    (evil-local-mode 1)
    (message "Evil mode restored in this buffer")))

(defun cider-storm--select-form (form-id)
  (let* ((form (cider-storm--get-form form-id))
         (form-file (nrepl-dict-get form "file"))
         (form-line (nrepl-dict-get form "line")))

    (if (and form-file form-line)
        (when-let* ((buf (cider--find-buffer-for-file form-file)))
          (with-current-buffer buf
            (switch-to-buffer buf)
            (cider-storm--debug-mode-enter)
            (forward-line (- form-line (line-number-at-pos)))
            form-line))

      (let* ((pprinted-form (nrepl-dict-get form "pprint"))
             (dbg-buf (cider-popup-buffer "*cider-storm-dbg*" 'select 'clojure-mode)))
        (with-current-buffer dbg-buf
          (let ((inhibit-read-only t))
            (cider-storm--debug-mode-enter)
            (insert "\n")
            (insert pprinted-form)
            (goto-line 2)
            2))))))

(defun cider-storm--entry-type (entry)
  (pcase (nrepl-dict-get entry "type")
    ("fn-call"   'fn-call)
    ("fn-return" 'fn-return)
    ("expr"      'expr)))

(defun cider-storm--show-header-overlay (form-line entry-idx total-entries)
  (let* ((form-beg-pos (save-excursion (goto-line (- form-line 1)) (point)))
         (props '(face cider-debug-code-overlay-face priority 2000))
         (o (make-overlay form-beg-pos form-beg-pos (current-buffer))))
    (overlay-put o 'category 'debug-code)
    (overlay-put o 'cider-temporary t)
    (overlay-put o 'face 'cider-debug-code-overlay-face)
    (overlay-put o 'priority 2000)
    (overlay-put o 'before-string (format "CiderStorm - Debugging (%d/%d), press h for help" entry-idx total-entries))
    (push #'cider--delete-overlay (overlay-get o 'modification-hooks))))

(defun cider-storm--display-step (form-id entry trace-cnt)
  (let* ((form-line (cider-storm--select-form form-id))
         (entry-type (cider-storm--entry-type entry))
         (entry-idx (nrepl-dict-get entry "idx")))

    (when-let* ((coord (nrepl-dict-get entry "coord")))
      (cider--debug-move-point coord))

    (cider--debug-remove-overlays)

    (when form-line
      (cider-storm--show-header-overlay form-line entry-idx trace-cnt))

    (when (or (eq entry-type 'fn-return)
              (eq entry-type 'expr))
      (let* ((val-ref (nrepl-dict-get entry "result"))
             (val-pprint (cider-storm--pprint-val-ref val-ref
                                                      50
                                                      3
                                                      nil
                                                      nil))
             (val-type (nrepl-dict-get val-pprint "val-type"))
             (val-str (nrepl-dict-get val-pprint "val-str")))

        (cider--debug-display-result-overlay val-str)))))

(defun cider-storm--show-help ()
  (let* ((help-text "Keybidings

P - Step prev over. Go to the previous recorded step on the same frame.
p - Step prev. Go to the previous recorded step.
n - Step next. Go to the next recorded step.
N - Step next over. Go to the next recorded step on the same frame.
^ - Step out. Go to the next recorded step after this frame.
< - Step first. Go to the first recorded step for the function you called cider-storm-debug-current-fn on.
> - Step last. Go to the last recorded step for the function you called cider-storm-debug-current-fn on.
. - Pprint current value.
i - Inspect current value using the Cider inspector.
t - Tap the current value.
D - Define all recorded bindings for this frame (scope capture like).
h - Prints this help.
q - Quit the debugger mode.")

         (help-buf (cider-popup-buffer "*cider-storm-help*" 'select)))
    (with-current-buffer help-buf
      (let ((inhibit-read-only t))
        (insert help-text)))))

(defun cider-storm--pprint-current-entry ()
  (let* ((entry-type (cider-storm--entry-type cider-storm-current-entry)))
    (when (or (eq entry-type 'fn-return)
              (eq entry-type 'expr))
      (let* ((val-ref (nrepl-dict-get cider-storm-current-entry "result"))
             (val-pprint (cider-storm--pprint-val-ref val-ref
                                                      50
                                                      3
                                                      nil
                                                      't))
             (val-type (nrepl-dict-get val-pprint "val-type"))
             (val-str (nrepl-dict-get val-pprint "val-str"))
             (val-buffer (cider-popup-buffer "*cider-storm-pprint*" 'select 'clojure-mode)))

        (with-current-buffer val-buffer
          (let ((inhibit-read-only t))
            (insert val-str)))))))

(defun cider-storm--jump-to-code (flow-id thread-id next-entry)
  (let* ((curr-fn-call-idx (nrepl-dict-get cider-storm-current-frame "fn-call-idx"))
         (next-fn-call-idx (nrepl-dict-get next-entry "fn-call-idx"))
         (changing-frame? (not (eq curr-fn-call-idx next-fn-call-idx)))
         (curr-frame (if changing-frame?
                         (let* ((first-frame (cider-storm--frame-data flow-id thread-id 0))
                                (first-entry (cider-storm--timeline-entry flow-id thread-id 0 "at"))
                                (trace-cnt (cider-storm--trace-cnt flow-id thread-id)))
                           (setq cider-storm-current-thread-trace-cnt trace-cnt)
                           (setq cider-storm-current-frame first-frame)
                           (setq cider-storm-current-entry first-entry)
                           first-frame)
                       cider-storm-current-frame))
         (curr-idx (nrepl-dict-get cider-storm-current-entry "idx"))
         (next-idx (nrepl-dict-get next-entry "idx"))

         (next-frame (if changing-frame?
                         (cider-storm--frame-data flow-id thread-id next-fn-call-idx)
                       cider-storm-current-frame))
         (curr-form-id (nrepl-dict-get cider-storm-current-frame "form-id"))
         (next-form-id (nrepl-dict-get next-frame "form-id"))
         (first-jump? (and (zerop curr-idx) (zerop next-idx)))
         (changing-form? (not (eq curr-form-id next-form-id))))

    (when changing-frame?
      (setq cider-storm-current-frame next-frame))

    (cider-storm--display-step next-form-id next-entry cider-storm-current-thread-trace-cnt)

    (setq cider-storm-current-entry next-entry)))

(defun cider-storm--jump-to (n)
  (let* ((entry (cider-storm--timeline-entry cider-storm-current-flow-id
                                             cider-storm-current-thread-id
                                             n
                                             "at")))
    (cider-storm--jump-to-code cider-storm-current-flow-id
                               cider-storm-current-thread-id
                               entry)))

(defun cider-storm--step (drift)

  (let* ((curr-idx (nrepl-dict-get cider-storm-current-entry "idx")))
    (if curr-idx
        (let* ((next-entry (cider-storm--timeline-entry cider-storm-current-flow-id
                                                        cider-storm-current-thread-id
                                                        curr-idx
                                                        drift)))
          (cider-storm--jump-to-code cider-storm-current-flow-id
                                     cider-storm-current-thread-id
                                     next-entry))

      (message "Not pointing at any recording entry."))))


(defun cider-storm--define-all-bindings-for-frame ()
  (let* ((bindings (cider-storm--bindings cider-storm-current-flow-id
                                          cider-storm-current-thread-id
                                          (nrepl-dict-get cider-storm-current-entry "idx")
                                          't)))
    (nrepl-dict-map
     (lambda (bind-name bind-val-id)
       (cider-interactive-eval (format "(def %s (flow-storm.runtime.values/deref-value (flow-storm.types/make-value-ref %d)))"
                                       bind-name
                                       bind-val-id)))
     bindings)))

(defun cider-storm--inspect-current-entry ()
  (let* ((entry-type (cider-storm--entry-type cider-storm-current-entry)))
    (if (or (eq entry-type 'fn-return)
            (eq entry-type 'expr))

        (let* ((val-ref (nrepl-dict-get cider-storm-current-entry "result")))
          (cider-inspect-expr (format "(flow-storm.runtime.values/deref-value (flow-storm.types/make-value-ref %d))" val-ref)
                              (cider-current-ns)))

      (message "You are currently positioned in a FnCall which is not inspectable."))))

(defun cider-storm--tap-current-entry ()
  (let* ((entry-type (cider-storm--entry-type cider-storm-current-entry)))
    (if (or (eq entry-type 'fn-return)
            (eq entry-type 'expr))

        (let* ((val-ref (nrepl-dict-get cider-storm-current-entry "result")))
          (cider-interactive-eval (format "(tap> (flow-storm.runtime.values/deref-value (flow-storm.types/make-value-ref %d)))" val-ref)))

      (message "You are currently positioned in a FnCall which is not inspectable."))))

(defun cider-storm--debug-fn (fq-fn-name)
  (let* ((fn-call (cider-storm--find-fn-call fq-fn-name 0 nil)))
    (if fn-call
        (let* ((form-id (nrepl-dict-get fn-call "form-id"))
               (flow-id (nrepl-dict-get fn-call "flow-id"))
               (thread-id (nrepl-dict-get fn-call "thread-id"))
               (trace-cnt (cider-storm--trace-cnt flow-id thread-id)))
          (setq cider-storm-current-entry fn-call)
          (setq cider-storm-current-flow-id flow-id)
          (setq cider-storm-current-thread-id thread-id)
          (setq cider-storm-initial-entry fn-call)
          (setq cider-storm-current-thread-trace-cnt trace-cnt)
          (setq cider-storm-current-frame nil)
          (cider-storm--display-step form-id fn-call cider-storm-current-thread-trace-cnt))
      (message "No recording found for %s/%s" fn-ns fn-name))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Debugger interactive API ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun cider-storm-clear-recordings ()

  "Clear all FlowStorm recordings, for every flow and every thread.

Useful for running it before executing the code you are interested in debugging,
to ensure all the recordings have to do with the code you just run."

  (interactive)

  (cider-storm--clear-recordings))

(defun cider-storm-debug-current-fn ()

  "When the cursor is over a fn name, it will start the debugger
on the first recording found for that fn name. Will search every flow and
every thread."

  (interactive)

  (cider-try-symbol-at-point
   "Debug fn"
   (lambda (var-name)
     (let* ((info (cider-var-info var-name))
            (fn-ns (nrepl-dict-get info "ns"))
            (fn-name (nrepl-dict-get info "name"))
            (fq-fn-name (format "%s/%s" fn-ns fn-name)))
       (when (and fn-ns fn-name)
         (cider-storm--debug-fn fq-fn-name))))))

(defun cider-storm-debug-fn ()

  "Lets you select a function from a list of all the functions currently recorded.
Will search every flow and every thread.

After selecting one, will start the debugger on that function."

  (interactive)

  (let* ((fns (cider-storm--recorded-functions))
         (fq-fn-name (completing-read "Recorded function :"
                                      (mapcar (lambda (fn-dict)
                                                (nrepl-dict-get fn-dict "fq-fn-name"))
                                              fns))))
    (cider-storm--debug-fn fq-fn-name)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; cider-storm minor mode ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-minor-mode cider-storm-debugging-mode
  "Toggle cider-storm-debugging-mode"
  ;; The initial value.
  :init-value nil
  ;; The indicator for the mode line.
  :lighter " STORM-DBG"
  ;; The minor mode bindings.
  :keymap
  '(("q" . (lambda () (interactive) (cider-storm--debug-mode-quit)))
    ("^" . (lambda () (interactive) (cider-storm--step "next-out")))
    ("n" . (lambda () (interactive) (cider-storm--step "next")))
    ("N" . (lambda () (interactive) (cider-storm--step "next-over")))
    ("p" . (lambda () (interactive) (cider-storm--step "prev")))
    ("P" . (lambda () (interactive) (cider-storm--step "prev-over")))
    ("<" . (lambda () (interactive) (cider-storm--jump-to (nrepl-dict-get cider-storm-initial-entry "idx"))))
    (">" . (lambda () (interactive) (cider-storm--jump-to (nrepl-dict-get cider-storm-initial-entry "ret-idx"))))
    ("h" . (lambda () (interactive) (cider-storm--show-help)))
    ("." . (lambda () (interactive) (cider-storm--pprint-current-entry)))
    ("i" . (lambda () (interactive) (cider-storm--inspect-current-entry)))
    ("t" . (lambda () (interactive) (cider-storm--tap-current-entry)))
    ("D" . (lambda () (interactive) (cider-storm--define-all-bindings-for-frame)))))

(provide 'cider-storm)
;;; cider-storm.el ends here
