;;; lispm-gl-test.el --- Tests of lispm-gl -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; On Emacs 30 and 31 these check that lispm-gl refuses, fetching and
;; loading nothing.  On Emacs 32 they draw, with the module Cargo built
;; (make module), or the one LISPM_GL_MODULE names; without either the
;; drawing tests are skipped.

;;; Code:

(require 'ert)
(require 'lispm-gl)

(defun lispm-gl-test--module ()
  "Return the module to draw with, or nil."
  (let ((file (or (getenv "LISPM_GL_MODULE")
                  (let ((lispm-gl-module-source 'build)) (lispm-gl-module-file)))))
    (and file (file-readable-p file) file)))

(defmacro lispm-gl-test--drawing (&rest body)
  "Run BODY where OpenGL can be drawn, the module loaded; else skip."
  (declare (indent 0))
  `(progn
     (skip-unless (lispm-gl-supported-p))
     (skip-unless (lispm-gl-test--module))
     (unless (featurep 'lispm-gl-core)
       (module-load (lispm-gl-test--module)))
     ,@body))

(defconst lispm-gl-test--vertex
  "#version 330 core
in vec2 position;
in vec3 colour;
out vec3 shade;
void main() { shade = colour; gl_Position = vec4(position, 0.0, 1.0); }")

(defconst lispm-gl-test--fragment
  "#version 330 core
in vec3 shade;
uniform float gain;
out vec4 colour;
void main() { colour = vec4(shade * gain, 1.0); }")

;;;; Before Emacs 32

(ert-deftest lispm-gl-refuses-before-emacs-32 ()
  (skip-unless (< emacs-major-version 32))
  (should-not (lispm-gl-supported-p))
  (should (string-match-p "needs Emacs 32" (lispm-gl-unsupported-reason)))
  ;; Loading is the only way to fetch, build or load the module.
  (cl-letf (((symbol-function 'lispm-gl-module-load)
             (lambda (&rest _) (error "The module was fetched, built or loaded"))))
    (should (equal (cadr (should-error (lispm-gl-create 16 16) :type 'lispm-gl-unsupported))
                   (lispm-gl-unsupported-reason))))
  (should-not (featurep 'lispm-gl-core)))

(ert-deftest lispm-gl-demo-refuses-before-emacs-32 ()
  (skip-unless (< emacs-major-version 32))
  (require 'lispm-gl-demo)
  (should (string-match-p "needs Emacs 32" (cadr (should-error (lispm-gl-demo) :type 'user-error)))))

;;;; Anywhere

(ert-deftest lispm-gl-matrices ()
  (let ((m (lispm-gl-rotation 0.7 0 1 0)))
    (should (equal (lispm-gl-matrix-multiply (lispm-gl-identity) m) m)))
  ;; A quarter turn about z takes x to y.
  (let ((turn (lispm-gl-rotation (/ float-pi 2) 0 0 1)))
    (should (< (abs (- (aref turn 1) 1.0)) 1e-9))
    (should (< (abs (aref turn 0)) 1e-9)))
  (should (equal (aref (lispm-gl-matrix-multiply (lispm-gl-translation 1 2 3) (lispm-gl-translation 1 1 1)) 14)
                 4.0)))

(ert-deftest lispm-gl-module-names-its-sources ()
  (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" (lispm-gl-module-source-version)))
  (should (equal (lispm-gl-module--target "aarch64-apple-darwin25.0.0") "aarch64-apple-darwin"))
  (should (equal (lispm-gl-module--target "x86_64-pc-linux-gnu") "x86_64-unknown-linux-gnu"))
  (should-not (lispm-gl-module--target "aarch64-unknown-openbsd"))
  (should (equal (lispm-gl-module--asset "x86_64-unknown-linux-gnu")
                 "lispm-gl-module-x86_64-unknown-linux-gnu.so.gz")))

(ert-deftest lispm-gl-module-keeps-only-what-is-pinned ()
  (let ((version (lispm-gl-module-source-version)))
    (cl-letf (((symbol-function 'lispm-gl-module--pins)
               (lambda () `(:version ,version :modules (("aarch64-apple-darwin" . ,(make-string 64 ?a)))))))
      (should (equal (lispm-gl-module--pinned-sha256 "aarch64-apple-darwin") (make-string 64 ?a)))
      (should-not (lispm-gl-module--pinned-sha256 "x86_64-apple-darwin")))
    (cl-letf (((symbol-function 'lispm-gl-module--pins)
               (lambda () '(:version "0000000000000000" :modules (("aarch64-apple-darwin" . "x"))))))
      (should-not (lispm-gl-module--pinned-sha256 "aarch64-apple-darwin")))))

;;;; Drawing, on Emacs 32

(ert-deftest lispm-gl-draws-into-the-canvas ()
  (lispm-gl-test--drawing
    (let* ((gl (lispm-gl-create 64 48))
           (program (lispm-gl-program gl lispm-gl-test--vertex lispm-gl-test--fragment))
           ;; A red rectangle over the top half.
           (top (lispm-gl-buffer gl [-1 0 1 0 0  1 0 1 0 0  1 1 1 0 0  -1 0 1 0 0  1 1 1 0 0  -1 1 1 0 0])))
      (lispm-gl-clear gl [0 0 1 1])
      (lispm-gl-draw gl program top :layout [("position" . 2) ("colour" . 3)] :uniforms '(("gain" . 1)))
      (lispm-gl-present gl)
      (should (equal (lispm-gl-pixel gl 32 10) #xffff0000))
      (should (equal (lispm-gl-pixel gl 32 40) #xff0000ff))
      (should-not (lispm-gl-pixel gl 64 0))
      ;; Half the gain, half the red.
      (lispm-gl-clear gl [0 0 1 1])
      (lispm-gl-draw gl program top :layout [("position" . 2) ("colour" . 3)] :uniforms '(("gain" . 0.5)))
      (lispm-gl-present gl)
      (should (<= #x7f (logand (ash (lispm-gl-pixel gl 32 10) -16) #xff) #x80)))))

(ert-deftest lispm-gl-says-what-does-not-compile ()
  (lispm-gl-test--drawing
    (let ((gl (lispm-gl-create 8 8)))
      (should (string-match-p "fragment shader does not compile"
                              (cadr (should-error (lispm-gl-program gl lispm-gl-test--vertex "#version 330 core\nvoid main() { nothing; }")
                                                  :type 'lispm-gl-error))))
      (let ((program (lispm-gl-program gl lispm-gl-test--vertex lispm-gl-test--fragment))
            (buffer (lispm-gl-buffer gl [0 0 1 1 1])))
        (should-error (lispm-gl-draw gl program buffer :layout [("position" . 2) ("colour" . 3)]
                                     :uniforms '(("gain" . [1 2])))
                      :type 'lispm-gl-error)
        (should-error (lispm-gl-draw gl program buffer :layout [("position" . 2) ("colour" . 3)] :count 2)
                      :type 'lispm-gl-error)
        (should-error (lispm-gl-draw gl 999 buffer :layout [("position" . 2)]) :type 'lispm-gl-error)
        (lispm-gl-delete gl buffer)
        (should-error (lispm-gl-draw gl program buffer :layout [("position" . 2)]) :type 'lispm-gl-error)))))

(ert-deftest lispm-gl-canvases-are-many ()
  (lispm-gl-test--drawing
    (let ((a (lispm-gl-create 4 4))
          (b (lispm-gl-create 4 4 :samples 0)))
      (lispm-gl-clear a [1 0 0 1])
      (lispm-gl-clear b [0 1 0 1])
      (lispm-gl-present a)
      (lispm-gl-present b)
      (should (equal (lispm-gl-pixel a 1 1) #xffff0000))
      (should (equal (lispm-gl-pixel b 1 1) #xff00ff00))
      (should (string-match-p "OpenGL" (lispm-gl-info a))))
    ;; Contexts no longer referenced go with the garbage.
    (garbage-collect)
    (let ((c (lispm-gl-create 4 4)))
      (lispm-gl-clear c [1 1 1 1])
      (lispm-gl-present c)
      (should (equal (lispm-gl-pixel c 0 0) #xffffffff)))))

(provide 'lispm-gl-test)
;;; lispm-gl-test.el ends here
