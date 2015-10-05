;;; incudine.el --- major mode for editing Incudine sources

;; Copyright (c) 2013-2015 Tito Latini

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
;; incudine.el

;; Installation:

;; Add the following lines to your `.emacs' file
;;
;;   (push "/path/to/incudine/contrib/editors/emacs" load-path)
;;   (require 'incudine)

;;; Code:
(require 'slime)

(defgroup incudine nil
  "Major mode for editing incudine code."
  :group 'languages)

(defvar incudine-mode-hook nil
  "Hook called when a buffer enters Incudine mode.")

(defcustom incudine-scratch-message nil
  "Initial message displayed in *incudine-scratch* buffer.
If this is nil, no message will be displayed."
  :type '(choice (text :tag "Message")
                 (const :tag "none" nil))
  :group 'incudine)

(defun incudine-buffer-name (string)
  (concat "*incudine-" string "*"))

(defvar incudine-scratch-buffer (incudine-buffer-name "scratch"))

(defun incudine-scratch ()
  "Switch to Incudine scratch buffer."
  (interactive)
  (let ((buffer (get-buffer incudine-scratch-buffer)))
    (unless buffer
      (setq buffer (get-buffer-create incudine-scratch-buffer))
      (with-current-buffer buffer
	(incudine-mode)
        (if incudine-scratch-message
            (insert incudine-scratch-message))))
    (switch-to-buffer buffer)))

(defun incudine-eval (string &rest args)
  (slime-eval-with-transcript
   `(swank:interactive-eval ,(if args
                                 (apply #'format string args)
                                 string))))

(defun incudine-eval-defun ()
  (interactive)
  (slime-eval-defun))

(defun incudine-show-repl ()
  "Show REPL in other window."
  (interactive)
  (switch-to-buffer-other-window (slime-output-buffer)))

(defun incudine-repl-clear-buffer ()
  (interactive)
  (save-window-excursion
    (with-current-buffer (slime-repl-buffer)
      (slime-repl-insert-prompt)
      (slime-repl-clear-buffer))))

(defun incudine-prev-defun (&optional n)
  "Jump at the end of the previous defun."
  (interactive "p")
  (end-of-defun)
  (beginning-of-defun)
  (if n
      (loop repeat n do (beginning-of-defun))
      (beginning-of-defun))
  (forward-sexp))

(defun incudine-next-defun (&optional n)
  "Jump at the end of the next defun."
  (interactive "p")
  (end-of-defun)
  (if n
      (loop repeat n do (end-of-defun))
      (forward-sexp))
  (beginning-of-defun)
  (forward-sexp))

(defun incudine-eval-and-next-fn ()
  "Eval the function and jump to the next."
  (interactive)
  (slime-eval-defun)
  (incudine-next-defun))

(defun incudine-eval-and-prev-fn ()
  "Eval the function and jump to the previous."
  (interactive)
  (slime-eval-defun)
  (incudine-prev-defun))

(defun prefix-numeric-value0 (n)
  (if n (prefix-numeric-value n) 0))

(defun incudine-rt-start (&optional block-size)
  "Realtime start.
If BLOCK-SIZE is positive, set the new block size before starting."
  (interactive "P")
  (let ((n (prefix-numeric-value0 block-size)))
    (if (> n 0)
        (incudine-eval
          "(progn (set-rt-block-size %d) (values (incudine:rt-start) (block-size)))"
          n)
        (incudine-eval "(incudine:rt-start)"))))

(defun incudine-rt-stop ()
  "Realtime stop."
  (interactive)
  (incudine-eval "(incudine:rt-stop)"))

(defun incudine-free-node (&optional id)
  "Stop to play a node of the graph.
If ID is negative, call INCUDINE:STOP instead of INCUDINE:FREE.
If ID is zero, call INCUDINE:FLUSH-PENDING before INCUDINE:FREE."
  (interactive "P")
  (let ((n (prefix-numeric-value0 id)))
    (incudine-eval (cond ((= n 0) "(progn (incudine:flush-pending) (incudine:free 0))")
                         ((< n 0) "(incudine:stop %d)")
                         (t "(incudine:free %d)"))
                   (abs n))))

(defun incudine-pause-node (&optional id)
  "Pause node."
  (interactive "P")
  (incudine-eval "(incudine:pause %d)"
                 (prefix-numeric-value0 id)))

(defun incudine-unpause-node (&optional id)
  "Pause node."
  (interactive "P")
  (incudine-eval "(incudine:unpause %d)"
                 (prefix-numeric-value0 id)))

(defun incudine-dump-graph (&optional node)
  "Print informations about the graph of nodes."
  (interactive "P")
  (incudine-eval "(incudine:dump (node %d))"
                 (prefix-numeric-value0 node)))

(defun incudine-gc ()
  "Initiate a garbage collection."
  (interactive)
  (incudine-eval "(tg:gc :full t)"))

