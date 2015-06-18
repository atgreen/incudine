(in-package :incudine-tests)

(enable-sharp-square-bracket-syntax)

(dsp! delete-var-test-1 ((buf buffer) amp)
  (with-samples ((rate 1.0))
    (setf rate (sample (if (> amp 0.5) 100 200)))
    ;;; The PHASOR's rate depends on the VUG-PARAMETER BUF, therefore
    ;;; the related VUG-VARIABLE is to preserve.
    (out (* amp (buffer-play buf rate 0 t #'identity)))))

(defun delete-var-test-2 ()
  (let ((*package* (find-package "INCUDINE-TESTS")))
    (handler-bind (((and warning (not style-warning)) #'error))
      (eval
       '(progn
         (destroy-dsp 'delete-var-test-2*)
         (dsp! delete-var-test-2* ()
           ;; A variable used in STEREO VUG is deleted and undeleted after
           ;; recheck. The test fails if this variable is undefined.
           (stereo (~ (delay (- (impulse 1 .5) (* .5 (zero it -1))) .001 .001))))
         (delete-var-test-2*))))))

(with-dsp-test (delete-var.1
      :md5 #(53 186 250 177 0 178 241 139 224 231 126 34 95 170 167 51))
  (delete-var-test-1 *sine-table* .3 :id 123)
  (at #[3 s] #'set-control 123 :amp .55))

(with-dsp-test (delete-var.2 :channels 2
      :md5 #(115 66 180 157 85 94 218 87 71 84 23 50 2 232 113 74))
  (delete-var-test-2))
