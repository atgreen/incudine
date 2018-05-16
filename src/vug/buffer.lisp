;;; Copyright (c) 2013-2018 Tito Latini
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

(defmacro %check-phase (phase function)
  `(progn
     (maybe-expand ,phase)
     (funcall ,function)))

(defmacro %no-interp (data phs channels wrap-phase-fn)
  (with-gensyms (index)
    `(with ((,index 0))
       (declare (type non-negative-fixnum ,index))
       (foreach-tick
         (%check-phase ,phs ,wrap-phase-fn)
         (setf ,index (the non-negative-fixnum
                        (* (sample->fixnum ,phs) ,channels))))
       (if (< current-channel ,channels)
           (smp-ref ,data (the non-negative-fixnum
                            (+ ,index current-channel)))
           +sample-zero+))))

(defmacro %two-points-interp (data phs frames channels size wrap-p
                              wrap-phase-fn interp-fn-name)
  (with-gensyms (frac iphase guard-frame decr y0 y1)
    `(with ((,iphase 0)
            (,frac 0.0d0)
            (,guard-frame (- ,frames 2))
            (,decr (- (if ,wrap-p ,size ,channels)))
            (,y0 0)
            (,y1 0))
       (declare (type fixnum ,iphase ,y0 ,y1)
                (type sample ,frac) (type positive-fixnum ,guard-frame)
                (type negative-fixnum ,decr))
       (foreach-tick
         (%check-phase ,phs ,wrap-phase-fn)
         (setf ,iphase (sample->fixnum ,phs))
         (setf ,frac (- ,phs ,iphase))
         (setf ,y0 (the fixnum (* ,iphase ,channels))
               ,y1 (the fixnum (+ ,y0 ,channels)))
         (when (> ,iphase ,guard-frame)
           (incf ,y1 ,decr)))
       (if (< current-channel ,channels)
           (,interp-fn-name ,frac
                            (smp-ref ,data (the non-negative-fixnum
                                             (+ ,y0 current-channel)))
                            (smp-ref ,data (the non-negative-fixnum
                                             (+ ,y1 current-channel))))
           +sample-zero+))))

(defmacro %four-points-interp (data phs frames channels size wrap-p
                               wrap-phase-fn interp-fn-name)
  (with-gensyms (frac iphase guard-frame incr1 incr2 decr1 decr2 y0 y1 y2 y3)
    `(with ((,iphase 0)
            (,frac 0.0d0)
            (,guard-frame (- ,frames 2))
            (,incr1 (if ,wrap-p ,size ,channels))
            (,incr2 (if ,wrap-p ,size (* 2 ,channels)))
            (,decr1 (- ,incr1))
            (,decr2 (- ,incr2))
            (,y0 0)
            (,y1 0)
            (,y2 0)
            (,y3 0))
       (declare (type fixnum ,iphase ,y0 ,y1 ,y2 ,y3) (type sample ,frac)
                (type positive-fixnum ,guard-frame ,incr1 ,incr2)
                (type negative-fixnum ,decr1 ,decr2))
       (foreach-tick
         (%check-phase ,phs ,wrap-phase-fn)
         (setf ,iphase (sample->fixnum ,phs))
         (setf ,frac (- ,phs ,iphase))
         (setf ,y1 (the fixnum (* ,iphase ,channels))
               ,y0 (the fixnum (- ,y1 ,channels))
               ,y2 (the fixnum (+ ,y1 ,channels))
               ,y3 (the fixnum (+ ,y2 ,channels)))
         (cond ((zerop ,iphase) (incf ,y0 ,incr1))
               ((= ,iphase ,guard-frame) (incf ,y3 ,decr1))
               ((> ,iphase ,guard-frame)
                (incf ,y2 ,decr1)
                (incf ,y3 ,decr2))))
       (if (< current-channel ,channels)
           (,interp-fn-name ,frac
                            (smp-ref ,data (the non-negative-fixnum
                                             (+ ,y0 current-channel)))
                            (smp-ref ,data (the non-negative-fixnum
                                             (+ ,y1 current-channel)))
                            (smp-ref ,data (the non-negative-fixnum
                                             (+ ,y2 current-channel)))
                            (smp-ref ,data (the non-negative-fixnum
                                             (+ ,y3 current-channel))))
           +sample-zero+))))

