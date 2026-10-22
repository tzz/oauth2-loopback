EMACS ?= emacs
EL := oauth2-loopback.el

.PHONY: compile lint clean

compile:
	$(EMACS) -Q --batch -L .  --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(EL)

lint: compile
	$(EMACS) -Q --batch -L .  -l checkdoc --eval '(checkdoc-file "$(EL)")'

clean:
	rm -f *.elc dev/*.elc
