(defpackage #:qlot/server
  (:use #:cl)
  (:import-from #:qlot/source
                #:source-project-name
                #:source-version
                #:source-initargs
                #:source-frozen-slots
                #:defrost-source)
  (:import-from #:qlot/color
                #:*enable-color*)
  (:import-from #:qlot/utils/shell
                #:run-lisp
                #:shell-command-error
                #:shell-command-error-output
                #:*qlot-source-directory*)
  (:import-from #:qlot/utils/tmp
                #:with-tmp-directory)
  (:import-from #:qlot/errors
                #:qlot-simple-error)
  (:export #:with-qlot-server
           #:run-distify-source-process))
(in-package #:qlot/server)

(defvar *handler*)

(defun qlot-fetch (url file &key follow-redirects quietly maximum-redirects)
  (declare (ignore follow-redirects quietly maximum-redirects))
  (let ((result (funcall *handler* url)))
    (etypecase result
      (pathname (uiop:copy-file result file))
      (null)))
  (values (make-instance (intern (string '#:header) '#:ql-http) :status 200)
          (probe-file file)))

(defun make-handler (destination)
  (lambda (url)
    (when (and (stringp url)
               (<= (length "qlot://localhost/")
                   (length url))
               (string= "qlot://localhost/" url :end2 (length "qlot://localhost/")))
      (let* ((path (subseq url (length "qlot://localhost/")))
             (file (merge-pathnames path destination)))
        (when (uiop:file-exists-p file)
          file)))))

(defun run-distify-source-process (source destination &key distinfo-only quicklisp-home)
  (let ((qlot-source-dir (or *qlot-source-directory*
                             (asdf:system-source-directory :qlot)))
        (quicklisp-home (or quicklisp-home
                            (and (find :quicklisp *features*)
                                 (symbol-value (intern (string '#:*quicklisp-home*) '#:ql))))))
    (handler-case
        (run-lisp (append
                   (list `(setf *enable-color* ,*enable-color*))
                   (list `(uiop:symbol-call :qlot/distify :distify
                                            ;; Call defrost-source to set '%version' from 'source-version'.
                                            (defrost-source
                                                (make-instance ',(type-of source)
                                                               :project-name ,(source-project-name source)
                                                               ,@(source-initargs source)
                                                               ,@(and (slot-boundp source 'qlot/source/base::version)
                                                                      `(:version ,(source-version source)))
                                                               ,@(source-frozen-slots source)))
                                            ,destination
                                            :distinfo-only ,distinfo-only)))
                  :load (or (probe-file (merge-pathnames #P".bundle-libs/bundle.lisp" qlot-source-dir))
                            (and quicklisp-home
                                 (merge-pathnames #P"setup.lisp" quicklisp-home)))
                  :systems '("qlot/distify")
                  :source-registry qlot-source-dir)
      (shell-command-error (e)
        (error 'qlot-simple-error
               :format-control (string-trim '(#\Newline) (shell-command-error-output e)))))))

(defmacro with-qlot-server ((source &key destination distinfo-only quicklisp-home) &body body)
  (let ((g-source (gensym "SOURCE"))
        (fetch-scheme-functions (gensym "FETCH-SCHEME-FUNCTIONS"))
        (g-destination (gensym "DESTINATION")))
    `(let ((,g-source ,source)
           (,fetch-scheme-functions (intern (string '#:*fetch-scheme-functions*) '#:ql-http)))
       (,@(if destination
              `(let ((,g-destination ,destination)))
              `(with-tmp-directory (,g-destination)))
         ;; Run distify in another Lisp process
         (run-distify-source-process ,g-source ,g-destination
                                     :distinfo-only ,distinfo-only
                                     :quicklisp-home ,quicklisp-home)
         (progv (list ,fetch-scheme-functions '*handler*)
             (list (cons '("qlot" . qlot-fetch)
                         (symbol-value ,fetch-scheme-functions))
                   (make-handler ,g-destination))
           ,@body)))))
