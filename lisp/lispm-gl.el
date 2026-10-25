;;; lispm-gl.el --- OpenGL drawn in Emacs buffers, on Emacs 32 -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (lispm-prebuilt "0.1.0"))
;; Keywords: multimedia
;; URL: https://github.com/LispMachineLab/lispm-gl
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; OpenGL, drawn in an Emacs buffer as an image among its text, scrolling
;; with it.  Emacs 32's canvas images lend their pixels to a module; the
;; module draws with OpenGL off screen and copies what it drew into them
;; (see native/src/lib.rs).  Emacs 30 and 31 have no canvas images, so
;; there lispm-gl refuses at once, signalling `lispm-gl-unsupported', and
;; fetches or loads nothing: `lispm-gl-supported-p' says beforehand.
;;
;;   (let ((gl (lispm-gl-create 320 240)))
;;     (lispm-gl-insert gl)
;;     (let ((program (lispm-gl-program gl VERTEX-SOURCE FRAGMENT-SOURCE))
;;           (triangle (lispm-gl-buffer gl [0 1  -1 -1  1 -1])))
;;       (lispm-gl-clear gl [0.1 0.1 0.1 1])
;;       (lispm-gl-draw gl program triangle :layout [("position" . 2)])
;;       (lispm-gl-present gl)))
;;
;; Shaders are GLSL 3.30, "#version 330 core": OpenGL's core profile, 4.1
;; on macOS, 3.3 or later elsewhere.  `lispm-gl-animate' draws a canvas
;; again and again while it is shown; `lispm-gl-demo' spins a cube.

;;; Code:

