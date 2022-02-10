EMACS ?= emacs

p4.elc: p4.el
	"$(EMACS)" -Q -batch -f batch-byte-compile p4.el

.PHONY:
clean:
	$(RM) p4.elc *~
