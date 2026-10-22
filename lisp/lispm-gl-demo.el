;;; lispm-gl-demo.el --- A cube spinning in a buffer, drawn with OpenGL -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
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

;; M-x lispm-gl-demo: a cube of six colours spinning between two lines of
;; text, in a buffer of its own, drawn with OpenGL 30 times a second while
;; it is shown.  On Emacs 30 or 31 it says why it cannot.

;;; Code:

(require 'lispm-gl)

(defconst lispm-gl-demo--vertex
  "#version 330 core
in vec3 position;
in vec3 colour;
uniform mat4 transform;
out vec3 shade;
void main() {
  shade = colour;
  gl_Position = transform * vec4(position, 1.0);
}"
  "The vertex shader: each corner moved by the transform, its colour kept.")

(defconst lispm-gl-demo--fragment
  "#version 330 core
in vec3 shade;
uniform float time;
out vec4 colour;
void main() {
  colour = vec4(shade * (0.85 + 0.15 * sin(time * 2.0)), 1.0);
}"
  "The fragment shader: the colour, breathing a little with the time.")

(defun lispm-gl-demo--cube ()
  "Return the cube's 36 vertices, a position and a colour each."
  (let ((faces '(;; normal axis, sign, colour
                 (0 1 (0.95 0.33 0.31)) (0 -1 (0.99 0.71 0.25))
                 (1 1 (0.42 0.80 0.38)) (1 -1 (0.31 0.62 0.95))
                 (2 1 (0.62 0.42 0.89)) (2 -1 (0.95 0.95 0.95))))
        (vertices nil))
    (pcase-dolist (`(,axis ,sign ,colour) faces)
      (let ((u (mod (1+ axis) 3)) (v (mod (+ axis 2) 3)))
        (dolist (corner '((-1 -1) (1 -1) (1 1) (-1 -1) (1 1) (-1 1)))
          (let ((position (make-vector 3 0.0)))
            (aset position axis (* 0.5 sign))
            (aset position u (* 0.5 sign (car corner)))
            (aset position v (* 0.5 (cadr corner)))
            (setq vertices (append vertices (append position colour) nil))))))
    (vconcat vertices)))

;;;###autoload
(defun lispm-gl-demo ()
  "Show a cube spinning in a buffer, drawn with OpenGL."
  (interactive)
  (when-let* ((reason (lispm-gl-unsupported-reason)))
    (user-error "%s" reason))
  (unless (display-graphic-p)
    (user-error "OpenGL is shown on a graphical display only"))
  (let* ((buffer (get-buffer-create "*OpenGL*"))
         (gl (lispm-gl-create 480 360))
         (program (lispm-gl-program gl lispm-gl-demo--vertex lispm-gl-demo--fragment))
         (cube (lispm-gl-buffer gl (lispm-gl-demo--cube)))
         (projection (lispm-gl-perspective (/ float-pi 4) (/ 480.0 360) 0.1 10.0)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "A cube, drawn with OpenGL in this buffer.\n\n")
        (lispm-gl-insert gl "[a spinning cube]")
        (insert "\n\n" (lispm-gl-info gl) "\n"))
      (special-mode)
      (add-hook 'kill-buffer-hook (lambda () (lispm-gl-stop gl)) nil t)
      (lispm-gl-animate
       gl (lambda (gl time)
            (lispm-gl-clear gl [0.08 0.08 0.1 1])
            (lispm-gl-draw gl program cube
                           :layout [("position" . 3) ("colour" . 3)]
                           :uniforms `(("transform" . ,(lispm-gl-matrix-multiply
                                                       projection
                                                       (lispm-gl-translation 0 0 -3)
                                                       (lispm-gl-rotation (* time 0.9) 0 1 0)
                                                       (lispm-gl-rotation (* time 0.5) 1 0 0)))
                                       ("time" . ,time))))))
    (pop-to-buffer buffer)))

(provide 'lispm-gl-demo)
;;; lispm-gl-demo.el ends here
