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
;; where it is.  The one the repository's gl-module workflow built for
;; this computer from these sources is downloaded, and kept only when its
;; SHA-256 is the one pinned beside this file, in lispm-gl-module-sums.eld.
;; Those checksums come with the Lisp, from the repository's signed
;; history, not from the release, so a module changed on the release after
;; it was pinned is refused.
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
;; `lispm-gl-module-batch-pin' then writes the SHA-256 of each into
;; lispm-gl-module-sums.eld, in the release of lispm-gl that ships them.
;;
;; The module is a few megabytes, so it is fetched when first needed,
;; with Emacs waiting for it: a canvas cannot be made without it.  It
;; speaks Emacs 32's module interface, and is never loaded in an older
;; Emacs: lispm-gl.el refuses there before anything is fetched.

;;; Code:

(require 'seq)
(require 'subr-x)

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

;;;; Sources and their version

(defun lispm-gl-module--source-files ()
  "Return the module's sources, sorted: its manifest, its lock file and
its Rust."
  (let ((root lispm-gl-module-source-directory))
    (sort (seq-filter
           #'file-regular-p
           (append (mapcar (lambda (name) (expand-file-name name root)) '("Cargo.toml" "Cargo.lock"))
                   (and (file-directory-p (expand-file-name "src" root))
                        (directory-files-recursively (expand-file-name "src" root) "\\.rs\\'"))))
          #'string<)))

(defun lispm-gl-module--sha256 (file)
  "Return the SHA-256 of FILE's bytes, in hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun lispm-gl-module-source-digest ()
  "Return the SHA-256 of the module's sources, in hex, or nil without them.
It is that of what sha256sum writes for them in native/: for each, in
order, a line of its SHA-256, two spaces and its name."
  (when-let* ((files (lispm-gl-module--source-files)))
    (secure-hash 'sha256
                 (mapconcat (lambda (file)
                              (format "%s  %s\n" (lispm-gl-module--sha256 file)
                                      (file-relative-name file lispm-gl-module-source-directory)))
                            files ""))))

(defun lispm-gl-module-source-version ()
  "Return the version of the module's sources, or nil without them: the
first 16 digits of `lispm-gl-module-source-digest'.  A prebuilt module is
published, pinned and kept under it."
  (when-let* ((digest (lispm-gl-module-source-digest)))
    (substring digest 0 16)))

;;;; Pinned checksums

(defun lispm-gl-module--sums-file ()
  "Return the file pinning the SHA-256 of the modules to download."
  (expand-file-name "lispm-gl-module-sums.eld" lispm-gl-module-lisp-directory))

(defun lispm-gl-module--pins ()
  "Return what lispm-gl-module-sums.eld pins: a plist whose :version is the
version of the sources pinned and :modules an alist of a SHA-256 for each
target; nil when nothing is pinned."
  (let ((file (lispm-gl-module--sums-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((pins (ignore-errors (read (current-buffer)))))
          (and (listp pins) pins))))))

(defun lispm-gl-module--pinned-sha256 (&optional target)
  "Return the SHA-256 pinned for the module of these sources for TARGET,
by default this computer's, or nil when none is pinned for them."
  (when-let* ((target (or target (lispm-gl-module--target)))
              (version (lispm-gl-module-source-version))
              (pins (lispm-gl-module--pins))
              ((equal (plist-get pins :version) version))
              (sha256 (cdr (assoc target (plist-get pins :modules)))))
    (and (stringp sha256) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256) sha256)))

;;;; Modules

(defun lispm-gl-module--target (&optional configuration)
  "Return the target of the prebuilt module for a computer Emacs was built
for as CONFIGURATION, by default this one's `system-configuration', or nil
when none is published for it."
  (let ((configuration (or configuration system-configuration)))
    (cond ((string-match-p "\\`\\(?:aarch64\\|arm64\\)-apple-darwin" configuration) "aarch64-apple-darwin")
          ((string-match-p "\\`x86_64-apple-darwin" configuration) "x86_64-apple-darwin")
          ((string-match-p "\\`x86_64-[^-]+-linux-gnu\\'" configuration) "x86_64-unknown-linux-gnu"))))