(defun incudine-bytes-consed-in (&optional time)
  "Rough estimate of the bytes consed in TIME seconds."
  (interactive "p")
  (incudine-eval "(incudine.util:get-bytes-consed-in %d)"
                 (prefix-numeric-value time)))

(defun incudine-rt-memory-free-size ()
  "Display the free realtime memory"
  (interactive)
  (incudine-eval
   "(values (incudine.util:get-foreign-sample-free-size)
            (incudine.util:get-rt-memory-free-size))"))

(defun incudine-peak-info (&optional ch)
  "Display the peak info of a channel. Reset the meters if CH is negative"
  (interactive "P")
  (let ((value (prefix-numeric-value0 ch)))
    (if (minusp value)
        (incudine-eval "(incudine:reset-peak-meters)")
        (incudine-eval "(incudine:peak-info %d)" value))))

(defun incudine-set-logger-level (value)
  "Set Logger Level."
  (incudine-eval "(setf (incudine.util:logger-level) %s)" value))

(defun incudine-logger-level-choice (c)
  "Set Logger Level from a single character."
  (interactive "cLogger level? (e)rror, (w)arn, (i)nfo or (d)ebug")
  (when (member c '(?e ?w ?i ?d))
    (incudine-set-logger-level
      (case c
        (?e ":ERROR")
        (?w ":WARN")
        (?i ":INFO")
        (?d ":DEBUG")))))

(defun incudine-set-logger-time (value)
  "Set Logger Time."
  (incudine-eval "(setf (incudine.util:logger-time) %s)" value))

(defun incudine-logger-time-choice (c)
  "Set Logger Time from a single character."
  (interactive "cLogger time? (S)amples, (s)econds or (n)il")
  (when (member c '(?S ?s ?n))
    (incudine-set-logger-time
      (case c
        (?n "NIL")
        (?s ":SEC")
        (?S ":SAMP")))))

(defvar incudine-mode-map
  (let ((map (make-sparse-keymap "Incudine")))
    (define-key map [C-return] 'incudine-eval-and-next-fn)
    (define-key map [C-S-return] 'incudine-eval-and-prev-fn)
    (define-key map [M-return] 'incudine-eval-defun)
    (define-key map [C-M-return] 'incudine-free-node)
    (define-key map [prior] 'incudine-prev-defun)
    (define-key map [next] 'incudine-next-defun)
    (define-key map "\C-cv" 'incudine-show-repl)
    (define-key map "\C-cs" 'incudine-scratch)
    (define-key map "\C-c\M-o" 'incudine-repl-clear-buffer)
    (define-key map "\C-crs" 'incudine-rt-start)
    (define-key map "\C-crq" 'incudine-rt-stop)
    (define-key map "\C-cp" 'incudine-pause-node)
    (define-key map "\C-cu" 'incudine-unpause-node)
    (define-key map "\C-cgc" 'incudine-gc)
    (define-key map "\C-cgb" 'incudine-bytes-consed-in)
    (define-key map "\C-cig" 'incudine-dump-graph)
    (define-key map "\C-cim" 'incudine-rt-memory-free-size)
    (define-key map "\C-cip" 'incudine-peak-info)
    (define-key map "\C-cll" 'incudine-logger-level-choice)
    (define-key map "\C-clt" 'incudine-logger-time-choice)
    map)
  "Keymap for Incudine mode.")

(easy-menu-define incudine-mode-menu incudine-mode-map
  "Menu used in Incudine mode."
  (list "Incudine"
        (list "REPL"
              ["Show REPL" incudine-show-repl t]
              ["REPL Clear Buffer" incudine-repl-clear-buffer t])
        (list "Realtime"
              ["RT Start" incudine-rt-start t]
              ["RT Stop" incudine-rt-stop t]
              ["Peak Info"
               (incudine-peak-info
                 (string-to-number (read-from-minibuffer "Channel: " "0")))
               :keys "C-c i p"]
              ["Reset Peak Meters" (incudine-peak-info -1) t])
        (list "Graph"
              ["Stop Playing" incudine-free-node t]
              ["Pause" incudine-pause-node t]
              ["Unpause" incudine-unpause-node t]
              ["Print Graph" incudine-dump-graph t])
        (list "Memory"
              ["Garbage Collection" incudine-gc t]
              ["RT Memory Free Size" incudine-rt-memory-free-size t])
        (list "Logger"
              ["Log Level" incudine-logger-level-choice t]
              ["Log Time"  incudine-logger-time-choice t])
        ["Scratch buffer" incudine-scratch t]))

(add-to-list 'auto-mode-alist '("\\.cudo$" . incudine-mode))

(define-derived-mode incudine-mode lisp-mode "Incudine"
  "Major mode for incudine.

\\{incudine-mode-map}"
  (use-local-map incudine-mode-map)
  (easy-menu-add incudine-mode-menu)
  (run-hooks 'incudine-mode-hook))

(provide 'incudine)
