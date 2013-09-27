;;; Copyright (c) 2013 Tito Latini
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

(eval-when (:compile-toplevel :load-toplevel :execute)
  (import
   '(incudine:+seg-lin-func+
     incudine:envelope
     incudine:envelope-data
     incudine::envelope-data-size
     incudine:envelope-points
     incudine:envelope-max-points
     incudine:envelope-loop-node
     incudine:envelope-release-node
     incudine::%segment-init
     incudine::%segment-update-level))
  (object-to-free incudine:make-envelope update-local-envelope))

(defmacro make-local-envelope (levels times &key curve (loop-node -1)
                               (release-node -1))
  (with-gensyms (%levels %times %curve env)
    `(with ((,%levels (locally (declare #.*reduce-warnings*)
                        ,levels))
            (,%times (locally (declare #.*reduce-warnings*)
                       ,times))
            (,%curve (locally (declare #.*reduce-warnings*)
                       ,curve))
            (,env (incudine:make-envelope ,%levels ,%times :curve ,%curve
                                          :loop-node ,loop-node
                                          :release-node ,release-node
                                          :real-time-p t)))
       ,env)))

(defmacro update-local-envelope (vug-varname args)
  (with-gensyms (size)
    `(let ((,size (max (length ,(first args))
                       (1+ (length ,(second args))))))
       (cond ((> ,size (envelope-max-points ,vug-varname))
              (incudine:free ,vug-varname)
              (setf ,vug-varname (incudine:make-envelope ,@args)))
             (t (incudine:set-envelope ,vug-varname
                                       ;; The last keyword is REAL-TIME-P,
                                       ;; absent in SET-ENVELOPE
                                       ,@(butlast args 2)))))))

(defmacro make-local-linen (attack-time sustain-time release-time
                            &key (level 1) (curve :lin))
  `(make-local-envelope (list 0 ,level ,level 0)
                        (list ,attack-time ,sustain-time ,release-time)
                        :curve ,curve))

(defmacro make-local-perc (attack-time release-time
                           &key (level 1) (curve -4))
  `(make-local-envelope (list 0 ,level 0) (list ,attack-time ,release-time)
                        :curve ,curve))

(defmacro make-local-cutoff (release-time &key (level 1) (curve :exp))
  `(make-local-envelope (list ,level 0) (list ,release-time)
                        :curve ,curve :release-node 0))

(defmacro make-local-asr (attack-time sustain-level release-time
                          &key (curve -4))
  `(make-local-envelope (list 0 ,sustain-level 0)
                        (list ,attack-time ,release-time)
                        :curve ,curve :release-node 1))

(defmacro make-local-adsr (attack-time decay-time sustain-level release-time
                           &key (peak-level 1) (curve -4))
  `(make-local-envelope (list 0 ,peak-level (* ,peak-level ,sustain-level) 0)
                        (list ,attack-time ,decay-time ,release-time)
                        :curve ,curve :release-node 2))

(defmacro make-local-dadsr (delay-time attack-time decay-time sustain-level
                            release-time &key (peak-level 1) (curve -4))
  `(make-envelope (list 0 0 ,peak-level (* ,peak-level ,sustain-level) 0)
                  (list ,delay-time ,attack-time ,decay-time ,release-time)
                  :curve ,curve :release-node 3))

;;; Simple segments

(define-vug line (start end dur (done-action function))
  (with ((done-p nil)
         (samples (max 1 (sample->fixnum (* dur *sample-rate*))))
         (remain samples)
         (value start)
         (slope (without-follow (start end)
                  ;; Update only if DUR is changed
                  (init-only (when done-p
                               ;; Restart
                               (setf done-p nil))
                             (/ (- end value) samples)))))
    (declare (type sample value slope) (type boolean done-p)
             (type non-negative-fixnum samples remain))
    (if done-p
        value
        (cond ((zerop remain)
               (done-action done-action)
               (setf done-p t)
               value)
              (t (decf remain)
                 (incf value slope))))))

