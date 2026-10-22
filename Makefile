# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   make              build the module for this computer
#   make test         the tests: refusals before Emacs 32, drawing on it
#   make compile      byte-compile the Emacs Lisp, warnings failing it
#   make pin          pin the published modules of these sources
#   make check-pins   check the pins against the release

EMACS ?= emacs
CARGO ?= cargo
TARGET ?= $(shell rustc -vV | sed -n 's/^host: //p')
EMACS_BATCH = $(EMACS) -Q --batch -L lisp

.PHONY: all module test compile pin check-pins clean

all: module

module:
	cd native && $(CARGO) build --release --target $(TARGET)

test:
	$(EMACS_BATCH) -l test/lispm-gl-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile lisp/*.el
	/bin/rm -f lisp/*.elc

pin:
	$(EMACS_BATCH) -l lispm-gl-module -f lispm-gl-module-batch-pin

check-pins:
	LISPM_GL_PIN_CHECK=1 $(EMACS_BATCH) -l lispm-gl-module -f lispm-gl-module-batch-pin

clean:
	cd native && $(CARGO) clean