(defun lispm-gl-module--suffix (target)
  "Return the file name suffix of a module for TARGET."
  (if (string-suffix-p "-apple-darwin" target) ".dylib" ".so"))

(defun lispm-gl-module--asset (target)
  "Return the name the module for TARGET is published under, compressed."
  (format "lispm-gl-module-%s%s.gz" target (lispm-gl-module--suffix target)))

(defun lispm-gl-module--built-file ()
  "Return where Cargo builds the module for this computer, or nil."
  (when-let* ((target (lispm-gl-module--target)))
    (expand-file-name (format "target/%s/release/liblispm_gl%s" target (lispm-gl-module--suffix target))
                      lispm-gl-module-source-directory)))

(defun lispm-gl-module--stale-p ()
  "Return non-nil when a source of the module is newer than the module
Cargo built, as after an update."
  (let ((module (lispm-gl-module--built-file)))
    (and module (file-exists-p module)
         (seq-some (lambda (file) (file-newer-than-file-p file module))
                   (lispm-gl-module--source-files)))))

(defun lispm-gl-module--prebuilt-directory ()
  "Return the directory downloaded modules are kept in, by version."
  (expand-file-name "prebuilt" lispm-gl-module-source-directory))

(defun lispm-gl-module--prebuilt-file ()
  "Return where the module downloaded for the sources is kept, whether it
is there or not, or nil when none is published for this computer or there
are no sources to name its version."
  (when-let* ((target (lispm-gl-module--target))
              (version (lispm-gl-module-source-version)))
    (expand-file-name (format "lispm-gl-module-%s%s" target (lispm-gl-module--suffix target))
                      (expand-file-name version (lispm-gl-module--prebuilt-directory)))))

