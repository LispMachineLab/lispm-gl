;;; lispm-gl-module.el --- lispm-gl's native module, downloaded and checked -*- lexical-binding: t; -*-

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

;; OpenGL is drawn by a Rust module, and nobody has to build it or say
;; where it is.  lispm-prebuilt downloads the one the repository's
;; gl-module workflow built for this computer from these sources, and
;; keeps it only when its SHA-256 is the one pinned beside this file, in
;; lispm-gl-module-sums.eld.  Those checksums come with the Lisp, from the
;; repository's signed history, not from the release, so a module changed
;; on the release after it was pinned is refused.
;;
;; Cargo builds it only when asked to: `lispm-gl-module-source' set to
;; `build' builds it from the sources there are, and again when one is
;; newer than the module Cargo built, and downloads nothing.
;;
;;   download   native/prebuilt/VERSION/lispm-gl-module-TARGET.SUFFIX
;;   build      native/target/TARGET/release/liblispm_gl.SUFFIX
;;
;; VERSION is `lispm-gl-module-source-version', a digest of the module's
;; sources.  The workflow publishes the modules of each version,
;; compressed with gzip, as the release gl-module-VERSION;
;; `lispm-gl-module-batch-pin' (`make pin') then writes the SHA-256 of
;; each into lispm-gl-module-sums.eld, in the release of lispm-gl that
;; ships them.
;;
;; The module is a few megabytes.  Loaded in an Emacs that can draw,
;; lispm-gl has it downloaded in the background, see
;; `lispm-gl-module-prefetch'; a canvas made before it is there waits for
;; it.  It speaks Emacs 32's module interface, and is never loaded in an
;; older Emacs: lispm-gl.el refuses there before anything is fetched.

;;; Code:

(require 'lispm-prebuilt)

(defgroup lispm-gl nil
  "OpenGL drawn in Emacs buffers, on Emacs 32."
  :group 'multimedia
  :prefix "lispm-gl-")

(defcustom lispm-gl-module-source 'download
  "Where lispm-gl's module comes from.
`download', the default, downloads the module the repository's workflow
built for this computer from these sources, and keeps it only when its
SHA-256 is the one pinned in lispm-gl-module-sums.eld.  `build' builds
it with Cargo instead, from the sources there are, and again when one is
newer than the module Cargo built; nothing is downloaded then."
  :type '(choice (const :tag "Download it, checked" download)
                 (const :tag "Build it with Cargo" build)))

(defcustom lispm-gl-module-prebuilt-url
  "https://github.com/LispMachineLab/lispm-gl/releases/download"
  "Where the prebuilt modules are.
The modules of the sources whose version is VERSION, see
`lispm-gl-module-source-version', are under gl-module-VERSION there:
lispm-gl-module-TARGET.SUFFIX.gz for each TARGET.  Whatever the URL, a
module is kept only when its SHA-256 is the one
lispm-gl-module-sums.eld pins."
  :type 'string)

(defconst lispm-gl-module-lisp-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of lispm-gl's Emacs Lisp.")

(defconst lispm-gl-module-source-directory
  (expand-file-name "native" (file-name-directory (directory-file-name lispm-gl-module-lisp-directory)))
  "Directory of the module's Rust crate.")

(defconst lispm-gl-module-targets
  '("aarch64-apple-darwin" "x86_64-apple-darwin" "x86_64-unknown-linux-gnu")
  "The computers a module is published for.")

(lispm-prebuilt-define 'lispm-gl-module
  :title "lispm-gl's module"
  :root lispm-gl-module-source-directory
  :sources '("Cargo.toml" "Cargo.lock" ("src" "\\.rs\\'"))
  :targets lispm-gl-module-targets
  :url 'lispm-gl-module-prebuilt-url
  :source 'lispm-gl-module-source
  :release "gl-module-%v"
  :asset "lispm-gl-module-%t%e.gz"
  :file "lispm-gl-module-%t%e"
  :sums (expand-file-name "lispm-gl-module-sums.eld" lispm-gl-module-lisp-directory)
  :build '("cargo" "build" "--release" "--target" "%t")
  :built "target/%t/release/liblispm_gl%e"
  :pin-check "LISPM_GL_PIN_CHECK")

(defun lispm-gl-module-source-version ()
  "Return the version of the module's sources, or nil without them: the
first 16 digits of the SHA-256 of what sha256sum writes for them in
native/.  A prebuilt module is published, pinned and kept under it."
  (lispm-prebuilt-source-version 'lispm-gl-module))

(defun lispm-gl-module-file ()
  "Return the module current for the sources, or nil: when building, the
one Cargo built unless a source is newer; else the one downloaded and
checked for them."
  (lispm-prebuilt-file 'lispm-gl-module))

(defun lispm-gl-module-build ()
  "Build the module with Cargo for this computer, Emacs waiting; return
the module, or signal why there is none."
  (interactive)
  (lispm-prebuilt-build 'lispm-gl-module))

(defun lispm-gl-module-download ()
  "Download the module built for this computer from the sources there are,
Emacs waiting, check it against the SHA-256 pinned for it, and keep it;
return it, or signal why there is none."
  (interactive)
  (lispm-prebuilt-download 'lispm-gl-module))

(defun lispm-gl-module-prefetch ()
  "Download the module in the background when it is not there, so that a
canvas need not wait for it."
  (lispm-prebuilt-prefetch 'lispm-gl-module))

(defun lispm-gl-module-load ()
  "Load lispm-gl's module, getting it first when it is not there, Emacs
waiting.  Signal an error when it cannot be had.  Only Emacs 32 or later
loads it: see `lispm-gl-unsupported-reason'."
  (lispm-prebuilt-load 'lispm-gl-module 'lispm-gl-core))

(defun lispm-gl-module-batch-pin ()
  "Pin the published modules of these sources, for Emacs in batch.
See `lispm-prebuilt-batch-pin'; LISPM_GL_PIN_CHECK set asks it only to
check the pins against the release."
  (lispm-prebuilt-batch-pin 'lispm-gl-module))

(provide 'lispm-gl-module)
;;; lispm-gl-module.el ends here
