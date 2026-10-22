;;; lispm-gl-module-sums.eld --- The modules lispm-gl downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each module of the release gl-module-VERSION, as
;; published, compressed: the module lispm-gl-module.el downloads for
;; these sources.  A module whose SHA-256 is not the one here is refused.
;; VERSION must be the version of the sources in native/.
;; `lispm-gl-module-batch-pin' writes it once the gl-module workflow has
;; published that release.

(:version "1219494ca4377283"
 :modules (("aarch64-apple-darwin" . "3c808edc44f5c98f627d96c1497b08af4f84bc508dd78d942c879291d2035334")
           ("x86_64-apple-darwin" . "d7179ccf096e8c9e2423114bb7a01ea38c8820c0b444fbd44c01ee79c93f0f48")
           ("x86_64-unknown-linux-gnu" . "fe0cf679f9ee4bc649abb20011ed902d2e75d7377f8b3867a1e03e28ad233acb")))
