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

(in-package :incudine)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *core-init-function*
    (lambda ()
      (set-sample-rate (sample (or incudine.config::*sample-rate* 48000)))
      (set-sound-velocity (sample (or incudine.config::*sound-velocity* 345)))
      ;; gsl random
      (setf incudine.external::*gsl-random-generator*
            (incudine.external::make-gsl-rng))
      ;; pool
      (setf incudine.util::*foreign-sample-pool*
            (foreign-alloc :char
                           :count incudine.util::*foreign-sample-pool-size*))
      (setf incudine.util::*foreign-rt-memory-pool*
            (foreign-alloc :char
                           :count incudine.util::*foreign-rt-memory-pool-size*))
      (setf incudine.util::*foreign-nrt-memory-pool*
            (foreign-alloc :char
                           :count incudine.util::*foreign-nrt-memory-pool-size*))
      (setf incudine.util::*initialized-foreign-memory-pools* nil)
      ;; edf
      (setf incudine.edf:*heap-size*
            (if (power-of-two-p *rt-edf-heap-size*)
                *rt-edf-heap-size*
                (next-power-of-two *rt-edf-heap-size*)))
      (setf incudine.edf:*heap* (incudine.edf:make-heap))
      (setf incudine.edf::*rt-heap* incudine.edf:*heap*)
      (setf *nrt-edf-heap-size*
            (if (power-of-two-p *nrt-edf-heap-size*)
                *nrt-edf-heap-size*
                (next-power-of-two *nrt-edf-heap-size*)))
      (setf *nrt-edf-heap* (incudine.edf:make-heap *nrt-edf-heap-size*))
      ;; bus
      (setf *%input-pointer* (alloc-bus-pointer 'input))
      (setf *input-pointer*
            (foreign-alloc :pointer :initial-element *%input-pointer*))
      (setf *%output-pointer* (alloc-bus-pointer 'output))
      (setf *output-pointer*
            (foreign-alloc :pointer :initial-element *%output-pointer*))
      (setf *bus-pointer* (alloc-bus-pointer 'bus))
      (setf *output-peak-values*
            (foreign-alloc-sample *number-of-output-bus-channels*))
      ;; time
      (setf *tempo* (make-tempo *default-bpm*))
      (setf *sample-counter*
            (foreign-alloc 'sample :initial-element +sample-zero+))
      ;; graph
      (setf *node-hash* (make-node-hash *max-number-of-nodes*))
      (setf *node-root*
            (let ((group (make-node 0
                           (length (int-hash-table-items *node-hash*)))))
              (setf (node-prev group) :dummy-node
                    (node-funcons group) nil
                    (node-last group) :dummy-node)
              group))
      ;; nrt
      (setf *nrt-node-root*
            (let ((group (make-node 0 *max-number-of-nodes*)))
              (setf (node-prev group) :dummy-node
                    (node-funcons group) nil
                    (node-last group) :dummy-node)
              group))
      (setf *nrt-node-hash* (make-node-hash *max-number-of-nodes*))
      (setf *%nrt-input-pointer* (alloc-bus-pointer 'input))
      (setf *nrt-input-pointer*
            (foreign-alloc :pointer :initial-element *%nrt-input-pointer*))
      (setf *%nrt-output-pointer* (alloc-bus-pointer 'output))
      (setf *nrt-output-pointer*
            (foreign-alloc :pointer :initial-element *%nrt-output-pointer*))
      (setf *nrt-bus-pointer* (alloc-bus-pointer 'bus))
      (setf *nrt-output-peak-values*
            (foreign-alloc-sample *max-number-of-channels*))
      (setf *nrt-sample-counter*
            (foreign-alloc :double :initial-element +sample-zero+))
      (setf *nrt-tempo* (make-tempo *default-bpm*))
      ;; midi
      (setf *portmidi-time*
            (foreign-alloc 'sample :initial-element +sample-zero+))
      (setf incudine.vug::*midi-normalize-table*
            (incudine.vug::make-midi-normalize-table))
      (setf incudine.vug::*midi-normalize-pb-bipolar-table*
            (incudine.vug::make-midi-normalize-pb-bipolar-table))
      (setf incudine.vug::*midi-normalize-pb-table*
            (incudine.vug::make-midi-normalize-pb-table))
      (setf incudine.vug:*linear-midi-table*
            (incudine:make-buffer 128
              :initial-contents (loop for i below 128 collect (/ i 127))))
      ;; mouse
      (setf incudine.vug::*mouse-event* (incudine.vug::alloc-mouse-event))
      ;; init
      (funcall #'init t)
      ;; buffer
      (setf *sine-table*
            (make-buffer *default-table-size*
                         :fill-function (gen:partials '(1))))
      (setf *cosine-table*
            (make-buffer *default-table-size*
                         :fill-function (gen:partials '((1 1 .25)))))
      (setf *package* (find-package :incudine.scratch))
      ;; tuning
      (setf *tuning-et12* (make-tuning))
      (setf *default-tuning* *tuning-et12*))
    "Allocation of the foreign memory and initialization when a saved
core image starts up.")

  (defvar *core-config-and-init-function*
    (lambda ()
      (incudine.config:load-incudinerc)
      (funcall *core-init-function*)))

  (defvar *core-save-function*
    (lambda ()
      ;; Stop realtime and non-realtime threads
      (rt-stop)
      (nrt-stop)
      (loop for (pool size)
                in `((,*buffer-pool* ,+buffer-pool-initial-size+)
                     (,*rt-buffer-pool* ,+buffer-pool-initial-size+)
                     (,*envelope-pool* ,+envelope-pool-initial-size+)
                     (,*rt-envelope-pool* ,+envelope-pool-initial-size+)
                     (,*tempo-envelope-pool* ,+tempo-envelope-pool-initial-size+)
                     (,*rt-tempo-envelope-pool* ,+tempo-envelope-pool-initial-size+)
                     (,*tuning-pool* ,+tuning-pool-initial-size+)
                     (,*rt-tuning-pool* ,+tuning-pool-initial-size+))
            do (ensure-incudine-object-pool-size pool size))
      (clrhash incudine.analysis::*fft-plan*)
      (values))
    "Function to call before to save a core image.")

  (defvar *exit-function*
    (lambda () (rt-stop))
    "Function to call when SBCL process exits.")

  (defvar *set-core-hooks-p* t)
  (when *set-core-hooks-p*
    (pushnew *core-config-and-init-function* sb-ext:*init-hooks*)
    (pushnew *core-save-function* sb-ext:*save-hooks*)
    (pushnew *exit-function* sb-ext:*exit-hooks*)
    (setf *set-core-hooks-p* nil)))
