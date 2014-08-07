(in-package :cl-user)
(defpackage qlot.install
  (:use :cl
        :iterate)
  (:import-from :qlot.parser
                :prepare-qlfile)
  (:import-from :qlot.server
                :localhost
                :start-server
                :stop-server)
  (:import-from :qlot.tmp
                :*tmp-directory*)
  (:import-from :qlot.source
                :source-dist-name
                :freeze-source
                :url-path-for
                :project.txt)
  (:import-from :qlot.http
                :download-file)
  (:import-from :qlot.shell
                :safety-shell-command)
  (:import-from :qlot.asdf
                :qlot-system
                :system-quicklisp-home)
  (:import-from :qlot.util
                :find-qlfile
                :with-quicklisp-home
                :with-package-functions
                :ensure-installed-in-local-quicklisp)
  (:import-from :fad
                :pathname-as-directory
                :pathname-absolute-p
                :pathname-directory-pathname
                :generate-random-string
                :delete-directory-and-files)
  (:export :install-quicklisp
           :install-qlfile
           :install-project))
(in-package :qlot.install)

(defvar *current-lisp-path*
  (or
   #+ccl (car ccl:*command-line-argument-list*)
   #+sbcl (car sb-ext:*posix-argv*)
   #+allegro (car (system:command-line-arguments))
   #+clisp "clisp"
   #+cmu (car ext:*command-line-strings*)
   #+ecl (car (si:command-args))))

(defun install-quicklisp (&optional (path (merge-pathnames #P"quicklisp/" *default-pathname-defaults*)))
  (format t "~&Installing Quicklisp to ~A ...~%" path)
  (let ((*standard-output* (make-broadcast-stream))
        (quicklisp-file (merge-pathnames (format nil "quicklisp-~A.lisp"
                                                 (fad::generate-random-string))
                                         *tmp-directory*)))
    (ensure-directories-exist *tmp-directory*)
    (download-file "http://beta.quicklisp.org/quicklisp.lisp"
                   quicklisp-file)

    #+(or ccl sbcl allegro clisp cmu ecl)
    (let ((eval-option (or
                        #+ccl "--eval"
                        #+sbcl "--eval"
                        #+allegro "-e"
                        #+clisp "-x"
                        #+cmu "-eval"
                        #+ecl "-eval")))
      (safety-shell-command *current-lisp-path*

                            (append

                             #+ccl '("--no-init" "--quiet" "--batch")
                             #+sbcl '("--noinform" "--no-sysinit" "--no-userinit" "--non-interactive")
                             #+allegro '("--qq")
                             #+clisp '("-norc" "--quiet" "--silent" "-on-error" "exit")
                             #+cmu '("-noinit")
                             #+ecl '("-norc")

                             `(,eval-option
                               ,(prin1-to-string `(load ,quicklisp-file)))

                             `(,eval-option
                               ,(format nil "(quicklisp-quickstart:install :path #P\"~A\")" path))

                             `(,eval-option
                               ,(prin1-to-string
                                 (quote
                                  #+ccl (ccl:quit)
                                  #+sbcl (sb-ext:exit)
                                  #+allegro (excl:exit :quiet t)
                                  #+clisp (ext:quit)
                                  #+cmucl (unix:unix-exit)
                                  #+ecl (ext:quit)
                                  #-(or ccl sbcl allegro clisp cmucl ecl) (cl-user::quit)))))))
    #-(or ccl sbcl allegro clisp cmu ecl)
    (progn
      (when (find-package :ql)
        (delete-package :ql))
      (asdf:clear-system :quicklisp)
      (load quicklisp-file)
      (with-package-functions :quicklisp-quickstart (install)
        (install :path path))))
  T)

(defun uninstall-all-dists (qlhome)
  (with-package-functions :ql-dist (uninstall all-dists)
    (with-quicklisp-home qlhome
      (mapc #'uninstall (all-dists)))))

(defun canonical-qlhome (qlhome &optional (base *default-pathname-defaults*))
  (setf qlhome (fad:pathname-as-directory qlhome))
  (if (fad:pathname-absolute-p qlhome)
      qlhome
      (merge-pathnames qlhome base)))

(defparameter *current-system* nil)

(defun install-qlfile (file &key (quicklisp-home #P"quicklisp/"))
  (unless (probe-file file)
    (error "File does not exist: ~A" file))

  (let ((qlhome (canonical-qlhome quicklisp-home (fad:pathname-directory-pathname file))))

    (unless (probe-file qlhome)
      (install-quicklisp qlhome))

    (unless (find-package :ql)
      (load (merge-pathnames #P"setup.lisp" qlhome)))

    (uninstall-all-dists qlhome)
    (apply-qlfile-to-qlhome file qlhome)

    (format t "~&Successfully installed.~%")))

(defun update-qlfile (file &key (quicklisp-home #P"quicklisp/"))
  (unless (probe-file file)
    (error "File does not exist: ~A" file))

  (let ((qlhome (canonical-qlhome quicklisp-home (fad:pathname-directory-pathname file))))

    (unless (probe-file qlhome)
      (error "~S does not exist." qlhome))

    (unless (find-package :ql)
      (load (merge-pathnames #P"setup.lisp" qlhome)))

    (apply-qlfile-to-qlhome file qlhome)

    (format t "~&Successfully updated.~%")))

(defun apply-qlfile-to-qlhome (file qlhome)
  (let* ((dists-map (make-hash-table :test 'equal))
         (*tmp-directory* (fad:pathname-as-directory (merge-pathnames (fad::generate-random-string)
                                                                      (merge-pathnames #P"tmp/qlot/" qlhome))))
         (sources (prepare-qlfile file)))
    (start-server sources)
    (with-quicklisp-home qlhome
      (let (to-install to-update to-uninstall)
        (with-package-functions :ql-dist (all-dists name)
          (iter (for dist in (all-dists))
            (setf (gethash (name dist) dists-map) dist)))

        (with-package-functions :ql-dist (distinfo-subscription-url (setf distinfo-subscription-url) available-update)
          (iter (for source in sources)
            (let ((dist (gethash (source-dist-name source) dists-map)))
              (cond
                (dist (remhash (source-dist-name source) dists-map)
                      (setf (distinfo-subscription-url dist)
                            (ppcre:regex-replace "^http://127\\.0\\.0\\.1:\\d+"
                                                 (distinfo-subscription-url dist)
                                                 (localhost)))
                      (when (available-update dist)
                        (push dist to-update)))
                (T (push source to-install))))
            (finally (setf to-update (nreverse to-update))
                     (setf to-install (nreverse to-install)))))

        (iter (for (dist-name dist) in-hashtable dists-map)
          (push dist to-uninstall)
          (finally (setf to-uninstall (nreverse to-uninstall))))

        ;; Report
        (with-package-functions :ql-dist (name)
          (when to-install
            (format t "~&  New dists:~%    ~{~A~^ ~}~%" (mapcar #'source-dist-name to-install)))
          (when to-update
            (format t "~&  Updated dists:~%    ~{~A~^ ~}~%" (mapcar #'name to-update)))
          (when to-uninstall
            (format t "~&  Removed dists:~%    ~{~A~^ ~}~%" (mapcar #'name to-uninstall))))

        ;; Installing
        (with-package-functions :ql-dist (install-dist)
          (iter (for source in to-install)
            (install-dist (localhost (url-path-for source 'project.txt)) :prompt nil :replace nil)))

        ;; Updating
        (with-package-functions :ql-dist (update-in-place available-update name version uninstall installed-releases)
          (iter (for dist in to-update)
            (let ((new-dist (available-update dist)))
              (format t "~&Updating dist ~S version ~S -> ~S.~%"
                      (name dist)
                      (version dist)
                      (version new-dist))
              (map nil #'uninstall (installed-releases dist))
              (update-in-place dist new-dist))))

        ;; Uninstalling
        (with-package-functions :ql-dist (uninstall name)
          (iter (for dist in to-uninstall)
            (format t "~&Removing dist ~S.~%" (name dist))
            (uninstall dist)))

        (with-package-functions :ql-dist (dist (setf preference))
          (iter
            (for source in sources)
            (for time from (get-universal-time))
            (setf (preference (dist (source-dist-name source)))
                  time)))

        (when *current-system*
          (let ((qlhome (system-quicklisp-home *current-system*)))
            (map nil
                 (lambda (asd)
                   (ensure-installed-in-local-quicklisp
                    (asdf:find-system (pathname-name asd))
                    qlhome))
                 (asdf::directory-asd-files (asdf:component-pathname *current-system*)))))))
    (stop-server)

    (unless (string= (pathname-type file) "lock")
      (with-quicklisp-home qlhome
        (with-open-file (out (merge-pathnames (format nil "~A.lock" (file-namestring file))
                                              file)
                             :direction :output
                             :if-exists :supersede)
          (format out "~{~A~&~}" (mapcar #'freeze-source sources)))))

    (when (probe-file *tmp-directory*)
      (fad:delete-directory-and-files *tmp-directory*))))

(defun directory-system-for-qlhome (directory)
  (iter (for asd in (asdf::directory-asd-files directory))
    (for system = (asdf:find-system (pathname-name asd)))
    (when (typep system 'qlot-system)
      (return-from directory-system-for-qlhome system)))
  (car (asdf::directory-asd-files directory)))

(defgeneric install-project (object &rest args)
  (:method ((object symbol) &rest args)
    (apply #'install-project (asdf:find-system object) args))
  (:method ((object string) &rest args)
    (apply #'install-project (asdf:find-system object) args))
  (:method ((object qlot-system) &rest args &key quicklisp-home &allow-other-keys)
    (unless quicklisp-home
      (setf args
            (list* :quicklisp-home
                   (system-quicklisp-home object)
                   args)))
    (apply #'call-next-method object args))
  (:method ((object asdf:system) &rest args)
    (let ((*current-system* object)
          (system-dir (asdf:component-pathname object)))
      (apply #'install-qlfile
             (or (find-qlfile system-dir :errorp nil :use-lock t)
                 (find-qlfile system-dir :errorp nil)
                 (error "qlfile does not exist in '~S'." system-dir))
             args)))
  (:method ((object pathname) &rest args)
    (let ((object (truename object)))
      (if (fad:directory-pathname-p object)
          (let ((*current-system* (directory-system-for-qlhome object)))
            (apply #'install-qlfile
                   (or (find-qlfile object :errorp nil :use-lock t)
                       (find-qlfile object :errorp nil)
                       (error "qlfile does not exist in '~S'." object))
                   args))
          (apply #'install-qlfile object args)))))

(defgeneric update-project (object &rest args)
  (:method ((object symbol) &rest args)
    (apply #'update-project (asdf:find-system object) args))
  (:method ((object string) &rest args)
    (apply #'update-project (asdf:find-system object) args))
  (:method ((object qlot-system) &rest args &key quicklisp-home &allow-other-keys)
    (unless quicklisp-home
      (setf args
            (list* :quicklisp-home
                   (system-quicklisp-home object)
                   args)))
    (apply #'call-next-method object args))
  (:method ((object asdf:system) &rest args)
    (let ((*current-system* object)
          (system-dir (asdf:component-pathname object)))
      (apply #'update-qlfile
             (or (find-qlfile system-dir :errorp nil :use-lock t)
                 (find-qlfile system-dir :errorp nil)
                 (error "qlfile does not exist in '~S'." system-dir))
             args)))
  (:method ((object pathname) &rest args)
    (let ((object (truename object)))
      (if (fad:directory-pathname-p object)
          (let ((*current-system* (directory-system-for-qlhome object)))
            (apply #'update-qlfile (find-qlfile object) args))
          (apply #'update-qlfile object args)))))
