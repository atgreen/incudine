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

;;; Graph of nodes inspired by James McCartney's SuperCollider3

(define-constant +max-node-id+ (logand most-positive-fixnum #x7fffffff))
(define-constant +default-large-node-id+ (ash 1 24))

(defvar *max-number-of-nodes* 1024)
(declaim (type non-negative-fixnum *max-number-of-nodes*))

(defvar *last-node-id* 1)
(declaim (type non-negative-fixnum *last-node-id*))

(defvar *last-large-node-id* +default-large-node-id+)
(declaim (type non-negative-fixnum *last-large-node-id*))

(defvar *node-enable-gain-p* nil)
(declaim (type boolean *node-enable-gain-p*))

(defvar *fade-time* 0)
(declaim (type (real 0) *fade-time*))

(defvar *fade-curve* :lin)
(declaim (type (or symbol real) *fade-curve*))

(defstruct (node (:constructor %make-node) (:copier nil))
  (id nil :type (or fixnum null))
  (hash 0 :type fixnum)
  ;; Index in the array of the nodes
  (index (* 2 *max-number-of-nodes*) :type non-negative-fixnum)
  (name nil :type symbol)
  (start-time-ptr (foreign-alloc 'sample :initial-element +sample-zero+)
                  :type foreign-pointer)
  ;; List of functions, where the CAR is the function related to the
  ;; node and the CDR is the list of the next functions. If the node
  ;; is a group, it is the FUNCONS of the next node of the group
  (funcons (list nil) :type list)
  (function #'identity :type function)
  (init-function #'identity :type function)
  (init-args nil :type list)
  (controls nil :type (or hash-table null))
  ;; c-array to control the master gain of the node.
  ;; The value at the first pointer is the current level. The other
  ;; pointers are used to calc the curve of an envelope segment. The
  ;; value of the last pointer is the fade-time
  (gain-data (foreign-alloc-sample 10) :type foreign-pointer)
  (enable-gain-p nil :type boolean)
  (done-p nil :type boolean)
  (release-phase-p nil :type boolean)
  (pause-p nil :type boolean)
  ;; List of the functions to call after NODE-STOP
  (stop-hook nil :type list)
  ;; List of the functions to call after NODE-FREE
  (free-hook nil :type list)
  (parent nil :type (or node null))
  (prev nil :type (or node null keyword))
  (next nil :type (or node null))
  ;; The last node of a group. It is NIL if the node is not a group
  (last nil))

(defun make-node (id index)
  (let ((obj (%make-node :id id :index index)))
    (when id (setf (node-hash obj) (int-hash id)))
    ;; default level
    (setf (smp-ref (node-gain-data obj) 0) (sample 1))
    ;; default curve
    (setf (smp-ref (node-gain-data obj) 3) +seg-lin-func+)
    ;; default fade-time
    (setf (smp-ref (node-gain-data obj) 9) (sample 0.02))
    (let ((start-time-ptr (node-start-time-ptr obj))
          (gain-data-ptr (node-gain-data obj)))
      (tg:finalize obj (lambda ()
                         (foreign-free start-time-ptr)
                         (foreign-free gain-data-ptr)))
      obj)))

(defun make-node-hash (size)
  (let ((index 0))
    (make-int-hash-table
     :size size
     :initial-element-fn (lambda () (prog1 (make-node nil index)
                                      (incf index))))))

(defvar *node-hash* (make-node-hash *max-number-of-nodes*))
(declaim (type int-hash-table *node-hash*))

(defvar *node-root*
  (let ((group (make-node 0 (length (int-hash-table-items *node-hash*)))))
    (setf (node-prev group) :dummy-node
          (node-funcons group) nil
          (node-last group) :dummy-node)
    group))
(declaim (type node *node-root*))

(declaim (inline node-root-p))
(defun node-root-p (obj)
  (declare #.*standard-optimize-settings*)
  (eq obj *node-root*))

(defmacro make-temp-node (&rest rest)
  `(prog1 (%make-node :id -1 ,@rest)
     (nrt-msg info "new temporary node")))

(declaim (inline temp-node-p))
(defun temp-node-p (node)
  (declare (type node node))
  (let ((id (node-id node)))
    (and id (minusp id))))

(declaim (inline null-node-p))
(defun null-node-p (obj)
  (null (node-id obj)))

(declaim (inline group-p))
(defun group-p (obj)
  (declare (type node obj))
  (when (node-last obj) t))

(declaim (inline node))
(defun node (id)
  (declare (type fixnum id) #.*standard-optimize-settings*)
  (if (zerop id) *node-root* (values (getihash id))))

;;; Previous node not in pause
(defun unpaused-node-prev (curr)
  (declare (type node curr))
  (let ((prev (node-prev curr)))
    (when (node-p prev)
      (unless (or (eq (node-parent curr) prev)
                  (eq (node-parent prev) (node-parent curr)))
        (when (and (not (eq prev *node-root*))
                   (node-pause-p (node-parent prev)))
          ;; Skip the nodes of the paused group
          (setf prev (node-parent prev))))
      (if (node-pause-p prev)
          (unpaused-node-prev prev)
          prev))))

;;; Next node not in pause
(defun unpaused-node-next (curr)
  (declare (type node curr))
  (when (and (group-p curr) (node-p (node-last curr)))
    (setf curr (node-last curr)))
  (let ((next (node-next curr)))
    (if (node-p next)
        (if (node-pause-p next) (unpaused-node-next next) next))))

(declaim (inline link-to-prev))
(defun link-to-prev (item prev)
  (declare (type node item))
  (when (node-p prev)
    (cond ((group-p prev)
           (setf (node-funcons prev) (node-funcons item))
           (update-prev-groups prev))
          (t (setf (cdr (node-funcons prev)) (node-funcons item))))))

(declaim (inline link-to-unpaused-prev))
(defun link-to-unpaused-prev (item prev)
  (declare (type node item prev))
  (when (node-pause-p prev)
    (let ((prev (unpaused-node-prev prev)))
      (link-to-prev item prev))))

(declaim (inline node-next-funcons))
(defun node-next-funcons (node)
  (declare (type node node))
  (let ((next (unpaused-node-next node)))
    (when (node-p next) (node-funcons next))))

(defun updated-node (id)
  (declare (type positive-fixnum id))
  (multiple-value-bind (node index) (getihash id)
    (unless (= (node-index node) index)
      (setf (node-index node) index))
    node))

(defun make-group (id &optional (add-action :head) (target *node-root*))
  (declare (type fixnum id) (type keyword add-action)
           (type (or node fixnum) target))
  (let ((target (if (numberp target) (node target) target)))
    (declare #.*standard-optimize-settings*)
    (rt-eval ()
      (let ((group (updated-node id)))
        (when (and (null-node-p group) (not (null-node-p target)))
          (flet ((common-set (group id)
                   (setf (node-id group) id
                         (node-hash group) (int-hash id)
                         (smp-ref (node-start-time-ptr group) 0) (now)
                         (node-last group) :dummy-node
                         (node-pause-p group) nil)
                   (incf (int-hash-table-count *node-hash*))))
            (case add-action
              (:before
               (unless (eq target *node-root*)
                 (common-set group id)
                 (setf (node-next group) target
                       (node-prev group) (node-prev target)
                       (node-prev target) group
                       (node-next (node-prev group)) group
                       (node-parent group) (node-parent target))
                 (setf (node-funcons group)
                       (if (node-pause-p target)
                           (node-next-funcons target)
                           (node-funcons target)))
                 (link-to-unpaused-prev group (node-prev group))
                 (nrt-msg info "new group ~D" id)))
              (:after
               (unless (eq target *node-root*)
                 (common-set group id)
                 (setf (node-parent group) (node-parent target))
                 (if (group-p target)
                     (let ((last (find-last-node target)))
                       (setf (node-prev group) last
                             (node-next group) (node-next last)
                             (node-next last) group))
                     (setf (node-prev group) target
                           (node-next group) (node-next target)
                           (node-next target) group))
                 (if (node-p (node-next group))
                     (setf (node-funcons group) (node-next-funcons group)
                           (node-prev (node-next group)) group)
                     (setf (node-funcons group) nil))
                 (when (eq target (node-last (node-parent group)))
                   (setf (node-last (node-parent group)) group))
                 (nrt-msg info "new group ~D" id)))
              (:head
               (when (group-p target)
                 (common-set group id)
                 (setf (node-prev group) target
                       (node-next group) (node-next target)
                       (node-next target) group
                       (node-parent group) target)
                 (when (node-p (node-next group))
                   (setf (node-prev (node-next group)) group))
                 (unless (node-p (node-last target))
                   (setf (node-last target) group))
                 (setf (node-funcons group)
                       (if (node-pause-p target)
                           (node-next-funcons group)
                           (node-funcons target)))
                 (nrt-msg info "new group ~D" id)))
              (:tail
               (when (group-p target)
                 (common-set group id)
                 (let ((last (find-last-node target)))
                   (setf (node-prev group) last
                         (node-next group) (node-next last)
                         (node-next last) group
                         (node-last target) group
                         (node-parent group) target)
                   (when (node-p (node-next group))
                     (setf (node-prev (node-next group)) group))
                   (setf (node-funcons group) (node-next-funcons group)))
                 (nrt-msg info "new group ~D" id)))
              (t (nrt-msg error "unknown add-action ~S" add-action)))))))))

(declaim (inline group))
(defun group (obj)
  (declare (type (or node fixnum)))
  (node-parent (if (node-p obj) obj (node obj))))

(defmethod print-object ((obj node) stream)
  (format stream "#<NODE :ID ~D>" (node-id obj)))

(declaim (inline graph-empty-p))
(defun graph-empty-p ()
  (null (node-funcons *node-root*)))

(declaim (inline graph-full-p))
(defun graph-full-p ()
  (int-hash-table-full-p *node-hash*))

(defun getihash (id)
  (declare (type fixnum id) #.*standard-optimize-settings*)
  (%getihash id *node-hash* node-hash node-id null-node-p node
             incudine-node-error :format-control "No more nodes available."))

(defun fix-collisions-from (node)
  (declare (type node node) #.*standard-optimize-settings*)
  (%fix-collisions-from
    (node-index node) *node-hash* node-hash node-id null-node-p node))

(declaim (inline live-nodes))
(defun live-nodes ()
  "Return the number of live nodes."
  (int-hash-table-count *node-hash*))

(declaim (inline node-start-time))
(defun node-start-time (obj)
  (smp-ref (node-start-time-ptr (if (node-p obj) obj (node obj))) 0))

(declaim (inline node-uptime))
(defun node-uptime (obj)
  (let ((n (if (node-p obj) obj (node obj))))
    (if (null-node-p n)
        +sample-zero+
        (- (now) (node-start-time n)))))

(defun node-gain (obj)
  (declare (type (or node fixnum) obj))
  (rt-eval (:return-value-p t)
    (smp-ref (node-gain-data (if (node-p obj) obj (node obj))) 0)))

(defun set-node-gain (obj value)
  (declare (type (or node fixnum) obj) (type real value))
  (rt-eval ()
    (setf (smp-ref (node-gain-data (if (node-p obj) obj (node obj))) 0)
          (sample value)))
  value)

(defsetf node-gain set-node-gain)

(defun node-fade-time (obj)
  (declare (type (or node fixnum) obj))
  (rt-eval (:return-value-p t)
    (smp-ref (node-gain-data (if (node-p obj) obj (node obj))) 9)))

(defun set-node-fade-time (obj value)
  (declare (type (or node fixnum) obj) (type real value))
  (rt-eval ()
    (setf (smp-ref (node-gain-data (if (node-p obj) obj (node obj))) 9)
          (sample value)))
  value)

(defsetf node-fade-time set-node-fade-time)

(defun node-fade-curve (obj)
  (declare (type (or node fixnum) obj))
  (rt-eval (:return-value-p t)
    (sample->seg-function-spec
     (smp-ref (node-gain-data (if (node-p obj) obj (node obj))) 3))))

(defun set-node-fade-curve (obj value)
  (declare (type (or node fixnum) obj))
  (rt-eval ()
    (setf (smp-ref (node-gain-data (if (node-p obj) obj (node obj))) 3)
          (seg-function-spec->sample value)))
  value)

(defsetf node-fade-curve set-node-fade-curve)

(declaim (inline node-current-function))
(defun node-current-function (obj)
  (car (node-funcons (if (node-p obj) obj (node obj)))))

(declaim (inline set-node-current-function))
(defun set-node-current-function (obj function)
  (setf (car (node-funcons (if (node-p obj) obj (node obj)))) function))

(defsetf node-current-function set-node-current-function)

(defun %next-node-id (default limit init)
  (declare (type non-negative-fixnum limit init))
  (labels ((next (id countdown)
             (declare (type non-negative-fixnum id countdown))
             (let ((id (if (>= id limit) default id)))
               (declare (type non-negative-fixnum id))
               (cond ((null-node-p (node id)) id)
                     ((zerop countdown)
                      (error 'incudine-node-error
                             :format-control "There aren't free nodes."))
                     (t (next (1+ id) (1- countdown)))))))
    (next init 65535)))

(declaim (inline next-node-id))
(defun next-node-id ()
  (%next-node-id 1 65535 *last-node-id*))

(declaim (inline next-large-node-id))
(defun next-large-node-id ()
  (%next-node-id +default-large-node-id+ +max-node-id+ *last-large-node-id*))

(defun get-node-id (id add-action)
  (declare (type (or non-negative-fixnum null) id))
  (cond (id id)
        ((eq add-action :replace) (next-large-node-id))
        (t (next-node-id))))

(defun swap-replaced (freed new id)
  (declare (type node freed new) (type fixnum id))
  (let ((items (int-hash-table-items *node-hash*))
        (size (length (int-hash-table-items *node-hash*))))
    (cond ((and (< 0 (node-index freed) size)
                (< 0 (node-index new) size))
           (let ((hash1 (node-hash freed))
                 (index1 (node-index freed)))
             ;; Ignore id for freed node.
             (setf (node-hash freed) (node-hash new)
                   (node-index freed) (node-index new)
                   (svref items (node-index freed)) freed
                   (node-id new) id
                   (node-hash new) hash1
                   (node-index new) index1
                   (svref items (node-index new)) new)))
          (t
           (error 'incudine-node-error
                  :format-control "Node hash-table has been corrupted.")))
    (values)))

(declaim (inline node-fade-in))
(defun node-fade-in (obj &optional duration curve)
  (let ((obj (if (node-p obj) obj (node obj))))
    (setf (node-gain obj) +sample-zero+)
    (node-segment obj (sample 1) (or duration (node-fade-time obj))
                  +sample-zero+ curve #'identity)))

(declaim (inline node-fade-out))
(defun node-fade-out (obj &optional duration curve)
  (let ((obj (if (node-p obj) obj (node obj))))
    (node-segment obj +sample-zero+ (or duration (node-fade-time obj))
                  nil curve #'free)))

(declaim (inline start-with-fade-in))
(defun start-with-fade-in (node fade-time fade-curve)
  (declare (type node node) #.*reduce-warnings*)
  (when (or *node-enable-gain-p* (node-enable-gain-p node))
    (setf (node-fade-time node)
          (or fade-time
              (let ((time (node-fade-time node)))
                (if (plusp time) time *fade-time*))))
    (node-fade-in node (node-fade-time node) fade-curve)))

(defun update-prev-groups (node)
  (declare (type node node))
  (unless (node-pause-p node)
    (let ((prev (node-prev node)))
      (when (node-p prev)
        (cond ((group-p prev)
               (setf (node-funcons prev) (node-funcons node))
               (update-prev-groups prev))
              (t (setf (cdr (node-funcons prev)) (node-funcons node))))))))

(defun find-last-node (node)
  (declare (type node node))
  (let ((last (node-last node)))
    (if (node-p last)
        (if (group-p last) (find-last-node last) last)
        node)))

(declaim (inline update-last-node-id))
(defun update-last-node-id (id)
  (if (> id 65535)
      (setf *last-large-node-id* id)
      (setf *last-node-id* id)))

(defvar *dirty-nodes* (make-array *max-number-of-nodes* :fill-pointer 0))
(declaim (type vector *dirty-nodes*))

(declaim (inline save-node))
(defun save-node (node)
  (vector-push node *dirty-nodes*))

(declaim (inline restore-node))
(defun restore-node ()
  (vector-pop *dirty-nodes*))

(defun free-dirty-nodes ()
  (declare #.*standard-optimize-settings*)
  (let ((nodes (fill-pointer *dirty-nodes*)))
    (when (plusp nodes)
      (dotimes (i nodes (setf (fill-pointer *dirty-nodes*) 0))
        (setf (node-id (reduce-warnings (aref *dirty-nodes* i))) nil)))))

(defun add-node-to-head (item target fade-time fade-curve)
  (cond ((and (node-id target) (group-p target))
         (unless (node-p (node-last target))
           (setf (node-last target) item))
         (setf (node-next item) (node-next target)
               (node-next target) item
               (node-prev item) target
               (node-parent item) target)
         (setf (cdr (node-funcons item))
               (if (node-pause-p target)
                   (node-next-funcons item)
                   (node-funcons target)))
         (unless (node-pause-p target)
           (setf (node-funcons target) (node-funcons item))
           (update-prev-groups target))
         (when (node-p (node-next item))
           (setf (node-prev (node-next item)) item))
         (incf (int-hash-table-count *node-hash*))
         (start-with-fade-in item fade-time fade-curve)
         item)
        (t (setf (node-id item) nil))))

(defun add-node-to-last (item target)
  ;; TARGET is empty
  (setf (node-prev item) target
        (node-next item) (node-next target))
  (when (node-p (node-next target))
    (setf (node-prev (node-next target)) item))
  (setf (node-next target) item)
  (unless (node-pause-p target)
    (setf (node-funcons target) (node-funcons item)))
  (update-prev-groups target))

(defun add-node-to-tail (item target fade-time fade-curve)
  (if (and (node-id target) (group-p target))
      (let ((last (find-last-node target)))
        (cond ((eq target last)
               (add-node-to-last item target))
              (t
               (setf (node-prev item) last
                     (node-next item) (node-next last)
                     (node-next last) item)
               (when (node-p (node-next item))
                 (setf (node-prev (node-next item)) item)
                 (setf (cdr (node-funcons item))
                       (node-funcons (unpaused-node-next item))))
               (cond ((group-p last)
                      (setf (node-funcons last)
                            (node-funcons item))
                      (link-to-prev item last)
                      (link-to-unpaused-prev item last))
                     (t (setf (cdr (node-funcons (node-prev item)))
                              (node-funcons item))
                        (link-to-prev item (node-prev item))
                        (link-to-unpaused-prev item (node-prev item))))))
        (setf (node-last target) item
              (node-parent item) target)
        (incf (int-hash-table-count *node-hash*))
        (start-with-fade-in item fade-time fade-curve)
        item)
      (setf (node-id item) nil)))

(defun add-node-before (item target fade-time fade-curve)
  (cond ((and (node-id target) (not (node-root-p target)))
         (setf (node-prev item) (node-prev target)
               (node-next item) target
               (node-prev target) item
               (node-next (node-prev item)) item
               (node-parent item) (node-parent target))
         (setf (cdr (node-funcons item))
               (if (node-pause-p target)
                   (let ((next (unpaused-node-next target)))
                     (when (node-p next) (node-funcons next)))
                   (node-funcons target)))
         (link-to-prev item (node-prev item))
         (link-to-unpaused-prev item (node-prev item))
         (incf (int-hash-table-count *node-hash*))
         (start-with-fade-in item fade-time fade-curve)
         item)
        (t (setf (node-id item) nil))))

(defun add-node-after (item target fade-time fade-curve)
  (cond ((node-id target)
         (setf (node-parent item) (node-parent target))
         (cond ((group-p target)
                (let ((last (find-last-node target)))
                  (setf (node-prev item) last
                        (node-next item) (node-next last)
                        (node-next last) item)
                  (link-to-prev item last)
                  (cond ((node-pause-p target)
                         (link-to-unpaused-prev item target))
                        ((node-pause-p last)
                         (link-to-unpaused-prev item last)))))
               (t (setf (node-prev item) target
                        (node-next item) (node-next target)
                        (node-next target) item)
                  (setf (cdr (node-funcons target))
                        (node-funcons item))
                  (link-to-unpaused-prev item target)))
         (when (node-p (node-next item))
           (setf (cdr (node-funcons item))
                 (node-funcons (unpaused-node-next item)))
           (setf (node-prev (node-next item)) item))
         (when (eq target (node-last (node-parent item)))
           (setf (node-last (node-parent item)) item))
         (incf (int-hash-table-count *node-hash*))
         (start-with-fade-in item fade-time fade-curve)
         item)
        (t (setf (node-id item) nil))))

(defmacro add-action-case ((add-action-var &rest args) &body body)
  `(case ,add-action-var
     ,@(mapcar (lambda (x) `(,(first x) (,(second x) ,@args))) body)
     (otherwise (error 'incudine-node-error
                       :format-control "Unknown add-action ~S"
                       :format-arguments (list ,add-action-var)))))

(defun initialize-node (item name init-fn init-args perf-fn fade-curve)
  (setf (node-name item) name
        (smp-ref (node-start-time-ptr item) 0) (now)
        (node-pause-p item) nil
        (node-init-function item) init-fn
        (node-init-args item) init-args
        (node-function item) perf-fn
        (node-last item) nil
        (node-release-phase-p item) nil
        (node-gain item) (sample 1)
        (node-fade-curve item) (or fade-curve :lin))
  (if (null (node-funcons item))
      (setf (node-funcons item) (list perf-fn))
      (setf (car (node-funcons item)) perf-fn
            (cdr (node-funcons item)) nil)))

(defun node-add (item add-action target id hash name fn init-args
                 fade-time fade-curve)
  (declare (type node item target) (type symbol name add-action)
           (type fixnum hash) (type positive-fixnum id) (type function fn)
           #.*standard-optimize-settings*)
  (cond ((graph-full-p)
         (error 'incudine-node-error :format-control "No more nodes availabe."))
        ((null-node-p target)
         (error 'incudine-node-error
           :format-control "Node target doesn't exists, cannot add the node."))
        ((eq add-action :replace)
         (let ((new-node (updated-node id)))
           (declare (type node new-node))
           (node-add new-node :before target id hash name fn init-args
                     fade-time fade-curve)
           (when (node-id new-node)
             (let ((id (node-id target)))
               (declare (type fixnum id))
               (node-fade-out target fade-time fade-curve)
               (swap-replaced target new-node id)
               new-node))))
        ((null-node-p item)
         (setf (node-hash item) hash)
         (setf (node-id item) id)
         ;; It is possible to recursively call NODE-ADD, so we save the node
         ;; to avoid nested UNWIND-PROTECT's. If there is an error, the function
         ;; FREE-DIRTY-NODES frees all the saved nodes.
         (save-node item)
         (update-last-node-id id)
         (multiple-value-bind (init-fn perf-fn) (funcall fn item)
           (declare (type function init-fn perf-fn))
           (restore-node)
           (initialize-node item name init-fn init-args perf-fn fade-curve)
           (add-action-case (add-action item target fade-time fade-curve)
             (:head add-node-to-head)
             (:tail add-node-to-tail)
             (:before add-node-before)
             (:after add-node-after))))))

(defun enqueue-node-function (node function init-args id name add-action
                              target action fade-time fade-curve)
  (declare (type node node) (type function function)
           (type non-negative-fixnum id) (type symbol name add-action)
           (type node target) (type (or function null) action))
  (when (node-add node add-action target id (int-hash id)
                  name function init-args fade-time fade-curve)
    (unless (eq add-action :replace)
      (nrt-msg info "new node ~D" id))
    (when action (funcall action node))))

(defmacro get-add-action-and-target (&rest keywords)
  `(cond ,@(mapcar (lambda (x) `(,x (values ,(make-keyword x) ,x)))
                   keywords)
         (t (values :head *node-root*))))

(defmacro with-add-action ((add-action target head tail before after replace)
                           &body body)
  `(multiple-value-bind (,add-action ,target)
       (get-add-action-and-target ,head ,tail ,before ,after ,replace)
     (let ((,target (if (numberp ,target) (node ,target) ,target)))
       ,@body)))

(defgeneric play (obj &key))

(defmethod play ((obj function) &key (init-function #'identity) id head tail
                 before after replace name action free-hook)
  (declare (type compiled-function obj init-function)
           (type (or non-negative-fixnum null) id)
           (type (or node fixnum null) head tail before after replace)
           (type symbol name) (type (or compiled-function null) action)
           (type list free-hook))
  (rt-eval ()
    (with-add-action (add-action target head tail before after replace)
      (let ((id (or id (get-node-id id add-action))))
        (declare (type non-negative-fixnum id))
        (enqueue-node-function (updated-node id)
          (lambda (node)
            (declare (type node node))
            (when free-hook
              (setf (node-free-hook node) free-hook))
            (funcall init-function node)
            (values init-function obj))
          nil id name add-action target action nil nil)))))

;;; Iteration over the nodes of the graph
(defmacro dograph ((var &optional node result) &body body)
  (with-gensyms (first-node)
    (let ((node (or node '*node-root*)))
      `(let ((,first-node ,node))
         (unless (null-node-p ,first-node)
           (do ((,var ,first-node (node-next ,var)))
               ((null ,var) ,result)
             (declare (type (or node null) ,var))
             ,@body))))))

;;; Iteration over the nodes of a group
(defmacro dogroup ((var group &optional result (recursive-p t)) &body body)
  (with-gensyms (old g)
    `(let ((,g ,group))
       (when (node-p (node-last ,g))
         (do ((,var (node-next ,g) (node-next ,var))
              (,old nil ,var))
             ((eq ,old (node-last ,g)) ,result)
           (declare (type (or node null) ,var ,old))
           ,@body
           ,@(unless recursive-p
               `((when (and (group-p ,var)
                            (node-p (node-last ,var))
                            (not (eq ,var (node-last ,g))))
                   ;; Skip the nodes of the sub-groups
                   (setf ,var (node-last ,var))))))))))

;;; Find a group inside another group
(defun find-group (group group-root)
  (dogroup (g group-root)
    (when (and (group-p g) (eq g group))
      (return t))))

(declaim (inline remove-node-from-hash))
(defun remove-node-from-hash (obj)
  (setf (node-id obj) nil
        (node-name obj) nil
        (node-enable-gain-p obj) nil)
  (decf (int-hash-table-count *node-hash*)))

(declaim (inline unlink-node))
(defun unlink-node (node)
  (declare #.*reduce-warnings*)
  (when #1=(node-free-hook node)
    (dolist (fn #1#) (funcall fn node))
    (setf #1# nil))
  (when #2=(node-stop-hook node) (setf #2# nil))
  (setf (node-done-p node) nil)
  (remove-node-from-hash node))

(defun unlink-group (group)
  (dogroup (item group nil nil)
    (when (node-p item)
      (if (group-p item) (unlink-group item) (unlink-node item))))
  (setf (node-funcons group) nil)
  (if (node-root-p group)
      (setf (node-next group) nil
            (node-last group) :dummy-node
            (node-pause-p group) nil)
      (remove-node-from-hash group)))

(defun unlink-prev (n1 n2)
  (setf (node-next (node-prev n1)) (node-next n2))
  (unless (node-pause-p n1)
    (let ((prev (unpaused-node-prev n1)))
      (when (node-p prev)
        (let ((next-funcons (let ((next (unpaused-node-next n2)))
                              (when (node-p next) (node-funcons next)))))
          (unless (eq prev (node-prev n1))
            (cond ((group-p (node-prev n1))
                   (setf (node-funcons (node-prev n1)) next-funcons)
                   (update-prev-groups (node-prev n1)))
                  (t (setf (cdr (node-funcons (node-prev n1))) next-funcons))))
          (cond ((group-p prev)
                 (setf (node-funcons prev) next-funcons)
                 (update-prev-groups prev))
                (t (setf (cdr (node-funcons prev)) next-funcons))))))))

(declaim (inline unlink-next))
(defun unlink-next (n1 n2)
  (when (node-p (node-next n1))
    (setf (node-prev (node-next n1)) (node-prev n2))))

(declaim (inline unlink-neighbors))
(defun unlink-neighbors (obj)
  (unlink-prev obj obj)
  (unlink-next obj obj))

(declaim (inline unlink-group-neighbors))
(defun unlink-group-neighbors (obj)
  (let ((last (find-last-node obj)))
    (cond ((eq last obj) (unlink-neighbors obj))
          (t (unlink-prev obj last)
             (unlink-next last obj)))))

(defun unlink-parent (obj)
  (labels ((prev-sister (n parent)
             (if (eq (node-parent n) parent)
                 n
                 (prev-sister (node-parent n) parent))))
    (cond ((eq (node-last (node-parent obj)) obj)
           (setf (node-last (node-parent obj))
                 (if (eq (node-next (node-parent obj)) obj)
                     :dummy-node
                     (prev-sister (node-prev obj) (node-parent obj)))))
          ((eq (node-next (node-parent obj)) obj)
           (setf (node-next (node-parent obj)) (node-next obj))))))

(declaim (inline %remove-group))
(defun %remove-group (obj)
  (unlink-group-neighbors obj)
  (unlink-group obj))

(declaim (inline %remove-node))
(defun %remove-node (obj)
  (unlink-neighbors obj)
  (unlink-node obj))

(defun %node-free (node)
  (declare (type node node) #.*standard-optimize-settings*)
  (cond ((node-root-p node)
         (setf *last-node-id* 1)
         (when (node-next *node-root*)
           (unlink-group node)
           (nrt-msg info "free group 0")))
        ((temp-node-p node)
         (foreign-free (node-start-time-ptr node))
         (foreign-free (node-gain-data node))
         (tg:cancel-finalization node)
         (setf (node-id node) nil)
         (nrt-msg info "free temporary node"))
        ((node-id node)
         (let ((id (node-id node)))
           (declare (type non-negative-fixnum id))
           (update-last-node-id id)
           (unlink-parent node)
           (cond ((group-p node)
                  (%remove-group node)
                  (nrt-msg info "free group ~D" id))
                 (t
                  (%remove-node node)
                  (fix-collisions-from node)
                  (nrt-msg info "free node ~D" id)))))))

(defun node-free (obj)
  (declare #.*standard-optimize-settings* (type node obj))
  (if (temp-node-p obj)
      (%node-free obj)
      (rt-eval () (%node-free obj)))
  (values))

(defmethod free ((obj node))
  (node-free obj))

(defmethod free ((obj integer))
  (node-free (node obj)))

(declaim (inline node-free-all))
(defun node-free-all ()
  (node-free *node-root*))

(defgeneric free-hook (obj))

(defmethod free-hook ((obj node))
  (rt-eval (:return-value-p t) (node-free-hook obj)))

(defmethod free-hook ((obj integer))
  (free-hook (node obj)))

(defgeneric (setf free-hook) (flist obj))

(defmethod (setf free-hook) ((flist list) (obj node))
  (rt-eval ()
    (unless (null-node-p obj) (setf (node-free-hook obj) flist))
    (values)))

(defmethod (setf free-hook) ((flist list) (obj integer))
  (setf (free-hook (node obj)) flist))

(defun %node-stop (obj)
  (declare #.*standard-optimize-settings*
           (type node obj))
  (labels ((rec (node)
             (unless (null-node-p node)
               (cond ((group-p node)
                      (dogroup (n obj) (rec n)))
                     (t (dolist (fn (node-stop-hook node))
                          (reduce-warnings (funcall fn node)))
                        (node-free node))))
             (values)))
    (rec obj)))

(declaim (inline node-stop))
(defun node-stop (obj)
  (declare #.*standard-optimize-settings* (type node obj))
  (rt-eval () (%node-stop obj))
  (values))

(defgeneric stop (obj))

(defmethod stop ((obj node))
  (node-stop obj))

(defmethod stop ((obj integer))
  (node-stop (node obj)))

(defgeneric stop-hook (obj))

(defmethod stop-hook ((obj node))
  (rt-eval (:return-value-p t) (node-stop-hook obj)))

(defmethod stop-hook ((obj integer))
  (stop-hook (node obj)))

(defgeneric (setf stop-hook) (flist obj))

(defmethod (setf stop-hook) ((flist list) (obj node))
  (rt-eval ()
    (unless (null-node-p obj) (setf (node-stop-hook obj) flist))
    (values)))

(defmethod (setf stop-hook) ((flist list) (obj integer))
  (setf (stop-hook (node obj)) flist))

(defun move (src move-action dest)
  "Move a node of the graph."
  (declare (type (or node fixnum) src dest) (type keyword move-action))
  (flet ((make-loop-p (group dest)
           ;; The final T to optimize the return value in SBCL
           (and (group-p dest) (find-group group dest) t)))
    (declare #.*standard-optimize-settings*)
    (let ((src (if (numberp src) (node src) src))
          (dest (if (numberp dest) (node dest) dest)))
      (declare (type node src dest))
      (rt-eval ()
        (unless (or (null-node-p src) (null-node-p dest))
          (case move-action
            (:before
             (cond ((eq dest *node-root*)
                    (nrt-msg error "cannot add a node after the root"))
                   ((make-loop-p (node-parent dest) src)
                    (nrt-msg error "~D -> ~D generates a loop"
                             (node-id src) (node-id dest)))
                   (t (unlink-parent src)
                      (unlink-group-neighbors src)
                      (setf (node-prev src) (node-prev dest)
                            (node-next (node-prev src)) src
                            (node-parent src) (node-parent dest))
                      (cond ((group-p src)
                             (let ((last (find-last-node src)))
                               (setf (node-next last) dest
                                     (node-prev dest) last)
                               (cond ((group-p last)
                                      (setf (node-funcons last)
                                            (if (node-pause-p dest)
                                                (node-next-funcons dest)
                                                (node-funcons dest)))
                                      (update-prev-groups last))
                                     (t (setf (cdr (node-funcons last))
                                              (if (node-pause-p dest)
                                                  (node-next-funcons dest)
                                                  (node-funcons dest)))))))
                            (t (setf (node-next src) dest
                                     (node-prev dest) src)
                               (setf (cdr (node-funcons src))
                                     (if (node-pause-p dest)
                                         (node-next-funcons dest)
                                         (node-funcons dest)))))
                      (unless (and (eq (node-prev src) (node-parent src))
                                   (node-pause-p (node-parent src)))
                        (update-prev-groups src)))))
            (:after
             (cond ((eq dest *node-root*)
                    (nrt-msg error "cannot add a node after the root"))
                   ((make-loop-p (node-parent dest) src)
                    (nrt-msg error "~D -> ~D generates a loop"
                             (node-id src) (node-id dest)))
                   (t (unlink-parent src)
                      (unlink-group-neighbors src)
                      (setf (node-parent src) (node-parent dest))
                      (let ((last-src (if (group-p src)
                                          (find-last-node src)
                                          src)))
                        (flet ((link-funcons (src dest)
                                 (when (node-p dest)
                                   (cond ((group-p dest)
                                          (setf (node-funcons dest)
                                                (node-funcons src))
                                          (update-prev-groups dest))
                                         (t (setf (cdr (node-funcons dest))
                                                  (node-funcons src)))))
                                 (values)))
                          (cond ((group-p dest)
                                 (let ((last (find-last-node dest)))
                                   (setf (node-prev src) last
                                         (node-next last-src) (node-next last)
                                         (node-next last) src)
                                   (unless (node-pause-p src)
                                     (let ((last (if (node-pause-p last)
                                                     (unpaused-node-prev last)
                                                     last)))
                                       (link-funcons src last)
                                       (when (node-pause-p dest)
                                         (link-funcons src (unpaused-node-prev
                                                            dest)))))))
                                (t (setf (node-prev src) dest
                                         (node-next last-src) (node-next dest)
                                         (node-next dest) src)
                                   (unless (node-pause-p src)
                                     (let ((dest (if (node-pause-p dest)
                                                     (unpaused-node-prev dest)
                                                     dest)))
                                       (link-funcons src dest))))))
                        (let ((next-funcons
                               (when (node-p (node-next last-src))
                                 (setf (node-prev (node-next last-src))
                                       last-src)
                                 (let ((next (unpaused-node-next last-src)))
                                   (when (node-p next) (node-funcons next))))))
                          (cond ((group-p last-src)
                                 (setf (node-funcons last-src) next-funcons)
                                 (update-prev-groups last-src))
                                (t (setf (cdr (node-funcons last-src))
                                         next-funcons))))
                        (when (eq dest (node-last (node-parent src)))
                          (setf (node-last (node-parent src)) src))))))
            (:head
             (cond ((not (group-p dest))
                    (nrt-msg error "the node ~D is not a group" (node-id dest)))
                   ((make-loop-p dest src)
                    (nrt-msg error "~D -> ~D generates a loop" (node-id src)
                             (node-id dest)))
                   ((node-p (node-last dest))
                    (move src :before (node-next dest)))
                   (t (unlink-parent src)
                      (unlink-group-neighbors src)
                      (let ((last-src (if (group-p src)
                                          (find-last-node src)
                                          src)))
                        (setf (node-next last-src) (node-next dest)
                              (node-prev src) dest
                              (node-next dest) src
                              (node-parent src) dest
                              (node-last dest) src)
                        (cond ((node-p (node-next last-src))
                               (setf (node-prev (node-next last-src)) last-src)
                               (unless (node-pause-p (node-next last-src))
                                 (if (group-p last-src)
                                     (setf (node-funcons last-src)
                                           (node-funcons (node-next last-src)))
                                     (setf (cdr (node-funcons last-src))
                                           (node-funcons
                                            (node-next last-src))))))
                              (t (if (group-p last-src)
                                     (setf (node-funcons last-src) nil)
                                     (setf (cdr (node-funcons last-src)) nil))))
                        (unless (node-pause-p src)
                          (setf (node-funcons dest) (node-funcons src))
                          (update-prev-groups dest))))))
            (:tail
             (cond ((not (group-p dest))
                    (nrt-msg error "the node ~D is not a group" (node-id dest)))
                   ((make-loop-p dest src)
                    (nrt-msg error "~D -> ~D generates a loop" (node-id src)
                             (node-id dest)))
                   ((node-p (node-last dest))
                    (move src :after (node-last dest)))
                   (t (move src :head dest))))
            (t (nrt-msg error "unknown move-action ~S" move-action))))))))

(defun before-p (n1 n2)
  (declare (type (or node fixnum)))
  (let ((n1 (if (numberp n1) (node n1) n1))
        (n2 (if (numberp n2) (node n2) n2))
        (result nil))
    (rt-eval (:return-value-p t)
      (unless (or (null-node-p n1) (null-node-p n2))
        (dograph (curr)
          (cond ((eq curr n2) (return result))
                ((eq curr n1) (setf result t))))))))

(defun after-p (n1 n2)
  (before-p n2 n1))

(defun head-p (node group)
  (declare (type (or node fixnum) node group))
  (let ((group (if (numberp group) (node group) group)))
    (rt-eval (:return-value-p t)
      (when (group-p group)
        (let ((node (if (numberp node) (node node) node)))
          (eq (node-next group) node))))))

(defun tail-p (node group)
  (declare (type (or node fixnum) node group))
  (let ((group (if (numberp group) (node group) group)))
    (rt-eval (:return-value-p t)
      (when (group-p group)
        (let ((node (if (numberp node) (node node) node)))
          (eq (node-last group) node))))))

(defun control-functions (obj control-name)
  (declare (type (or non-negative-fixnum node) obj)
           (type symbol control-name)
           #.*standard-optimize-settings*)
  (let ((obj (if (node-p obj) obj (getihash obj))))
    (declare (type node obj))
    (unless (null-node-p obj)
      (let ((ht (node-controls obj)))
        (declare (type (or hash-table null)))
        (when ht (gethash (symbol-name control-name) ht))))))

(declaim (inline control-getter))
(defun control-getter (obj control-name)
  (declare (type (or non-negative-fixnum node) obj) (type symbol control-name)
           #+(or cmu sbcl) (values (or function null)))
  (cdr (control-functions obj control-name)))

(declaim (inline control-setter))
(defun control-setter (obj control-name)
  (declare (type (or non-negative-fixnum node) obj) (type symbol control-name)
           #+(or cmu sbcl) (values (or function null)))
  (let ((fn (car (control-functions obj control-name))))
    (declare #.*standard-optimize-settings*)
    (or fn
        (let ((node (if (numberp obj) (node obj) obj)))
          (if (group-p node)
              ;; Set all the nodes of the group
              (lambda (value)
                (dogroup (n node value)
                  (let ((fn (car (control-functions n control-name))))
                    (declare (type (or function null) fn))
                    (when fn (funcall fn value))))))))))

(declaim (inline control-value))
(defun control-value (obj control-name)
  (declare (type (or non-negative-fixnum node) obj) (type symbol control-name))
  (rt-eval (:return-value-p t)
    (locally (declare #.*standard-optimize-settings*)
      (let ((fn (control-getter obj control-name)))
        (declare (type (or function null) fn))
        (if fn
            (values (funcall fn) t)
            (values nil nil))))))

(declaim (inline set-control))
(defun set-control (obj control-name value)
  (declare (type (or non-negative-fixnum node) obj) (type symbol control-name))
  (rt-eval ()
    (locally (declare #.*standard-optimize-settings*)
      (let ((fn (control-setter obj control-name)))
        (declare (type (or function null) fn))
        (when fn
          (funcall fn value)
          (nrt-msg info "set node ~D ~A ~A"
                   (if (numberp obj) obj (node-id obj))
                   control-name value)))))
  value)

(defsetf control-value set-control)

(defun set-controls (obj &rest plist)
  (declare (type (or non-negative-fixnum node) obj))
  (rt-eval ()
    (locally (declare #.*standard-optimize-settings*)
      (let ((node (if (numberp obj) (node obj) obj)))
        (declare (type node node))
        (do ((pl plist (cdr pl)))
            ((null pl))
          (declare (type list pl))
          (let ((control-name (car pl)))
            (declare (type symbol control-name))
            (setf pl (cdr pl))
            (locally (declare (optimize (speed 1)))
              (set-control node control-name (car pl))))))))
  (values))

(declaim (inline control-list))
(defun control-list (obj)
  (declare (type (or non-negative-fixnum node) obj))
  (rt-eval (:return-value-p t) (control-value obj :%control-list%)))

(declaim (inline control-names))
(defun control-names (obj)
  (declare (type (or non-negative-fixnum node) obj))
  (rt-eval (:return-value-p t) (control-value obj :%control-names%)))

(declaim (inline node-init-parse-args))
(defun node-init-parse-args (node)
  (the function (car (node-init-args node))))

(defun reinit (node &rest args)
  (declare (type (or node positive-fixnum) node))
  (at 0
      (lambda ()
        (declare #.*standard-optimize-settings*)
        (let ((node (if (node-p node) node (node node))))
          (declare (type node node))
          (when (node-id node)
            (let ((free-hook #1=(node-free-hook node)))
              (setf #1# nil)
              (apply (node-init-function node) node
                     (if args
                         (apply (node-init-parse-args node) args)
                         (cdr (node-init-args node))))
              ;; Restore the complete FREE-HOOK after the re-initialization.
              (setf #1# free-hook)))
          node))))

(defgeneric pause (obj))

(defmethod pause ((obj node))
  (rt-eval (:return-value-p t)
    (locally (declare #.*standard-optimize-settings*)
      (unless (or (null-node-p obj) (node-pause-p obj))
        (let ((prev (unpaused-node-prev obj)))
          (cond ((group-p obj)
                 (setf (node-pause-p obj) t)
                 (if (node-p prev)
                     (cond ((group-p prev)
                            (setf (node-funcons prev)
                                  (node-next-funcons (find-last-node obj)))
                            (update-prev-groups prev))
                           (t (setf (cdr (node-funcons prev))
                                    (node-next-funcons (find-last-node obj)))))
                     (setf (node-funcons obj)
                           (node-next-funcons (find-last-node obj))))
                 (nrt-msg info "pause node ~D" (node-id obj)))
                ((null prev) nil)
                (t (setf (node-pause-p obj) t)
                   (cond ((group-p prev)
                          (unless (node-pause-p (node-parent obj))
                            (setf (node-funcons prev) (cdr (node-funcons obj)))
                            (update-prev-groups prev)))
                         (t (setf (cdr (node-funcons prev))
                                  (cdr (node-funcons obj)))))
                   (nrt-msg info "pause node ~D" (node-id obj))))
          obj)))))

(defmethod pause ((obj integer))
  (pause (node obj)))

(defgeneric unpause (obj))

(defmethod unpause ((obj node))
  (rt-eval (:return-value-p t)
    (locally (declare #.*standard-optimize-settings*)
      (when (and (node-pause-p obj) (not (null-node-p obj)))
        (let ((prev (unpaused-node-prev obj)))
          (setf (node-pause-p obj) nil)
          (cond ((eq obj *node-root*)
                 (let ((next (if (node-p (node-next obj))
                                 (if (node-pause-p (node-next obj))
                                     (unpaused-node-next (node-next obj))
                                     (node-next obj)))))
                   (when next
                     (setf (node-funcons *node-root*) (node-funcons next))))
                 (nrt-msg info "unpause node ~D" (node-id obj)))
                ((group-p obj)
                 (let ((last (find-last-node obj)))
                   (when (node-pause-p last)
                     (setf last (unpaused-node-prev last)))
                   (cond ((group-p last)
                          (setf (node-funcons last) (node-next-funcons last))
                          (update-prev-groups last))
                         (t (setf (cdr (node-funcons last))
                                  (node-next-funcons last)))))
                 (when (node-p prev)
                   (if (group-p prev)
                       (progn
                         (setf (node-funcons prev) (node-funcons obj))
                         (update-prev-groups prev))
                       (setf (cdr (node-funcons prev)) (node-funcons obj))))
                 (nrt-msg info "unpause node ~D" (node-id obj)))
                (t (setf (cdr (node-funcons obj)) (node-next-funcons obj))
                   (if (group-p prev)
                       (unless (node-pause-p (node-parent obj))
                         (setf (node-funcons prev) (node-funcons obj))
                         (update-prev-groups prev))
                       (setf (cdr (node-funcons prev)) (node-funcons obj)))
                   (nrt-msg info "unpause node ~D" (node-id obj))))
          obj)))))

(defmethod unpause ((obj integer))
  (unpause (node obj)))

(defgeneric pause-p (obj))

(defmethod pause-p ((obj node))
  (node-pause-p obj))

(defmethod pause-p ((obj integer))
  (node-pause-p (node obj)))

(defgeneric dump (obj &optional stream))

(defmethod dump ((obj node) &optional (stream *logger-stream*))
  (declare (type stream stream))
  (let ((indent 0)
        (indent-incr 4)
        (last-list nil))
    (declare (type non-negative-fixnum indent indent-incr)
             #.*standard-optimize-settings*)
    (fresh-line stream)
    (flet ((inc-indent (n)
             (unless (symbolp (node-last n))
               (incf indent indent-incr)
               (push (find-last-node n) last-list)))
           (dec-indent (n)
             (loop while (eq n (car last-list)) do
               (pop last-list)
               (decf indent indent-incr)))
           (indent-line ()
             (do ((i 0 (1+ i)))
                 ((= i indent))
               (declare (type non-negative-fixnum i))
               (princ " " stream))))
      (dograph (n obj)
        (indent-line)
        (cond ((group-p n)
               (dec-indent n)
               (format stream "group ~D~:[~; (pause)~]~%" (node-id n)
                       (node-pause-p n))
               (inc-indent n))
              (t (format stream "node ~D~:[~; (pause)~]~%" (node-id n)
                         (node-pause-p n))
                 (indent-line)
                 (format stream "  ~A ~{~A ~}~%"
                         (node-name n) (reduce-warnings (control-list n)))
                 (dec-indent n))))
      (force-output stream))))

;;; Envelope segment of a node.

(defmacro with-node-segment-symbols (node symbols &body body)
  (let ((count 0)
        (instance (gensym "INSTANCE")))
    `(symbol-macrolet ((,instance (node-gain-data ,node))
                       ,@(mapcar
                          (lambda (sym)
                            (prog1 `(,sym (smp-ref ,instance ,count))
                              (incf count)))
                          symbols))
       ,@body)))

(defun node-segment (obj end dur &optional start curve (done-action #'identity))
  (let ((obj (if (node-p obj) obj (node obj))))
    (declare #.*standard-optimize-settings* #.*reduce-warnings*)
    (cond ((or (null-node-p obj) (node-release-phase-p obj)) obj)
          ((or *node-enable-gain-p* (node-enable-gain-p obj))
           (with-node-segment-symbols obj
               (level start0 end0 curve0 grow a2 b1 y1 y2)
             (when curve (setf curve0 (seg-function-spec->sample curve)))
             (let* ((samples (max 1 (sample->fixnum (* dur *sample-rate*))))
                    (remain samples)
                    (curve (or curve (sample->seg-function-spec curve0))))
               (declare (type non-negative-fixnum samples remain))
               (setf level (envelope-fix-zero level curve))
               (setf start0 (if start
                                (envelope-fix-zero start curve)
                                level))
               (setf end0 (envelope-fix-zero end curve))
               (when (eq done-action #'free)
                 (setf (node-release-phase-p obj) t))
               (%segment-init start0 end0 samples curve0 grow a2 b1 y1 y2)
               (setf (node-current-function obj)
                     (lambda (chan)
                       (declare (type non-negative-fixnum chan))
                       (cond ((plusp remain)
                              (when (zerop chan)
                                (%segment-update-level level curve0 grow a2 b1
                                                       y1 y2)
                                (decf remain))
                              (funcall (node-function obj) chan))
                             (t (funcall (setf (node-current-function obj)
                                               (node-function obj))
                                         chan)
                                (funcall done-action obj)))
                       (values)))
               obj)))
          (t (funcall done-action obj)))))