(defmacro wrap-phase-func (phs frames wrap-p)
  (with-gensyms (max)
    `(with-samples ((,max (sample (- ,frames (if ,wrap-p 0 1)))))
       (if ,wrap-p
           (lambda ()
             (wrap-cond (,phs +sample-zero+ ,max ,max)
               ((>= ,phs ,max) (decf ,phs ,max))
               ((minusp ,phs)  (incf ,phs ,max)))
             (values))
           (lambda ()
             (cond ((>= ,phs ,max)
                    (setf (done-p) t ,phs ,max))
                   ((minusp ,phs)
                    (setf (done-p) t ,phs +sample-zero+)))
             (values))))))

(defmacro select-buffer-interp (interp data phs frames channels size wrap-p
                                wrap-phase-fn)
  (case interp
    (:linear
     `(%two-points-interp ,data ,phs ,frames ,channels ,size ,wrap-p
                          ,wrap-phase-fn linear-interp))
    (:cubic
     `(%four-points-interp ,data ,phs ,frames ,channels ,size ,wrap-p
                           ,wrap-phase-fn cubic-interp))
    (otherwise `(%no-interp ,data ,phs ,channels ,wrap-phase-fn))))

(define-vug-macro buffer-read (buffer frame &key wrap-p interpolation)
  "Return the value of the CURRENT-CHANNEL of the BUFFER FRAME.

If WRAP-P is T, wrap around if necessary.

INTERPOLATION is one of :LINEAR, :CUBIC or NIL (default)."
  (with-gensyms (bread)
    `(vuglet ((,bread ((buf buffer) frame (wrap-p boolean))
                (with ((size (buffer-size buf))
                       (frames (buffer-frames buf))
                       (channels (buffer-channels buf))
                       (data (buffer-data buf))
                       (wrap-phase-fn (wrap-phase-func frame frames wrap-p)))
                  (declare (type non-negative-fixnum size frames channels)
                           (type foreign-pointer data)
                           (type function wrap-phase-fn))
                  (select-buffer-interp ,interpolation data frame frames
                                        channels size wrap-p wrap-phase-fn))))
       (,bread ,buffer ,frame ,wrap-p))))

(define-vug buffer-write ((buf buffer) (frame non-negative-fixnum) input)
  "Write INPUT to the CURRENT-CHANNEL of the BUFFER FRAME.

Return the related buffer index."
  (with ((data (buffer-data buf))
         (upper-limit (1- (buffer-size buf)))
         (index (clip (the fixnum
                        (+ (* frame (buffer-channels buf)) current-channel))
                      0 upper-limit)))
    (declare (type foreign-pointer data)
             (type non-negative-fixnum upper-limit index))
    (setf (smp-ref data index) input)))

(define-vug-macro buffer-frame (buffer frame &key wrap-p interpolation)
  "Return the BUFFER FRAME.

If WRAP-P is T, wrap around if necessary.

INTERPOLATION is one of :LINEAR, :CUBIC or NIL (default)."
  (with-gensyms (bframe)
    `(vuglet ((,bframe ((buf buffer) frame (wrap-p boolean))
                (with ((channels (buffer-channels buf))
                       (frame (make-frame channels)))
                  (dochannels (current-channel channels)
                    (setf (frame-ref frame current-channel)
                          (buffer-read buf frame
                                       :wrap-p wrap-p
                                       :interpolation ,interpolation)))
                  frame)))
       (,bframe ,buffer ,frame ,wrap-p))))