(require 'cl-lib)
(require 'lispm-gl-module)

(declare-function canvas-refresh "image.c" (image &optional reload-data))
(declare-function lispm-gl-core-new "lispm-gl-core" (width height samples))
(declare-function lispm-gl-core-info "lispm-gl-core" (gl))
(declare-function lispm-gl-core-program "lispm-gl-core" (gl vertex fragment))
(declare-function lispm-gl-core-buffer "lispm-gl-core" (gl data))
(declare-function lispm-gl-core-buffer-set "lispm-gl-core" (gl buffer data))
(declare-function lispm-gl-core-delete "lispm-gl-core" (gl name))
(declare-function lispm-gl-core-clear "lispm-gl-core" (gl red green blue alpha))
(declare-function lispm-gl-core-capability "lispm-gl-core" (gl capability on))
(declare-function lispm-gl-core-draw "lispm-gl-core"
                  (gl program buffer mode layout uniforms first count))
(declare-function lispm-gl-core-read "lispm-gl-core" (gl canvas))
(declare-function lispm-gl-core-pixel "lispm-gl-core" (canvas x y))

(defconst lispm-gl-emacs-version 32
  "The first major version of Emacs whose buffers lispm-gl draws in.")

(define-error 'lispm-gl-unsupported "OpenGL in buffers is not supported here")
(define-error 'lispm-gl-error "OpenGL error")

(defcustom lispm-gl-samples 4
  "How many samples a canvas's pixels are drawn with, smoothing edges.
0 draws each pixel once.  A renderer with fewer uses its most."
  :type 'natnum :group 'lispm-gl)

;;;; Whether it can

(defun lispm-gl-unsupported-reason ()
  "Return why OpenGL cannot be drawn in this Emacs's buffers, a sentence,
or nil when it can."
  (cond ((< emacs-major-version lispm-gl-emacs-version)
         (format "OpenGL in buffers needs Emacs %d or later; this is Emacs %s"
                 lispm-gl-emacs-version emacs-version))
        ((not (and (fboundp 'canvas-refresh) (image-type-available-p 'canvas)))
         "this Emacs has no canvas images to draw in")
        ((not (bound-and-true-p module-file-suffix))
         "this Emacs cannot load modules")
        ((not (memq system-type '(darwin gnu/linux)))
         (format "OpenGL in buffers runs on macOS and GNU/Linux, not on %s" system-type))))

(defun lispm-gl-supported-p ()
  "Return non-nil when OpenGL can be drawn in this Emacs's buffers."
  (not (lispm-gl-unsupported-reason)))

(defun lispm-gl--ensure ()
  "Signal `lispm-gl-unsupported' unless OpenGL can be drawn here; load the
module when it can."
  (when-let* ((reason (lispm-gl-unsupported-reason)))
    (signal 'lispm-gl-unsupported (list reason)))
  (lispm-gl-module-load))

;;;; Canvases

(cl-defstruct (lispm-gl (:constructor lispm-gl--make) (:copier nil) (:predicate lispm-gl-p))
  "An OpenGL canvas: the context drawing it, and the image it is shown as."
  context image width height timer)

(cl-defun lispm-gl-create (width height &key (samples lispm-gl-samples))
  "Return a canvas WIDTH by HEIGHT pixels to draw on with OpenGL.
SAMPLES, by default `lispm-gl-samples', smooths edges.  Signal
`lispm-gl-unsupported' when this Emacs cannot draw OpenGL in buffers,
see `lispm-gl-unsupported-reason'.  Show it with `lispm-gl-insert', or
put `lispm-gl-image' itself, not a copy, in a display property."
  (lispm-gl--ensure)
  (lispm-gl--make
   :context (lispm-gl-core-new width height samples)
   :image (list 'image :type 'canvas :id (make-symbol "lispm-gl")
                :data-width width :data-height height)
   :width width :height height))

(defun lispm-gl-insert (gl &optional string)
  "Insert canvas GL at point, as the image of STRING (by default
\"[OpenGL]\", what a display without images shows).
Emacs finds a canvas's pixels by its image spec itself, not by an equal
one, so the display property holds `lispm-gl-image' as it is:
`insert-image' would put a copy, whose pixels nothing draws."
  (let ((start (point)))
    (insert (or string "[OpenGL]"))
    (add-text-properties start (point) `(display ,(lispm-gl-image gl) rear-nonsticky t))))

(defun lispm-gl-info (gl)
  "Return what draws GL: the renderer, the version of OpenGL and of GLSL."
  (lispm-gl-core-info (lispm-gl-context gl)))

(defun lispm-gl-program (gl vertex fragment)
  "Link a program of the shaders whose GLSL sources are VERTEX and
FRAGMENT for GL, and return its number.  A shader that does not compile,
or a program that does not link, signals `lispm-gl-error' with its log."
  (lispm-gl-core-program (lispm-gl-context gl) vertex fragment))

(defun lispm-gl-buffer (gl data)
  "Make a buffer of the vertices DATA holds, a vector of numbers, for GL,
and return its number."
  (lispm-gl-core-buffer (lispm-gl-context gl) data))

(defun lispm-gl-buffer-set (gl buffer data)
  "Make the buffer numbered BUFFER of GL hold DATA, a vector of numbers."
  (lispm-gl-core-buffer-set (lispm-gl-context gl) buffer data))

(defun lispm-gl-delete (gl name)
  "Delete the program or buffer numbered NAME of GL."
  (lispm-gl-core-delete (lispm-gl-context gl) name))

(defun lispm-gl-capability (gl capability on)
  "Turn CAPABILITY of GL on when ON is non-nil, else off: `depth-test',
`blend' or `cull-face'.  The first two are on to begin with."
  (lispm-gl-core-capability (lispm-gl-context gl) capability on))

(defun lispm-gl-clear (gl &optional colour)
  "Clear GL to COLOUR, a vector of red, green, blue and alpha from 0 to 1,
by default opaque black."
  (let ((colour (or colour [0 0 0 1])))
    (lispm-gl-core-clear (lispm-gl-context gl)
                           (aref colour 0) (aref colour 1) (aref colour 2)
                           (if (> (length colour) 3) (aref colour 3) 1))))

(cl-defun lispm-gl-draw (gl program buffer &key (mode 'triangles) layout uniforms (first 0) count)
  "Draw on GL with PROGRAM, a program's number, the vertices of BUFFER, a
buffer's number.
MODE is how they join: `triangles', the default, `triangle-strip',
`triangle-fan', `lines', `line-strip', `line-loop' or `points'.  LAYOUT is
a vector of what each vertex holds, in order, as a name of the vertex
shader's input and a number of floats: [(\"position\" . 3) (\"colour\" . 3)].
UNIFORMS is an alist of a uniform's name and its value: a number, a
vector of numbers, a matrix's by columns, or for a bool, t or nil.
FIRST and COUNT say which vertices; by default, all."
  (lispm-gl-core-draw (lispm-gl-context gl) program buffer mode
                        (or layout (error "lispm-gl-draw: no :layout"))
                        uniforms first count))

(defun lispm-gl-present (gl)
  "Show what was drawn on GL, wherever its image is."
  (lispm-gl-core-read (lispm-gl-context gl) (lispm-gl-image gl))
  (canvas-refresh (lispm-gl-image gl)))

(defun lispm-gl-pixel (gl x y)
  "Return the pixel at X, Y of GL as last presented, counted from its top
left: an integer #xAARRGGBB, or nil outside it."
  (lispm-gl-core-pixel (lispm-gl-image gl) x y))

;;;; Drawing again and again

(defun lispm-gl-animate (gl function &optional fps)
  "Draw GL again and again: call FUNCTION with GL and the seconds since
the first time, then present GL, FPS times a second (by default 30).
Call it in the buffer GL's image is in: it draws only while a window
shows that buffer, and stops once the buffer is killed, or FUNCTION
signals an error.  `lispm-gl-stop' stops it."
  (lispm-gl-stop gl)
  (let ((start (float-time))
        (buffer (current-buffer)))
    (setf (lispm-gl-timer gl)
          (run-at-time
           0 (/ 1.0 (or fps 30))
           (lambda ()
             (cond ((not (buffer-live-p buffer)) (lispm-gl-stop gl))
                   ((get-buffer-window buffer t)
                    (condition-case error
                        (progn (funcall function gl (- (float-time) start))
                               (lispm-gl-present gl))
                      (error (lispm-gl-stop gl)
                             (message "lispm-gl: %s" (error-message-string error)))))))))))

(defun lispm-gl-stop (gl)
  "Stop drawing GL again and again."
  (when (timerp (lispm-gl-timer gl))
    (cancel-timer (lispm-gl-timer gl)))
  (setf (lispm-gl-timer gl) nil))

;;;; Matrices: vectors of 16 numbers, by columns, as OpenGL takes them

(defun lispm-gl-matrix-multiply (&rest matrices)
  "Return the product of MATRICES, left to right."
  (cl-reduce
   (lambda (a b)
     (let ((product (make-vector 16 0.0)))
       (dotimes (column 4)
         (dotimes (row 4)
           (let ((sum 0.0))
             (dotimes (k 4)
               (setq sum (+ sum (* (aref a (+ row (* k 4))) (aref b (+ k (* column 4)))))))
             (aset product (+ row (* column 4)) sum))))
       product))
   matrices))

(defun lispm-gl-identity ()
  "Return the identity matrix."
  (vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))

(defun lispm-gl-translation (x y z)
  "Return the matrix moving by X, Y and Z."
  (vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  (float x) (float y) (float z) 1.0))

(defun lispm-gl-rotation (angle x y z)
  "Return the matrix turning by ANGLE radians about the axis X, Y, Z."
  (let* ((length (sqrt (+ (* x x) (* y y) (* z z))))
         (x (/ x length)) (y (/ y length)) (z (/ z length))
         (c (cos angle)) (s (sin angle)) (k (- 1 c)))
    (vector (+ c (* x x k)) (+ (* y x k) (* z s)) (- (* z x k) (* y s)) 0.0
            (- (* x y k) (* z s)) (+ c (* y y k)) (+ (* z y k) (* x s)) 0.0
            (+ (* x z k) (* y s)) (- (* y z k) (* x s)) (+ c (* z z k)) 0.0
            0.0 0.0 0.0 1.0)))

(defun lispm-gl-perspective (fovy aspect near far)
  "Return the projection of a field of view FOVY radians high, ASPECT wide
to high, between the distances NEAR and FAR."
  (let ((f (/ 1.0 (tan (/ fovy 2.0)))))
    (vector (/ f aspect) 0.0 0.0 0.0
            0.0 f 0.0 0.0
            0.0 0.0 (/ (+ far near) (- near far)) -1.0
            0.0 0.0 (/ (* 2.0 far near) (- near far)) 0.0)))

;; In an Emacs that can draw, the module comes in the background, so that
;; the first canvas need not wait for it.
(when (and (not noninteractive) (lispm-gl-supported-p))
  (run-with-idle-timer 2 nil #'lispm-gl-module-prefetch))

(provide 'lispm-gl)
;;; lispm-gl.el ends here