(define-vug x-line (start end dur (done-action function))
  (with ((done-p nil)
         (samples (max 1 (sample->fixnum (* dur *sample-rate*))))
         (remain samples)
         (%start (if (zerop start) 1d-5 start))
         (value %start)
         (power (without-follow (start end)
                  ;; Update only if DUR is changed
                  (init-only (when done-p
                               ;; Restart
                               (setf done-p nil))
                             (expt (the non-negative-sample
                                     (/ end value))
                                   (/ (sample samples)))))))
    (declare (type sample %start value power) (type boolean done-p)
             (type non-negative-fixnum samples remain))
    (if done-p
        value
        (cond ((zerop remain)
               (done-action done-action)
               (setf done-p t)
               value)
              (t (decf remain)
                 (setf value (* value power)))))))

;;; Envelope Generator inspired by EnvGen of SuperCollider

(eval-when (:compile-toplevel :load-toplevel)
  (declaim (inline envgen-next-dur))
  (defun envgen-next-dur (env-data index time-scale offset)
    (max 1 (+ offset (sample->fixnum
                      (* (smp-ref env-data index)
                         time-scale *sample-rate*)))))

  (defmacro envgen-next-index (data-size index curr-node)
    `(the non-negative-fixnum
       (cond ((zerop ,index) 0)
             ((>= ,index ,data-size)
              ;; point to the last segment
              (setf ,index (- ,data-size 4)
                    ,curr-node (1- (the positive-fixnum
                                     (/ ,index 3))))
              ,index)
             (t (- ,index 3)))))

  (defmacro envgen-jump-node (node-dest node-src index)
    (with-gensyms (dest)
      `(let ((,dest ,node-dest))
         (incf ,index (the non-negative-fixnum
                        (* (the non-negative-fixnum
                             (- ,dest ,node-src))
                           3)))
         (setf ,node-src ,dest))))

  (declaim (inline jump-to-loop-node-p))
  (defun jump-to-loop-node-p (gate curr-node loop-node release-node)
    (and (>= loop-node 0)
         (= (1+ curr-node) release-node)
         (plusp gate)
         (/= curr-node loop-node)))

  (declaim (inline envgen-end-of-data-p))
  (defun envgen-end-of-data-p (index data-size)
    (>= index data-size))

  (declaim (inline envgen-to-sustain-p))
  (defun envgen-to-sustain-p (gate curr-node release-node)
    (and (= curr-node release-node) (plusp gate)))

  (declaim (inline release-before-sustain-p))
  (defun release-before-sustain-p (gate sustain curr-node release-node)
    (and (zerop gate)
         (null sustain)
         (plusp release-node)
         (< release-node curr-node)))

  (defmacro envgen-update-sustain (var gate curr-node release-node)
    `(setf ,var
           (and (>= ,curr-node 0)
                (envgen-to-sustain-p ,gate ,curr-node ,release-node))))

  (defmacro envgen-sustain (sustain-var)
    `(setf ,sustain-var t))

  (defmacro envgen-no-sustain (sustain-var)
    `(if ,sustain-var (setf ,sustain-var nil)))

  (declaim (inline immediate-cutoff-p))
  (defun immediate-cutoff-p (gate)
    (= gate -1.0))

  (declaim (inline release-with-custom-duration-p))
  (defun release-with-custom-duration-p (gate)
    (< gate -1.0))

  (declaim (inline envgen-custom-duration))
  (defun envgen-custom-duration (gate)
    (sample->fixnum (* (- -1.0 gate) *sample-rate*)))

  (declaim (inline envgen-begin-p))
  (defun envgen-begin-p (index dur)
    (and (zerop index) (zerop dur))))

(define-vug envgen ((env envelope) gate time-scale (done-action function))
  (with-samples (tmp end grow a2 b1 y1 y2)
    (with ((index 0)
           (curr-node -1)
           (env-data (envelope-data env))
           (data-size (envelope-data-size env))
           (last-point (1- (the non-negative-fixnum (envelope-points env))))
           (curr-index (envgen-next-index data-size index curr-node))
           (prev-index 0)
           (loop-node (envelope-loop-node env))
           (release-node (envelope-release-node env))
           (sustain nil)
           (done-p nil)
           (dur 0)
           (remain 0)
           (curve +seg-lin-func+)
           (gate-trig (plusp gate))
           (level (cond ((release-before-sustain-p gate sustain curr-node release-node)
                         (envgen-jump-node (1- release-node) curr-node index)
                         (setf remain 0)
                         tmp)
                        ((immediate-cutoff-p gate)
                         (setf sustain nil remain 0)
                         (envgen-jump-node last-point curr-node index)
                         +sample-zero+)
                        ((release-with-custom-duration-p gate)
                         ;; Force the release stage with custom duration
                         (setf dur (envgen-custom-duration gate)
                               ;; Anticipate one sample to avoid the repetition of
                               ;; a vertex because the last value of a segment is
                               ;; the first value of the next segment.
                               remain (1- dur)
                               curr-node (1+ curr-node))
                         (unless (= curr-node last-point)
                           (envgen-jump-node (1- last-point) curr-node index)
                           (setf index (+ index 2) ; skip dur
                                 end (smp-ref env-data index)
                                 index (+ index 1)
                                 curve (smp-ref env-data index)
                                 prev-index curr-index))
                         (setf sustain nil)
                         (%segment-init tmp end dur curve grow a2 b1 y1 y2)
                         tmp)
                        ((envgen-begin-p index dur)
                         (cond (gate-trig
                                (envgen-update-sustain sustain gate curr-node release-node)
                                (setf gate-trig nil)
                                (smp-ref env-data 0))
                               ;; ENVGEN started with GATE zero
                               (t (setf index data-size)
                                  (samples-zero tmp end))))
                        (gate-trig
                         ;; Restart
                         (setf gate-trig nil
                               remain 0
                               index 0
                               curr-node -1
                               curr-index (envgen-next-index data-size index curr-node)
                               prev-index curr-index
                               done-p nil
                               sustain nil
                               ;; LEVEL is set to END during the performance
                               end tmp))
                        ((zerop dur)
                         (envgen-no-sustain sustain)
                         end)
                        ((or done-p (= curr-index prev-index))
                         (envgen-no-sustain sustain)
                         tmp)
                        (t (envgen-no-sustain sustain)
                           (setf dur (envgen-next-dur env-data index time-scale
                                                      (- remain dur))
                                 ;; One sample is subtracted in the previous
                                 ;; value of REMAIN
                                 remain dur
                                 index (1+ index)
                                 end (smp-ref env-data index)
                                 index (1+ index)
                                 curve (smp-ref env-data index))
                           (%segment-init tmp end dur curve grow a2 b1 y1 y2)
                           tmp))))
      (declare (type non-negative-fixnum index data-size last-point dur remain
                     curr-index prev-index)
               (type fixnum curr-node loop-node release-node)
               (type sample level curve) (type boolean sustain done-p gate-trig))
      (initialize (setf end level))
      ;; Useful when GATE is modulated. In this case, the expansion
      ;; of GATE occurs here. If GATE is not modulated, GATE-TRIG is
      ;; always NIL at this point.
      (and gate-trig level)
      (cond ((or done-p sustain) tmp)
            (t (cond ((zerop remain)
                      ;; End of segment
                      (cond ((envgen-end-of-data-p (incf index) data-size)
                             (done-action done-action)
                             (setf done-p t tmp end))
                            (t (incf curr-node)
                               (cond ((jump-to-loop-node-p gate curr-node loop-node
                                                           release-node)
                                      (envgen-jump-node loop-node curr-node index))
                                     ((envgen-to-sustain-p gate curr-node release-node)
                                      (envgen-sustain sustain)))
                               ;; Compute the parameters for the next segment
                               (setf dur (envgen-next-dur env-data index time-scale 0)
                                     remain (1- dur)
                                     index (1+ index)
                                     ;; The first value of the segment is the last value
                                     ;; of the previous segment
                                     level end
                                     end (smp-ref env-data index)
                                     index (1+ index)
                                     curve (smp-ref env-data index)
                                     prev-index curr-index)
                               (%segment-init level end dur curve grow a2 b1 y1 y2)
                               (setf tmp level))))
                     (t (decf remain)
                        ;; Compute the next point
                        (%segment-update-level level curve grow a2 b1 y1 y2)
                        (setf tmp level))))))))
