;;; Copyright (c) 2013-2014 Tito Latini
;;;
;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 2 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program; if not, write to the Free Software
;;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

(in-package :incudine.vug)

(defmacro done-action (action)
  `(funcall ,action (dsp-node)))

(defmacro done-self ()
  `(incudine::node-done-p (dsp-node)))

(defmacro free-self ()
  `(incudine:free (dsp-node)))

(defmacro free-self-when-done ()
  `(when (done-self) (free-self)))

;;;  +--------------------------------+
;;;  |   Header of a foreign array    |
;;;  +--------+-----------------------+
;;;  | 4 bits |        24 bits        |
;;;  +--------+-----------------------+
;;;  |  type  |      array length     |
;;;  +--------+-----------------------+

(define-constant +foreign-header-size+ 4)

(define-constant +foreign-array-length-bits+ 24)

(define-constant +foreign-array-length-mask+ #xFFFFFF)

(define-constant +unknown-foreign-type+ 0)

(defvar *foreign-array-types*
  #(:unknown sample :int32 :uint32 :int64 :uint64 :float :double :pointer))
(declaim (type simple-vector *foreign-array-types*))

(declaim (inline foreign-type-to-tag))
(defun foreign-type-to-tag (type)
  (the (unsigned-byte 28)
       (ash (or (position type *foreign-array-types* :test #'eq)
                +unknown-foreign-type+)
            +foreign-array-length-bits+)))

(declaim (inline make-foreign-header))
(defun make-foreign-header (size type)
  (logior (foreign-type-to-tag type)
          (logand size +foreign-array-length-mask+)))

(defmacro %make-foreign-array (size type &rest args)
  (let ((arr-wrap (gensym (format nil "~A-WRAP" type)))
        (data (gensym "DATA")))
    `(with ((,arr-wrap (make-foreign-array (the positive-fixnum (1+ ,size))
                                           ',type ,@args))
            (,data (let ((,data (foreign-array-data ,arr-wrap)))
                     (setf (cffi:mem-ref ,data :uint32
                                         ,(- (cffi:foreign-type-size type)
                                             +foreign-header-size+))
                           (make-foreign-header ,size ',type))
                     (cffi:inc-pointer ,data ,(cffi:foreign-type-size type)))))
       (declare (type foreign-array ,arr-wrap) (type foreign-pointer ,data))
       ,data)))

(declaim (inline foreign-length))
(defun foreign-length (pointer)
  (logand (cffi:mem-ref (cffi:inc-pointer pointer (- +foreign-header-size+))
                        :uint32)
          +foreign-array-length-mask+))

(declaim (inline foreign-array-type-of))
(defun foreign-array-type-of (pointer)
  (svref *foreign-array-types*
         (ash (cffi:mem-ref (cffi:inc-pointer pointer (- +foreign-header-size+))
                            :uint32)
              (- +foreign-array-length-bits+))))

(macrolet ((make-*-array (name type)
             `(defmacro ,name (&whole whole size &key zero-p initial-element
                               initial-contents)
                (declare (ignore zero-p initial-element initial-contents))
                `(%make-foreign-array ,size ,,type ,@(cddr whole)))))
  ;; A FRAME is a foreign array of SAMPLE type, useful to efficiently
  ;; store and return multiple values from a VUG
  (make-*-array make-frame 'sample)
  ;; Other utilities to create foreign arrays.
  (make-*-array make-int32-array :int32)
  (make-*-array make-uint32-array :uint32)
  (make-*-array make-int64-array :int64)
  (make-*-array make-uint64-array :uint64)
  (make-*-array make-f32-array :float)
  (make-*-array make-f64-array :double))

(defmacro make-pointer-array (size)
  `(%make-foreign-array ,size :pointer))

(defmacro maybe-make-i32-array (&whole whole size &key zero-p initial-element
                                initial-contents)
  (declare (ignore initial-element initial-contents))
  (let ((key-args (copy-list (cddr whole))))
    (if (< incudine.util::n-fixnum-bits 32)
        `(make-int32-array ,size ,@key-args)
        `(make-array ,size ,@(if zero-p `(:initial-element 0))
                     ,@(progn (remf key-args :zero-p) key-args)))))

(defmacro maybe-make-u32-array (&whole whole size &key zero-p initial-element
                                initial-contents)
  (declare (ignore initial-element initial-contents))
  (let ((key-args (copy-list (cddr whole))))
    (if (< incudine.util::n-fixnum-bits 32)
        `(make-uint32-array ,size ,@key-args)
        `(make-array ,size ,@(if zero-p `(:initial-element 0))
                     ,@(progn (remf key-args :zero-p) key-args)))))

(defmacro maybe-i32-ref (array index)
  (if (< incudine.util::n-fixnum-bits 32)
      `(i32-ref ,array ,index)
      `(the fixnum (svref ,array ,index))))

(defmacro maybe-u32-ref (array index)
  (if (< incudine.util::n-fixnum-bits 32)
      `(u32-ref ,array ,index)
      `(the fixnum (svref ,array ,index))))

;;; Return a value of a frame
(defmacro frame-ref (frame channel)
  `(smp-ref ,frame ,channel))

;;; Like MULTIPLE-VALUE-BIND but dedicated to a FRAME
(defmacro multiple-sample-bind (vars frame &body body)
  (with-gensyms (frm)
    `(with ((,frm ,frame))
       (declare (type frame ,frm))
       (maybe-expand ,frm)
       (symbol-macrolet ,(loop for var in vars for count from 0
                               collect `(,var (frame-ref ,frm ,count)))
         ,@body))))

(defmacro samples (&rest values)
  (with-gensyms (frm)
    (let ((size (length values)))
    `(with ((,frm (make-frame ,size)))
       ,@(loop for value in values for count from 0
               collect `(setf (frame-ref ,frm ,count)
                              ,(if (and (numberp value)
                                        (not (typep value 'sample)))
                                   (sample value)
                                   value)))
       (values ,frm ,size)))))

;;; Calc only one time during a tick
(defmacro foreach-tick (&body body)
  (with-gensyms (old-time)
    `(with-samples ((,old-time -1.0d0))
       (unless (= (now) ,old-time)
         (setf ,old-time (now))
         ,@body)
       (values))))

(defmacro foreach-channel (&body body)
  (with-gensyms (i)
    `(dochannels (,i *number-of-output-bus-channels*)
       (let ((current-channel ,i))
         (declare (type channel-number current-channel)
                  (ignorable current-channel))
         ,@body))))

;;; Count from START to END (excluded)
(define-vug-macro counter (start end &key (step 1) loop-p done-action)
  (with-gensyms (%start %end %step index done-p %loop-p)
    `(with-vug-inputs ((,%start ,start)
                       (,%end ,end)
                       (,%step ,step)
                       (,%loop-p ,loop-p))
       (declare (type fixnum ,%start ,%end ,%step) (type boolean ,%loop-p))
       (with ((,done-p nil)
              (,index (progn (if ,done-p (setf ,done-p nil))
                             ,%start)))
         (declare (type fixnum ,index) (type boolean ,done-p))
         (prog1 ,index
           (unless ,done-p
             (setf ,index
                   (the fixnum
                     (if (< ,index ,%end)
                         (+ ,index ,%step)
                         (cond (,%loop-p ,%start)
                               (t (done-action ,(or done-action
                                                    '(function identity)))
                                  (setf ,done-p t)
                                  ,index)))))))))))

(define-vug downsamp ((control-period fixnum) in)
  (with ((count control-period)
         (value +sample-zero+))
    (declare (type fixnum count) (type sample value))
    (initialize (setf count 0))
    (if (<= count 1)
        (setf count control-period value in)
        (progn (decf count) value))))

(define-vug snapshot ((gate fixnum) (start-offset fixnum) input)
  "INPUT is updated every GATE samples, on demand or never.
If GATE is positive, the output is INPUT calculated every GATE samples.
If GATE is zero, the output is the old value of INPUT.
If GATE is negative, the output is the current value of INPUT and GATE
becomes zero.
START-OFFSET is the initial offset for the internal counter."
  (with-samples ((next-time (init-only (+ (now) gate)))
                 (value +sample-zero+))
    (initialize (setf next-time (+ (now) start-offset)))
    (cond ((plusp gate)
           (unless (< (now) next-time)
             (setf value (update input))
             (setf next-time (+ (now) gate))))
          ((minusp gate)
           (setf value (update input) gate 0)))
    value))

(define-vug %with-control-period ((gate fixnum) (start-offset fixnum) (input t))
  (with-samples ((next-time (init-only (+ (now) gate))))
    (initialize (setf next-time (+ (now) start-offset)))
    (cond ((plusp gate)
           (unless (< (now) next-time)
             (update input)
             (setf next-time (+ (now) gate))))
          ((minusp gate)
           (update input)
           (setf gate 0)))
    nil))

(define-vug-macro with-control-period ((n &optional (start-offset 0))
                                       &body body)
  "BODY is updated every N samples, on demand or never.
If N is positive, BODY is updated every N samples.
If N is zero, BODY is not updated.
If N is negative, BODY is updated and N becomes zero.
START-OFFSET is the initial offset for the internal counter."
  (with-gensyms (gate start)
    `(with-vug-inputs ((,gate ,n)
                       (,start ,start-offset))
       (%with-control-period ,gate ,start (progn ,@body)))))

(define-vug samphold (in gate initial-value initial-threshold)
  (with-samples ((threshold initial-threshold)
                 (value initial-value))
    (when (< gate threshold) (setf value in))
    (setf threshold gate)
    value))

(define-vug lin->lin (in old-min old-max new-min new-max)
  (with-samples ((old-rdelta (/ (sample 1) (- old-max old-min)))
                 (new-delta (- new-max new-min)))
    (+ new-min (* new-delta old-rdelta (- in old-min)))))

(define-vug lin->exp (in old-min old-max new-min new-max)
  (with-samples ((old-rdelta (/ (sample 1) (- old-max old-min)))
                 (new-ratio (/ new-max new-min)))
    (* (expt (the non-negative-sample new-ratio)
             (* old-rdelta (- in old-min)))
       new-min)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro %with-samples-rebinding (bindings &body body)
    `(let ,(mapcar (lambda (x)
                     (let ((value (cadr x)))
                       `(,(car x) (if (atom ,value) ,value (gensym)))))
                   bindings)
       `(with-samples (,@,@(mapcar (lambda (x)
                                     (let ((value (cadr x)))
                                       `(unless (atom ,value)
                                          `((,,(car x) (vug-input ,,value))))))
                                   bindings))
          ,,@body)))

  (define-vug-macro nclip (in low high)
    (%with-samples-rebinding ((lo low) (hi high))
      `(progn
         (cond ((> ,in ,hi) (setf ,in ,hi))
               ((< ,in ,lo) (setf ,in ,lo)))
         ,in)))

  (defmacro wrap-cond ((in low high range &optional (offset in)) &rest clauses)
    `(progn
       ;; If the input is to set, here is a good place, because the
       ;; first condition in the next COND contains an explicit setter
       ;; form, so the automatic setter is disabled.
       (maybe-expand ,in)
       (cond ((zerop ,range)
              (setf ,in ,(if (eql high range) +sample-zero+ low)))
             ,@(mapcar (lambda (x)
                         `(,(car x) ,@(cdr x)
                            (when ,(car x)
                              (decf ,in (* ,range (sample->fixnum
                                                   (/ ,offset ,range)))))))
                       clauses))))

  (define-vug-macro nwrap (in low high &optional range offset)
    (%with-samples-rebinding ((lo low) (hi high))
      (let ((delta (or range hi)))
        `(progn
           (wrap-cond (,in ,lo ,hi ,delta ,(or offset in))
             ((>= ,in ,hi) (decf ,in ,delta))
             (,(if range `(< ,in ,lo) `(minusp ,in))
              (incf ,in ,delta)))
           ,in))))

  (defmacro %mirror-consequent (in threshold1 threshold2 range two-range offset
                                offset-p bias)
    (with-gensyms (os)
      `(progn
         (setf ,in (- (+ ,threshold1 ,threshold1) ,in))
         (if (< ,in ,threshold2)
             (let ((,os ,offset))
               (setf ,in (- ,os (* ,two-range
                                   (sample->fixnum (/ ,os ,two-range)))))
               (when (>= ,in ,range)
                 (setf ,in (- ,two-range ,in)))
               ,(if offset-p `(+ ,in ,bias) in))
             ,in))))

  (define-vug-macro nmirror (in low high &optional range two-range offset)
    (%with-samples-rebinding ((lo low) (hi high))
      (let ((%range (or range hi))
            (%offset (or offset in)))
          `(progn
             (maybe-expand ,in)
             (cond ((zerop ,%range)
                    (setf ,in ,(if (eql hi %range) +sample-zero+ lo)))
                   ((>= ,in ,hi)
                    (%mirror-consequent ,in ,hi ,lo ,%range ,two-range ,%offset
                                        ,offset ,lo))
                   ((< ,in ,lo)
                    (%mirror-consequent ,in ,lo ,hi ,%range ,two-range ,%offset
                                        ,offset ,lo))
                   (t ,in)))))))

(declaim (inline clip))
(defun clip (in low high)
  (flet ((%clip (in low high)
           (cond ((> in high) high)
                 ((< in low) low)
                 (t in))))
    (if (typep in 'sample)
        (%clip in (sample low) (sample high))
        (%clip in low high))))

(define-vug wrap (in low high)
  (with-samples ((range (- high low))
                 (%in in))
    (nwrap %in low high range (- %in low))))

(define-vug mirror (in low high)
  (with-samples ((range (- high low))
                 (two-range (+ range range))
                 (%in in))
    (nmirror %in low high range two-range (- in low))))

;;; Interpolation of the values generated by a VUG. The values of the
;;; generator are calculated with a modulable frequency. The possible
;;; types of the interpolation are :LINEAR (or :LIN), :COS, :CUBIC or NIL.
;;; INTERPOLATE is particularly useful with the random or chaotic VUGs.
(define-vug-macro interpolate (generator freq &optional (interpolation :linear)
                               initial-value-p)
  (with-gensyms (input phase inc x0 x1 x2 x3 delta)
    (destructuring-bind (bindings init update result)
        (case interpolation
          ((:lin :linear)
           `(((,x1 0.0d0) (,delta 0.0d0))
             (setf ,x1 ,input)
             (setf ,x0 ,x1 ,x1 (update ,input) ,delta (- ,x0 ,x1))
             (+ ,x1 (* ,phase ,delta))))
          (:cos `(((,x1 0.0d0))
                  (setf ,x1 ,input)
                  (setf ,x0 ,x1 ,x1 (update ,input))
                  (cos-interp ,phase ,x1 ,x0)))
          (:cubic `(((,x1 0.0d0) (,x2 0.0d0) (,x3 0.0d0))
                    (setf ,x1 ,input
                          ;; Three adjacent points initialized with the same
                          ;; value when it is required an initial value.
                          ,x2 ,(if initial-value-p input `(update ,input))
                          ,x3 ,(if initial-value-p input `(update ,input)))
                    (setf ,x0 ,x1 ,x1 ,x2 ,x2 ,x3 ,x3 (update ,input))
                    (cubic-interp ,phase ,x3 ,x2 ,x1 ,x0)))
          (otherwise `(nil nil (setf ,x0 (update ,input)) ,x0)))
      `(with-samples ((,input (vug-input ,generator))
                      (,phase 0.0d0)
                      (,inc (vug-input (* ,freq *sample-duration*)))
                      (,x0 0.0d0)
                      ,@bindings)
         ,@(when init `((initialize ,init)))
         (decf ,phase ,inc)
         (when (minusp ,phase)
           (setf ,phase (wrap ,phase 0 1))
           ,update)
         ,result))))