(defun lispm-gl-module-file ()
  "Return the module current for the sources, or nil: when building, the
one Cargo built unless a source is newer; else the one downloaded and
checked for them."
  (let ((file (if (eq lispm-gl-module-source 'build)
                  (and (not (lispm-gl-module--stale-p)) (lispm-gl-module--built-file))
                (lispm-gl-module--prebuilt-file))))
    (and file (file-readable-p file) file)))

(defun lispm-gl-module--why-not ()
  "Return why no module can be had, a sentence."
  (let ((version (lispm-gl-module-source-version)))
    (cond ((not (lispm-gl-module--target))
           (format "no module is published for %s" system-configuration))
          ((not version) "the module's sources, which name the module to download, are not there")
          ((eq lispm-gl-module-source 'build)
           (if (executable-find "cargo") "Cargo built no module: see *lispm-gl build*"
             "building the module needs Cargo"))
          ((not (lispm-gl-module--pinned-sha256))
           (format "no module is pinned for these sources (version %s); set `lispm-gl-module-source' to `build' to build one"
                   version))
          ((not (executable-find "curl")) "downloading the module needs curl")
          ((not (executable-find "gzip")) "unpacking the module needs gzip")
          (t "no module is there"))))

;;;; Building, when asked to

(defun lispm-gl-module-build ()
  "Build the module with Cargo for this computer, Emacs waiting; return
the module, or signal why there is none.  The output is in the
*lispm-gl build* buffer."
  (interactive)
  (let ((target (lispm-gl-module--target)))
    (unless (and target (executable-find "cargo") (lispm-gl-module--source-files))
      (user-error "Building lispm-gl's module needs Cargo, the module's sources and a known computer"))
    (let ((default-directory (file-name-as-directory lispm-gl-module-source-directory))
          (buffer (get-buffer-create "*lispm-gl build*")))
      (with-current-buffer buffer (erase-buffer))
      (message "Building lispm-gl's module…")
      (unless (and (zerop (call-process "cargo" nil buffer nil "build" "--release" "--target" target))
                   (file-readable-p (lispm-gl-module--built-file)))
        (error "Cargo could not build lispm-gl's module: see %s" (buffer-name buffer)))
      (message "Building lispm-gl's module…done")
      (lispm-gl-module--built-file))))

;;;; Downloading, checked

(defun lispm-gl-module--fetch (url file)
  "Download URL into FILE with curl, or signal an error."
  (unless (zerop (call-process "curl" nil nil nil "--fail" "--silent" "--show-error" "--location"
                               "--retry" "2" "--max-time" "120" "--output" file url))
    (error "Could not download %s" url)))

(defun lispm-gl-module-download ()
  "Download the module built for this computer from the sources there are,
Emacs waiting, check it against the SHA-256 pinned for it, and keep it;
return it, or signal why there is none."
  (interactive)
  (let ((file (lispm-gl-module--prebuilt-file))
        (sha256 (lispm-gl-module--pinned-sha256)))
    (unless (and file sha256 (executable-find "curl") (executable-find "gzip"))
      (error "No lispm-gl module can be downloaded: %s" (lispm-gl-module--why-not)))
    (let* ((target (lispm-gl-module--target))
           (asset (lispm-gl-module--asset target))
           (url (format "%s/gl-module-%s/%s" (string-trim-right lispm-gl-module-prebuilt-url "/+")
                        (lispm-gl-module-source-version) asset))
           (directory (make-temp-file "lispm-gl" t))
           (compressed (expand-file-name asset directory))
           (unpacked (file-name-sans-extension compressed)))
      (unwind-protect
          (progn
            (message "Downloading lispm-gl's module…")
            (lispm-gl-module--fetch url compressed)
            (unless (equal (lispm-gl-module--sha256 compressed) sha256)
              (error "%s is not the module pinned for these sources: its SHA-256 differs, so it was refused"
                     asset))
            (unless (zerop (call-process "gzip" nil nil nil "-d" "-f" compressed))
              (error "%s could not be unpacked" asset))
            (make-directory (file-name-directory file) t)
            ;; Renamed into place, so the module is there whole or not at all.
            (copy-file unpacked (concat file ".part") t)
            (rename-file (concat file ".part") file t)
            (dolist (old (directory-files (lispm-gl-module--prebuilt-directory) t "\\`[^.]"))
              (when (and (file-directory-p old)
                         (not (string= old (directory-file-name (file-name-directory file)))))
                (delete-directory old t)))
            (message "Downloading lispm-gl's module…done")
            file)
        (delete-directory directory t)))))

;;;; Loading

(defun lispm-gl-module-load ()
  "Load lispm-gl's module, getting it first when it is not there.
Signal an error when it cannot be had.  Only Emacs 32 or later loads it:
see `lispm-gl-unsupported-reason'."
  (unless (featurep 'lispm-gl-core)
    (let ((file (or (lispm-gl-module-file)
                    (if (eq lispm-gl-module-source 'build)
                        (lispm-gl-module-build)
                      (lispm-gl-module-download)))))
      (module-load file)
      (unless (featurep 'lispm-gl-core)
        (error "%s is not lispm-gl's module" file)))))

;;;; In batch: a workflow's

(defun lispm-gl-module-published (url version)
  "Return the alist of target and SHA-256 of the release of VERSION under
URL, each module downloaded and found to be the one its SHA256SUMS lists,
and one there for every target in `lispm-gl-module-targets'.  Signal an
error otherwise."
  (let* ((release (format "%s/gl-module-%s/" (string-trim-right url "/+") version))
         (directory (make-temp-file "lispm-gl-pin" t))
         (sums (expand-file-name "SHA256SUMS" directory))
         (modules nil))
    (unwind-protect
        (progn
          (lispm-gl-module--fetch (concat release "SHA256SUMS") sums)
          (dolist (line (split-string (with-temp-buffer (insert-file-contents sums) (buffer-string))
                                      "\n" t "[ \t\r]+"))
            (unless (string-match "\\`\\([0-9a-f]\\{64\\}\\) [ *]lispm-gl-module-\\(.+?\\)\\.\\(?:dylib\\|so\\)\\.gz\\'" line)
              (error "SHA256SUMS of gl-module-%s lists %S, not a module" version line))
            (let* ((sha256 (match-string 1 line))
                   (target (match-string 2 line))
                   (file (expand-file-name (lispm-gl-module--asset target) directory)))
              (lispm-gl-module--fetch (concat release (lispm-gl-module--asset target)) file)
              (unless (equal (lispm-gl-module--sha256 file) sha256)
                (error "%s is not the module SHA256SUMS lists: refusing to pin it"
                       (lispm-gl-module--asset target)))
              (push (cons target sha256) modules)))
          (let ((missing (seq-remove (lambda (target) (assoc target modules)) lispm-gl-module-targets)))
            (when missing
              (error "gl-module-%s has no module for %s" version (string-join missing ", "))))
          (sort modules (lambda (a b) (string< (car a) (car b)))))
      (delete-directory directory t))))

(defun lispm-gl-module--render-pins (version modules)
  (concat ";;; lispm-gl-module-sums.eld --- The modules lispm-gl downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each module of the release gl-module-VERSION, as
;; published, compressed: the module lispm-gl-module.el downloads for
;; these sources.  A module whose SHA-256 is not the one here is refused.
;; VERSION must be the version of the sources in native/.
;; `lispm-gl-module-batch-pin' writes it once the gl-module workflow has
;; published that release.

"
          (format "(:version %S\n :modules (%s))\n" version
                  (mapconcat (lambda (module) (format "(%S . %S)" (car module) (cdr module)))
                             modules "\n           "))))

(defun lispm-gl-module-batch-pin ()
  "Pin the published modules of these sources, for Emacs in batch.
It writes lispm-gl-module-sums.eld from the release gl-module-VERSION
under `lispm-gl-module-prebuilt-url', each module checked against the
release's SHA256SUMS; run it once the workflow has published the release,
and commit the file with a change of lispm-gl.el's Version header.  With
LISPM_GL_PIN_CHECK set it writes nothing and exits with 1 when the file
pins these sources otherwise than the release has them; a file pinning
other sources passes, with a notice, as it does between a change of the
sources and the next release."
  (let ((version (or (lispm-gl-module-source-version) (error "No sources here")))
        (pins (lispm-gl-module--pins))
        (file (lispm-gl-module--sums-file)))
    (condition-case error
        (if (getenv "LISPM_GL_PIN_CHECK")
            (cond ((not (equal (plist-get pins :version) version))
                   (message "::notice::%s pins %s, not the sources' %s: pin it once gl-module-%s is published"
                            (file-name-nondirectory file)
                            (if (plist-get pins :version)
                                (format "gl-module-%s" (plist-get pins :version))
                              "nothing")
                            version version))
                  ((equal (lispm-gl-module-published lispm-gl-module-prebuilt-url version)
                          (sort (copy-sequence (plist-get pins :modules))
                                (lambda (a b) (string< (car a) (car b)))))
                   (message "%s pins gl-module-%s as published" (file-name-nondirectory file) version))
                  (t (error "%s differs from the release gl-module-%s"
                            (file-name-nondirectory file) version)))
          (with-temp-file file
            (insert (lispm-gl-module--render-pins
                     version (lispm-gl-module-published lispm-gl-module-prebuilt-url version))))
          (message "%s pins gl-module-%s" (file-name-nondirectory file) version))
      (error (message "%s" (error-message-string error))
             (kill-emacs 1)))
    (kill-emacs 0)))

(provide 'lispm-gl-module)
;;; lispm-gl-module.el ends here
