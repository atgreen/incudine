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

(in-package :incudine.gen)

(defun polynomial (coefficients &key (xmin -1) (xmax 1) (normalize-p t))
  "Return a function called to fill a foreign array by evaluating a
nth-order polynomial in x between XMIN and XMAX (-1 and 1 by default)
with COEFFICIENTS

          (cN ... c2 c1 c0)

The returned function takes two arguments, the foreign pointer to the
sample data and the data size, and returns three values: the foreign
array, the scale factor to normalize the samples and the boolean
NORMALIZE-P to specify whether the normalization is necessary.

Example: 2 x^2 - 3, with x in [-1, 1]

    (gen:polynomial '(2 0 -3))"
  (declare (type list coefficients) (type real xmin xmax)
           (type boolean normalize-p))
  (let* ((xmin (sample xmin))
         (range (abs (- xmax xmin)))
         (coeffs (or (mapcar (lambda (x) (sample x)) coefficients)
                     `(,+sample-zero+))))
    (declare (type sample xmin range) (type cons coeffs))
    (lambda (foreign-array size)
      (declare (type foreign-pointer foreign-array)
               (type non-negative-fixnum size))
      (locally (declare #.*standard-optimize-settings* #.*reduce-warnings*)
        (with-samples* ((scale (/ range size))
                        (xloc (sample->fixnum (/ xmin scale)))
                        (max-value 0.0)
                        x sum abs-value)
          (dotimes (i size)
            (setf x (* xloc scale))
            (incf xloc)
            (setf sum (car coeffs))
            (setf (smp-ref foreign-array i)
                  (dolist (c (cdr coeffs) sum)
                    (setf sum (+ (* sum x) (the sample c)))
                    (setf abs-value (abs sum))
                    (when (< max-value abs-value)
                      (setf max-value abs-value)))))
          (values foreign-array (/ max-value) normalize-p))))))
