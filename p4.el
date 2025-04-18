;;; p4.el --- Perforce-Emacs Integration -*- lexical-binding: t; -*-

;; Copyright (c) 1996-1997 Eric Promislow
;; Copyright (c) 1997-2004 Rajesh Vaidheeswarran
;; Copyright (c) 2005      Peter Osterlund
;; Copyright (c) 2009      Fujii Hironori
;; Copyright (c) 2012      Jason Filsinger
;; Copyright (c) 2013-2015 Gareth Rees <gdr@garethrees.org>
;; Copyright (c) 2015-2024 John Ciolfi

;; Version: 14.0
;;   This version started with the 2015 Version 12.0 from Gareth Rees <gdr@garethrees.org>
;;   https://github.com/gareth-rees/p4.el
;;
;;   This version has significant changes, features, fixes, and performance improvements. One
;;   example difference is the elimination of the Perforce status in the mode line. Perforce
;;   interactions can be slow and this slowed Emacs. Now all interactions with Perforce are explicit
;;   and invoked from a P4 menu selection or keybinding. This means that Emacs will be performant
;;   even if the Perforce server is slow or not responding. By default, most commands prompt you to
;;   run the action requests, which lets you provide additional switches if desired.

;;; Commentary:

;; p4.el integrates the Perforce software version management system
;; into Emacs.  It is designed for users who are familiar with Perforce
;; and want to access it from Emacs: it provides Emacs interfaces that
;; map directly to Perforce commands.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

;;; Installation:

;; 1. Download p4.el and compile it:
;;
;;      emacs -Q -batch -f batch-byte-compile /path/to/dir/containing/p4.el
;;
;; 2. In your .emacs add:
;;
;;      (add-to-list 'load-path "/path/to/dir/containing/p4")
;;      (require 'p4)
;;
;; By default, the P4 global key bindings start with C-c p. If you prefer a different key prefix,
;; then you should customize the setting p4-global-key-prefix.

;;; Code:

(require 'calendar)
(require 'comint)
(require 'dired)
(require 'diff-mode)
(require 'font-lock)

(eval-when-compile (require 'cl-lib))

(defvar p4-version "14" "Perforce-Emacs Integration version.")

;; Forward declarations to avoid byte-compile warning "reference to free variable"
(defvar p4-global-key-prefix)
(defvar p4-basic-mode-map)
(defvar p4-annotate-mode-map)

;;; User options:

(defgroup p4 nil "Perforce VC System." :group 'tools)

(defcustom p4-executable
  (locate-file "p4" (append exec-path '("/usr/local/bin" "~/bin" ""))
               (if (memq system-type '(ms-dos windows-nt)) '(".exe"))
               #'file-executable-p)
  "The p4 executable."
  :type 'string
  :group 'p4)

(defcustom p4-default-describe-options "-s"
  "Options to pass to `p4-describe'."
  :type 'string
  :group 'p4)

(defcustom p4-default-describe-diff-options "-a -du"
  "Perforce, p4 describe, options for `p4-describe-with-diff'."
  :type 'string
  :group 'p4)

(defcustom p4-default-diff-options "-du"
  "Options to pass to `p4-diff', `p4-diff2'.
Set to:
-du[n]  Unified output format, optional [n] is number of context lines
-dn     RCS output format (not recommended in Emacs)
-ds     Summary output format (not recommended in Emacs)
-dc[n]  Context output format, optional [n] is number of context lines
        (not recommended in Emacs)
-dw     Ignore whitespace altogether, implies -dl
-db     Ignore changes made within whitespace, implies -dl
-dl     Ignore line endings"
  :type 'string
  :group 'p4)

(defcustom p4-default-resolve-options "..."
  "Options to pass to `p4-resolve'."
  :type 'string
  :group 'p4)

(defcustom p4-check-empty-diffs nil
  "If non-NIL, check for files with empty diffs before submitting."
  :type 'boolean
  :group 'p4)

(defcustom p4-follow-symlinks t
  "If non-NIL, call `file-truename' on all opened files.
In addition, call `p4-refresh-buffer-with-true-path' before running p4
commands."
  :type 'boolean
  :group 'p4)

(defcustom p4-synchronous-commands '(add delete edit lock logout reopen revert
                                         unlock)
  "List of Perforce commands that are run synchronously."
  :type (let ((cmds '(add branch branches change changes client clients delete
                          describe diff diff2 edit filelog files fix fixes flush
                          fstat group groups have info integ job jobs jobspec label
                          labels labelsync lock logout move opened passwd print
                          reconcile reopen revert set shelve status submit sync
                          tickets unlock unshelve update user users where)))
          (cons 'set (cl-loop for cmd in cmds collect (list 'const cmd))))
  :group 'p4)

(defcustom p4-password-source nil
  "Action to take when Perforce needs a password.
If NIL, prompt the user to enter password.
Otherwise, this is a string containing a shell command that
prints the password.  This command is run in an environment where
P4PORT and P4USER and set from the current Perforce settings."
  :type '(radio (const :tag "Prompt user to enter password." nil)
                (const :tag "Fetch password from OS X Keychain.\n\n\tFor each Perforce account, use Keychain Access to create an\n\tapplication password with \"Account\" the Perforce user name\n\t(P4USER) and \"Where\" the Perforce server setting (P4PORT).\n"
                       "security find-generic-password -s $P4PORT -a $P4USER -w")
                (const :tag "Fetch password from Python keyring.\n\n\tFor each Perforce account, run:\n\t    python -c \"import keyring,sys;keyring.set_password(*sys.argv[1:])\" \\\n\t        P4PORT P4USER PASSWORD\n\treplacing P4PORT with the Perforce server setting, P4PORT with the\n\tPerforce user name, and PASSWORD with the password.\n"
                       "python -c \"import keyring, sys; print(keyring.get_password(*sys.argv[1:3]))\" \"$P4PORT\" \"$P4USER\"")
                (string :tag "Run custom command"))
  :group 'p4)

(defcustom p4-mode-hook nil
  "Hook run by `p4-mode'."
  :type 'hook
  :group 'p4)

(defcustom p4-form-mode-hook nil
  "Hook run by `p4-form-mode'."
  :type 'hook
  :group 'p4)

(defcustom p4-file-form-mode-hook nil
  "Hook run by `p4-file-form-mode'."
  :type 'hook
  :group 'p4)

(defcustom p4-edit-hook nil
  "Hook run after opening a file for edit."
  :type 'hook
  :group 'p4)

(defcustom p4-set-client-hooks nil
  "Hook run after client is changed."
  :type 'hook
  :group 'p4)

(defcustom p4-strict-complete t
  "If non-NIL, `p4-set-my-client' requires an exact match."
  :type 'boolean
  :group 'p4)

(defcustom p4-cleanup-time 600
  "Perforce cache timeout.

Time in seconds after which a cache of information from the
Perforce server becomes stale."
  :type 'integer
  :group 'p4)

(defcustom p4-my-clients nil
  "Clients tracked for the current Emacs session.
The list of Perforce clients that the function
`p4-set-client-name' will complete on, or NIL if it should
complete on all clients."
  :type '(repeat (string))
  :group 'p4)

(defcustom p4-modify-args-function #'identity
  "Function that modifies a Perforce command line argument list.
All calls to the Perforce executable are routed through this
function to enable global modifications of argument vectors.  The
function will be called with one argument, the list of command
line arguments for Perforce (excluding the program name).  It
should return a possibly modified command line argument list.
This can be used to e.g. support wrapper scripts taking custom
flags."
  :type 'function
  :group 'p4)

(defcustom p4-branch-from-depot-filespec-function nil
  "Function that extracts a branch from a depot file spec.
This takes one argument a depot path, e.g. //branch/name/path/to/file.ext
and should return the //branch/name port if possible or nil."
  :type 'function
  :group 'p4)

(defgroup p4-faces nil "Perforce VC System Faces." :group 'p4)

(defface p4-description-face '((t (:inherit font-lock-doc-face)))
  "Face used for change descriptions."
  :group 'p4-faces)

(defface p4-heading-face '((t))
  "Face used for section heading."
  :group 'p4-faces)

(defface p4-link-face '((t (:weight bold)))
  "Face used to highlight clickable links."
  :group 'p4-faces)

(defface p4-action-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce actions (add/edit/integrate/delete)."
  :group 'p4-faces)

(defface p4-branch-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce branches."
  :group 'p4-faces)

(defface p4-change-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce change numbers."
  :group 'p4-faces)

(defface p4-client-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce users."
  :group 'p4-faces)

(defface p4-filespec-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce filespec."
  :group 'p4-faces)

(defface p4-job-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce job names."
  :group 'p4-faces)

(defface p4-label-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce labels."
  :group 'p4-faces)

(defface p4-revision-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce revision numbers."
  :group 'p4-faces)

(defface p4-user-face '((t (:inherit p4-link-face)))
  "Face used to highlight Perforce users."
  :group 'p4-faces)

(defface p4-depot-add-face
  '((((class color) (background light)) (:foreground "blue"))
    (((class color) (background dark)) (:foreground "cyan")))
  "Face used for files open for add."
  :group 'p4-faces)

(defface p4-depot-branch-face
  '((((class color) (background light)) (:foreground "blue4"))
    (((class color) (background dark)) (:foreground "sky blue")))
  "Face used for files open for integrate."
  :group 'p4-faces)

(defface p4-depot-delete-face
  '((((class color) (background light)) (:foreground "red"))
    (((class color) (background dark)) (:foreground "pink")))
  "Face used for files open for delete."
  :group 'p4-faces)

(defface p4-depot-edit-face
  '((((class color) (background light)) (:foreground "dark green"))
    (((class color) (background dark)) (:foreground "light green")))
  "Face used for files open for edit."
  :group 'p4-faces)

(defface p4-depot-move-delete-face
  '((((class color) (background light)) (:foreground "brown"))
    (((class color) (background dark)) (:foreground "brown")))
  "Face used for files open for delete."
  :group 'p4-faces)

(defface p4-depot-move-add-face
  '((((class color) (background light)) (:foreground "navy"))
    (((class color) (background dark)) (:foreground "CadetBlue1")))
  "Face used for files open for add."
  :group 'p4-faces)

(defface p4-form-comment-face '((t (:inherit font-lock-comment-face)))
  "Face for comment in P4 Form mode."
  :group 'p4-faces)

(defface p4-form-keyword-face '((t (:inherit font-lock-keyword-face)))
  "Face for keyword in P4 Form mode."
  :group 'p4-faces)

(defface p4-highlight-face
  '((((class color) (background light))
     (:foreground "Firebrick" :background  "yellow"))
    (((class color) (background dark))
     (:foreground "chocolate1" :background  "blue3")))
  "Face used for highlight items."
  :group 'p4-faces)

(defcustom p4-annotate-line-number-threshold 50000
  "In p4-annotate, show source line numbers when below this threshold.
Line number background is shaded based on Adige."
  :type 'integer
  :group 'p4)

;; White to black background shades for p4-annotate-line-ageNNN-face:
;; https://www.w3schools.com/colors/colors_picker.asp?colorhex=000000

(defface p4-annotate-line-age1-face
  '((t :foreground "black"
       :background "#f2f2f2"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age2-face
  '((t :foreground "black"
       :background "#e6e6e6"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age3-face
  '((t :foreground "black"
       :background "#d9d9d9"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age4-face
  '((t :foreground "black"
       :background "#cccccc"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age5-face
  '((t :foreground "black"
       :background "#bfbfbf"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age6-face
  '((t :foreground "black"
       :background "#b3b3b3"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age7-face
  '((t :foreground "black"
       :background "#a6a6a6"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age8-face
  '((t :foreground "white"
       :background "#999999"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age9-face
  '((t :foreground "white"
       :background "#8c8c8c"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age10-face
  '((t :foreground "white"
       :background "#808080"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age11-face
  '((t :foreground "white"
       :background "#737373"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age12-face
  '((t :foreground "white"
       :background "#666666"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age13-face
  '((t :foreground "white"
       :background "#595959"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age14-face
  '((t :foreground "white"
       :background "#4d4d4d"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age15-face
  '((t :foreground "white"
       :background "#404040"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age16-face
  '((t :foreground "white"
       :background "#333333"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age17-face
  '((t :foreground "white"
       :background "#262626"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age18-face
  '((t :foreground "white"
       :background "#1a1a1a"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age19-face
  '((t :foreground "white"
       :background "#0d0d0d"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defface p4-annotate-line-age20-face
  '((t :foreground "white"
       :background "#000000"))
  "Face used in p4-annotate for line age."
  :group 'p4-faces)

(defvar p4-annotate-line-first-360-day-faces
  '(p4-annotate-line-age1-face
    p4-annotate-line-age2-face
    p4-annotate-line-age3-face
    p4-annotate-line-age4-face
    p4-annotate-line-age5-face
    p4-annotate-line-age6-face)
  "List of faces for showing annotation line age in first 360 days.")

(defvar p4-annotate-line-year-faces
  '(p4-annotate-line-age7-face
    p4-annotate-line-age8-face
    p4-annotate-line-age9-face
    p4-annotate-line-age10-face
    p4-annotate-line-age11-face
    p4-annotate-line-age12-face
    p4-annotate-line-age13-face
    p4-annotate-line-age14-face
    p4-annotate-line-age15-face
    p4-annotate-line-age16-face
    p4-annotate-line-age17-face
    p4-annotate-line-age18-face
    p4-annotate-line-age19-face
    p4-annotate-line-age20-face)
  "List of faces for showing annotation line age after 360 days.")

;; Local variables in all buffers.
(defvar-local p4-mode nil "P4 minor mode.")

;; Local variables in P4 process buffers.
(defvar-local p4-process-args nil "List of p4 command and arguments.")
(defvar-local p4-process-callback nil
  "Function run when p4 command completes successfully.")
(defvar-local p4-process-after-show nil
  "Function run after showing output of successful p4 command.")
(defvar-local p4-process-auto-login nil
  "If non-NIL, automatically prompt user to log in.")
(defvar-local p4-process-buffers nil
  "List of buffers whose status is being updated here.")
(defvar-local p4-process-pending nil
  "Pending status update structure being updated here.")
(defvar-local p4-process-pop-up-output nil
  "Pop-up window?
Function that returns non-NIL to display output in a pop-up
window, or NIL to display it in the echo area.")
(defvar-local p4-process-synchronous nil
  "If non-NIL, run p4 command synchronously.")

;; Local variables in P4 Form buffers.
(defvar-local p4-form-commit-command nil
  "Perforce, p4 command to run when committing this form.")
(defvar-local p4-form-commit-success-callback nil
  "Callback for p4 commit.
Function run if commit succeeds.  It receives two arguments:
the commit command and the buffer containing the output from the
commit command.")
(defvar-local p4-form-commit-failure-callback nil
  "Callback for p4 commit failures.
Function run if commit fails.  It receives two arguments:
the commit command and the buffer containing the output from the
commit command.")

(defvar-local p4-form-head-text
    (format "# Created using Perforce-Emacs Integration version %s.
# Type C-c C-c to send the form to the server.
# Type C-x k to cancel the operation.
#\n" p4-version)
  "Text added to top of generic form.")

;; Local variables in P4 depot buffers.
(defvar-local p4-default-directory nil "Original value of `default-directory'.")
(defvar-local p4--opened-args nil "Used internally by `p4-opened'.")

;;; P4 minor mode:

(add-to-list 'minor-mode-alist '(p4-mode p4-mode))

;;; Keymap:

(defvar p4-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a"         'p4-add)
    (define-key map "A"         'p4-fstat)
    (define-key map "b"         'p4-branch)
    (define-key map "B"         'p4-branches)
    (define-key map "c"         'p4-client)
    (define-key map "C"         'p4-change)
    (define-key map (kbd "M-c") 'p4-changes)
    (define-key map "d"         'p4-diff2)
    (define-key map "D"         'p4-describe)
    (define-key map "\C-d"      'p4-describe-with-diff)
    (define-key map (kbd "M-d") 'p4-describe-all-files)
    (define-key map "e"         'p4-edit)
    (define-key map "E"         'p4-reopen)
    (define-key map "\C-f"      'p4-depot-find-file)
    (define-key map "f"         'p4-filelog)
    (define-key map "F"         'p4-files)
    (define-key map "G"         'p4-get-client-name)
    (define-key map "g"         'p4-update)
    (define-key map "h"         'p4-help)
    (define-key map "H"         'p4-have)
    (define-key map "i"         'p4-info)
    (define-key map "I"         'p4-integ)
    (define-key map "j"         'p4-job)
    (define-key map "J"         'p4-jobs)
    (define-key map "l"         'p4-label)
    (define-key map "L"         'p4-labels)
    (define-key map "\C-l"      'p4-labelsync)
    (define-key map "m"         'p4-move)
    (define-key map "o"         'p4-opened)
    (define-key map "p"         'p4-print)
    (define-key map "P"         'p4-set-p4-port)
    (define-key map "\C-p"      'p4-changes-pending)
    (define-key map "q"         'quit-window)
    (define-key map "r"         'p4-revert-dwim)
    (define-key map "R"         'p4-refresh)
    (define-key map "\C-r"      'p4-resolve)
    (define-key map "s"         'p4-status)
    (define-key map "S"         'p4-submit)
    (define-key map (kbd "M-s") 'p4-shelve)
    (define-key map "\C-s"      'p4-changes-shelved)
    (define-key map (kbd "M-u") 'p4-unshelve)
    (define-key map "u"         'p4-user)
    (define-key map "U"         'p4-users)
    (define-key map "v"         'p4-version)
    (define-key map "V"         'p4-annotate)
    (define-key map "w"         'p4-where)
    (define-key map "x"         'p4-delete)
    (define-key map "X"         'p4-fix)
    (define-key map "z"         'p4-reconcile)
    (define-key map "="         'p4-diff)
    (define-key map (kbd "C-=") 'p4-diff-all-opened)
    (define-key map (kbd "M-=") 'p4-diff-all-opened-side-by-side)
    (define-key map "-"         'p4-ediff)
    (define-key map "`"         'p4-ediff-with-head)
    (define-key map "_"         'p4-ediff2)
    map)
  "The prefix map for Perforce, p4.el, commands.")

(fset 'p4-prefix-map p4-prefix-map)

(defun p4-update-global-key-prefix (symbol value)
  "Update the P4 global key prefix.
This uses the `p4-global-key-prefix' user setting along with SYMBOL and VALUE."
  (set symbol value)
  (let ((map (current-global-map)))
    ;; Remove old binding(s).
    (dolist (key (where-is-internal p4-prefix-map map))
      (define-key map key nil))
    ;; Add new binding.
    (when p4-global-key-prefix
      (define-key map p4-global-key-prefix p4-prefix-map))))

;; From https://www.gnu.org/software/emacs/manual/html_node/elisp/Key-Binding-Conventions.html
;; In summary, the general rules are:
;;   C-x reserved for Emacs native essential keybindings:
;;       buffer, window, frame, file, directory, etc...
;;   C-c reserved for user and major mode:
;;   C-c letter reserved for user. <F5>-<F9> reserved for user.
;;   C-c C-letter reserved for major mode.
;;   Don't rebind C-g, C-h and ESC.
(defcustom p4-global-key-prefix (kbd "C-c p")
  "The global key prefix for P4 commands."
  :type '(radio (const :tag "No global key prefix" nil) (key-sequence))
  :set 'p4-update-global-key-prefix
  :group 'p4)

(defcustom p4-prompt-before-running-cmd t
  "Before running a p4 command prompt user for the arguments.
This is equivalent to running \\[universal-argument] `universal-argument' before the
p4 command."
  :type 'boolean
  :group 'p4)

;;; Menu:

(easy-menu-define p4-menu nil "Perforce menu."
  `("P4"
    ["Add" p4-add
     :help "M-x p4-add
Open a new file to add it to the depot"]
    ["Edit" p4-edit
     :help "M-x p4-edit
Open an existing file for edit"]
    ["Revert" p4-revert-dwim
     :help "M-x p4-revert-dwim
Discard changes from an opened file(s). If buffer is visiting file p4 revert the file,
otherwise run p4 revert."]
    ["Delete" p4-delete
     :help "M-x p4-delete
Open an existing file for deletion from the depot"]
    ["Move open file (rename)" p4-move
     :help "M-x p4-move
Move file(s) from one location to another"]
    ["Reopen (move between changelists or change file type)" p4-reopen
     :help "M-x p4 reopen
Change the filetype of an open file or move it to another changelist.
Tip: 'p4 reopen -c CN FILE' to move FILE to changelist num, CN"]
    ["--" nil nil]
    ["File attributes (p4 fstat)" p4-fstat
     :help "M-x p4-fstat
Display file attributes - have revision, etc."]
    ["File log" p4-filelog]
    ["--" nil nil]
    ("Diff"
     ["EDiff current" p4-ediff
      :help "M-x p4-ediff
Ediff file with its original client version"]
     ["EDiff two versions" p4-ediff2
      :help "M-x p4-ediff2
Ediff two versions of a depot file"]
     ["EDiff current with head" p4-ediff-with-head
      :help "M-x p4-ediff-with-head
Ediff file with head version"]
     ["Diff file with its original client version" p4-diff
      :help "M-x p4-diff"]
     ["Diff file with its original client" p4-diff2
      :help "M-x p4-diff2"]
     ["Diff all opened files" p4-diff-all-opened
      :help "M-x p4-diff-all-opened"]
     ["Diff all opened files side-by-side" p4-diff-all-opened-side-by-side
      :help "M-x p4-diff-all-opened-side-by-side"]
     )
    ["--" nil nil]
    ("Changes"
     ["Show opened files" p4-opened
      :help "M-x p4-opened"]
     ["Show changes pending" p4-changes-pending
      :help "M-x p4-changes-pending
Show pending changelists"]
     ["Show changes shelved" p4-changes-shelved
      :help "M-x p4-changes-shelved
Show shelved changelists"]
     ["Show changes submitted" p4-changes
      :help "M-x p4-changes
Show submitted changelists"]
     ["--" nil nil]
     ["Describe change" p4-describe
      :help "M-x p4-describe
Run 'p4 describe -s CHANGE_NUM' on changelist"]
     ["Describe change with diff" p4-describe-with-diff
      :help "M-x p4-describe-with-diff
Run 'p4 describe -a -du CHANGE_NUM' on changelist"]
     ["Describe change showing affected and shelved files" p4-describe-all-files
      :help "M-x p4-describe-all-files
Show all affected and shelved files in a changelist."]
     ["--" nil nil]
     ["Change" p4-change
      :help "M-x p4-change
Create, update, submit, or delete a changelist"]
     ["Shelve" p4-shelve
      :help "M-x p4-shelve
Store files from a pending changelist into the depot"]
     ["Unshelve" p4-unshelve
      :help "M-x p4-unshelve
Restore shelved files from a pending change into a workspace"]
     ["Submit"  p4-submit
      :help "M-x p4-submit
Submit opened files to depot"]
     ["Job" p4-job
      :help "M-x p4-job
Create or edit a job (defect) specification"]
     ["Jobs" p4-jobs
      :help "M-x p4-jobs
Display list of jobs"]
     ["Fix (link job to changelist)" p4-fix
      :help "M-x p4-fix
Mark jobs as being fixed by the specified changelist"]
     )
    ("Workspace"
     ["Update files from depot" p4-update
      :help "M-x p4-update
Synchronize the client with its view of the depot"]
     ["Sync" p4-sync
      :help "M-x p4-sync
Synchronize the client with its view of the depot"]
     ["Sync specific changelist" p4-sync-changelist
      :help "M-x p4-sync-changelist
Run 'p4 sync @=CHANGE_NUM' to sync ONLY the contents of a CHANGE_NUM"]
     ["Refresh (sync -f) file" p4-refresh
      :help "M-x p4-refresh
Refresh contents of an unopened file: p4 sync -f FILE"]
     ["Status of files on client" p4-status
      :help "M-x p4-status
Previews output of open files for add, delete, and/or edit in order to reconcile a workspace
with changes made outside of Perforce"]
     ["Reconcile files with depot" p4-reconcile
      :help "M-x p4-reconcile
Open files for add, delete, and/or edit to reconcile
client with workspace changes made outside of Perforce"]
     ["List files in depot" p4-files
      :help "M-x p4-files"]
     ["Get client name" p4-get-client-name
      :help "M-x p4-get-client-name"]
     ["Unload" p4-unload
      :help "M-x p4-unload
Unload a client, label, or task stream to the unload depot"]
     ["Reload" p4-reload
      :help "M-x p4-reload
Reload an unloaded client, label, or task stream"]
     ["Have (list files in workspace)" p4-have
      :help "M-x p4-have
List the revisions most recently synced to workspace"]
     ["Show where file is mapped" p4-where
      :help "M-x p4-where
Show how file names are mapped by the client view"]
     ["--" nil nil]
     ["List clients" p4-clients
      :help "M-x p4-clients
Display list of clients. Example: p4-clients -u USERNAME -m 100"]
     )
    ["--" nil nil]
    ["Open for integrate" p4-integ
     :help "M-x p4-integ
Integrate one set of files into another"]
    ["Resolve conflicts" p4-resolve
     :help "M-x p4-resolve
Resolve integrations and updates to workspace files"]
    ["--" nil nil]
    ["View (print) depot file" p4-print
     :help "M-x p4-print
Visit version of file in a buffer"]
    ["Annotate" p4-annotate
     :help "M-x p4-annotate
Use 'p4 annotate -I' to follow integrations into a file along with additional p4 commands
to annotate each line with info from the changelist which introduced the change"]
    ["Find File using Depot Spec" p4-depot-find-file
     :help "M-x p4-depot-find-file
Visit client file corresponding to depot FILESPEC if possible,
otherwise print FILESPEC to a new buffer"]
    ["--" nil nil]
    ("Config"
     ["Branch" p4-branch
      :help "M-x p4-branch
Create, modify, or delete a branch view specification"]
     ["Branches" p4-branches
      :help "M-x p4-branches
Display list of branch specifications"]
     ["Edit a label specification" p4-label
      :help "M-x p4-label
Create or edit a label specification"]
     ["Display list of defined labels" p4-labels
      :help "M-x p4-labels"]
     ["Apply label to workspace" p4-labelsync
      :help "M-x p4-labelsync"]
     ["Edit a client specification" p4-client
      :help "M-x p4-client
Create or edit a client workspace specification and its view workspace"]
     ["Edit a user specification" p4-user
      :help "M-x p4-user
Create or edit a user specification"]
     ["List Perforce users" p4-users
      :help "M-x p4-users"]
     ["--" nil nil]
     ["Set P4CONFIG" p4-set-p4-config
      :help "M-x p4-set-p4-config
Set the P4CONFIG environment variable to VALUE
P4CONFIG is typically set to the filename '.perforce' and this
file is placed at the root of your Perforce workspace.  Within
this file, you place Perforce environment variables, such as
  P4CLIENT=client_name"]
     ["Set P4CLIENT" p4-set-client-name
      :help "M-x p4-set-client-name
Set the P4CLIENT environment variable to VALUE"]
     ["Set P4PORT" p4-set-p4-port
      :help "M-x p4-set-p4-port
Set the P4PORT environment variable to VALUE."]
     ["Show client info" p4-set
      "M-x p4-set
Set or display Perforce variables."]
     ["Show server info" p4-info
      :help "M-x p4-info
Display client/server information."]
     ["About P4" p4-version
      :help "M-x p4-version
Display the Perforce-Emacs package, p4.el, version"]
     )
    ["Quit WINDOW and bury its buffer" quit-window]
    ["Help" p4-help
     :help "M-x p4-help
Run p4 help CMD"]
    ))

(defcustom p4-after-menu 'tools
  "Top-level menu to place P4 after."
  :type 'symbol
  :group 'p4)

;; Put P4 menu after the desired menu
(define-key-after (lookup-key global-map [menu-bar]) [p4-menu]
  (cons "P4" p4-menu)
  p4-after-menu)

;;; Running Perforce (defun's required for macros)

(defun p4-executable ()
  "Get the p4-executable.
If `p4-executable' is NIL, prompt for it."
  (interactive)
  (or p4-executable
      (if noninteractive
          (error "The p4-executable is not set")
        (call-interactively 'p4-set-p4-executable))))

(defun p4--get-process-environment ()
  "Return a modified process environment for p4 commands."
  ;; 1. Account for P4COLORS, e.g.
  ;;      export P4COLORS="@info=0:@error=31;1:@warning=33;1:action=36:how:36:change=33:\
  ;;      depotFile=32:path=32:location=32:rev=31:depotRev=31"
  ;;    which cause commands like p4-opened to have ANSI control characters in the output that
  ;;    isn't handle by Emacs (we do our own syntax highlighting).  Therefore, we instruct p4 to
  ;;    not produce ANSI escape codes when running p4 by setting P4COLORS to empty.
  ;;
  ;; 2. Account for P4DIFF set to an external diff tool which won't work when generating diff's
  ;;    for use in Emacs.
  (cons "P4DIFF=" (cons "P4COLORS=" process-environment)))

(defun p4-call-process (&optional infile destination display &rest args)
  "Call Perforce synchronously in separate process.
The program to be executed is taken from `p4-executable'; INFILE,
DESTINATION, and DISPLAY are to be interpreted as for
`call-process'.  The argument list ARGS is modified using
`p4-modify-args-function'."
  (let ((process-environment (p4--get-process-environment)))
    (apply #'call-process (p4-executable) infile destination display
           (funcall p4-modify-args-function args))))

;;; Macros (must be defined before use if compilation is to work)

(defmacro p4-with-temp-buffer (args &rest body)
  "Run p4 ARGS in a temporary buffer.

Place point at the start of the output, and evaluate BODY
if the command completed successfully."
  `(let ((dir (or p4-default-directory default-directory)))
     (with-temp-buffer
       (cd dir)
       (when (zerop (p4-run ,args)) ,@body))))

(put 'p4-with-temp-buffer 'lisp-indent-function 1)

(defmacro p4-with-set-output (&rest body)
  "Run p4 set in a temporary buffer.

Place point at the start of the output,
and evaluate BODY if the command completed successfully."
  ;; Can't use `p4-with-temp-buffer' for this, because that would lead
  ;; to infinite recursion via `p4-coding-system'.
  `(let ((dir (or p4-default-directory default-directory)))
     (with-temp-buffer
       (cd dir)
       (when (zerop (save-excursion
                      (p4-call-process nil t nil "set")))
         ,@body))))

(put 'p4-with-set-output 'lisp-indent-function 0)

(defmacro p4-with-coding-system (&rest body)
  "Evaluate BODY using `p4-coding-system'.

This will evaluate BODY `coding-system-for-read' and
`coding-system-for-write' set to the result of
`p4-coding-system'."
  `(let* ((coding (p4-coding-system))
          (coding-system-for-read coding)
          (coding-system-for-write coding))
     ,@body))

(put 'p4-with-coding-system 'lisp-indent-function 0)


;;; Environment:

(defun p4-version ()
  "Describe the Emacs-Perforce Integration version."
  (interactive)
  (message "Emacs-P4 Integration version %s" p4-version))

(defvar p4-current-setting-cache (make-hash-table :test 'equal)
  "Cached of result \"p4 set VAR\".")

(defun p4-current-setting-clear ()
  "Clear (empty) the `p4-current-setting-cache' used by `p4-current-setting'."
  (clrhash p4-current-setting-cache))

(defun p4-current-setting (var &optional default)
  "Return the current Perforce client setting for VAR.

If VAR is not set, return DEFAULT.  The client setting can come
from a .perforce file or the environment.  The values are cached
to avoid repeated calls to p4 which can be slow."
  (let* ((p4config (p4--get-p4-config)) ;; typically .perforce
         (workspace-root (locate-dominating-file default-directory p4config))
         (key (concat (format "%s : %s" var default)
                      (if workspace-root (concat " <" workspace-root p4config ">"))))
         (ans (gethash key p4-current-setting-cache 'missing)))
    (when (equal ans 'missing)
      (setq ans (or (p4-with-set-output
                     (let ((re (format "^%s=\\(\\S-+\\)" (regexp-quote var))))
                       (when (re-search-forward re nil t)
                         (match-string 1))))
                    default))
      (puthash key ans p4-current-setting-cache))
    ans))

(defun p4--exists-in-p4-set-vars (var p4-set-vars)
  "Does VAR=value exist in P4-SET-VARS?"
  ;; Would be nice to use
  ;;   (seq-find (lambda (el) (string-match "^P4PORT=" el)) p4-set-vars))
  ;; instead of p4--exists-in-p4-set-vars ("P4PORT" p4-set-vars)
  ;; but seq-find isn't in emacs 24.
  (let (ans
        (el (car p4-set-vars)))
    (while el
      (if (string-match (concat "^" var "=") el)
          (setq ans t
                el nil)
        (setq p4-set-vars (cdr p4-set-vars)
              el (car p4-set-vars))))
    ans))

(defun p4-current-environment ()
  "Return Perforce process environment.

This is `process-environment' updated with the current Perforce client settings."
  (let ((p4-set-vars (p4-with-set-output
                      (cl-loop while (re-search-forward "^P4[A-Z]+=\\S-+" nil t)
                               collect (match-string 0)))))
    ;; Default values for P4PORT and P4USER may be needed by
    ;; p4-password-source even if not supplied by "p4 set". See:
    ;; http://www.perforce.com/perforce/doc.current/manuals/cmdref/P4PORT.html
    ;; http://www.perforce.com/perforce/doc.current/manuals/cmdref/P4USER.html
    (when (not (p4--exists-in-p4-set-vars "P4PORT" p4-set-vars))
      (setq p4-set-vars (append p4-set-vars (list "P4PORT=perforce:1666"))))
    (when (not (p4--exists-in-p4-set-vars "P4PORT" p4-set-vars))
      (setq p4-set-vars (append p4-set-vars (list (concat "P4USER="
                                                          (or (getenv "USER")
                                                              (getenv "USERNAME")
                                                              (user-login-name)))))))
    (append p4-set-vars process-environment)))

(defvar p4-coding-system-alist
  ;; I've preferred the IANA name, where possible. See
  ;; <http://www.iana.org/assignments/character-sets/character-sets.xhtml>
  ;; Note that Emacs (as of 24.3) does not support utf-32 and its
  ;; variants; these will lead to an error in `p4-coding-system'.
  '(("cp1251"      . windows-1251)
    ("cp936"       . windows-936)
    ("cp949"       . euc-kr)
    ("cp950"       . big5)
    ("eucjp"       . euc-jp)
    ("iso8859-1"   . iso-8859-1)
    ("iso8859-15"  . iso-8859-15)
    ("iso8859-5"   . iso-8859-5)
    ("koi8-r"      . koi8-r)
    ("macosroman"  . macintosh)
    ("shiftjis"    . shift_jis)
    ("utf16"       . utf-16-with-signature)
    ("utf16-nobom" . utf-16)
    ("utf16be"     . utf-16be)
    ("utf16be-bom" . utf-16be-with-signature)
    ("utf16le"     . utf-16le)
    ("utf16le-bom" . utf-16le-with-signature)
    ("utf8"        . utf-8)
    ("utf8-bom"    . utf-8-with-signature)
    ("winansi"     . windows-1252)
    ("none"        . utf-8)
    (nil           . utf-8))
  "Association list mapping P4CHARSET to Emacs coding system.")

(defun p4-coding-system ()
  "Return an Emacs coding system equivalent to P4CHARSET."
  (let* ((charset (p4-current-setting "P4CHARSET"))
         (c (assoc charset p4-coding-system-alist)))
    (if c (cdr c)
      (error "Coding system %s not available in Emacs" charset))))

(defun p4-set-process-coding-system (process)
  "Set coding systems of PROCESS appropriately."
  (let ((coding (p4-coding-system)))
    (set-process-coding-system process coding coding)))

(defun p4-current-client ()
  "Return the current Perforce client."
  (p4-current-setting "P4CLIENT"))

(defun p4-get-client-name ()
  "Display the name of the current Perforce client."
  (interactive)
  (message "P4CLIENT=%s" (p4-current-client)))

(defun p4-current-server-port ()
  "Return the current Perforce port."
  ;; http://www.perforce.com/perforce/doc.current/manuals/cmdref/P4PORT.html
  (or (p4-current-setting "P4PORT") "perforce:1666"))

(defun p4-set-client-name (value)
  "Set the P4CLIENT environment variable to VALUE.
If the setting `p4-set-my-clients' is non-NIL, complete on those
clients only.  If `p4-strict-complete' is non-NIL, require an
exact match."
  (interactive
   (list
    (completing-read
     "P4CLIENT="
     (or p4-my-clients
         (p4-completion-arg-completion-fn (p4-get-completion 'client)))
     nil p4-strict-complete (p4-current-client) 'p4-client-history)))
  (p4-current-setting-clear)
  (setenv "P4CLIENT" (unless (string-equal value "") value))
  (run-hooks 'p4-set-client-hooks))

(defvar p4--p4config-value-cache nil)
(defun p4--get-p4-config (&optional force)
  "Get the value of \"p4 set P4CONFIG\".
This is typically \".perforce\" and is a file that is placed at
the Perforce client workspace root.  This is a system wide setting
defined by the environment variable $P4CONFIG, or by
P4CONFIG=value saved by p4 set P4CONFIG=value in ~/.p4enviro.
This will cache the results.  Specify FORCE to not use the cache."
  (when (and (not force)
             (not p4--p4config-value-cache))
    (setq p4--p4config-value-cache
          (with-temp-buffer
            (if (zerop (save-excursion
                         (p4-call-process nil t nil "set" "P4CONFIG")))
                (progn
                  (goto-char (point-min))
                  (if (re-search-forward "^P4CONFIG=\\(\\S-+\\)" nil t)
                      (match-string-no-properties 1)
                    (if (re-search-forward "\\S-" nil t)
                        (error "'%s set P4CONFIG' did not return P4CONFIG=value.  It returned:\n%s"
                               (p4-executable) (buffer-string))
                      (error "'%s set P4CONFIG' did not return P4CONFIG=value.
To fix:
  1. Set, in your environment, P4CONFIG=value (e.g. in bash export P4CONFIG=.perforce)
  2. Run: p4 set P4CONFIG=value (e.g. p4 set P4CONFIG=.perforce)
"
                             (p4-executable)))))
              (error "'%s set P4CONFIG' failed with output\n%s" (p4-executable) (buffer-string))))))
  p4--p4config-value-cache)

(defun p4-set-p4-config (value)
  "Set the P4CONFIG environment variable to VALUE.
P4CONFIG is typically set to the filename '.perforce' and this
file is placed at the root of your Perforce workspace.  Within
this file, you place Perforce environment variables, such as
  P4CLIENT=client_name"
  (interactive (list (read-string "P4CONFIG=" (p4-current-setting "P4CONFIG"))))
  (setenv "P4CONFIG" (unless (string-equal value "") value))
  (p4--get-p4-config t) ;; force reload of the cache to ensure it was set correctly
  (p4-current-setting-clear))

(defun p4-set-p4-port (value)
  "Set the P4PORT environment variable to VALUE."
  (interactive (list (read-string "P4PORT=" (p4-current-setting "P4PORT"))))
  (setenv "P4PORT" (unless (string-equal value "") value))
  (p4-current-setting-clear))

(defun p4-set-default-directory-to-root ()
  "Set Perforce default directory to the workspace root.

If in a Perforce workspace as identified by the P4CONFIG
file (typically .perforce) set `p4-default-directory' to that
location."
  (let* ((p4config (p4--get-p4-config)) ;; typically .perforce
         (root (locate-dominating-file default-directory p4config)))
    (when root
      (setq-local p4-default-directory root))))

;;; Utilities:

(defun p4-find-file-or-print-other-window (client-name depot-name)
  "Find Perforce file for CLIENT-NAME and DEPOT-NAME."
  (if client-name
      (find-file-other-window client-name)
    (p4-depot-find-file depot-name)))

(defvar p4-filespec-buffer-cache nil
  "Association list mapping filespec to buffer visiting that filespec.")

(defun p4-purge-filespec-buffer-cache ()
  "Remove stale entries from `p4-filespec-buffer-cache'."
  (let ((stale (time-subtract (current-time)
                              (seconds-to-time p4-cleanup-time))))
    (setf p4-filespec-buffer-cache
          (cl-loop for c in p4-filespec-buffer-cache
                   when (and (time-less-p stale (cl-second c))
                             (buffer-live-p (cl-third c)))
                   collect c))))

(defun p4-visit-filespec (filespec)
  "Visit FILESPEC in some buffer and return the buffer."
  (p4-purge-filespec-buffer-cache)
  (let ((cached (assoc filespec p4-filespec-buffer-cache)))
    (if cached (cl-third cached)
      (let ((args (list "print" filespec)))
        (set-buffer (p4-make-output-buffer (p4-process-buffer-name args)))
        (if (zerop (p4-run args))
            (progn
              (p4-activate-print-buffer t)
              (push (list filespec (current-time) (current-buffer))
                    p4-filespec-buffer-cache)
              (current-buffer))
          (p4-process-show-error))))))

(defun p4-depot-find-file-noselect (filespec)
  "Read depot FILESPEC in to a buffer and return the buffer.
If a buffer exists visiting FILESPEC, return that one."
  (string-match "\\(.*?\\)\\(#[1-9][0-9]*\\|\\(@\\S-+\\)\\)?$" filespec)
  (let* ((file (match-string 1 filespec))
         (spec (match-string 2 filespec))
         (change (match-string 3 filespec)))
    (if change
        ;; TODO: work out if we have the file synced at this
        ;; changelevel, perhaps by running sync -n and seeing if it
        ;; prints "files(s) up to date"?
        (p4-visit-filespec filespec)
      (with-temp-buffer
        (if (and (zerop (p4-run (list "have" file)))
                 (not (looking-at "//[^ \n]+ - file(s) not on client"))
                 (looking-at "//.*?\\(#[1-9][0-9]*\\) - \\(.*\\)$")
                 (or (not spec) (string-equal spec (match-string 1))))
            (find-file-noselect (match-string 2))
          (p4-visit-filespec filespec))))))

(defun p4-depot-find-file (filespec &optional line offset)
  "Visit the client file corresponding to depot FILESPEC.

If the file is mapped (and synced to the right revision if
necessary), otherwise print FILESPEC to a new buffer
synchronously and pop to it.  With optional arguments LINE and
OFFSET, go to line number LINE and move forward by OFFSET
characters.  Return result of calling function `buffer-file-name'."
  (interactive (list (p4-read-arg-string "Enter filespec: " "//" 'filespec)))
  (let ((buffer (p4-depot-find-file-noselect filespec))
        file-name)
    (when buffer
      (pop-to-buffer buffer)
      (setq file-name (buffer-file-name buffer))
      (when line (p4-goto-line line)
            (when offset (forward-char offset))))
    file-name))

(defun p4-make-derived-map (base-map)
  "Make a derived map for BASE-MAP."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map base-map)
    map))

(defun p4-goto-line (line)
  "Move to start of LINE number."
  (goto-char (point-min))
  (forward-line (1- line)))

(defun p4-join-list (list)
  "Joint LIST of strings together."
  (mapconcat 'identity list " "))

;; Break up a string into a list of words
;; (p4-make-list-from-string "ab 'c de'  \"'f'\"") -> ("ab" "c de" "'f'")
(defun p4-make-list-from-string (str)
  "Split STR into a list."
  (let (lst)
    (while (or (string-match "^ *\"\\([^\"]*\\)\"" str)
               (string-match "^ *\'\\([^\']*\\)\'" str)
               (string-match "^ *\\([^ ]+\\)" str))
      (setq lst (append lst (list (match-string 1 str))))
      (setq str (substring str (match-end 0))))
    lst))

(defun p4-dired-get-marked-files ()
  "Wrapper for `dired-get-marked-files'."
  ;; In Emacs 24.2 (and earlier) this raises an error if there are no marked files and no file on
  ;; the current line, so we suppress the error here.
  ;;
  ;; The (delq nil ...) works around a bug in Dired+. See issue #172
  ;; <https://github.com/gareth-rees/p4.el/issues/172>
  (ignore-errors (delq nil (dired-get-marked-files nil))))

(defun p4-follow-link-name (name)
  "Follow symlink NAME."
  (if p4-follow-symlinks
      (file-truename name)
    name))

(defun p4-is-encoded-path (file-path)
  "Check if FILE-PATH is encoded.
//foo/goo/bar.cpp    ==> t
//foo/%40goo/bar.cpp ==> t
//foo/@goo/bar.cpp   ==> nil ;; p4-encode-path yields //foo/%40goo/bar.cpp"
  (setq file-path (replace-regexp-in-string "[#@][0-9]+$" "" file-path)) ;; strip version
  (let ((ans t))
    (if (string-match "[@#*]" file-path)
        (setq ans nil) ;; "@" "#" or "*" ==> not encoded
      (let ((start-index 0))
        (while (and start-index
                    (< start-index (length file-path)))
          (setq start-index (string-match "%\\(25\\|40\\|23\\|2A\\)?" file-path start-index))
          (let ((num (and start-index (match-string 1 file-path))))
            (when start-index
              (if (not num)
                  ;; "%" followed by non-encoded number => not encoded
                  (setq start-index nil
                        ans nil)
                (setq start-index (1+ start-index))))))))
    ans))

(defun p4-encode-path (file-path)
  "Encode FILE-PATH for Perforce.
Encode a FILE-PATH per p4 requirements by replacing
% => %25, @ => %40, # => %23, * => %2A.
FILE-PATH may exist on disk, if so it's full path is used.
FILE-PATH may also be a depot path with optional version (not on disk)."
  (when (and file-path
             (not (p4-is-encoded-path file-path)))
    (let ((f-path file-path)
          (ver ""))
      ;; Strip the version specification on a depot path
      (when (string-match "^\\(.+\\)\\([#@][0-9]+\\)$" file-path)
        (setq f-path (match-string 1 file-path)
              ver (match-string 2 file-path)))
      ;; Resolve symbolic links, get full path when file exists
      (when (file-exists-p f-path)
        (setq f-path (file-truename f-path)))
      ;; Encode
      (setq f-path (replace-regexp-in-string "%" "%25" f-path))
      (setq f-path (replace-regexp-in-string "@" "%40" f-path))
      (setq f-path (replace-regexp-in-string "#" "%23" f-path))
      (setq f-path (replace-regexp-in-string "*" "%2A" f-path))
      (setq file-path (concat f-path ver))))
  file-path)

(defun p4-decode-path (path)
  "Does inverse of `p4-encode-path', decoding Perforce PATH."
  (setq path (replace-regexp-in-string "%40" "@" path))
  (setq path (replace-regexp-in-string "%23" "#" path))
  (setq path (replace-regexp-in-string "%2A" "*" path))
  ;; # do last to ensure foo%2525bar becomes foo%25bar
  (setq path (replace-regexp-in-string "%25" "%" path))
  path)

(defun p4-buffer-file-name (&optional buffer do-not-encode-path-for-p4)
  "Return name of file BUFFER is visiting, or NIL if none.
This respects the `p4-follow-symlinks' setting.  Note, the name
returned is encoded per p4 file name requirements.  See
`p4-encode-path'.  Specify DO-NOT-ENCODE-PATH-FOR-P4 for to return
the file system path instead of the Perforce encoded path."
  (let* ((f (buffer-file-name buffer))
         (ff (if f (p4-follow-link-name f))))
    (if do-not-encode-path-for-p4
        ff
      (p4-encode-path ff))))

(defun p4-process-output (cmd &rest args)
  "Run CMD (with the given ARGS) and return the output as a string.
Strips newlines from the end of the output."
  (with-temp-buffer
    (let ((process-environment (p4--get-process-environment)))
      (apply 'call-process cmd nil t nil args))
    (skip-chars-backward "\n")
    (buffer-substring (point-min) (point))))

(defun p4-starts-with (string prefix)
  "Return non-NIL if STRING begins with PREFIX."
  (let ((l (length prefix)))
    (and (>= (length string) l) (string-equal (substring string 0 l) prefix))))

;;; Running Perforce:

(defun p4-set-p4-executable (filename)
  "Set `p4-executable' to the argument FILENAME.
To set the executable for future sessions, customize
`p4-executable' instead."
  (interactive "fFull path to your p4 executable: ")
  (if (and (file-executable-p filename) (not (file-directory-p filename)))
      (setq p4-executable filename)
    (error "%s is not an executable file" filename)))

(defun p4-call-process-region (start end &optional delete buffer display &rest args)
  "Send text from START to END to a synchronous Perforce process.
The program to be executed is taken from `p4-executable'; START,
END, DELETE, BUFFER, and DISPLAY are to be interpreted as for
`call-process-region'.  The argument list ARGS is modified using
`p4-modify-args-function'."
  (let ((process-environment (p4--get-process-environment)))
    (apply #'call-process-region start end (p4-executable) delete buffer display
           (funcall p4-modify-args-function args))))

(defun p4-start-process (name buffer &rest program-args)
  "Start Perforce in a subprocess.  Return the process object for it.
The program to be executed is taken from `p4-executable'; NAME
and BUFFER are to be interpreted as for `start-process'.  The
argument list PROGRAM-ARGS is modified using
`p4-modify-args-function'."
  (let ((process-environment (p4--get-process-environment)))
    (apply #'start-process name buffer (p4-executable)
           (funcall p4-modify-args-function program-args))))

(defun p4-compilation-start (args &optional mode name-function highlight-regexp)
  "Run Perforce with arguments ARGS in a compilation buffer.
The program to be executed is taken from `p4-executable'; MODE,
NAME-FUNCTION, and HIGHLIGHT-REGEXP are to be interpreted as for
`compilation-start'.  ARGS, however, is an argument vector, not a
shell command.  It will be modified using
`p4-modify-args-function'."
  (apply #'compilation-start
         (mapconcat #'shell-quote-argument
                    (cons (p4-executable)
                          (funcall p4-modify-args-function args))
                    " ")
         mode name-function highlight-regexp))

(defun p4-make-comint (name &optional startfile &rest switches)
  "Make a Comint process NAME in a buffer, running Perforce.
The program to be executed is taken from `p4-executable';
STARTFILE is to be interpreted as for `p4-make-comint'.  SWITCHES
is modified using `p4-modify-args'."
  (apply #'make-comint name (p4-executable) startfile
         (funcall p4-modify-args-function switches)))

(defun p4-make-output-buffer (buffer-name &optional mode)
  "Make a read-only buffer named BUFFER-NAME and return it.
Run the function MODE if non-NIL, otherwise `p4-basic-mode'."
  (let ((dir (or p4-default-directory default-directory))
        (inhibit-read-only t))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (funcall (or mode 'p4-basic-mode))
      (setq buffer-read-only t)
      (setq buffer-undo-list t)
      (cd dir)
      (current-buffer))))

(defvar p4-no-session-regexp
  (concat "\\(?:error: \\)?"
          "\\(?:Perforce password (P4PASSWD) invalid or unset\\|"
          "Your session has expired, please login again\\)")
  "Regular expression matching output from Perforce when you are logged out.")

(defvar p4-untrusted-regexp
  (concat "\\(?:error: \\)?"
          "\\(?:The authenticity of '.*' can't be established"
          "\\|\\** WARNING P4PORT IDENTIFICATION HAS CHANGED! \\**\\)")
  "Regular expression matching output from an untrusted Perforce server.")

(defvar p4-connect-failed-regexp
  (concat "\\(?:error: \\)?"
          "Perforce client error:\n"
          "\tConnect to server failed")
  "Regex matching output from Perforce when it can't connect to the server.")

(defun p4-request-trust ()
  "Ask the user for permission to trust the Perforce server."
  (with-selected-window (display-buffer (current-buffer))
    (goto-char (point-min)))
  (unless (yes-or-no-p "Trust server? ")
    (error "Server not trusted"))
  (with-temp-buffer
    (insert "yes\n")
    (p4-with-coding-system
     (p4-call-process-region (point-min) (point-max)
                             t t nil "trust" "-f"))))

(defun p4-iterate-with-login (fun)
  "Call FUN in the current buffer and return its result.
If FUN returns non-zero because the user is not logged in, login
and repeat."
  (let ((incomplete t)
        (default-directory (or p4-default-directory default-directory))
        (inhibit-read-only t)
        status)
    (while incomplete
      (save-excursion
        (save-restriction
          (setq incomplete nil)
          (narrow-to-region (point) (point))
          (setq status (funcall fun))
          (goto-char (point-min))
          (cond ((zerop status))
                ((looking-at p4-no-session-regexp)
                 (setq incomplete t)
                 (p4-login)
                 (delete-region (point-min) (point-max)))
                ((looking-at p4-untrusted-regexp)
                 (setq incomplete t)
                 (p4-request-trust))))))
    status))

(defun p4-ensure-logged-in ()
  "Ensure that user is logged in, prompting for password if necessary."
  (p4-with-temp-buffer '("login" "-s")
                       ;; Dummy body avoids byte-compilation warning.
                       'logged-in))

(defun p4-run (args)
  "Run p4 ARGS in the current buffer, with output after point.
Return the status of the command.  If the command cannot be run
because the user is not logged in, prompt for a password and
re-run the command."
  (p4-iterate-with-login
   (lambda ()
     (p4-with-coding-system
      (apply #'p4-call-process nil t nil args)))))

(defun p4-refresh-callback (&optional hook)
  "Perforce refresh callback.
Return a callback function that refreshes the current buffer
after a p4 command successfully completes.  If optional argument
HOOK is non-NIL, run that hook."
  (let ((buffer (current-buffer))
        (hook hook))
    (lambda ()
      (with-current-buffer buffer
        (p4-refresh-buffer)
        (when hook (run-hooks hook))))))

(defun p4-process-show-output ()
  "Show the current buffer to the user and maybe kill it."
  (let ((lines (count-lines (point-min) (point-max))))
    (if (or p4-process-after-show
            (get-buffer-window) ; already visible
            (if p4-process-pop-up-output
                (funcall p4-process-pop-up-output)
              (> lines 1)))
        (unless (eq (window-buffer) (current-buffer))
          (with-selected-window (display-buffer (current-buffer))
            (goto-char (point-min))))
      (if (zerop lines)
          (message "p4 %s\nproduced no output"
                   (p4-join-list p4-process-args))
        (goto-char (point-max))
        (message "%s" (buffer-substring (point-min) (line-end-position 0))))
      (kill-buffer (current-buffer)))))

(defvar p4-error-handler #'(lambda (msg) (error "%s" msg))
  "Function to be called when an error is encountered.
Organizations can set this in their environment to provide
more diagnostic information, such as requirements for
setting up perforce.")

(defun p4-process-show-error (&rest args)
  "Show the contents of the current buffer as an error message.
If there's no content in the buffer, pass ARGS to `error'
instead.  You can specify a custom error function using `p4-error-handler'."
  (let ((msg
         (cond ((and (bobp) (eobp))
                (kill-buffer (current-buffer))
                (apply 'message args))
               ((eql (count-lines (point-min) (point-max)) 1)
                (goto-char (point-min))
                (let ((message (buffer-substring (point) (line-end-position))))
                  (kill-buffer (current-buffer))
                  message))
               (t
                (let ((set (p4-with-set-output
                            (buffer-substring (point-min) (point-max))))
                      (inhibit-read-only t))
                  (with-selected-window (display-buffer (current-buffer))
                    (goto-char (point-max))
                    (insert (concat "\n\"p4 set\" shows that you have "
                                    (if (string-match "\\S-" set)
                                        (concat "the following Perforce configuration:\n" set)
                                      "have no Perforce configuration.\n")))
                    (goto-char (point-min))))
                (apply 'message args)))))
    (apply p4-error-handler (list msg))))


(defun p4-process-finished (buffer process-name message)
  "Perforce process finished.
Uses BUFFER and PROCESS-NAME and resulting MESSAGE."
  (let ((inhibit-read-only t))
    (with-current-buffer buffer
      (cond ((and p4-process-auto-login
                  (save-excursion
                    (goto-char (point-min))
                    (looking-at p4-no-session-regexp)))
             (p4-login)
             (p4-process-restart))
            ((save-excursion
               (goto-char (point-min))
               (looking-at p4-untrusted-regexp))
             (p4-request-trust)
             (p4-process-restart))
            ((not (string-equal message "finished\n"))
             (p4-process-show-error "Process %s %s" process-name
                                    (replace-regexp-in-string "\n$" ""
                                                              message)))
            (t
             (when p4-process-callback (funcall p4-process-callback))
             (set-buffer-modified-p nil)
             (p4-process-show-output)
             (when p4-process-after-show
               (funcall p4-process-after-show)
               (setq p4-process-after-show nil)))))))

(defun p4-process-sentinel (process message)
  "Perforce PROCESS MESSAGE sentinel."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (p4-process-finished buffer (process-name process) message))))

(defun p4-process-restart ()
  "Start a Perforce process.
Restarts in the current buffer with command
and arguments taken from the local variable `p4-process-args'."
  (interactive)
  (unless p4-process-args
    (error "Can't restart Perforce process in this buffer"))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if p4-process-synchronous
        (p4-with-coding-system
         (let ((status (apply #'p4-call-process nil t nil
                              p4-process-args)))
           (p4-process-finished (current-buffer) "P4"
                                (if (zerop status) "finished\n"
                                  (format "exited with status %d\n" status)))))
      (let ((process (apply #'p4-start-process "P4" (current-buffer)
                            p4-process-args)))
        (set-process-query-on-exit-flag process nil)
        (set-process-sentinel process 'p4-process-sentinel)
        (p4-set-process-coding-system process)
        (message "Running: p4 %s" (p4-join-list p4-process-args))))))

(defun p4-revert-buffer (&optional ignore-auto noconfirm)
  "Perforce revert buffer.
IGNORE-AUTO and NOCONFIRM are placeholders."
  (ignore ignore-auto noconfirm)
  (p4-process-restart))

(defun p4-process-buffer-name (args)
  "Return a suitable buffer name for the p4 ARGS command."
  (let* ((args-str (p4-join-list args))
         (p4config (p4--get-p4-config)) ;; typically .perforce
         (root (locate-dominating-file default-directory p4config))
         ;; Add " <root>" postfix if args-str doesn't contain the root, e.g.  p4-filelog will
         ;; contain the root in args-str, whereas p4-changes will not, so we add it.
         (postfix (if (and root
                           (not (string-match (regexp-quote root) args-str)))
                      (concat " <" root ">")
                    "")))
    ;; Don't use "*P4 ...*" as a buffer name. If we did, we'd have *P4 print ...*, and if you
    ;; attempt to ediff-buffers with two print buffers open, they will not be selected because
    ;; of the leading '*'.
    (format "P4 %s%s" args-str postfix)))

(defun p4-refresh-buffer-with-true-path ()
  "Set buffer to `file-truename'.

Set file buffer or `default-directory' of non-file buffer to be
`file-truename'.  In addition, on Windows, replace subst drives
with the true path.  In Windows Command Prompt, type \"subst /?\"
to see subst'ed drives."
  (let ((file (buffer-file-name))
        true-file)
    (when (and (not file)
               (equal major-mode 'dired-mode))
      (setq file default-directory))
    (when file
      (setq true-file (file-truename file))
      ;; See if Windows subst'd drive, if so use switch to the true path.
      (when (and (equal system-type 'windows-nt)
                 (string-match "^\\([a-zA-Z]:\\)/" true-file)) ;; Emacs forward slashes, e.g. d:/
        (let ((drive (upcase (match-string 1 true-file))) ;; For example, drive == D:
              (subst-drives (shell-command-to-string "subst")))
          ;; Example:
          ;;   B:\>subst w: "c:\program files\GIMP 2"
          ;;   B:\>subst
          ;;   B:\: => Z:\path\to\some\workspace
          ;;   W:\: => C:\program files\GIMP 2
          ;;   X:\: => L:\work
          ;;   Y:\: => L:\
          (when (string-match (concat drive "\\\\: => \\([A-Z]:\\\\[^\n\r]*\\)") subst-drives)
            (setq true-file (concat
                             (replace-regexp-in-string "\\\\" "/" (match-string 1 subst-drives))
                             (substring true-file 2))))
          )))
    (when (not (string= true-file file))
      (find-alternate-file true-file))))

(cl-defun p4-call-command (cmd &optional args &key mode callback after-show
                               (auto-login t) synchronous pop-up-output)
  "Start a Perforce command.
First (required) argument CMD is the p4 command to run.
Second (optional) argument ARGS is a list of arguments to the p4 command.
Remaining arguments are keyword arguments:
:MODE is a function run when creating the output buffer.
:CALLBACK is a function run when the p4 command completes successfully.
:AFTER-SHOW is a function run after displaying the output.
If :AUTO-LOGIN is NIL, don't try logging in if logged out.
If :SYNCHRONOUS is non-NIL, or command appears in
`p4-synchronous-commands', run command synchronously.
If :POP-UP-OUTPUT is non-NIL, call that function to determine
whether or not to pop up the output of a command in a window (as
opposed to showing it in the echo area)."

  ;; Don't call `p4-refresh-buffer-with-true-path' here because args will contain the original file
  ;; path. For example M-x p4-edit RET /path/to/file.ext RET will result in args containing
  ;; /path/to/file.ext.
  (with-current-buffer
      (p4-make-output-buffer (p4-process-buffer-name (cons cmd args)) mode)
    (let ((default-directory (file-truename default-directory)))
      (set (make-local-variable 'revert-buffer-function) 'p4-revert-buffer)
      (setq p4-process-args (cons cmd args)
            p4-process-after-show after-show
            p4-process-auto-login auto-login
            p4-process-callback callback
            p4-process-pop-up-output pop-up-output
            p4-process-synchronous
            (or synchronous (memq (intern cmd) p4-synchronous-commands)))
      (p4-process-restart))))

;; This empty function can be passed as an :after-show callback
;; function to p4-call-command where it has the side effect of
;; displaying the output buffer even if it contains a single line.
(defun p4-display-one-line ()
  "Empty function for callbacks."
  )


;;; Form commands:

(defun p4-form-value (key)
  "Perforce form value.
Return the value in the current form corresponding to KEY, or
NIL if the form has no value for that key."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (format "^%s:" (regexp-quote key)) nil t)
      (if (looking-at "[ \t]\\(.+\\)")
          (match-string-no-properties 1)
        (forward-line 1)
        (cl-loop while (looking-at "[ \t]\\(.*\\(?:\n\\|\\'\\)\\)")
                 do (forward-line 1)
                 concat (match-string-no-properties 1))))))

(defun p4-form-callback (regexp cmd success-callback failure-callback
                                mode head-text)
  "Perforce form callback.
Operates on REGEXP, CMD, SUCCESS-CALLBACK, FAILURE-CALLBACK, MODE, HEAD-TEXT."
  (goto-char (point-min))
  ;; The Windows p4 client outputs this line before the spec unless
  ;; run via CMD.EXE.
  (when (looking-at "Found client MATCH : .*\n") (replace-match ""))
  (insert head-text)
  (funcall mode)
  (pop-to-buffer (current-buffer))
  (setq p4-form-commit-command cmd)
  (setq p4-form-commit-success-callback success-callback)
  (setq p4-form-commit-failure-callback failure-callback)
  (setq buffer-offer-save t)
  (set-buffer-modified-p nil)
  (setq buffer-undo-list nil)

  (let (buf-read-only)
    (save-excursion
      (cond

       ;; Handle P4 change forms
       ((string-match "^P4 change " (buffer-name))

        ;; If this form is a submitted changelist, make buffer read-only
        (goto-char (point-min))
        (when (re-search-forward "^Status: submitted" nil t)
          (setq buf-read-only t)))

       ;; other type of form
       (t
        (message "C-c C-c to finish editing and exit buffer."))))

    (setq buffer-read-only buf-read-only))

  ;; Move to desired location
  (when regexp (re-search-forward regexp nil t)))

(cl-defun p4-form-command (cmd &optional args
                               &key move-to
                               commit-cmd
                               success-callback
                               (failure-callback
                                'p4-form-commit-failure-callback-default)
                               (mode 'p4-form-mode)
                               (head-text p4-form-head-text)
                               force-refresh)
  "Maybe start a form-editing session.
CMD is the p4 command to run \(it must take -o and output a form\).
ARGS is a list of arguments to pass to the p4 command.
If args contains -d, then the command is run as-is.
Otherwise, -o is prepended to the arguments and the command
outputs a form which is presented to the user for editing.
The remaining arguments are keyword arguments:
:MOVE-TO is an optional regular expression to set the cursor on.
:COMMIT-CMD is the command that will be called when
`p4-form-commit' is called \(it must take -i and a form on
standard input\).  If not supplied, cmd is reused.
:SUCCESS-CALLBACK is a function that is called if the commit succeeds.
:FAILURE-CALLBACK is a function that is called if the commit fails.
:MODE is the mode for the form buffer.
:HEAD-TEXT is the text to insert at the top of the form buffer.
:FORCE-REFRESH if t refresh the form."
  (unless mode (error "Mode"))
  (when (member "-i" args)
    (error "'%s -i' is not supported here" cmd))
  (if (member "-d" args)
      (p4-call-command (or commit-cmd cmd) args)
    (let* ((args (cons "-o" (remove "-o" args)))
           (buf (get-buffer (p4-process-buffer-name (cons cmd args)))))
      ;; Is there already a form with the same name? If so, just
      ;; switch to it.
      (if (and (not force-refresh) buf)
          (select-window (display-buffer buf))
        (let* ((move-to move-to)
               (commit-cmd (or commit-cmd cmd))
               (success-callback success-callback)
               (failure-callback failure-callback)
               (mode mode)
               (head-text head-text))
          (p4-call-command cmd args
                           :callback (lambda ()
                                       (p4-form-callback move-to commit-cmd success-callback
                                                         failure-callback mode head-text))))))))

(defun p4-form-commit-failure-callback-default (cmd buffer)
  "Perforce form commit failure callback for CMD and BUFFER."
  (with-current-buffer buffer
    (p4-process-show-error "%s -i failed to complete successfully" cmd)))

(defun p4-form-commit ()
  "Commit the form in the current buffer to the server."
  (interactive)
  (let* ((form-buf (current-buffer))
         (cmd p4-form-commit-command)
         (args '("-i"))
         (buffer (p4-make-output-buffer (p4-process-buffer-name
                                         (cons cmd args)))))
    (cond ((with-current-buffer buffer
             (zerop
              (p4-iterate-with-login
               (lambda ()
                 (with-current-buffer form-buf
                   (save-restriction
                     (widen)
                     (p4-with-coding-system
                      (apply #'p4-call-process-region (point-min)
                             (point-max)
                             nil buffer nil cmd args))))))))
           (setq mode-name "P4 Form Committed")
           (when p4-form-commit-success-callback
             (funcall p4-form-commit-success-callback cmd buffer))
           (set-buffer-modified-p nil)
           (with-current-buffer buffer
             (p4-process-show-output))
           (p4-partial-cache-cleanup
            (if (string= cmd "change") 'pending (intern cmd))))
          (p4-form-commit-failure-callback
           (funcall p4-form-commit-failure-callback cmd buffer)))))

;;; P4 mode:

(defun p4-refresh-buffer ()
  "Perforce refresh buffer.
Refresh the current buffer if it is under Perforce control and
the file on disk has changed.  If it has unsaved changes, prompt
first."
  (and buffer-file-name
       (file-readable-p buffer-file-name)
       (revert-buffer t (not (buffer-modified-p)))))

;;; Context-aware arguments:

(defun p4-get-depot-path-from-buffer-name ()
  "Return a depot path or nil based on the buffer name."
  (let ((name (buffer-name)))
    (when (string-match "P4 .*\\(//[^#]+#[0-9]+\\)" name)
      (match-string 1 name))))

(defun p4--filelog-buffer-get-filename ()
  "If in a \"P4 filelog ...\" buffer return the path name."
  ;; If (buffer-name) looks like
  ;;    P4 filelog -l -t //branch/path/to/file.ext
  ;;    P4 filelog -l -t //branch/path/to/file.ext#11
  ;;    P4 filelog -l -t //branch/path/to/file.ext#11 <directory/>
  ;; return //branch/path/to/file.ext
  (let ((buf-name (buffer-name)))
    (setq buf-name (replace-regexp-in-string " <[^>]+>$" "" buf-name))
    (when (string-match "^P4 filelog .*?\\([^ \t#]+\\)\\(?:#[0-9]+\\)?$" buf-name)
      (match-string 1 buf-name))))

(defun p4-context-single-filename (&optional do-not-encode-path-for-p4 no-error)
  "Return a single filename based on the current context.
Try the following, in order, until one succeeds:
  1. the file that the current buffer is visiting;
  2. the link at point;
  3. the marked file in a Dired buffer;
  4. the file at point in a Dired buffer;
  5. the file on the current line in a P4 Basic List buffer.
When NO-ERROR is nil, if a filename is not found then an error is
generated, otherwise nil is returned.
If DO-NOT-ENCODE-PATH-FOR-P4 it t, this returns the path to a
file on disk, e.g. for p4 add."
  (let ((ans (cond ((p4-buffer-file-name nil do-not-encode-path-for-p4))
                   ((and (not do-not-encode-path-for-p4)
                         (get-char-property (point) 'link-client-name)))
                   ((and (not do-not-encode-path-for-p4)
                         (get-char-property (point) 'link-depot-name)))
                   ((and (not do-not-encode-path-for-p4)
                         (get-char-property (point) 'block-client-name)))
                   ((and (not do-not-encode-path-for-p4)
                         (get-char-property (point) 'block-depot-name)))
                   ((let ((f (p4-dired-get-marked-files)))
                      (and f (p4-follow-link-name (cl-first f)))))
                   ((and (not do-not-encode-path-for-p4)
                         (p4-basic-list-get-filename)))
                   ((and (not do-not-encode-path-for-p4)
                         (p4-get-depot-path-from-buffer-name)))
                   ;; p4-filelog => get it from the buffer name
                   ((and (not do-not-encode-path-for-p4)
                         (p4--filelog-buffer-get-filename)))
                   )))
    (if (and (not ans) (not no-error))
        (error "Buffer is not associated with a file"))
    ans))

(defun p4-context-filenames-list (&optional do-not-encode-path-for-p4 no-error)
  "Return a list of filenames based on the current context.
Optional: DO-NOT-ENCODE-PATH-FOR-P4, NO-ERROR"
  (let ((f (p4-dired-get-marked-files)))
    (if f (mapcar 'p4-follow-link-name f)
      (let ((f (p4-context-single-filename do-not-encode-path-for-p4 no-error)))
        (when f (list f))))))

(defcustom p4-open-in-changelist nil
  "If non-NIL, prompt for a numbered pending changelist when opening files."
  :type 'boolean
  :group 'p4)

(defun p4-context-filenames-and-maybe-pending (&optional do-not-encode-path-for-p4)
  "Return a list of filenames based on the current context.
This will be preceded by \"-c\" and a changelist number if the user setting
p4-open-in-changelist is non-NIL.
Specify DO-NOT-ENCODE-PATH-FOR-P4 to return the file system path."
  (append (and p4-open-in-changelist
               (list "-c" (p4-completing-read 'pending "Open in change: ")))
          (p4-context-filenames-list do-not-encode-path-for-p4)))

(defun p4-context-single-filename-args ()
  "Return an argument list consisting of a single filename.
Returned filename is from the current context, or NIL if no
filename can be found in the current context."
  (let ((f (p4-context-single-filename nil t)))
    (when f (list f))))

(defun p4-context-single-filename-revision-args ()
  "Return an argument list consisting of a single filename.
Returned filename contains the revision or changelevel, based on
the current context, or NIL if the current context doesn't
contain a filename with a revision or changelevel."
  (let ((f (p4-context-single-filename nil t)))
    (when f
      (let ((rev (get-char-property (point) 'rev)))
        (if rev (list (format "%s#%d" f rev))
          (let ((change (get-char-property (point) 'change)))
            (if change (list (format "%s@%d" f change))
              (list f))))))))


;;; Defining Perforce command interfaces:

(defmacro defp4cmd (name arglist help-cmd help-text &rest body)
  "Define a p4 function.

NAME -- command name
ARGLIST -- command args
HELP-TEXT -- text to prepend to the Perforce help
BODY -- body of command.

Running p4 help HELP-CMD at compile time to get its docstring."
  `(defun ,name ,arglist
     ,(concat help-text "\n\n" "See M-x p4-help " help-cmd " for options.")
     ,@body))

(defmacro defp4cmd* (name help-text args-default &rest body)
  "Define an interactive p4 command.

NAME -- command name
HELP-TEXT -- text to prepend to the Perforce help
ARGS-DEFAULT -- form that evaluates to default list of p4 command arguments
BODY -- body of command.

Inside BODY: `cmd' is NAME converted to a string, `args-orig'
is the list of p4 command arguments passed to the command, and
`args' is the actual list of p4 command arguments (either
`args-orig' if non-NIL, or the result of evaluating
`args-default' otherwise.  Note that `args-default' thus appears
twice in the expansion."
  `(defp4cmd
    ,(intern (format "p4-%s" name))
    (&optional args-orig)
    ,(format "%s" name)
    ,(format "%s\n\nWith a prefix argument, prompt for \"p4 %s\" command-line options."
             help-text name)
    (interactive
     (when (or p4-prompt-before-running-cmd current-prefix-arg)
       (let* ((args ,args-default)
              (args-string (p4-join-list args)))
         (list (p4-read-args (format "Run p4 %s (with args): " ',name) args-string)))))
    (let ((cmd (format "%s" ',name))
          (args (or args-orig ,args-default)))
      ,@body)))


;;; Perforce command interfaces:


(defp4cmd* ;; defun p4-add
 add
 "Open a new file to add it to the depot."
 ;; For p4 add, if FILE contains Perforce wildcards [@#%*] then we
 ;; must prefix the add with -f. For example to add a file named
 ;; /path/to/file/@dir/foo.m we need to add it using
 ;;   p4 add -f /path/to/file/@dir/foo.m"
 (let ((file-list (p4-context-filenames-and-maybe-pending t)))
   (if (and (= (length file-list) 1)
            (string-match "[@#%*]" (car file-list)))
       `("-f" ,@file-list)
     file-list))
 (p4-call-command cmd args :mode 'p4-basic-list-mode
                  :callback (p4-refresh-callback)))

(defun p4-annotate (&optional file)
  "Annotate FILE lines with who changed them.
A buffer named \"P4 annotate FILE\" will be created where each source line
will be prefixed with
  LN CN REV DATE USER: <source line>
where LN is a shaded line number showing age, CN is the change number,
REV is the revision and DATE is when the change was made."
  (interactive
   (let* ((default-file (p4-context-single-filename-revision-args))
          (ans (p4-read-args "Annotate file: " (p4-join-list default-file))))
     (when (> (length ans) 1)
       (user-error "A single file with no options must be specified"))
     ans))
  (setq file (p4-encode-path file))
  (p4-annotate-file file))

(defp4cmd ;; defun p4-branch
 p4-branch (&rest args)
 "branch"
 "Create, modify, or delete a branch view specification."
 (interactive (p4-read-args "p4 branch: " "" 'branch))
 (unless args
   (error "Branch must be specified!"))
 (p4-form-command "branch" args :move-to "Description:\n\t"))

(defp4cmd* ;; defun p4-branches
 branches
 "Display list of branch specifications."
 nil
 (p4-call-command cmd args
                  :callback (lambda ()
                              (p4-regexp-create-links "^Branch \\([^ \t\n]+\\).*\n" 'branch
                                                      "Describe branch"))))

(defun p4-change-update-form (buffer new-status re)
  "Perforce change update form.
Rename a \"P4 change\" buffer if needed
BUFFER contains the output of \"p4 submit -i\" or \"p4 change -i\"
NEW-STATUS is what to set the \"Status: value\" to when RE
to identify the changenum is found in BUFFER.
Returns t if updated."

  (let (updated
        (change (with-current-buffer buffer
                  (save-excursion
                    (goto-char (point-min))
                    (when (re-search-forward re nil t)
                      (match-string 1))))))
    (when change
      (rename-buffer (p4-process-buffer-name (list "change" "-o" change)))
      (save-excursion
        (save-restriction
          (widen)
          ;; Change: new           ==> Change: CHANGENUM
          ;; Change: OLD_CHANGENUM ==> Change: NEW_CHANGENUM
          (goto-char (point-min))
          (when (re-search-forward "^Change:\\s-+\\(new\\|[0-9]+\\)$" nil t)
            (replace-match change t t nil 1))
          ;; Status: new     ==> Change: pending
          ;; Status: pending ==> Change: submitted
          (goto-char (point-min))
          (when (re-search-forward "^Status:\\s-+\\(new\\|pending\\)$" nil t)
            (replace-match new-status t t nil 1))))
      (set-buffer-modified-p nil)
      (setq updated t)
      )
    updated ;; result
    ))

(defun p4-change-success (cmd buffer)
  "Perforce change success.
Handle successful CMD (\"p4 change -i\" or \"p4 submit -i\")
BUFFER is the result of \"p4 change -i\" or \"p4 submit -i\""

  (cond

   ;; p4 change -i
   ;;   When a new change is created, it will become pending and be given a changelist number.
   ;;   Thus, update to be:
   ;;       Change: new   =>   Change: CHANGENUM
   ;;       Status: new   =>   Status: pending
   ;;    and rename the buffer to have the CHANGENUM.
   ;;    On successful creation of a pending changelist, 'buffer' will contain:
   ;;       /change \d+ created/
   ((string= cmd "change")
    (p4-change-update-form buffer "pending" "^Change \\([0-9]+\\) created"))

   ;; p4-shelve
   ((string= cmd "shelve")
    (p4-change-update-form buffer "pending" "^Change \\([0-9]+\\) files shelved"))

   ;; p4 submit -i
   ;;    When a pending change is submitted, we have
   ;;       Change: CHANGENUM   =>   Change: NEW_CHANGENUM   (may rename)
   ;;       Status: pending     =>   Status: submitted
   ;;    and rename the buffer to have the new CHANGENUM and make readonly (submitted changes
   ;;    shouldn't be modified).
   ;;    On successful submission of a pending changelist, 'buffer' will contain:
   ;;       /^Change \d+ submitted/
   ;;       /^Change \d+ renamed change \d+ and submitted/
   ((string= cmd "submit")
    (when (p4-change-update-form
           buffer "submitted"
           "^Change \\(?:[0-9]+ renamed change \\)?\\([0-9]+\\)\\(?: and\\)? submitted")
      (setq buffer-read-only t)))

   (t
    (error "Assert - unexpected cmd %S" cmd))
   ))

(defvar p4-change-head-text
  (format "# Created using Perforce-Emacs Integration version %s.
# Type C-c C-c to update the change description on the server.
# Type C-c C-r to refresh the change form by fetching contents from the server.
# Type C-c C-s to submit the change to the server.
# Type C-c C-d to delete the change.
# Type C-x k to cancel the operation.
#\n" p4-version)
  "Text added to top of change form.")

(defp4cmd ;; defun p4-change
 p4-change (&rest args)
 "change"
 "Create, edit, submit, or delete a changelist description."
 (interactive
  (progn
    (p4-set-default-directory-to-root)
    (p4-read-args* "Run p4 change (with args): "
                   (if (thing-at-point 'number)
                       (format "%s" (thing-at-point 'number)))
                   'pending)))
 ;; Set :force-refresh to t. Consider an existing "P4 change -o CN", then one goes to the
 ;; "P4 opened" buffer and reverts a file. Running p4-change should refresh the change buffer.
 (p4-form-command "change" args
                  :force-refresh t
                  :move-to "Description:\n\t"
                  :mode 'p4-change-form-mode
                  :head-text p4-change-head-text
                  :success-callback 'p4-change-success))

(defcustom p4-changes-default-args (concat "-m 200 -L -s submitted -u " user-login-name)
  "Default arguments for p4-changes command."
  :type 'string
  :group 'p4)

(defp4cmd* ;; defun p4-changes
 changes
 "Display list of submitted changelists per `p4-changes-default-args'"
 (progn
   (p4-set-default-directory-to-root)
   (p4-make-list-from-string p4-changes-default-args))
 (p4-file-change-log cmd args t))

(defp4cmd ;; defun p4-changes-pending
 p4-changes-pending ()
 "changes"
 "Display list of pending changelists for the current client."
 (interactive)
 (let ((client (p4-current-client)))
   (p4-set-default-directory-to-root)
   (p4-file-change-log "changes" `("-s" "pending" "-L"
                                   ,@(if client
                                         (list "-c" client)
                                       (list "-u" user-login-name))))))

(defp4cmd ;; defun p4-changes-shelved
 p4-changes-shelved ()
 "changes"
 "Display list of shelved changelists for current user."
 (interactive)
 (p4-set-default-directory-to-root)
 (p4-file-change-log "changes" `("-s" "shelved" "-L" "-u" ,user-login-name)))

(defp4cmd ;; defun p4-client
 p4-client (&rest args)
 "client"
 "Create or edit a client workspace specification and its view."
 (interactive
  (progn
    (p4-set-default-directory-to-root)
    (p4-read-args* "p4 client: " "" 'client)))
 (p4-form-command "client" args :move-to "\\(Description\\|View\\):\n\t"))

(defp4cmd* ;; defun p4-clients
 clients
 "Display list of clients."
 nil
 (p4-call-command cmd args
                  :callback (lambda ()
                              (p4-regexp-create-links "^Client \\([^ \t\n]+\\).*\n" 'client
                                                      "Describe client"))))

(defp4cmd* ;; defun p4-delete
 delete
 "Open an existing file for deletion from the depot."
 (p4-context-filenames-and-maybe-pending)
 (when (yes-or-no-p "Really delete from depot? ")
   (p4-call-command cmd args :mode 'p4-basic-list-mode
                    :callback (p4-refresh-callback))))

(defun p4-describe-all-files (&rest args)
  "Show both affected and shelved files in a changelist.
Only the first line of the changelist description is shown.
This exists because p4 describe doesn't have the ability to show
both \"affected\" and \"shelved\" files in a pending changelist.
To see all files in a pending changelist, it takes two commands:
    p4 describe -s CHANGENUM
    p4 describe -S -s CHANGENUM
which is what this function does.
ARGS are optional arguments for p4 describe."
  (interactive
   (progn
     (p4-set-default-directory-to-root)
     (p4-read-args* "Show files in change: "
                    (if (thing-at-point 'number)
                        (format "%s" (thing-at-point 'number)))
                    'pending)))
  (let ((files-buf (p4-process-buffer-name (cons "describe-all-files" args)))
        (describe-args `("-s" ,@args))
        (shelved-files))

    (with-current-buffer (p4-make-output-buffer files-buf 'p4-diff-mode)

      (p4-run (cons "describe" describe-args))

      ;; Since we are interested in showing the files in the changelist, only show the
      ;; first line of the description.

      (let ((inhibit-read-only t))
        (goto-char (point-min))
        (forward-line 3) ;; move past first line of description
        (let ((start-point (point)))
          (when (re-search-forward "^Affected files \\.\\.\\." nil t)
            (beginning-of-line)
            (delete-region start-point (point))
            (insert "\n")))

        (with-temp-buffer
          (setq describe-args `("-S" ,@describe-args))
          (p4-run (cons "describe" describe-args))
          (goto-char (point-min))
          (when (re-search-forward "^Shelved files \\.\\.\\." nil t)
            (beginning-of-line)
            (let ((start-point (point)))
              (forward-line 2)
              (when (looking-at "^\\.\\.\\. ") ;; have shelved files?
                (setq shelved-files (buffer-substring start-point (point-max)))))))

        (when shelved-files
          (goto-char (point-max))
          (insert shelved-files))

        (p4-activate-diff-buffer)

        (goto-char (point-min))))

    (display-buffer files-buf)))

(defp4cmd ;; defun p4-describe
 p4-describe (&rest args)
 "describe"
 "Display a changelist description using p4 describe with
`p4-default-describe-options'"
 (interactive (p4-read-args "p4 describe: "
                            (concat p4-default-describe-options " "
                                    (if (thing-at-point 'number)
                                        (format "%s" (thing-at-point 'number))))))
 (p4-call-command "describe" args :mode 'p4-diff-mode
                  :callback 'p4-activate-diff-buffer))

(defun p4-describe-click-callback (changelist-num)
  "Perforce describe click callback.
Called when one on clicks (RET) on a changelist number in a buffer
such as that created by `p4-describe' and similar functions.
CHANGELIST-NUM is the Perforce changelist number."
  (let ((args-to-use (p4-read-args
                      "Run p4 describe (with args): "
                      (concat p4-default-describe-options " " changelist-num))))
    (p4-call-command "describe" args-to-use :mode 'p4-diff-mode
                     :callback (lambda ()
                                 (p4-activate-diff-buffer)
                                 (goto-char (point-min))))))

(defun p4-describe-with-diff ()
  "Run p4 describe with `p4-default-describe-diff-options'."
  (interactive)
  (let ((p4-default-describe-options p4-default-describe-diff-options))
    (call-interactively 'p4-describe)))

(defp4cmd* ;; defun p4-diff
 diff
 "Display diff of client file with depot file."
 (cons p4-default-diff-options (p4-context-filenames-list))
 (p4-call-command cmd args :mode 'p4-diff-mode
                  :callback 'p4-activate-diff-buffer))

(defun p4--get-diff-options ()
  "Get p4 diff options.
-du or -duN is required because Emacs works best when diff'ing unified diffs.
See `p4-default-diff-options` or `p4-help` diff for options."
  (let (ok
        options)
    (while (not ok)
      (setq options (p4-read-args "p4 diff options (e.g. '-du -dw' to ignore whitespace): "
                                  p4-default-diff-options))
      (dolist (opt options)
        (when (string-match "^-du[0-9]*$" opt)
          (setq ok t)))
      (when (not ok)
        (message "-du or -duN (unified diff option) is required")
        (sit-for 3)))
    ;; answer
    options))

(defun p4-diff-all-opened ()
  "View unified diff all opened files."
  (interactive)
  (p4-diff (p4--get-diff-options)))

(defun p4-activate-diff-side-by-side-buffer ()
  "Activate side-by-side unified diff."
  (p4-activate-diff-buffer)
  (if (fboundp 'diffview-current)
      (diffview-current)
    (message "Install https://github.com/mgalgs/diffview-mode to view unified diff side-by-side")))

(defun p4-diff-all-opened-side-by-side ()
  "View unified diff of all opened files side-by-side."
  (interactive)
  (p4-call-command "diff" (p4--get-diff-options)
                   :mode 'p4-diff-mode
                   :callback 'p4-activate-diff-side-by-side-buffer))

(defun p4-get-file-rev (rev)
  "Return the full filespec corresponding to revision REV.
Uses the context to determine the filename if necessary."
  (cond ((integerp rev)
         (format "%s#%d" (p4-context-single-filename) rev))
        ((string-match "^\\([1-9][0-9]*\\|none\\|head\\|have\\)$" rev)
         (format "%s#%s" (p4-context-single-filename) rev))
        ((string-match "^\\(?:[#@]\\|$\\)" rev)
         (format "%s%s" (p4-context-single-filename) rev))
        (t
         rev)))

(defp4cmd ;; defun p4-diff2
 p4-diff2 (&rest args)
 "diff2"
 "Compare one set of depot files to another."
 (interactive
  (if current-prefix-arg
      (p4-read-args* "p4 diff2: " (concat p4-default-diff-options " ") 'branch)
    (let* ((rev (or (get-char-property (point) 'rev) 0))
           (rev1 (p4-read-arg-string
                  "First filespec/revision to diff: "
                  (when (> rev 1) (number-to-string (1- rev)))))
           (rev2 (p4-read-arg-string
                  "Second filespec/revision to diff: "
                  (when (> rev 1) (number-to-string rev))))
           (opts (p4-read-arg-string
                  "Optional arguments: "
                  (concat p4-default-diff-options " "))))
      (append (p4-make-list-from-string opts)
              (mapcar 'p4-get-file-rev (list rev1 rev2))))))
 (p4-call-command "diff2" args
                  :mode 'p4-diff-mode :callback 'p4-activate-diff-buffer))

(defun p4-activate-ediff-callback ()
  "Perforce activate ediff callback.
Return a callback function that runs ediff on the current
buffer and the P4 output buffer."
  (let ((orig-buffer (current-buffer)))
    (lambda ()
      (when (buffer-live-p orig-buffer)
        (p4-fontify-print-buffer t)
        (let ((depot-buffer (current-buffer)))
          ;; Buffer with changes should be on right to be consistent with tools
          ;; like cgit, reviewboard, etc.
          (ediff-buffers depot-buffer orig-buffer))))))

(defun p4--get-file-to-diff ()
  "Perforce get file to diff.
To support p4-ediff and friends on a p4-opened buffer, we need
to switch to the file to diff"
  (let ((file (p4-context-single-filename)))
    (when (not (buffer-file-name))
      (setq file (p4-depot-find-file file)))
    file))

(defun p4-ediff-with-head ()
  "Use ediff to compare file with the head (tip) of the branch the file is on."
  (interactive)
  (p4-call-command "print" (list (concat (p4--get-file-to-diff) "#head"))
                   :after-show (p4-activate-ediff-callback)))

(defun p4-ediff (prefix)
  "Use ediff to compare file with its original client version.
If PREFIX specified, run interactively p4-ediff2."
  (interactive "P")
  (if prefix
      (call-interactively 'p4-ediff2)
    (p4-call-command "print" (list (concat (p4--get-file-to-diff) "#have"))
                     :after-show (p4-activate-ediff-callback))))

(defun p4-activate-ediff2-callback (other-file)
  "Return a ediff callback function.
This callback will runs ediff on the P4 output buffer and OTHER-FILE."
  (let ((other-file other-file))
    (lambda ()
      (p4-fontify-print-buffer t)
      (p4-call-command "print" (list other-file)
                       :after-show (p4-activate-ediff-callback)))))

(defun p4-ediff2 (rev1 rev2)
  "Use ediff to compare REV1 and REV2 of a depot file.
When visiting a depot file, type \\[p4-ediff2] and enter the versions."
  (interactive
   (let ((rev (or (get-char-property (point) 'rev) 0)))
     (list (p4-read-arg-string "First filespec/revision to diff: "
                               (when (> rev 1) (number-to-string (1- rev))))
           (p4-read-arg-string "Second filespec/revision to diff: "
                               (when (> rev 1) (number-to-string rev))))))
  (p4-call-command "print" (list (p4-get-file-rev rev1))
                   :after-show (p4-activate-ediff2-callback (p4-get-file-rev rev2))))

(defun p4-ediff-file-at-point ()
  "Use ediff to compare the version of the depot file at point.
Compares against the prior version.  The depot file must look like
  //branch/path/to/file.ext#REV"
  (interactive)
  (let ((depot-file (get-char-property (point) 'link-depot-name))
        rev
        prior-depot-file)
    (when (not depot-file)
      (setq depot-file (thing-at-point 'filename))
      (if (not (and depot-file
                    (string-match "^\\(//.+\\)#\\([0-9]+\\)$" depot-file)))
          (error (concat "Current buffer point is not a Perforce depot file of form "
                         "//branch/path/to/file.ext#REV"))))
    (when (not (string-match "^\\(//.+\\)#\\([0-9]+\\)$" depot-file))
      (error "Assert, %s, is not of form //branch/path/to/file#REV" depot-file))
    (setq rev (match-string 2 depot-file))
    (if (equal rev "1")
        (p4-call-command "print" (list depot-file) :callback 'p4-activate-print-buffer)
      (setq prior-depot-file (format "%s#%d" (match-string 1 depot-file)
                                     (- (string-to-number rev) 1)))
      (p4-call-command "print" (list depot-file)
                       :after-show (p4-activate-ediff2-callback prior-depot-file)))))

(defun p4-edit-pop-up-output-p ()
  "Should we show the output of p4 edit?
Returns t if output contains a line and possibly a second
continuation line \"... also opened by\", otherwise returns nil,
meaning we need to show more output in a popup window."
  (save-excursion
    (goto-char (point-min))
    (not (looking-at ".*\n\\(?:\\.\\.\\. .*\n\\)*\\'"))))

(defp4cmd* ;; defun p4-edit
 edit
 "Open an existing file for edit."
 (p4-context-filenames-and-maybe-pending)
 (p4-call-command cmd args
                  :mode 'p4-basic-list-mode
                  :pop-up-output 'p4-edit-pop-up-output-p
                  :callback (p4-refresh-callback 'p4-edit-hook)))

(defp4cmd* ;; defun p4-filelog
 filelog
 "List revision history of files."
 (p4-context-filenames-list)
 (p4-file-change-log cmd args t))

(defp4cmd* ;; defun p4-files
 files
 "List files in the depot."
 (p4-context-filenames-list)
 (p4-call-command cmd args :mode 'p4-basic-list-mode))

(defp4cmd ;; defun p4-fix
 p4-fix (&rest args)
 "fix"
 "Mark jobs as being fixed by the specified changelist."
 (interactive (p4-read-args "p4 fix: " "" 'job))
 (p4-call-command "fix" args))

(defp4cmd* ;; defun p4-fixes
 fixes
 "List jobs with fixes and the changelists that fix them."
 nil
 (p4-call-command cmd args :callback 'p4-activate-fixes-buffer
                  :pop-up-output (lambda () t)))

(defp4cmd* ;; defun p4-flush
 flush
 "Synchronize the client with its view of the depot (without copying files)."
 nil
 (p4-call-command cmd args :mode 'p4-basic-list-mode))

(defp4cmd* ;; defun p4-fstat
 fstat
 "Dump file info."
 (p4-context-filenames-list)
 (p4-call-command cmd args))

(defp4cmd ;; defun p4-grep
 p4-grep (&rest args)
 "grep"
 "Print lines matching a pattern."
 (interactive (p4-read-args "p4 grep: " '("-e  ..." . 3)))
 (p4-ensure-logged-in)
 (p4-compilation-start
  (append (list "grep" "-n") args)
  'p4-grep-mode))

(defp4cmd ;; defun p4-group
 p4-group (&rest args)
 "group"
 "Change members of user group."
 (interactive (p4-read-args* "p4 group: " "" 'group))
 (p4-form-command "group" args))

(defp4cmd ;; defun p4-groups
 p4-groups (&rest args)
 "groups"
 "List groups (of users)."
 (interactive (p4-read-args* "p4 groups: " "" 'group))
 (p4-call-command "groups" args
                  :callback (lambda ()
                              (p4-regexp-create-links "^\\(.*\\)\n" 'group
                                                      "Describe group"))))

(defp4cmd ;; defun p4-unload
 p4-unload (&rest args)
 "unload"
 "Unload a client, label, or task stream to the unload depot"
 (interactive
  (let* ((client (p4-current-client))
         (initial-args (if client (concat "-c " (p4-current-client)))))
    (p4-read-args "p4 unload: " initial-args 'client)))
 (p4-call-command "unload" args))

(defp4cmd ;; defun p4-reload
 p4-reload (&rest args)
 "reload"
 "Reload an unloaded client, label, or task stream"
 (interactive
  (let* ((client (p4-current-client))
         (initial-args (if client (concat "-c " (p4-current-client)))))
    (p4-read-args "p4 reload: " initial-args 'client)))
 (p4-call-command "reload" args))

(defp4cmd* ;; defun p4-have
 have
 "List the revisions most recently synced to the current workspace."
 (p4-context-filenames-list)
 (p4-call-command cmd args
                  :mode 'p4-basic-list-mode
                  :pop-up-output (lambda () t)))

(defp4cmd ;; defun p4-help
 p4-help (&rest args)
 "help"
 "Print help message."
 (interactive (p4-read-args "p4 help: " "" 'help))
 (p4-call-command "help" args
                  :callback (lambda ()
                              (let ((case-fold-search))
                                (cl-loop for re in '("\\<p4\\s-+help\\s-+\\([a-z][a-z0-9]*\\)\\>"
                                                     "'p4\\(?:\\s-+-[a-z]+\\)*\\s-+\\([a-z][a-z0-9]*\\)\\>"
                                                     "^\t\\([a-z][a-z0-9]*\\) +[A-Z]")
                                         do (p4-regexp-create-links re 'help))))))

(defp4cmd ;; defun p4-info
 p4-info ()
 "info"
 "Display client/server information."
 (interactive)
 (p4-call-command "info" nil :mode 'conf-colon-mode))

(defp4cmd ;; defun p4-integ
 p4-integ (&rest args)
 "integ"
 "Integrate one set of files into another."
 (interactive (p4-read-args "p4 integ: " "-b "))
 (p4-call-command "integ" args :mode 'p4-basic-list-mode))

(defun p4-job-success (cmd buffer)
  "Perforce job success for CMD, BUFFER."
  (ignore cmd)
  (let ((job (with-current-buffer buffer
               (when (looking-at "Job \\(.+\\) saved\\.$")
                 (match-string 1)))))
    (when job
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (when (re-search-forward "Job:\\s-+\\(new\\)$" nil t)
            (replace-match job t t nil 1)
            (rename-buffer (p4-process-buffer-name (list "job" "-o" job)))
            (set-buffer-modified-p nil)))))))

(defvar p4-job-head-text
  (format "# Created using Perforce-Emacs Integration version %s.
# Type C-c C-c to update the job description on the server.
# Type C-c C-f to show the fixes associated with this job.
# Type C-x k to cancel the operation.
#\n" p4-version)
  "Text added to top of job form.")

(defp4cmd ;; defun p4-job
 p4-job (&rest args)
 "job"
 "Create or edit a job (defect) specification."
 (interactive (p4-read-args* "p4 job: " "" 'job))
 (p4-form-command "job" args :move-to "Description:\n\t"
                  :mode 'p4-job-form-mode
                  :head-text p4-job-head-text
                  :success-callback 'p4-job-success))

(defp4cmd* ;; defun p4-jobs
 jobs
 "Display list of jobs."
 nil
 (p4-call-command cmd args
                  :callback (lambda () (p4-find-jobs (point-min) (point-max)))))

(defp4cmd ;; defun p4-jobspec
 p4-jobspec ()
 "jobspec"
 "Edit the job template."
 (interactive)
 (p4-form-command "jobspec"))

(defp4cmd ;; defun p4-label
 p4-label (&rest args)
 "label"
 "Create or edit a label specification."
 (interactive (p4-read-args "p4 label: " "" 'label))
 (if args
     (p4-form-command "label" args :move-to "Description:\n\t")
   (error "Label must be specified!")))

(defp4cmd* ;; defun p4-labels
 labels
 "Display list of defined labels."
 nil
 (p4-call-command cmd args
                  :callback (lambda ()
                              (p4-regexp-create-links "^Label \\([^ \t\n]+\\).*\n" 'label
                                                      "Describe label"))))

(defp4cmd ;; defun p4-labelsync
 p4-labelsync (&rest args)
 "labelsync"
 "Apply the label to the contents of the client workspace."
 (interactive (p4-read-args* "p4 labelsync: "))
 (p4-call-command "labelsync" args :mode 'p4-basic-list-mode))

(defp4cmd* ;; defun p4-lock
 lock
 "Lock an open file to prevent it from being submitted."
 (p4-context-filenames-list)
 (p4-call-command cmd args :callback (p4-refresh-callback)))

(defp4cmd* ;; defun p4-login
 login
 "Log in to Perforce by obtaining a session ticket."
 nil
 (if (member "-s" args)
     (p4-call-command cmd args)
   (let ((first-iteration t)
         (logged-in nil)
         (prompt "Enter password for %s: "))
     (while (not logged-in)
       (with-temp-buffer
         (or (and first-iteration (stringp p4-password-source)
                  (let ((process-environment (p4-current-environment)))
                    (zerop (call-process-shell-command p4-password-source
                                                       nil '(t nil)))))
             (insert (read-passwd (format prompt (p4-current-server-port))) "\n"))
         (setq first-iteration nil)
         (p4-with-coding-system
          (apply #'p4-call-process-region (point-min) (point-max)
                 t t nil cmd "-a" args))
         (goto-char (point-min))
         (when (re-search-forward "Enter password:.*\n" nil t)
           (replace-match ""))
         (goto-char (point-min))
         (if (looking-at "Password invalid")
             (setq prompt "Password invalid. Enter password for %s: ")
           (setq logged-in t)
           (message "%s" (buffer-substring (point-min) (1- (point-max))))))))))

(defp4cmd* ;; defun p4-logout
 logout
 "Log out from Perforce by removing or invalidating a ticket."
 nil
 (p4-call-command cmd args :auto-login nil))

(defun p4-move-complete-callback (from-file to-file)
  "Perforce move complete callback on FROM-FILE and TO-FILE."
  (let ((from-file from-file) (to-file to-file))
    (lambda ()
      (let ((buffer (get-file-buffer from-file)))
        (when buffer
          (with-current-buffer buffer
            (find-alternate-file to-file)))))))

(defp4cmd ;; defun p4-move
 p4-move (from-file to-file)
 "move"
 "Move file(s) from one location to another.
If the \"move\" command is unavailable, use \"integrate\"
followed by \"delete\"."
 (interactive
  (list
   (p4-read-arg-string "move from: " (p4-context-single-filename))
   (p4-read-arg-string "move to: " (p4-context-single-filename))))
 (p4-call-command "move" (list from-file to-file)
                  :mode 'p4-basic-list-mode
                  :callback (p4-move-complete-callback from-file to-file)))

(defalias 'p4-rename 'p4-move)

(defun p4--opened-get-info (opened-files)
  "Perforce opened get info on OPENED-FILES.
Used by p4-opened to run p4 fstat and return a hash of depotFiles to
\(cons head-rev is-unresolved)"
  (let ((x-file (make-temp-file "p4-x-file-opened-" nil ".txt"))
        (opened-info-table (make-hash-table :test 'equal))
        depotFile
        headRev
        is-unresolved
        bad-content)

    (with-temp-file x-file ;; using (insert) to avoid "wrote x-file" message
      (insert opened-files))

    ;; p4 -x x-file fstat -T "depotFile, headRev"
    ;; Produces
    ;;  ... depotFile //branch/path/to/file1.ext
    ;;  ... headRev NUM
    ;;  <newline>
    ;;  ... depotFile //branch/path/to/file2.ext
    ;;  <newline>      // no headRev when file is a p4 add, delete, dest of move

    (with-temp-buffer
      (p4-run (list "-x" x-file "fstat" "-T" "depotFile, headRev, unresolved"))
      (goto-char (point-min))
      (while (and (not (eobp))
                  (not bad-content))
        (if (looking-at "^\\.\\.\\. depotFile \\([^[:space:]]+\\)$")
            (progn
              (setq depotFile
                    (buffer-substring-no-properties (match-beginning 1) (match-end 1))
                    headRev nil
                    is-unresolved nil)
              (forward-line)
              (when (looking-at "^\\.\\.\\. headRev \\([0-9]+\\)")
                (setq headRev
                      (buffer-substring-no-properties (match-beginning 1) (match-end 1)))
                (forward-line))
              (when (looking-at "^\\.\\.\\. unresolved")
                (setq is-unresolved t)
                (forward-line))
              (if (looking-at "^$")
                  (progn
                    (when headRev
                      (puthash depotFile (cons headRev is-unresolved) opened-info-table))
                    (forward-line))
                ;; unexpected content from p4 fstat
                (setq bad-content t)))
          (setq bad-content t))))

    (when bad-content
      (setq opened-info-table nil))
    ;; answer
    opened-info-table))

(defun p4--opened-internal-move-to-start ()
  "Locate first non-comment line in \"P4 opened\" buffer."
  (goto-char (point-min))
  (while (looking-at "^#")
    (forward-line)))

(defun p4--ztag-opened-entry (name entry-hash &optional is-optional)
  "Get p4 -ztag opened entry NAME from ENTRY-HASH.
If entry NAME does not exist and if IS-OPTIONAL, then return nil,
else assert."
  (or (gethash name entry-hash)
      (if is-optional
          nil
        (error "Assert, p4 -ztag entry name not found: %s" name))))

(defun p4--opened-get-move-adds (moved-files args)
  "Run p4 -ztag opened MOVED-FILES ARGS to get move-adds hash."
  (let ((args-file (make-temp-file "p4-el-opened-moved-" nil ".txt"))
        (move-adds (make-hash-table :test 'equal)) ;; movedFile -> opened-line
        (ztag-entry-re "^\\.\\.\\. \\([^ ]+\\) \\(.+\\)$"))
    (with-temp-file args-file ;; using (insert) to avoid "wrote x-file" message
      (insert moved-files))
    (with-temp-buffer
      (p4-run (append `("-x" ,args-file "-ztag" "opened") args))
      (when (looking-at ztag-entry-re)
        (while (not (eobp))
          ;; Skip blank lines
          (while (and (not (eobp)) (looking-at "^[ \t]*$"))
            (forward-line))
          ;; Parse at entry
          (when (not (eobp))
            (let (depotFile movedFile rev action change type line)
              (while (looking-at ztag-entry-re)
                (let ((field (match-string 1))
                      (value (match-string 2)))
                  (cond
                   ((string= field "depotFile")
                    (setq depotFile value))
                   ((string= field "movedFile")
                    (setq movedFile value))
                   ((string= field "rev")
                    (setq rev value))
                   ((string= field "action")
                    (setq action value))
                   ((string= field "change")
                    (setq change value))
                   ((string= field "type")
                    (setq type value)))
                  (forward-line)))
              (setq line (concat depotFile (when rev (concat "#" rev ))
                                 " - " action " " change " change"
                                 (when type (concat " (" type ")")) "\n"))
              ;; When -s is used as in p4 -ztag opened -s (or -as, etc.), we have less fields
              ;; and the move sorting will not work. With -s, movedFile, rev, type are not
              ;; present.
              (when (string= action "move/add")
                (puthash movedFile line move-adds) ;; stow line for later insertion
                ))))))
    (delete-file args-file)
    move-adds))

(defun p4--opened-sorted (args)
  "Run p4 opened ARGS with sorting.
By default p4 opened ARGS sorts the results.  This means
that you see things like:
  //branch/path/to/a.txt#3 - move/delete default change (text)
  //branch/path/to/b.txt#7 - move/delete default change (text)
  //branch/path/to/c.txt#2 - edit default change (text)
  //branch/path/to/y/r.txt#1 - move/add default change (text)
  //branch/path/to/z/t.txt#1 - move/add default change (text)
where p4 move a.txt y/r.txt and p4 move b.txt y/r.txt.  We produce:
  //branch/path/to/a.txt#3 - move/delete default change (text); move[1]
  //branch/path/to/z/t.txt#1 - move/add default change (text); move[1]
  //branch/path/to/b.txt#7 - move/delete default change (text); move[2]
  //branch/path/to/y/r.txt#1 - move/add default change (text); move[2]
  //branch/path/to/c.txt#2 - edit default change (text)
We annotate each move line with a move[count] to show the entries are paired.
To achieve this, we use p4 -ztag opened ARGS to get the connection
between move/delete and move/add actions and then format the
output matching p4 opened ARGS, but with the move/delete and
move/add actions grouped together."
  ;; Example for p4 move a.txt y/r.txt:
  ;;  ... depotFile //branch/path/to/a.txt             (1)
  ;;  ... movedFile //branch/path/to/y/r.txt
  ;;  ... rev 3
  ;;  ... action move/delete
  ;;
  ;;  ... depotFile //branch/path/to/y/r.txt
  ;;  ... movedFile //branch/path/to/a.txt             (2)
  ;;  ... rev 1
  ;;  ... action move/add
  ;; Notice that for the move/add, (2) connects to the moved/delete via (1).

  (p4-run (cons "opened" args))
  (let (moved-files)
    (while (re-search-forward "^\\([^# ]+\\)#[0-9]+ - move/\\(?:add\\|delete\\)" nil t)
      (setq moved-files (concat moved-files (match-string 1) "\n")))
    (when moved-files
      (let ((move-adds (p4--opened-get-move-adds moved-files args))
            (inhibit-read-only t)
            (move-count 1))

        ;; Delete move/add entry lines
        (goto-char (point-min))
        (while (re-search-forward "^\\([^# ]+\\)#[0-9]+ - move/add" nil t)
          (delete-region (line-beginning-position)
                         (save-excursion (forward-line) (line-beginning-position))))

        ;; Add in the move/add entry lines after the corresponding move/delete line
        (goto-char (point-min))
        (while (re-search-forward "^\\([^# ]+\\)#[0-9]+ - move/delete" nil t)
          (let* ((depotFile (match-string 1))
                 (line (gethash depotFile move-adds))
                 (move-count-label (format "; move[%d]" move-count)))
            (setq move-count (1+ move-count))
            (end-of-line)
            (insert move-count-label)
            (forward-line) ;; insert move/add line after current move/delete line
            ;; Consider: p4 edit a.txt; p4 move a.txt y/r.txt; p4 -ztag opened -m 1
            ;; We'll only have the moved/delete entry, hence no move/add line to insert.
            (when line
              (insert (replace-regexp-in-string "\n$" (concat move-count-label "\n") line)))))
        (goto-char (point-min))))))

(defun p4--opened-internal (args)
  "Perforce opened ARGS implementation.
Use both \"p4 opened\" and \"p4 fstat\" to display \"P4 opened <dir>\"
containing //branch/path/to/file.exe#REV OPENED_INFO; head#HEAD_REV
where HEAD_REV is highlighted if it is different from REV."
  (when p4-follow-symlinks
    (p4-refresh-buffer-with-true-path))
  (let ((opened-buf (p4-process-buffer-name (cons "opened" args))))
    (with-current-buffer (p4-make-output-buffer opened-buf 'p4-opened-list-mode)

      (setq p4--opened-args args) ;; for refresh

      (p4--opened-sorted args)

      (let ((inhibit-read-only t))
        (goto-char (point-min))
        (when (looking-at "^//")
          (insert "\
# keys- r: p4 revert  c: p4 reopen -c CHANGENUM  t: p4 reopen -t FILETYPE  g: refresh p4 opened
#       n/p: {next/prev}-line  k/j: {down/up}-line  d/u: {down/up}-page  </>: top/bottom
#       RET: visit-file  'C-c p KEY': run p4 command  'C-c p -': p4-ediff
")))
      (p4--opened-internal-move-to-start)

      ;; Each line of current buffer should contain
      ;;    //branch/path/to/file.exe#REV OPENED_INFO
      ;; Set opened-files containing "//branch/path/to/file.exe\n" lines
      (let (bad-content) ;; bad content occurs when p4 opened was invoked outside of a workspace

        (while (and (not (eobp)) ;; look for bad-content
                    (not bad-content))
          (when (not (looking-at "^\\(//[^ #]+\\)"))
            (setq bad-content t))
          (forward-line))
        (p4--opened-internal-move-to-start)

        (when (not bad-content)
          ;; p4 opened content is good, now run p4 fstat and load
          ;; opened-info-table with KEY = depotFile, VALUE = (cons headRev is-unresolved)
          (let* ((opened-files (replace-regexp-in-string
                                "#[0-9]+ - .+$" ""
                                (buffer-substring-no-properties (point) (point-max))))
                 (opened-info-table (p4--opened-get-info opened-files)))

            (when opened-info-table
              ;; Augment the p4 opened lines with the headRev's
              (let ((inhibit-read-only t))
                (p4--opened-internal-move-to-start)
                (while (and (not (eobp))
                            (not bad-content))
                  (if (looking-at "^\\(//[^ #]+\\)#\\([0-9]+\\)")
                      (let* ((depotFile (buffer-substring-no-properties
                                         (match-beginning 1) (match-end 1)))
                             (haveRev (buffer-substring-no-properties
                                       (match-beginning 2) (match-end 2)))
                             (opened-info (gethash depotFile opened-info-table))
                             (headRev (car opened-info))
                             (is-unresolved (cdr opened-info)))
                        (when headRev
                          (move-end-of-line 1)
                          (let ((opened-info-text
                                 (concat (if (string= haveRev headRev) "; head#" "; HEAD#") headRev
                                         (when is-unresolved "; NEEDS-RESOLVE"))))
                            (insert opened-info-text)))
                        (forward-line))
                    (setq bad-content t))))))))
      (p4--opened-internal-move-to-start))
    (display-buffer opened-buf)))

(defp4cmd* ;; defun p4-opened
 opened
 "List open files and display file status."
 (progn
   (p4-set-default-directory-to-root)
   nil)
 (ignore cmd)
 (p4--opened-internal args))

(defp4cmd* ;; defun p4-print
 print
 "Write a depot file to a buffer."
 (p4-context-single-filename-revision-args)
 (p4-call-command cmd args :callback 'p4-activate-print-buffer))

(defp4cmd ;; defun p4-passwd
 p4-passwd (old-pw new-pw new-pw2)
 "passwd"
 "Set the user's password on the server (and Windows client)."
 (interactive
  (list (read-passwd "Enter old password: ")
        (read-passwd "Enter new password: ")
        (read-passwd "Re-enter new password: ")))
 (if (string= new-pw new-pw2)
     (p4-call-command "passwd" (list "-O" old-pw "-P" new-pw2))
   (error "Passwords don't match")))

(defp4cmd* ;; defun p4-reconcile
 reconcile
 "Open files for add, delete, and/or edit to reconcile client
with workspace changes made outside of Perforce."
 '("...")
 (p4-call-command cmd args :mode 'p4-basic-list-mode))

(defun p4-refresh (&optional args)
  "Run p4 sync -f ARGS to refresh the contents of an unopened file."
  (interactive
   (when (or p4-prompt-before-running-cmd current-prefix-arg)
     (let* ((args (cons "-f" (p4-context-filenames-list)))
            (args-string (p4-join-list args)))
       (list (p4-read-args "Run p4 sync (with args): " args-string)))))
  (p4-call-command "sync" args :mode 'p4-basic-list-mode))

(defp4cmd* ;; defun p4-reopen
 reopen
 "Change the filetype of an open file or move it to another
changelist."
 (p4-context-filenames-list)
 (p4-call-command cmd args :mode 'p4-basic-list-mode
                  :callback (p4-refresh-callback)))

(defp4cmd* ;; defun p4-resolve
 resolve
 "Resolve integrations and updates to workspace files."
 (list (concat p4-default-resolve-options " "))
 (let (buffer (buf-name "P4 resolve"))
   (setq buffer (get-buffer buf-name))
   (if (and (buffer-live-p buffer)
            (not (comint-check-proc buffer)))
       (let ((cur-dir default-directory))
         (with-current-buffer buffer
           (cd cur-dir)
           (goto-char (point-max))
           (insert "\n--------\n\n"))))
   (setq args (cons cmd args))
   (let ((process-environment (cons "P4PAGER=" process-environment)))
     (p4-ensure-logged-in)
     (setq buffer (apply #'p4-make-comint "P4 resolve" nil args)))
   (switch-to-buffer-other-window buffer)
   (goto-char (point-max))))

(defvar p4-empty-diff-regexp
  "\\(?:==== .* ====\\|--- .*\n\\+\\+\\+ .*\\)\n\\'"
  "Regular expression matching p4 diff output when there are no changes.")

(defp4cmd* ;; defun p4-revert
 revert
 "Discard changes from an opened file."
 (p4-context-filenames-list)
 (let ((prompt (not p4-prompt-before-running-cmd)))
   (when (or (not prompt) (yes-or-no-p "Really revert? "))
     (p4-call-command cmd args :mode 'p4-basic-list-mode
                      :callback (p4-refresh-callback)))))

(defun p4-revert-non-file (args)
  "Run p4 revert without defaulting to a file using ARGS."
  (interactive
   (when (or p4-prompt-before-running-cmd current-prefix-arg)
     (list (p4-read-args "Run p4 revert (with args): "))))
  (p4-call-command "revert" args :mode 'p4-basic-list-mode))


(defun p4-revert-dwim ()
  "Run p4 revert on current buffer if visiting a file, else p4 revert."
  (interactive)
  (if (or buffer-file-name
          (p4-context-filenames-list nil t))
      (call-interactively 'p4-revert)
    (call-interactively 'p4-revert-non-file)))

(defp4cmd ;; defun p4-set
 p4-set ()
 "set"
 "Set or display Perforce variables."
 (interactive)
 (p4-call-command "set" nil :mode 'conf-mode))

(defun p4-shelve-failure (cmd buffer)
  "Perforce shelve failure for CMD, BUFFER."
  ;; The failure might be because no files were shelved. But the
  ;; change was created, so this counts as a success for us.
  (if (with-current-buffer buffer
        (looking-at "^Change \\([0-9]+\\) created\\.\nShelving files for change \\1\\.\nNo files to shelve\\.$"))
      (p4-change-success cmd buffer)
    (p4-form-commit-failure-callback-default cmd buffer)))

(defp4cmd ;; defun p4-shelve
 p4-shelve (&optional args)
 "shelve"
 "Store files from a pending changelist into the depot."
 (interactive
  (cond ((integerp current-prefix-arg)
         (list (format "%d" current-prefix-arg)))
        ((or p4-prompt-before-running-cmd current-prefix-arg)
         (list (p4-read-args "Run p4 shelve (with args): " "" 'pending)))))
 (save-some-buffers)
 (p4-form-command "change" args :move-to "Description:\n\t"
                  :commit-cmd "shelve"
                  :success-callback 'p4-change-success
                  :failure-callback 'p4-shelve-failure))

(defp4cmd* ;; defun p4-status
 status
 "Identify differences between the workspace with the depot."
 '("...")
 (p4-call-command cmd args :mode 'p4-status-list-mode))

(defun p4-empty-diff-buffer ()
  "Perforce empty diff buffer.
If there exist any files opened for edit with an empty diff,
return a buffer listing those files.  Otherwise, return NIL."
  (let ((args (list "diff" "-sr")))
    (with-current-buffer (p4-make-output-buffer (p4-process-buffer-name args))
      (when (zerop (p4-run args))
        ;; The output of p4 diff -sr can be:
        ;; "File(s) not opened on this client." if no files opened at all.
        ;; "File(s) not opened for edit." if files opened (but none for edit)
        ;; Nothing if files opened for edit (but all have changes).
        ;; List of filenames (otherwise).
        (if (or (eobp) (looking-at "File(s) not opened"))
            (progn (kill-buffer (current-buffer)) nil)
          (current-buffer))))))

(defun p4-submit-success (cmd buffer)
  "Perforce submit success for CMD, BUFFER."
  (ignore cmd)
  (p4-change-update-form
   buffer
   "submitted"
   "^Change \\(?:[0-9]+ renamed change \\)?\\([0-9]+\\)\\(?: and\\)? submitted\\.$"))

(defun p4-submit-failure (cmd buffer)
  "Perforce submit failure for CMD, BUFFER."
  (ignore cmd)
  (p4-change-update-form
   buffer
   "pending"
   "^Submit failed -- fix problems above then use 'p4 submit -c \\([0-9]+\\)'\\.$")
  (with-current-buffer buffer
    (p4-process-show-error "Perforce submit -i failed to complete successfully")))

(defvar p4-submit-head-text
  (format "# Created using Perforce-Emacs Integration version %s.
# Type C-c C-c to submit the change to the server.
# Type C-c C-p to save the change description as a pending changelist.
# Type C-x k to cancel the operation.
#\n" p4-version)
  "Text added to top of change form.")

(defp4cmd ;; defun p4-submit
 p4-submit (&optional args)
 "submit"
 "Submit open files to the depot."
 (interactive
  (cond ((integerp current-prefix-arg)
         (list (format "%d" current-prefix-arg)))
        ((or p4-prompt-before-running-cmd current-prefix-arg)
         (list (p4-read-args "Run p4 change (with args): " "" 'pending)))))
 (p4-with-temp-buffer (list "-s" "opened")
                      (unless (re-search-forward "^info: " nil t)
                        (error "Files not opened on this client")))
 (save-some-buffers)
 (let ((empty-buf (and p4-check-empty-diffs (p4-empty-diff-buffer))))
   (when (or (not empty-buf)
             (save-window-excursion
               (pop-to-buffer empty-buf)
               (yes-or-no-p
                "File with empty diff opened for edit, submit anyway? ")))
     (p4-form-command "change" args :move-to "Description:\n\t"
                      :commit-cmd "submit"
                      :mode 'p4-change-form-mode
                      :head-text p4-submit-head-text
                      :success-callback 'p4-submit-success
                      :failure-callback 'p4-submit-failure))))

(defp4cmd* ;; defun p4-sync
 sync
 "Synchronize the client with its view of the depot."
 nil
 (let (p4-default-directory) ;; use default-directory
   (p4-call-command cmd args :mode 'p4-basic-list-mode)))

(defp4cmd ;; defun p4-sync-changelist
 p4-sync-changelist (num)
 "sync"
 "Run p4 sync @=CHANGE_NUM to sync ONLY the contents of a specific
changelist number"
 (interactive "nChangelist number: ")
 (setq num (number-to-string num))
 (if (not (string-match "^[0-9]+$" num))
     (error "Changelist number must be an integer"))
 (if (yes-or-no-p
      (format
       (concat
        "Warning sync'ing a specific changelist can corrupt your sandbox.\n"
        "'p4 sync @=%s' syncs to that changelevel scoped to the files in changelist %s.\n"
        "Continue? ") num num))
     (p4-call-command "sync" (list (concat "@=" num))
                      :mode 'p4-basic-list-mode)))

;; (p4-file-change-log "sync" (list (concat "@=" num))))

(defalias 'p4-get 'p4-sync)

(defp4cmd* ;; defun p4-tickets
 tickets ;; p4-tickets
 "Display list of session tickets for this user."
 nil
 (p4-call-command cmd args))

(defp4cmd* ;; defun p4-unlock
 unlock
 "Release a locked file, leaving it open."
 (p4-context-filenames-list)
 (p4-call-command cmd args :callback (p4-refresh-callback)))

(defp4cmd ;; defun p4-unshelve
 p4-unshelve (&rest args)
 "unshelve"
 "Restore shelved files from a pending change into a workspace."
 (interactive
  (if (or p4-prompt-before-running-cmd current-prefix-arg)
      (p4-read-args "Run p4 unshelve (with args): " "" 'shelved)
    (append (list "-s" (p4-completing-read 'shelved "Unshelve from: "))
            (when p4-open-in-changelist
              (list "-c" (p4-completing-read 'pending "Open in change: "))))))
 (p4-call-command "unshelve" args :mode 'p4-basic-list-mode))

(defp4cmd* ;; defun p4-update
 update
 "Synchronize the client with its view of the depot (with safety check).
Alias for \"sync -s\"."
 nil
 (p4-call-command cmd args :mode 'p4-basic-list-mode))

(defp4cmd ;; defun p4-user
 p4-user (&rest args)
 "user"
 "Create or edit a user specification."
 (interactive (p4-read-args* "p4 user: " "" 'user))
 (p4-form-command "user" args))

(defp4cmd ;; defun p4-users
 p4-users (&rest args)
 "users"
 "List Perforce users."
 (interactive (p4-read-args* "p4 users: " "" 'user))
 (p4-call-command "users" args
                  :callback (lambda ()
                              (p4-regexp-create-links "^\\([^ \t\n]+\\).*\n" 'user
                                                      "Describe user"))))

(defp4cmd* ;; defun p4-where
 where
 "Show how file names are mapped by the client view."
 (p4-context-filenames-list)
 (p4-call-command cmd args))


;;; Output decoration:

(defun p4-create-active-link (start end prop-list &optional help-echo)
  "Perforce create active link.
Uses START, END, PROP-LIST with optional HELP-ECHO."
  (add-text-properties start end prop-list)
  (add-text-properties start end '(active t face bold mouse-face highlight))
  (when help-echo
    (add-text-properties start end
                         `(help-echo ,(concat "mouse-1: " help-echo)))))

(defun p4-create-active-link-group (group prop-list &optional help-echo)
  "Perforce create active link GROUP for PROP-LIST with optional HELP-ECHO."
  (p4-create-active-link (match-beginning group) (match-end group)
                         prop-list help-echo))

(defun p4-file-change-log (cmd file-list-spec &optional no-prompt)
  "Run p4 CMD FILE-LIST-SPEC (e.g. p4 filelog foo.cpp)
Specify NO-PROMPT as t when caller is going to re-prompt."
  (when (and p4-prompt-before-running-cmd (not no-prompt))
    (let* ((args file-list-spec)
           (args-string (p4-join-list args)))
      (setq file-list-spec (p4-read-args (format "Run p4 %s (with args): " cmd) args-string))))
  (p4-call-command cmd (cons "-l" (cons "-t" file-list-spec))
                   :mode 'p4-filelog-mode
                   :callback 'p4-activate-file-change-log-buffer))

(defvar p4-filelog-mode-head-text
  "# keys- s: short-format  l: long-format  n: goto-next-item  p: goto-prev-item
#  RET: run-action-at-point  f: find-file-other-window  e: p4-ediff2  D: p4-diff2
#  ScrollOtherWindow-  k/j: {down/up}-line  d/u: {down/up}-page  </>: top/bottom
"
  "Text added to top of p4 filelog and related buffers.")

(defun p4-activate-file-change-log-buffer ()
  "Perforce activate file change log buffer."
  (save-excursion
    (p4-mark-print-buffer)
    (goto-char (point-min))
    (while (re-search-forward (concat
                               "^\\(\\.\\.\\. #\\([1-9][0-9]*\\) \\)?[Cc]hange "
                               "\\([1-9][0-9]*\\) \\([a-z]+\\)?.*on.*by "
                               "\\([^ @\n]+\\)@\\([^ \n]+\\).*\n"
                               "\\(\\(?:\n\\|[ \t].*\n\\)*\\)")
                              nil t)
      (let* ((rev-match 2)
             (rev (and (match-string rev-match)
                       (string-to-number (match-string rev-match))))
             (ch-match 3)
             (change (string-to-number (match-string ch-match)))
             (act-match 4)
             (action (match-string-no-properties act-match))
             (user-match 5)
             (user (match-string-no-properties user-match))
             (cl-match 6)
             (client (match-string-no-properties cl-match))
             (desc-match 7))
        (when rev
          (p4-create-active-link-group rev-match `(rev ,rev) "Print revision"))
        (p4-create-active-link-group ch-match `(change ,change) "Describe change")
        (when action
          (p4-create-active-link-group act-match `(action ,action rev ,rev)
                                       "Show diff"))
        (p4-create-active-link-group user-match `(user ,user) "Describe user")
        (p4-create-active-link-group cl-match `(client ,client) "Describe client")
        (let ((desc-start-point (match-beginning desc-match))
              (desc-end-point (match-end desc-match)))
          (save-excursion
            (goto-char desc-start-point)
            (when (looking-at "^[ \t]*$")
              (forward-line)
              (add-text-properties desc-start-point (point)
                                   '(invisible t isearch-open-invisible t)))
            ;; keep first description line
            (forward-line)
            (when (< (point) desc-end-point)
              (add-text-properties (point) desc-end-point
                                   '(invisible t isearch-open-invisible t)))))))
    (p4-find-change-numbers (point-min) (point-max))
    (goto-char (point-min))
    (insert p4-filelog-mode-head-text)
    (setq buffer-invisibility-spec (list))))

(defvar p4-plaintext-change-regexp
  (concat "\\(?:[#@]\\|number\\|no\\.\\|\\)\\s-*"
          "\\([1-9][0-9]*\\)[-,]?\\s-*"
          "\\(?:and/or\\|and\\|&\\|or\\|\\)\\s-*")
  "Regexp matching a Perforce change number in plain English text.")

(defun p4-find-change-numbers (start end)
  "Find change numbers.
Scan region between START and END for plain-text references to
change numbers, and make the change numbers clickable."
  (save-excursion
    (save-restriction
      (narrow-to-region start end)
      (goto-char (point-min))
      (while (re-search-forward
              "\\(?:changes?\\|submit\\|p4\\)[:#]?[ \t\n]+" nil t)
        (save-excursion
          (while (looking-at p4-plaintext-change-regexp)
            (p4-create-active-link-group
             1 `(change ,(string-to-number (match-string 1)))
             "Describe change")
            (goto-char (match-end 0))))))))

(defun p4-find-jobs (start end)
  "Perforce find jobs between START and END."
  (save-excursion
    (save-restriction
      (narrow-to-region start end)
      (goto-char (point-min))
      (while (re-search-forward "^\\([^ \n]+\\) on [0-9]+/[0-9]+/[0-9]+ by \\([^ \n]+\\)" nil t)
        (p4-create-active-link-group 1 `(job ,(match-string-no-properties 1))
                                     "Describe job")
        (p4-create-active-link-group 2 `(user ,(match-string-no-properties 2))
                                     "Describe user")))))

(defun p4-mark-depot-list-buffer (&optional print-buffer)
  "Perforce mark depot list buffer.
Optional PRINT-BUFFER should be specified if operating on a p4 print buffer."
  (save-excursion
    (let ((depot-regexp
           (if print-buffer
               "\\(^\\)\\(//[^/@# \n][^/@#\n]*/[^@#\n]+#[1-9][0-9]*\\) - "
             "^\\(\\.\\.\\. [^/\n]*\\|==== \\)?\\(//[^/@# \n][^/@#\n]*/[^#\n]*\\(?:#[1-9][0-9]*\\)?\\)")))
      (goto-char (point-min))
      (while (re-search-forward depot-regexp nil t)
        (let* ((p4-depot-file (match-string-no-properties 2))
               (start (match-beginning 2))
               (end (match-end 2))
               (branching-op-p (and (match-string 1)
                                    (string-match "\\.\\.\\. \\.\\.\\..*"
                                                  (match-string 1))))
               (prop-list `(link-depot-name ,p4-depot-file)))
          ;; some kind of operation related to branching/integration
          (when branching-op-p
            (setq prop-list (append `(history-for ,p4-depot-file
                                                  face p4-depot-branch-face)
                                    prop-list)))
          (p4-create-active-link start end prop-list "Visit file"))))))

(defun p4--noop-run-mode-hooks (&rest hooks)
  "Perforce noop run mode HOOKS."
  (ignore hooks))

(defun p4-fontify-print-buffer (&optional delete-filespec)
  "Fontify a p4-print buffer.
Will fontify according to the filename in the
first line of output from \"p4 print\".  If the optional
argument DELETE-FILESPEC is non-NIL, remove the first line."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "^//[^#@\n]+/\\([^/#@\n]+\\).*\n")
      (let ((file-name (match-string 1))
            (first-line (match-string-no-properties 0))
            (inhibit-read-only t))

        (replace-match "" t t) ;; temporarily remove the first "//branch/blah#123" line

        ;; Consider case where one add a callback to `c++-mode-hook' to activate `lsp-mode' when
        ;; `buffer-file-name' is t. `p4-fontify-print-buffer' needs to set `buffer-file-name' to the
        ;; file base name so `set-auto-mode' can determine the mode for the buffer. However, we
        ;; don't want `set-auto-mode' to call the hook for lsp-mode because the file doesn't exist
        ;; on disk and if we were to call the hook, an error is produced.
        ;;
        ;; Another case is matlab-mode's mlint.el which has a hook to lint the contents of the
        ;; buffer which is assumed to be on disk if buffer-file-name is non-nil.
        ;;
        ;; cl-letf: http://endlessparentheses.com/understanding-letf-and-how-it-replaces-flet.html
        (cl-letf (((symbol-function 'run-mode-hooks) #'p4--noop-run-mode-hooks))
          (let ((buffer-file-name file-name))
            (set-auto-mode)
            (when (fboundp 'font-lock-ensure) ;; emacs 25 or later?
              (font-lock-ensure (point-min) (point-max)))))

        ;; Now turn off the major mode, freezing the fontification so that when we add contents to
        ;; the buffer (such as restoring the first line containing the filespec, or adding
        ;; annotations) these additions don't get fontified.
        (remove-hook 'change-major-mode-hook 'font-lock-change-mode t)
        (when (eq major-mode 'nxml-mode)
          (remove-hook 'change-major-mode-hook 'nxml-cleanup t))
        (fundamental-mode)
        (goto-char (point-min))
        (unless delete-filespec
          (insert first-line))
        (set-buffer-modified-p nil)))))

(defun p4-mark-print-buffer (&optional print-buffer)
  "Perforce mark print buffer using optional PRINT-BUFFER."
  (save-excursion
    (p4-mark-depot-list-buffer print-buffer)
    (let ((depot-regexp
           (if print-buffer
               "^\\(//[^/@# \n][^/@#\n]*/\\)[^@#\n]+#[1-9][0-9]* - "
             "^\\(//[^/@# \n][^/@#\n]*/\\)")))
      (goto-char (point-min))
      (while (re-search-forward depot-regexp nil t)
        (let ((link-client-name (get-char-property (match-end 1)
                                                   'link-client-name))
              (link-depot-name (get-char-property (match-end 1)
                                                  'link-depot-name))
              (start (match-beginning 1))
              (end (point-max)))
          (save-excursion
            (when (re-search-forward depot-regexp nil t)
              (setq end (match-beginning 1))))
          (when link-client-name
            (add-text-properties start end
                                 `(block-client-name ,link-client-name)))
          (when link-depot-name
            (add-text-properties start end
                                 `(block-depot-name ,link-depot-name)))
          (p4-find-change-numbers start
                                  (save-excursion
                                    (goto-char start)
                                    (line-end-position))))))))

(defun p4-activate-print-buffer (&optional delete-filespec)
  "Perforce activate print buffer using optional DELETE-FILESPEC."
  (p4-fontify-print-buffer delete-filespec)
  (p4-mark-print-buffer t)
  (use-local-map p4-basic-mode-map))

(defun p4-buffer-set-face-property (regexp face-property)
  "Perforce buffer set fact property using REGEXP FACE-PROPERTY."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (let ((start (match-beginning 0))
            (end (match-end 0)))
        (add-text-properties start end `(face ,face-property))))))

(defun p4-activate-diff-buffer ()
  "Activate a p4 diff or p4 describe buffer."
  ;; Link //branch/path/to/file.ext#REV to the file system
  (when (or (not (string-match "^P4 describe" (buffer-name))) ;; non p4-describe buffer
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^Change [^\n]+ \\*pending\\*" nil t)))
    (save-excursion
      (save-restriction
        (goto-char (point-min))
        ;; In p4 describe -s -s CHANGE_NUM, shelved files should not be linked to the file system
        ;; To view shelved files, use p4 print //branch/path/to/file@=CHANGENUM
        (let ((end-point (if (re-search-forward "^Shelved files \\.\\.\\." nil t)
                             (point)
                           (point-max))))
          (narrow-to-region (point-min) end-point)
          (p4-mark-depot-list-buffer)))))

  (save-excursion
    (p4-find-jobs (point-min) (point-max))

    ;; For p4-describe, add help at top
    (when (string-match "^P4 describe" (buffer-name))
      (goto-char (point-min))
      (insert
       (propertize (if (string-match "^P4 describe.* -d" (buffer-name))
                       (concat
                        "# RET, mouse, o : Visit item      |  e        : Ediff depot file\n"
                        "# TAB, n        : Next diff hunk  |  S-TAB, p : Prev diff hunk\n"
                        "# N, }          : Next diff file  |  P, {     : Prev diff file\n\n")
                     "# RET, mouse, o : Visit item  |  e : Ediff depot file\n\n")
                   'face 'font-lock-comment-face)))

    (goto-char (point-min))
    (while (re-search-forward "^\\(==== //\\).*\n"
                              nil t)
      (let* ((link-depot-name (get-char-property (match-end 1) 'link-depot-name))
             (start (match-beginning 0))
             (end (save-excursion
                    (if (re-search-forward "^==== " nil t)
                        (match-beginning 0)
                      (point-max)))))
        (when link-depot-name
          (add-text-properties start end `(block-depot-name ,link-depot-name)))))

    (goto-char (point-min))
    (while (re-search-forward (concat "^[@0-9].*\\([cad+]\\)\\([0-9]*\\).*\n"
                                      "\\(\\(\n\\|[^@0-9\n].*\n\\)*\\)")
                              nil t)
      (let ((first-line (string-to-number (match-string 2)))
            (start (match-beginning 3))
            (end (match-end 3)))
        (add-text-properties start end `(first-line ,first-line start ,start))))

    (goto-char (point-min))
    (let ((stop
           (if (re-search-forward "^\\(\\.\\.\\.\\|====\\)" nil t)
               (match-beginning 0)
             (point-max))))
      (p4-find-change-numbers (point-min) stop))

    (goto-char (point-min))
    (when (looking-at "^Change [1-9][0-9]* by \\([^ @\n]+\\)@\\([^ \n]+\\)")
      (p4-create-active-link-group 1 `(user ,(match-string-no-properties 1))
                                   "Describe user")
      (p4-create-active-link-group 2 `(client ,(match-string-no-properties 2))
                                   "Describe client"))))

(defun p4-activate-fixes-buffer ()
  "Perforce activate fixes buffer."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\(\\S-+\\) fixed by change \\([0-9]+\\) on [0-9/]+ by \\([^ @\n]+\\)@\\([^ \n]+\\)" nil t)
        (p4-create-active-link-group 1 `(job ,(match-string-no-properties 1)))
        (p4-create-active-link-group 2 `(change ,(string-to-number (match-string 2))))
        (p4-create-active-link-group 3 `(user ,(match-string-no-properties 3)))
        (p4-create-active-link-group 4 `(client ,(match-string-no-properties 4)))))))

(defun p4-regexp-create-links (regexp property &optional help-echo)
  "Perforce REGEXP create links using PROPERTY and HELP-ECHO."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (p4-create-active-link-group
         1 (list property (match-string-no-properties 1)) help-echo)))))


;;; Annotation:

(defconst p4-blame-change-regex
  (concat "^\\.\\.\\. #"     "\\([1-9][0-9]*\\)"   ; revision
          "\\s-+change\\s-+" "\\([1-9][0-9]*\\)"   ; change
          "\\s-+"            "\\([^ \t\n]+\\)"       ; type
          "\\s-+on\\s-+"     "\\([^ \t\n]+\\)"       ; date
          "\\s-+by\\s-+"     "\\([^ \t\n]+\\)"       ; author
          "@.*\n\n\t\\(.*\\)"))                    ; description

(defconst p4-blame-revision-regex
  (concat "^\\([0-9]+\\),?"
          "\\([0-9]*\\)"
          "\\([acd]\\)"
          "\\([0-9]+\\),?"
          "\\([0-9]*\\)"))

(defalias 'p4-blame 'p4-annotate)

(cl-defstruct p4-file-revision filespec filename revision change date user description links desc)

(defun p4-link (width value properties &optional help-echo)
  "Insert VALUE, right-aligned, into a field of WIDTH.
Make it into an active link with PROPERTIES.
Optional argument HELP-ECHO is the text to display when hovering
the mouse over the link."
  (let* ((text (format (format "%%%ds" width) value))
         (length (length text))
         (text (if (< length width) text (substring text 0 width)))
         (p (point)))
    (insert text)
    (p4-create-active-link p (point) properties help-echo)))

(defvar p4--get-full-name-hash (make-hash-table :test 'equal)
  "Map user name to full name.")

(defun p4--get-full-name (user)
  "Get full name for USER name."
  (let ((full-name (gethash user p4--get-full-name-hash)))
    (when (not full-name)
      (setq full-name (user-full-name user))
      (if (not full-name)
          (setq full-name user))
      (puthash user full-name p4--get-full-name-hash))
    full-name))

(defun p4-file-revision-annotate-links (rev rev-date change-width)
  "Annotate links for REV, REV-DATE using CHANGE-WIDTH."
  (let ((links (p4-file-revision-links rev)))
    (or links
        (with-temp-buffer
          (let ((change (p4-file-revision-change rev))
                (filename (p4-file-revision-filename rev))
                (revision (p4-file-revision-revision rev))
                (user (p4-file-revision-user rev))
                (desc (p4-file-revision-description rev)))
            (p4-link change-width (format "%d" change) `(change ,change)
                     (concat "Describe change: " desc))
            (insert " ")
            (if (= revision -1)
                (progn
                  (insert "  #??")
                  (add-text-properties (- (point) 3) (point)
                                       '(help-echo
                                         "mouse-1: unable to programmatically determine file from
changelist contributing to this line, click the changelist")))
              (p4-link 5 (format "#%d" revision)
                       `(rev ,revision link-depot-name ,filename)
                       (format "Print revision: %s#%d" filename revision)))
            (insert " ")
            (insert (format "%10s " rev-date))
            (p4-link 8 user `(user ,user) (concat "Describe user: " (p4--get-full-name user)))
            (insert ": "))
          (setf (p4-file-revision-links rev)
                (buffer-substring (point-min) (point-max)))))))

(defun p4-file-revision-annotate-desc (rev desc-width)
  "Annotate description for REV and DESC-WIDTH."
  (let ((links (p4-file-revision-desc rev)))
    (or links
        (let ((desc (p4-file-revision-description rev)))
          (setf (p4-file-revision-desc rev)
                (if (<= (length desc) desc-width)
                    (format (format "%%-%ds: " desc-width) desc)
                  (format (format "%%%ds: " desc-width) (substring desc 0 desc-width))))))))

(defun p4-parse-filelog (filespec)
  "Parse the filelog for FILESPEC.
Return an association list mapping revision number to a
`p4-file-revision' structure, in reverse order (earliest revision
first)."
  (let (head-seen        ; head revision not deleted?
        change-alist     ; alist mapping change to p4-file-revision structures
        deleted-revision ; non-nil if filespec was deleted
        current-file     ; current filename in filelog
        (args (list "filelog" "-l" "-i" filespec)))
    (message "Running: p4 %s" (p4-join-list args))
    (let ((dir (or p4-default-directory default-directory)))
      (with-temp-buffer
        (cd dir)
        (when (zerop (p4-run args))
          (while (not (eobp))
            (cond ((looking-at "^//.*$")
                   (setq current-file (match-string 0)))
                  ((looking-at p4-blame-change-regex)
                   (let ((op (match-string 3))
                         (revision (string-to-number (match-string 1)))
                         (change (string-to-number (match-string 2))))
                     (if (string= op "delete")
                         (unless head-seen
                           (setq deleted-revision revision)
                           (goto-char (point-max)))
                       (push (cons change
                                   (make-p4-file-revision
                                    :filespec (format "%s#%d" current-file revision)
                                    :filename current-file
                                    :revision revision
                                    :change change
                                    :date (match-string 4)
                                    :user (match-string 5)
                                    :description (match-string 6)))
                             change-alist)
                       (setq head-seen t)))))
            (forward-line))
          (cons change-alist deleted-revision))))))

(defun p4-have-rev (filespec)
  "Run \"p4 fstat -t haveRev FILESPEC\" and return depotFile#haveRev."
  (let ((args (list "fstat" "-T" "depotFile,haveRev" filespec)))
    (message "Running p4 %s" (p4-join-list args))
    (p4-with-temp-buffer
     args
     (let (depotFile
           haveRev)
       (while (not (eobp))
         (cond
          ((looking-at "^\\.\\.\\. depotFile \\(.+\\)$")
           (setq depotFile (match-string 1)))
          ((looking-at "^\\.\\.\\. haveRev \\([0-9]+\\)")
           (setq haveRev (match-string 1))))
         (when (and depotFile haveRev)
           (goto-char (point-max)))
         (forward-line))
       (when (not haveRev)
         (error "Unable to determine have revision from 'p4 %s' which returned\n%s"
                (p4-join-list args) (buffer-substring (point-min) (point-max))))
       ;; answer
       (if (and depotFile haveRev)
           (concat depotFile "#" haveRev)
         nil)))))

(defun p4-annotate-changes (filespec)
  "Use p4 annotate to get list of change numbers.
Using p4 annotate -I -q -dw FILESPEC, return a list of change
numbers, one for each line of FILESPEC."
  (let* ((args (list "annotate" "-I" "-q" "-dw" filespec)))
    (message "Running p4 %s" (p4-join-list args))
    (p4-with-temp-buffer
     args
     (cl-loop while (re-search-forward "^\\([1-9][0-9]*\\):" nil t)
              collect (string-to-number (match-string 1))))))

(defun p4-get-relative-depot-filespec (encoded-filespec)
  "Get relative depot filespec for ENCODED-FILESPEC.
Given a p4 encoded filespec, typically a path to a local file
with special characters encoded, see `p4-encoded-path', return
the depot relative encoded filespec, i.e. the path without the
branch and special chars encoded."
  (let* ((fspec (if (string-match "^\\(.+\\)#" encoded-filespec)
                    (match-string 1 encoded-filespec)
                  encoded-filespec))
         (args (list "-ztag" "where" fspec)))
    (message "Running: p4 %s" (p4-join-list args))
    (with-current-buffer (p4-make-output-buffer (p4-process-buffer-name args))
      (let (relative-depot-filespec)
        ;; p4 -ztag where FILESPEC_ENCODED will produce:
        ;;   ... deportFile FILE_P4_ENCODED
        ;;   ... clientFile HOST/FILE
        ;;   ... path LOCAL_NON_ENCODED_FILE_SYSTEM_PATH
        ;; if it is successful. On fatal errors it produces a non-zero status, on "soft" errors
        ;; it produces success with output like
        ;;   FILESPEC_ENCODED - file(s) not in client view
        (if (or (not (zerop (p4-run args)))
                (not (looking-at "^\\.\\.\\. depotFile \\(.+\\)$")))
            ;; "p4 where fspec" failed, see if client supplied an extraction function
            ;; that can identify the branch
            (let ((branch (if p4-branch-from-depot-filespec-function
                              (funcall p4-branch-from-depot-filespec-function fspec))))
              (if branch
                  (setq relative-depot-filespec (substring fspec (+ (length branch) 1)))
                (let ((msg (format "p4 %s failed with message '%s'\n" (p4-join-list args)
                                   (buffer-substring (point-min) (point-max)))))
                  (if p4-branch-from-depot-filespec-function
                      (setq msg (concat "Also, p4-branch-from-depot-filespec-function was unable "
                                        "to extract the branch. Consider updating the function"))
                    (setq msg (concat "p4-branch-from-depot-filespec-function is not defined. "
                                      "Consider defining it to extract the branch")))
                  (error msg))))
          (let ((depot-file (match-string 1))
                local-file  ;; local file p4 encoded
                )
            (forward-line) ;; move to line: "... clientFile FILE"
            (forward-line) ;; skip clientFile line
            (if (looking-at "^\\.\\.\\. path \\(.+\\)$") ;; looking at "... path FILE"
                (setq local-file (p4-encode-path (match-string 1)))
              (error "Unexpected output from p4 -ztag where FILE while looking for path"))
            (let ((match t))
              (while match
                (let ((depot-base (file-name-nondirectory depot-file))
                      (local-base (file-name-nondirectory local-file)))
                  (if (not (equal depot-base local-base))
                      (setq match nil)
                    (setq relative-depot-filespec
                          (concat depot-base
                                  (if relative-depot-filespec (concat "/" relative-depot-filespec)))
                          depot-file (directory-file-name (file-name-directory depot-file))
                          local-file (directory-file-name (file-name-directory local-file))))))
              (when (not relative-depot-filespec)
                (error "Failed to get relative-depot-filespec"))
              ;; answer
              relative-depot-filespec)))))))

(defun p4--annotation-date-age-in-days (date-str)
  "Get DATE-STR (yyyy/mm/dd) age in days."
  (when (not (string-match "^\\([0-9]+\\)/\\([0-9]+\\)/\\([0-9]+\\)$" date-str))
    (error "Assert, bad date-str, %s" date-str))
  (let* ((year     (string-to-number (match-string 1 date-str)))
         (mm       (string-to-number (match-string 2 date-str)))
         (dd       (string-to-number (match-string 3 date-str)))
         (now      (decode-time (current-time)))
         (now-dd   (nth 3 now))
         (now-mm   (nth 4 now))
         (now-year (nth 5 now)))
    (- (calendar-absolute-from-gregorian `(,now-mm ,now-dd ,now-year))
       (calendar-absolute-from-gregorian `(,mm ,dd ,year)))))

(defun p4--annotation-age-face (date-str)
  "Return face to show how old DATE-STR (yyyy/mm/dd) is."
  (let* ((n-days (p4--annotation-date-age-in-days date-str)))
    (if (< n-days 360)
        (let* ((day-spacing (/ 360 (length p4-annotate-line-first-360-day-faces)))
               (day-idx (/ n-days day-spacing))) ;; index by day-spacing, e.g. 60 days
          (nth day-idx p4-annotate-line-first-360-day-faces))
      ;; Else: grab face using year indexing
      (setq n-days (- n-days 360)) ;; first 360 days are taken by the first 360 day faces
      (let ((year-idx (/ n-days 365))
            (n-year-faces (length p4-annotate-line-year-faces)))
        (when (>= year-idx n-year-faces)
          (setq year-idx (1- n-year-faces)))
        (nth year-idx p4-annotate-line-year-faces)))))

(defun p4-get-rev-struct-from-change (change relative-filespec)
  "Perforce get revision info from change.
Run p4 describe -s CHANGE and return a `p4-file-revision'
struct and REV for p4 encoded relative-filespec.  There are cases
where the RELATIVE-FILESPEC won't exist in CHANGE because of p4
move.  In this case, the other-filespec and revision within the
return struct will invalid (revision will be -1)."
  (let ((args (list "describe" "-s" (format "%s" change))))
    (message "Running: p4 %s" (p4-join-list args))

    (p4-with-temp-buffer
     args
     (let* ((re-start "^\\.\\.\\. \\(//[^ ]+/")
            (branch-re (concat re-start (regexp-quote relative-filespec) "\\)" "#\\([0-9]+\\)"))
            (base-re (concat re-start (file-name-nondirectory relative-filespec) "\\)"
                             "#\\([0-9]+\\)"))
            matched-basename
            other-filespec
            user
            date
            desc
            rev)
       (while (not (eobp))
         ;; grab user?
         (if (and (not user)
                  (looking-at "^Change [0-9]+ by \\([^@]+\\)@[^ ]+ on \\([^ ]+\\)"))
             (setq user (match-string 1)
                   date (match-string 2))
           ;; else grab first line of desc?
           (if (and (not desc)
                    (looking-at "\t\\(.+\\)"))
               (setq desc (match-string 1))
             ;; grab other-filespec and rev?
             (if (looking-at branch-re) ;; Looking at //OTHER-BRANCH/RELATIVE-FILESPEC?
                 (progn
                   (setq other-filespec (match-string 1)
                         rev    (match-string 2))
                   (goto-char (point-max)))
               (when (looking-at base-re) ;; else looking at //OTHER-BRANCH/..../BASENAME?
                 ;; Match this as it's most likely the move of a file from one directory to another
                 ;; which keeping same basename.
                 (if matched-basename
                     ;; multiple matches on same basename, can't use basename
                     (setq other-filespec nil)
                   ;; else first match
                   (setq other-filespec (match-string 1) ;; really more than the branch
                         rev    (match-string 2)
                         matched-basename t))))))
         (forward-line))

       (when (not other-filespec)
         (setq rev "-1"
               other-filespec (concat "//OTHER-BRANCH/" relative-filespec)))
       ;; answer
       (let ((revision (string-to-number rev)))
         (make-p4-file-revision
          :filespec (format "%s#%d" other-filespec revision)
          :filename other-filespec
          :revision revision
          :change change
          :date date
          :user user
          :description desc))))))

(defun p4--annotate-line-num-pair (for-export)
  "Compute line numbering strings for p4 annotate.
Returns: (line-num-format-str . no-line-num-str)
1. line-num-format-str is computed based on the buffer length minus
   the in-buffer header lines.  The length of the header lines is
   one less when setting up the buffer FOR-EXPORT.
2. no-line-num-str is the text to prefix in-buffer header lines with."
  (save-excursion
    (goto-char (point-max))
    (if (> (line-number-at-pos) p4-annotate-line-number-threshold)
        ;; Do not display the "source" line numbers in the annotate buffer.
        '(nil . nil)
      ;; Else displaying source line numbers. These differ from the buffer line numbers because we
      ;; have a few in-buffer header lines that don't count. Also, we shade the background based on
      ;; the change age.
      (display-line-numbers-mode 0)
      (let* ((n-lines-str (format "%d" (- (line-number-at-pos)
                                          (+ 1 (if for-export 0 1)))))
             (fringe-width (format "%d" (length n-lines-str)))
             (no-line-num-str (format (concat  " %" fringe-width "s") " ")))
        (cons (concat " %" fringe-width "d") no-line-num-str)))))

(defun p4--annotate-insert-line-num (line-num-str for-export)
  "Insert a LINE-NUM-STR.
It's assumed point is beginning of line.
When FOR-EXPORT is specified, setup for `htmlize-buffer',
such that the p4 annotate buffer can be converted to HTML."
  (when line-num-str
    (setq line-num-str (concat line-num-str " "))
    (if for-export
        (insert line-num-str)
      (let* ((pt (point))
             (ol (make-overlay pt pt)))
        (overlay-put ol 'before-string line-num-str)))))

(defun p4--annotate-insert-header (no-line-num-str for-export)
  "Insert a header comment for p4-annotate.
NO-LINE-NUM-STR is the prefix to insert before the comments.
FOR-EXPORT  has the same meaning as in `p4-annotate-file'."
  (when (not for-export)
    (p4--annotate-insert-line-num no-line-num-str for-export)
    (insert (propertize
             "# Keys-  n/p: next/prev change  l: toggle line wrap  g: goto source line\n"
             'face 'font-lock-comment-face))))

(defvar p4--annotate-source-line-start)

(defun p4-annotate-file (file &optional for-export no-show)
  "Annotate FILE walking through integrations.
FILE can be a path to a local file or a depot path (optionally
including the #REV).

Optional FOR-EXPORT, if t, will suppress the '# keys- ...'
comment at the top of the annotation buffer and insert line
numbers as text.  For example, you can export the buffer using
the `htmlize-buffer'.

Optional NO-SHOW, if t, will not show the annotated buffer."
  (let* ((decoded-file (p4-decode-path file))
         ;; set default-directory to ensure we pickup the right client
         ;; when within a symlink.
         (is-regular-file (file-regular-p decoded-file))
         (default-directory (if is-regular-file
                                (file-name-directory decoded-file)
                              default-directory))
         (filespec (if is-regular-file
                       (p4-have-rev file)
                     file))
         (src-line (and (string-equal file (p4-buffer-file-name))
                        (line-number-at-pos (point))))
         (buf (p4-process-buffer-name (list "annotate" filespec))))
    (unless (get-buffer buf)
      (let* ((parsed-info (p4-parse-filelog filespec))
             (file-change-alist (car parsed-info))
             (deleted-revision (cdr parsed-info))
             relative-filespec)
        (when (not file-change-alist)
          ;; Attempt to annotate a deleted file? If so, annotate prior revision.
          (when deleted-revision
            (let* ((prior-filespec (concat (replace-regexp-in-string "#[0-9]+$" "" filespec)
                                           "#" (format "%d" (- deleted-revision 1))))
                   (prior-parsed-info (p4-parse-filelog prior-filespec)))
              (when (setq file-change-alist (car prior-parsed-info))
                (setq filespec prior-filespec))))
          (when (not file-change-alist)
            (error "%s is not in Perforce (p4 filelog failed)" filespec)))
        (with-current-buffer (p4-make-output-buffer buf)
          (let* ((line-changes (p4-annotate-changes filespec))
                 (lines (length line-changes))
                 (inhibit-read-only t)
                 (inhibit-modification-hooks t)
                 (current-line 0)
                 (current-repeats 0)
                 (current-percent -1)
                 (most-recent-change (caar (last file-change-alist)))
                 (change-width (length (number-to-string most-recent-change)))
                 (desc-width (+ change-width 26))
                 current-change
                 rev-date
                 (line-num 0)
                 line-num-format-str
                 no-line-num-str)
            (p4-run (list "print" filespec))
            (p4-fontify-print-buffer)
            (let ((line-num-pair (p4--annotate-line-num-pair for-export)))
              (setq line-num-format-str (car line-num-pair)
                    no-line-num-str (cdr line-num-pair)))
            (p4--annotate-insert-line-num no-line-num-str for-export) ;; //branch/filespec line
            (forward-line 1) ;; skip over depot path, //branch/filespec
            (p4--annotate-insert-header no-line-num-str for-export)
            (make-local-variable 'p4--annotate-source-line-start)
            (setq p4--annotate-source-line-start (line-number-at-pos))
            (dolist (change line-changes)
              (cl-incf current-line)
              (let ((percent (/ (* current-line 100) lines)))
                (when (> percent current-percent)
                  (message "Formatting...%d%%" percent)
                  (cl-incf current-percent 10)))
              (if (eql change current-change)
                  (cl-incf current-repeats)
                (setq current-repeats 0))
              (let ((rev (cdr (assoc change file-change-alist))))
                (when (not rev)
                  ;; This is from an integrated change due to p4 annotate -I, i.e a change on
                  ;; a different branch. To handle this we:
                  ;; 1. get the relative-filespec from
                  ;;     p4 -ztag where /path/to/workspace/..../dir/file.cpp
                  ;;     ... depotFile //loc/workspace/..../dir/file.cpp
                  ;;     ... clientFile .....
                  ;;     ... path /path/to/workspace/..../dir/file.cpp
                  ;;     (a) Encode local file path
                  ;;     (b) Match each path piece until no match starting from filename working
                  ;;         way up
                  ;;           - file.cpp      : match
                  ;;           - dir           : match
                  ;;           - ....          : match
                  ;;           - workspace     : match
                  ;;         now we know the relative file name.
                  ;; 2. Use "p4 describe -s CN" (-s is summary and omits the diffs) to get
                  ;;    the OTHER_BRANCH and REV from by looking for relative-filespec in
                  ;;    list of changed files.
                  ;; 3. Add CN and REV to file-change-alist
                  ;; 4. Make clicking the #REV use the OTHER_BRANCH/relative-filespec
                  (when (not relative-filespec)
                    (setq relative-filespec (p4-get-relative-depot-filespec filespec)))
                  (let ((file-rev-struct (p4-get-rev-struct-from-change change relative-filespec)))
                    (push (cons change file-rev-struct) file-change-alist)
                    (setq rev (cdr (assoc change file-change-alist)))))
                (setq line-num (+ line-num 1))
                (when (= current-repeats 0)
                  (setq rev-date (p4-file-revision-date rev)))
                (when line-num-format-str
                  (p4--annotate-insert-line-num
                   (propertize (format line-num-format-str line-num)
                               'face (p4--annotation-age-face rev-date))
                   for-export))
                (cl-case current-repeats
                  (0 (insert (p4-file-revision-annotate-links rev rev-date change-width)))
                  (1 (insert (p4-file-revision-annotate-desc rev desc-width)))
                  (t (insert (format (format "%%%ds: " desc-width) "")))))
              (setq current-change change)
              (forward-line))
            (goto-char (point-min))
            (p4-mark-print-buffer)
            (message "Formatting...done")
            (setq truncate-lines t)
            (use-local-map p4-annotate-mode-map)))))
    (setq p4--get-full-name-hash (make-hash-table :test 'equal))
    (when (not no-show)
      (with-selected-window (display-buffer buf)
        (when src-line
          (p4-goto-line (+ 1 src-line)))))
    ;; Return the "P4 annotate FILE" buffer
    buf))

;;; Completion:

(cl-defstruct p4-completion
  cache                ; association list mapping query to list of results.
  cache-exact          ; cache lookups must be exact (not prefix matches).
  history              ; symbol naming the history variable.
  query-cmd            ; p4 command to fetch completions from depot.
  query-arg            ; p4 command argument to put before the query string.
  query-prefix         ; string to prepend to the query string.
  regexp               ; regular expression matching results in p4 output.
  group                ; group in regexp containing the completion (default 1).
  annotation           ; group in regexp containing the annotation.
  fetch-completions-fn ; function to fetch completions from the depot.
  completion-fn        ; function to do the completion.
  arg-completion-fn)   ; function to do completion in arg list context.

(defun p4-output-matches (args regexp &optional group)
  "Run p4 ARGS and return match list for REGEXP in the output.
With optional argument GROUP, return that group from each match."
  (p4-with-temp-buffer args
                       (let (result)
                         (while (re-search-forward regexp nil t)
                           (push (match-string (or group 0)) result))
                         (nreverse result))))

;; Completions are generated as needed in completing-read, but there's
;; no way for the completion function to return the annotations as
;; well as completions. We don't want to query the depot for each
;; annotation (that would be disastrous for performance). So the only
;; way annotations can work at all efficiently is for the function
;; that gets the list of completions (p4-complete) to also update this
;; global variable (either by calling p4-output-annotations, or by
;; getting the annotation table out of the cache).

(defvar p4-completion-annotations nil
  "Hash table mapping completion to its annotation.
This applies to the most recently generated set of
completions, or NIL if there are no annotations.")

(defun p4-completion-annotate (key)
  "Return the completion annotation corresponding to KEY, or NIL if none."
  (when p4-completion-annotations
    (let ((annotation (gethash key p4-completion-annotations)))
      (when annotation (concat " " annotation)))))

(defun p4-output-annotations (args regexp group annotation)
  "Output annotation using ARGS and REGEXP.
As p4-output-matches, but additionally update
p4-completion-annotations so that it maps the matches for GROUP
to the matches for ANNOTATION."
  (p4-with-temp-buffer args
                       (let (result (ht (make-hash-table :test #'equal)))
                         (while (re-search-forward regexp nil t)
                           (let ((key (match-string group)))
                             (push key result)
                             (puthash key (match-string annotation) ht)))
                         (setq p4-completion-annotations ht)
                         (nreverse result))))

(defun p4-completing-read (completion-type prompt &optional initial-input)
  "Wrapper around `completing-read'.
Uses COMPLETION-TYPE, PROMPT, and optional INITIAL-INPUT."
  (let ((completion (p4-get-completion completion-type))
        (completion-extra-properties
         '(:annotation-function p4-completion-annotate)))
    (completing-read prompt
                     (p4-completion-arg-completion-fn completion)
                     nil nil initial-input
                     (p4-completion-history completion))))

(defun p4-fetch-change-completions (status)
  "Fetch change completions with status STATUS from the depot."
  (let ((client (p4-current-client)))
    (when client
      (cons "default"
            (p4-output-annotations `("changes" "-s" ,status "-c" ,client)
                                   "^Change \\([1-9][0-9]*\\) .*'\\(.*\\)'"
                                   1 2)))))

(defun p4-fetch-pending-completions (completion string)
  "Fetch pending change completions from the depot.
COMPLETION and STRING are ignored."
  (ignore completion string)
  (p4-fetch-change-completions "pending"))

(defun p4-fetch-shelved-completions (completion string)
  "Fetch shelved change completions from the depot.
COMPLETION and STRING are ignored."
  (ignore completion string)
  (p4-fetch-change-completions "shelved"))

(defun p4-fetch-filespec-completions (completion string)
  "Fetch file and directory completions for STRING from the depot.
COMPLETION is ignored."
  (ignore completion)
  (append (cl-loop for dir in (p4-output-matches (list "dirs" (concat string "*"))
                                                 "^//[^ \n]+$")
                   collect (concat dir "/"))
          (p4-output-matches (list "files" (concat string "*"))
                             "^\\(//[^#\n]+\\)#[1-9][0-9]* - " 1)))

(defun p4-fetch-help-completions (completion string)
  "Fetch help completions for STRING from the depot.
COMPLETION and STRING are ignored."
  (ignore completion string)
  (append (p4-output-matches '("help") "^\tp4 help \\([^ \n]+\\)" 1)
          (p4-output-matches '("help" "commands") "^\t\\([^ \n]+\\)" 1)
          (p4-output-matches '("help" "administration") "^\t\\([^ \n]+\\)" 1)
          '("undoc")
          (p4-output-matches '("help" "undoc")
                             "^    p4 \\(?:help \\)?\\([a-z0-9]+\\)" 1)))

(defun p4-fetch-completions (completion string)
  "Fetch possible COMPLETION for STRING from the depot as a list.
Update the p4-completion-annotations hash table."
  (let* ((cmd (p4-completion-query-cmd completion))
         (arg (p4-completion-query-arg completion))
         (prefix (p4-completion-query-prefix completion))
         (regexp (p4-completion-regexp completion))
         (group (or (p4-completion-group completion) 1))
         (annotation (p4-completion-annotation completion))
         (have-string (> (length string) 0))
         (args (append (if (listp cmd) cmd (list cmd))
                       (and arg have-string (list arg))
                       (and (or arg prefix) have-string
                            (list (concat prefix string "*"))))))
    (if annotation
        (p4-output-annotations args regexp group annotation)
      (p4-output-matches args regexp group))))

(defun p4-purge-completion-cache (completion)
  "Remove stale entries from the cache for COMPLETION."
  (let ((stale (time-subtract (current-time)
                              (seconds-to-time p4-cleanup-time))))
    (setf (p4-completion-cache completion)
          (cl-loop for c in (p4-completion-cache completion)
                   when (time-less-p stale (cl-second c))
                   collect c))))

(defun p4-complete (completion string)
  "Perforce complete.

Returns list of items of type COMPLETION that are possible
completions for STRING, also updates the annotations hash table.
Use the cache if available, otherwise fetch them from the depot
and update the cache accordingly."
  (p4-purge-completion-cache completion)
  (let* ((cache (p4-completion-cache completion))
         (cached (assoc string cache)))
    ;; Exact cache hit?
    (if cached
        (progn
          (setq p4-completion-annotations (cl-fourth cached))
          (cl-third cached))
      ;; Any hit on a prefix (unless :cache-exact)
      (or (and (not (p4-completion-cache-exact completion))
               (cl-loop for (query timestamp results annotations) in cache
                        for best-results = nil
                        for best-length = -1
                        for l = (length query)
                        when (and (> l best-length) (p4-starts-with string query))
                        do (progn (ignore timestamp)
                                  (ignore annotations)
                                  (setq best-length l best-results results))
                        finally return best-results))
          ;; Fetch from depot and update cache.
          (let* ((fetch-fn (or (p4-completion-fetch-completions-fn completion)
                               'p4-fetch-completions))
                 (results (funcall fetch-fn completion string))
                 (timestamp (current-time)))
            (push (list string timestamp results p4-completion-annotations)
                  (p4-completion-cache completion))
            results)))))

(defun p4-completion-builder (completion)
  "Completion builder for COMPLETION."
  (let ((completion completion))
    (completion-table-dynamic
     (lambda (string) (p4-complete completion string)))))

(defun p4-arg-completion-builder (completion)
  "Arg completion builder for COMPLETION."
  (let ((completion completion))
    (lambda (string predicate action)
      (string-match "^\\(\\(?:.* \\)?\\)\\([^ \t\n]*\\)$" string)
      (let* ((first (match-string 1 string))
             (remainder (match-string 2 string))
             (f (p4-completion-completion-fn completion))
             (completions (unless (string-match "^-" remainder)
                            (funcall f remainder predicate action))))
        (if (and (null action)             ; try-completion
                 (stringp completions))
            (concat first completions)
          completions)))))

(defun p4-make-completion (&rest args)
  "Make completion for optional ARGS."
  (let* ((c (apply 'make-p4-completion args)))
    (setf (p4-completion-completion-fn c) (p4-completion-builder c))
    (setf (p4-completion-arg-completion-fn c) (p4-arg-completion-builder c))
    c))

(defvar p4-arg-string-history nil "P4 command line argument history.")
(defvar p4-branch-history nil "P4 branch history.")
(defvar p4-client-history nil "P4 client history.")
(defvar p4-filespec-history nil "P4 filespec history.")
(defvar p4-group-history nil "P4 group history.")
(defvar p4-help-history nil "P4 help history.")
(defvar p4-job-history nil "P4 job history.")
(defvar p4-label-history nil "P4 label history.")
(defvar p4-pending-history nil "P4 pending change history.")
(defvar p4-shelved-history nil "P4 shelved change history.")
(defvar p4-user-history nil "P4 user history.")

(defvar p4-all-completions
  (list
   (cons 'branch   (p4-make-completion
                    :query-cmd "branches" :query-arg "-E"
                    :regexp "^Branch \\([^ \n]*\\) [0-9]+/"
                    :history 'p4-branch-history))
   (cons 'client   (p4-make-completion
                    :query-cmd "clients" :query-arg "-E"
                    :regexp "^Client \\([^ \n]*\\) [0-9]+/"
                    :history 'p4-client-history))
   (cons 'filespec (p4-make-completion
                    :cache-exact t
                    :fetch-completions-fn 'p4-fetch-filespec-completions
                    :history 'p4-filespec-history))
   (cons 'group    (p4-make-completion
                    :query-cmd "groups"
                    :regexp "^\\([^ \n]+\\)"
                    :history 'p4-group-history))
   (cons 'help     (p4-make-completion
                    :fetch-completions-fn 'p4-fetch-help-completions
                    :history 'p4-help-history))
   (cons 'job      (p4-make-completion
                    :query-cmd "jobs" :query-arg "-e" :query-prefix "job="
                    :regexp "\\([^ \n]*\\) on [0-9]+/.*\\* '\\(.*\\)'"
                    :annotation 2
                    :history 'p4-job-history))
   (cons 'label    (p4-make-completion
                    :query-cmd "labels" :query-arg "-E"
                    :regexp "^Label \\([^ \n]*\\) [0-9]+/"
                    :history 'p4-label-history))
   (cons 'pending  (p4-make-completion
                    :fetch-completions-fn 'p4-fetch-pending-completions
                    :history 'p4-pending-history))
   (cons 'shelved  (p4-make-completion
                    :fetch-completions-fn 'p4-fetch-shelved-completions
                    :history 'p4-shelved-history))
   (cons 'user     (p4-make-completion
                    :query-cmd "users" :query-prefix ""
                    :regexp "^\\([^ \n]+\\)"
                    :history 'p4-user-history))))

(defun p4-get-completion (completion-type &optional noerror)
  "Return the `p4-completion' structure for COMPLETION-TYPE.
If there is no such completion type, report the error if NOERROR
is NIL, otherwise return NIL."
  (let ((res (assq completion-type p4-all-completions)))
    (when (not (or noerror res))
      (error "Unsupported completion type %s" completion-type))
    (cdr res)))

(defun p4-cache-cleanup ()
  "Empty all the completion caches."
  (cl-loop for (type . completion) in p4-all-completions
           do (progn
                (ignore type)
                (setf (p4-completion-cache completion) nil))))

(defun p4-partial-cache-cleanup (completion-type)
  "Cleanup a specific completion cache for COMPLETION-TYPE."
  (let ((completion (p4-get-completion completion-type 'noerror)))
    (when completion (setf (p4-completion-cache completion) nil))))

(defun p4--modify-prompt-with-dir (prompt)
  "Return modified PROMPT.
If `p4-default-directory' is not same as `default-directory'
modify prompt with it."
  (when (and p4-default-directory
             (not (string= p4-default-directory default-directory)))
    (setq prompt (concat (format "In %s\n" p4-default-directory) prompt)))
  prompt)

(defun p4-read-arg-string (prompt &optional initial-input completion-type)
  "Read input using PROMPT and optional INITIAL-INPUT COMPLETION-TYPE."
  (let* ((minibuffer-local-completion-map
          (copy-keymap minibuffer-local-completion-map)))
    (define-key minibuffer-local-completion-map " " 'self-insert-command)
    (setq prompt (p4--modify-prompt-with-dir prompt))
    (if completion-type
        (p4-completing-read completion-type prompt initial-input)
      (completing-read prompt #'p4-arg-string-completion nil nil
                       initial-input 'p4-arg-string-history))))

(defun p4-read-args (prompt &optional initial-input completion-type)
  "Read args using PROMPT and optional INITIAL-INPUT COMPLETION-TYPE."
  (p4-make-list-from-string
   (p4-read-arg-string prompt initial-input completion-type)))

(defun p4-read-args* (prompt &optional initial-input completion-type)
  "Read args using PROMPT and optional INITIAL-INPUT COMPLETION-TYPE.
Will prompt if needed."
  (p4-make-list-from-string
   (if (or p4-prompt-before-running-cmd current-prefix-arg)
       (p4-read-arg-string prompt initial-input completion-type)
     ;; else non-interactive mode, must have input
     (when (not initial-input)
       (user-error "No input for '%s'" (replace-regexp-in-string ": $" "" (downcase prompt))))
     initial-input)))

(defun p4-arg-complete (completion-type &rest args)
  "Complete using COMPLETION-TYPE and ARGS."
  (let ((completion (p4-get-completion completion-type)))
    (apply (p4-completion-arg-completion-fn completion) args)))

(defun p4-arg-string-completion (string predicate action)
  "Complete STRING PREDICATE ACTION."
  (let ((first-part "") completion)
    (if (string-match "^\\(.* +\\)\\(.*\\)" string)
        (progn
          (setq first-part (match-string 1 string))
          (setq string (match-string 2 string))))
    (cond ((string-match "-b +$" first-part)
           (setq completion (p4-arg-complete 'branch string predicate action)))
          ((string-match "-t +$" first-part)
           (setq completion (p4-list-completion
                             string (list "text " "xtext " "binary "
                                          "xbinary " "symlink ")
                             predicate action)))
          ((string-match "-j +$" first-part)
           (setq completion (p4-arg-complete 'job string predicate action)))
          ((string-match "-l +$" first-part)
           (setq completion (p4-arg-complete 'label string predicate action)))
          ((string-match "\\(.*status=\\)\\(.*\\)" string)
           (setq first-part (concat first-part (match-string 1 string)))
           (setq string (match-string 2 string))
           (setq completion (p4-list-completion
                             string (list "open " "closed " "suspended ")
                             predicate action)))
          ((or (string-match "\\(.*@.+,\\)\\(.*\\)" string)
               (string-match "\\(.*@\\)\\(.*\\)" string))
           (setq first-part (concat first-part (match-string 1 string)))
           (setq string (match-string 2 string))
           (setq completion (p4-arg-complete 'label string predicate action)))
          ((string-match "\\(.*#\\)\\(.*\\)" string)
           (setq first-part (concat first-part (match-string 1 string)))
           (setq string (match-string 2 string))
           (setq completion (p4-list-completion
                             string (list "none" "head" "have")
                             predicate action)))
          ((string-match "^//" string)
           (setq completion (p4-arg-complete 'filespec string predicate action)))
          ((string-match "\\(^-\\)\\(.*\\)" string)
           (setq first-part (concat first-part (match-string 1 string)))
           (setq string (match-string 2 string))
           (setq completion (p4-list-completion
                             string (list "a " "af " "am " "as " "at " "ay "
                                          "b " "c " "d " "dc " "dn "
                                          "ds " "du " "e " "f " "i " "j "
                                          "l " "m " "n " "q " "r " "s " "sa "
                                          "sd " "se " "sr " "t " "v ")
                             predicate action)))
          (t
           (setq completion (p4-file-name-completion string predicate action))))
    (if (and (null action)              ; try-completion
             (stringp completion))
        (concat first-part completion)
      completion)))

(defun p4-list-completion (string lst predicate action)
  "Complete list on STRING LST PREDICATE ACTION."
  (let ((collection (mapcar 'list lst)))
    (cond ((not action)
           (try-completion string collection predicate))
          ((eq action t)
           (all-completions string collection predicate))
          (t
           (eq (try-completion string collection predicate) t)))))

(defun p4-file-name-completion (string predicate action)
  "File completion using STRING PREDICATE ACTION."
  (ignore predicate)
  (if (string-match "//\\(.*\\)" string)
      (setq string (concat "/" (match-string 1 string))))
  (setq string (substitute-in-file-name string))
  (setq string (p4-follow-link-name (expand-file-name string)))
  (let ((dir-path "") completion)
    (if (string-match "^\\(.*[/\\]\\)\\(.*\\)" string)
        (progn
          (setq dir-path (match-string 1 string))
          (setq string (match-string 2 string))))
    (cond ((not action)
           (setq completion (file-name-completion string dir-path))
           (if (stringp completion)
               (concat dir-path completion)
             completion))
          ((eq action t)
           (file-name-all-completions string dir-path))
          (t
           (eq (file-name-completion string dir-path) t)))))


;;; Basic mode:

;; Major mode used for most P4 output buffers, and as the parent mode
;; for specialized modes below.

(defvar p4-basic-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] 'p4-buffer-mouse-clicked)
    (define-key map "\t" 'p4-forward-active-link)
    (define-key map "\e\t" 'p4-backward-active-link)
    (define-key map [(shift tab)] 'p4-backward-active-link)
    (define-key map "\C-m" 'p4-buffer-commands)
    (define-key map "q" 'quit-window)
    (define-key map "g" 'revert-buffer)
    (define-key map "k" 'p4-scroll-down-1-line)
    (define-key map "j" 'p4-scroll-up-1-line)
    (define-key map "d" 'p4-scroll-down-1-window)
    (define-key map "u" 'p4-scroll-up-1-window)
    (define-key map "n" 'next-line)
    (define-key map "p" 'previous-line)
    (define-key map "<" 'p4-top-of-buffer)
    (define-key map ">" 'p4-bottom-of-buffer)
    (define-key map "=" 'delete-other-windows)
    map))

(define-derived-mode p4-basic-mode nil "P4 Basic")

(defun p4-buffer-mouse-clicked (event)
  "Call `p4-buffer-commands' at the EVENT point clicked on with the mouse."
  (interactive "e")
  (select-window (posn-window (event-end event)))
  (goto-char (posn-point (event-start event)))
  (when (get-text-property (point) 'active)
    (p4-buffer-commands (point))))

(defun p4--describe-view-depot-file ()
  "Describe depot file.
If we are in a P4 describe buffer an one clicked on a depot
path, view it via p4 print and return t else return nil"
  (let (ans)
    (when (string-match "^P4 describe" (buffer-name))
      (save-excursion
        (beginning-of-line)
        (when (looking-at "^\\.\\.\\. \\(//[^ #]+\\)\\(#[0-9]+\\)")
          (let ((depot-path (buffer-substring-no-properties (match-beginning 1) (match-end 1)))
                (rev (buffer-substring-no-properties (match-beginning 2) (match-end 2))))
            ;; For submitted changelists, we p4 print //path/to/file.ext#REV, otherwise
            ;; we are in a pending changelist "shelved section" and we need to
            ;; p4 print //path/to/file.ext@=CHANGENUM
            (if (re-search-backward "^Shelved files \\.\\.\\." nil t)
                ;; In a pending changelist shelved section
                (when (re-search-backward "^Change \\([0-9]+\\) by" nil t)
                  (let ((cn (match-string 1)))
                    (p4-print (list (concat depot-path "@=" cn)))
                    (setq ans t)))
              (p4-print (list (concat depot-path rev)))
              (setq ans t))))))
    ;; ans is t if we p4 print'd the item at point
    ans))

(defun p4-buffer-commands (pnt &optional arg)
  "Function to get a given property and do the appropriate command on it.
Uses PNT and ARG."
  (interactive "d\nP")
  (let ((action (get-char-property pnt 'action))
        (active (get-char-property pnt 'active))
        (branch (get-char-property pnt 'branch))
        (change (get-char-property pnt 'change))
        (client (get-char-property pnt 'client))
        (filename (p4-context-single-filename nil t))
        (group (get-char-property pnt 'group))
        (help (get-char-property pnt 'help))
        (job (get-char-property pnt 'job))
        (label (get-char-property pnt 'label))
        (pending (get-char-property pnt 'pending))
        (user (get-char-property pnt 'user))
        (rev (get-char-property pnt 'rev)))
    (cond ((and (not action) rev)
           (p4-call-command "print" (list (format "%s#%d" filename rev))
                            :callback 'p4-activate-print-buffer))
          (action
           (when (<= rev 1)
             (error "There is no earlier revision to diff"))
           (apply #'p4-diff2
                  (append (p4-make-list-from-string p4-default-diff-options)
                          (mapcar 'p4-get-file-rev (list (1- rev) rev)))))
          (change (apply #'p4-describe-click-callback (list (format "%d" change))))
          (pending (p4-change pending))
          (user (p4-user user))
          (group (p4-group group))
          (client (p4-client client))
          (label (p4-label (list label)))
          (branch (p4-branch (list branch)))
          (job (p4-job job))
          (help (p4-help help))
          ((and (not active) (eq major-mode 'p4-diff-mode))
           (if (not (p4--describe-view-depot-file))
               (p4-diff-goto-source arg)))

          ;; Check if a "filename link" or an active "diff buffer area" was
          ;; selected.
          (t
           (let ((link-client-name (get-char-property pnt 'link-client-name))
                 (link-depot-name (get-char-property pnt 'link-depot-name))
                 (block-client-name (get-char-property pnt 'block-client-name))
                 (block-depot-name (get-char-property pnt 'block-depot-name))
                 (history-for (get-char-property pnt 'history-for))
                 (first-line (get-char-property pnt 'first-line))
                 (start (get-char-property pnt 'start)))
             (cond
              (history-for
               (p4-file-change-log "filelog" (list history-for)))
              ((or link-client-name link-depot-name)
               (p4-find-file-or-print-other-window
                link-client-name link-depot-name))
              ((or block-client-name block-depot-name)
               (if first-line
                   (let ((c (max 0 (- pnt
                                      (save-excursion
                                        (goto-char pnt)
                                        (beginning-of-line)
                                        (point))
                                      1)))
                         (r first-line))
                     (save-excursion
                       (goto-char start)
                       (while (re-search-forward "^[ +>].*\n" pnt t)
                         (setq r (1+ r))))
                     (p4-find-file-or-print-other-window
                      block-client-name block-depot-name)
                     (p4-goto-line r)
                     (if (not block-client-name)
                         (forward-line 1))
                     (beginning-of-line)
                     (goto-char (+ (point) c)))
                 (p4-find-file-or-print-other-window
                  block-client-name block-depot-name)))))))))

(defun p4-forward-active-link ()
  "Forward active link."
  (interactive)
  (while (and (not (eobp))
              (goto-char (next-overlay-change (point)))
              (not (get-char-property (point) 'face)))))

(defun p4-backward-active-link ()
  "Backward active link."
  (interactive)
  (while (and (not (bobp))
              (goto-char (previous-overlay-change (point)))
              (not (get-char-property (point) 'face)))))

(defun p4-scroll-down-1-line ()
  "Scroll down one line."
  (interactive)
  (scroll-down 1))

(defun p4-scroll-up-1-line ()
  "Scroll up one line."
  (interactive)
  (scroll-up 1))

(defun p4-scroll-down-1-window ()
  "Scroll down one window."
  (interactive)
  (scroll-down
   (- (window-height) next-screen-context-lines)))

(defun p4-scroll-up-1-window ()
  "Scroll up one window."
  (interactive)
  (scroll-up
   (- (window-height) next-screen-context-lines)))

(defun p4-top-of-buffer ()
  "Top of buffer."
  (interactive)
  (goto-char (point-min)))

(defun p4-bottom-of-buffer ()
  "Bottom of buffer."
  (interactive)
  (goto-char (point-max)))


;;; Basic List Mode:

;; This is for the output of files, sync, have, integ, labelsync, and
;; reconcile, which consists of a list of lines starting with a depot
;; filespec.

(defvar p4-basic-list-mode-map
  (let ((map (p4-make-derived-map p4-basic-mode-map)))
    (define-key map "\C-m" 'p4-basic-list-activate)
    map)
  "The keymap to use in P4 Basic List Mode.")

(defvar p4-basic-list-font-lock-keywords
  '(
    ("^\\(//.*#[1-9][0-9]*\\) - \\(?:\\(?:unshelved, \\)?opened for \\)?add"
     1 'p4-depot-add-face)
    ("^\\(//.*#[1-9][0-9]*\\) - \\(?:\\(?:unshelved, \\)?opened for \\)?\\(?:branch\\|integrate\\)"
     1 'p4-depot-branch-face)
    ("^\\(//.*#[1-9][0-9]*\\) - \\(?:\\(?:unshelved, \\)?opened for \\)?delete"
     1 'p4-depot-delete-face)
    ("^\\(//.*#[1-9][0-9]*\\) - \\(?:\\(?:unshelved, \\)?opened for \\)?\\(?:edit\\|updating\\)"
     1 'p4-depot-edit-face)
    ("^\\(//.*#[1-9][0-9]*\\) - \\(?:\\(?:unshelved, \\)?opened for \\)?move/delete"
     1 'p4-depot-move-delete-face)
    ("^\\(//.*#[1-9][0-9]*\\) - \\(?:\\(?:unshelved, \\)?opened for \\)?move/add"
     1 'p4-depot-move-add-face)
    ;; //branch/path/to/file.ext#1 - was edit, reverted
    ("^\\(//.*#[1-9][0-9]*\\)" 1 'p4-link-face)
    ("\\(HEAD#[0-9]+\\)"
     1 'font-lock-warning-face prepend)
    ("\\(NEEDS-RESOLVE\\)"
     1 'font-lock-warning-face prepend)
    ("\\(^#[^\n]+\\)"
     1 'p4-form-comment-face
     )))

(define-derived-mode p4-basic-list-mode p4-basic-mode "P4 Basic List"
  (setq font-lock-defaults '(p4-basic-list-font-lock-keywords t)))

(defvar p4-basic-list-filename-regexp
  "^\\(\\(//.*\\)#[1-9][0-9]*\\) - \\(\\(?:move/\\)?add\\)?")

(defun p4-basic-list-get-filename ()
  "Perforce basic list get filename."
  (save-excursion
    (beginning-of-line)
    (when (looking-at p4-basic-list-filename-regexp)
      (match-string (if (eq major-mode 'p4-opened-list-mode) 2 1)))))

(defun p4-basic-list-activate ()
  "Perforce basic list activate."
  (interactive)
  (if (get-char-property (point) 'active)
      (p4-buffer-commands (point))
    (save-excursion
      (beginning-of-line)
      (when (looking-at p4-basic-list-filename-regexp)
        (if (match-string 3)
            (let ((args (list "where" (match-string 2))))
              (p4-with-temp-buffer args
                                   (when (looking-at "//[^ \n]+ //[^ \n]+ \\(.*\\)")
                                     (find-file (match-string 1)))))
          (let ((depot-path (match-string-no-properties 1)))
            (if (looking-at "^\\(\\(//.*\\)#[1-9][0-9]*\\) - \\(?:move/\\)?delete")
                (p4-print `(,depot-path))
              (p4-depot-find-file depot-path))))))))

;;; Opened list mode:

;; This is for the output of p4 opened, where each line starts with
;; the depot filename for an opened file.

(defvar p4-opened-list-mode-map
  (let ((map (p4-make-derived-map p4-basic-list-mode-map)))
    (define-key map "c" 'p4--opened-reopen-changenum)
    (define-key map "g" 'p4--opened-refresh)
    (define-key map "r" 'p4--opened-revert)
    (define-key map "t" 'p4--opened-reopen-filetype)
    map)
  "The key map to use in P4 Status List Mode.")

(defvar p4-opened-list-font-lock-keywords
  (append p4-basic-list-font-lock-keywords
          '(("\\<change \\([1-9][0-9]*\\) ([a-z]+)" 1 'p4-change-face))))

(define-derived-mode p4-opened-list-mode p4-basic-list-mode "P4 Opened List"
  (setq font-lock-defaults '(p4-opened-list-font-lock-keywords t)))

(defun p4--opened-refresh ()
  "Re-run \"p4 opened\" in a \"P4 opened\" buffer."
  (interactive)
  (let ((curr-point (point))
        depot-path)
    (save-excursion
      (beginning-of-line)
      (when (looking-at p4-basic-list-filename-regexp)
        (setq depot-path (buffer-substring-no-properties (match-beginning 2) (match-end 2))))
      (p4-opened p4--opened-args)
      (when (and depot-path
                 (re-search-forward (concat "^" (regexp-quote depot-path) "#") nil t))
        (beginning-of-line)
        (setq curr-point (point))))
    (goto-char (if (< curr-point (point-max)) curr-point (point-max)))))

(defun p4--opened-reopen-filetype (filetype)
  "Change file type: p4 reopen -c FILETYPE."
  (interactive "sp4 reopen -c FILETYPE (text, binary, etc): ")
  (save-excursion
    (beginning-of-line)
    (when (looking-at p4-basic-list-filename-regexp)
      (p4-reopen (list "-t" filetype (match-string 2)))))
  (p4--opened-refresh))

(defun p4--opened-reopen-changenum (changenum)
  "Move to specified changelist: p4 reopen -c CHANGENUM."
  (interactive
   (list (p4-completing-read 'pending "p4 reopen -c CHANGENUM (number or default): ")))
  (save-excursion
    (beginning-of-line)
    (when (looking-at p4-basic-list-filename-regexp)
      (p4-reopen (list "-c" changenum (match-string 2)))))
  (p4--opened-refresh))

(defun p4--opened-revert ()
  "Perforce opened revert."
  (interactive)
  (call-interactively 'p4-revert)
  (let ((curr-point (point)))
    (save-excursion
      (p4--opened-refresh))
    (let ((new-point (if (< curr-point (point-max)) curr-point (point-max))))
      (save-excursion
        (goto-char new-point)
        (beginning-of-line)
        (setq new-point (point)))
      (goto-char new-point))))

;;; Status List Mode:

;; This is for the output of p4 status, where each line starts with a
;; client filename.

(defvar p4-status-list-mode-map
  (let ((map (p4-make-derived-map p4-basic-list-mode-map)))
    (define-key map "\C-m" 'p4-status-list-activate)
    map)
  "The key map to use in P4 Status List Mode.")

(defvar p4-status-list-font-lock-keywords
  '(("^\\(.*\\) - reconcile to add" 1 'p4-depot-add-face)
    ("^\\(.*\\) - reconcile to delete" 1 'p4-depot-delete-face)
    ("^\\(.*\\) - reconcile to edit" 1 'p4-depot-edit-face)))

(define-derived-mode p4-status-list-mode p4-basic-list-mode "P4 Status List"
  (setq font-lock-defaults '(p4-status-list-font-lock-keywords t)))

(defun p4-status-list-activate ()
  "Perforce status list activate."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^\\(.*\\) - reconcile to ")
      (find-file-other-window (match-string 1)))))


;;; Form mode:

(defvar p4-form-font-lock-keywords
  '(("^#.*$" . 'p4-form-comment-face)
    ("^\\(Status:\\)[ \t]+\\(new\\|pending\\)"
     (1 'p4-form-keyword-face)
     (2 'p4-highlight-face))
    ("^[^ \t\n:]+:" . 'p4-form-keyword-face)))

(defvar p4-form-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-x\C-s" 'p4-form-commit)
    (define-key map "\C-c\C-c" 'p4-form-commit)
    map)
  "Keymap for P4 form mode.")

(define-derived-mode p4-form-mode text-mode "P4 Form"
  "Major mode for P4 forms."
  (setq fill-column 100
        indent-tabs-mode t
        font-lock-defaults '(p4-form-font-lock-keywords t)))

;;; File Form mode:

(defvar p4-file-form-font-lock-keywords
  '(("^#.*$" . 'p4-form-comment-face)
    ("^[^ \t\n:]+:" . 'p4-form-keyword-face)))

(defvar p4-file-form-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for p4-file-form-mode.")

(define-derived-mode p4-file-form-mode text-mode "P4 File Form"
  "Major mode for \"p4 client\" and \"p4 change\"."
  (setq fill-column 100
        indent-tabs-mode t
        font-lock-defaults '(p4-form-font-lock-keywords t)))

;;; Change form mode::

(defvar p4-change-form-mode-map
  (let ((map (p4-make-derived-map p4-form-mode-map)))
    (define-key map "\C-c\C-r" 'p4--change-form-refresh)
    (define-key map "\C-c\C-s" 'p4--change-form-submit)
    (define-key map "\C-c\C-p" 'p4--change-form-update)
    (define-key map "\C-c\C-d" 'p4--change-form-delete)
    map)
  "Keymap for P4 change form mode.")

(define-derived-mode p4-change-form-mode p4-form-mode "P4 Change")

(defun p4--change-form-refresh()
  "Refresh the change form by fetching contents from the server."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      ;; Change: NUM
      (goto-char (point-min))
      (if (re-search-forward "^Change:\\s-+\\(new\\|[0-9]+\\)$" nil t)
          (let ((cn (match-string 1)))
            (when (string= cn "new")
              (user-error "Cannot refresh a new pending changelist"))
            (p4-change cn))
        ;; shouldn't be able to get here
        (error "Unable to locate 'Change: NUM'"))
      )))

(defun p4--change-form-submit ()
  "Submit the change in the current buffer to the server."
  (interactive)
  (let ((p4-form-commit-command "submit"))
    (p4-form-commit)))

(defun p4--change-form-update ()
  "Update the changelist description on the server."
  (interactive)
  (let ((p4-form-commit-command "change"))
    (p4-form-commit)))

(defun p4--change-form-delete ()
  "Delete the change in the current buffer."
  (interactive)
  (let ((change (p4-form-value "Change")))
    (when (and change (not (string= change "new"))
               (yes-or-no-p "Really delete this change? "))
      (p4-change "-d" change)
      (p4-partial-cache-cleanup 'pending)
      (p4-partial-cache-cleanup 'shelved))))


;;; Job form mode::

(defvar p4-job-form-mode-map
  (let ((map (p4-make-derived-map p4-form-mode-map)))
    (define-key map "\C-c\C-f" 'p4-job-form-fixes)
    map)
  "Keymap for P4 job form mode.")

(define-derived-mode p4-job-form-mode p4-form-mode "P4 Job")

(defun p4-job-form-fixes ()
  "Show the fixes for this job."
  (interactive)
  (let ((job (p4-form-value "Job")))
    (when (and job (not (string= job "new")))
      (p4-fixes (list "-j" job)))))


;;; Filelog mode:

(defvar p4-filelog-mode-map
  (let ((map (p4-make-derived-map p4-basic-mode-map)))
    (define-key map "s" 'p4-filelog-short-format)
    (define-key map "l" 'p4-filelog-long-format)
    (define-key map "n" 'p4-filelog-goto-next-item)
    (define-key map "p" 'p4-filelog-goto-prev-item)
    (define-key map "f" 'p4-find-file-other-window)
    (define-key map "e" 'p4-ediff2)
    (define-key map "D" 'p4-diff2)
    (define-key map "k" 'p4-scroll-down-line-other-window)
    (define-key map "j" 'p4-scroll-up-line-other-window)
    (define-key map "d" 'p4-scroll-down-page-other-window)
    (define-key map "u" 'p4-scroll-up-page-other-window)
    (define-key map [backspace] 'p4-scroll-down-page-other-window)
    (define-key map " " 'p4-scroll-up-page-window-other-window)
    (define-key map "<" 'p4-top-of-buffer-other-window)
    (define-key map ">" 'p4-bottom-of-buffer-other-window)
    map)
  "The key map to use for selecting filelog properties.")

(defvar p4-filelog-font-lock-keywords
  '(("^#.*" . 'font-lock-comment-face)
    ("^//.*" . 'p4-filespec-face)
    ("\\(?:^\\.\\.\\. #\\([1-9][0-9]*\\) \\)?[Cc]hange \\([1-9][0-9]*\\)\\(?: \\([a-z]+\\)\\)? on [0-9]+/[0-9]+/[0-9]+\\(?: [0-9]+:[0-9]+:[0-9]+\\) by \\(\\S-+\\)@\\(\\S-+\\).*"
     (1 'p4-revision-face nil t) (2 'p4-change-face) (3 'p4-action-face nil t)
     (4 'p4-user-face) (5 'p4-client-face))
    ("^\\.\\.\\. \\.\\.\\. [^/\n]+ \\(//[^#\n]+\\).*" (1 'p4-filespec-face))
    ("^\t.*" . 'p4-description-face)))

(define-derived-mode p4-filelog-mode p4-basic-mode "P4 File Log"
  (setq font-lock-defaults '(p4-filelog-font-lock-keywords t)))

(defun p4-find-file-other-window ()
  "Open/print file."
  (interactive)
  (let ((link-client-name (get-char-property (point) 'link-client-name))
        (link-depot-name (get-char-property (point) 'link-depot-name))
        (block-client-name (get-char-property (point) 'block-client-name))
        (block-depot-name (get-char-property (point) 'block-depot-name)))
    (cond ((or link-client-name link-depot-name)
           (p4-find-file-or-print-other-window
            link-client-name link-depot-name)
           (other-window 1))
          ((or block-client-name block-depot-name)
           (p4-find-file-or-print-other-window
            block-client-name block-depot-name)
           (other-window 1)))))

(defun p4-filelog-short-format ()
  "Short format."
  (interactive)
  (setq buffer-invisibility-spec t)
  (redraw-display))

(defun p4-filelog-long-format ()
  "Long format."
  (interactive)
  (setq buffer-invisibility-spec (list))
  (redraw-display))

(defun p4-scroll-down-line-other-window ()
  "Scroll other window down one line."
  (interactive)
  (scroll-other-window -1))

(defun p4-scroll-up-line-other-window ()
  "Scroll other window up one line."
  (interactive)
  (scroll-other-window 1))

(defun p4-scroll-down-page-other-window ()
  "Scroll other window down one page."
  (interactive)
  (scroll-other-window
   (- next-screen-context-lines (window-height))))

(defun p4-scroll-up-page-other-window ()
  "Scroll other window up one page."
  (interactive)
  (scroll-other-window
   (- (window-height) next-screen-context-lines)))

(defun p4-top-of-buffer-other-window ()
  "Top of buffer, other window."
  (interactive)
  (other-window 1)
  (goto-char (point-min))
  (other-window -1))

(defun p4-bottom-of-buffer-other-window ()
  "Bottom of buffer, other window."
  (interactive)
  (other-window 1)
  (goto-char (point-max))
  (other-window -1))

(defun p4-filelog-goto-next-item ()
  "Next change or item."
  (interactive)
  (forward-line 1)
  (if (string-match "^P4 filelog" (buffer-name))
      (let ((next-change-re "^\\.\\.\\. #"))
        (while (and (not (eobp))
                    (not (looking-at next-change-re)))
          (forward-line 1))
        (move-to-column (if (looking-at next-change-re) 5 0)))
    ;; else non-filelog buffer using filelog mode
    (let ((c (current-column)))
      (while (and (not (eobp))
                  (or (looking-at "^#") ;; header comment?
                      (get-char-property (point) 'invisible)))
        (forward-line 1))
      (move-to-column c))))

(defun p4-filelog-goto-prev-item ()
  "Previous change or item."
  (interactive)
  (forward-line -1)
  (if (string-match "^P4 filelog" (buffer-name))
      (let ((prev-change-re "^\\.\\.\\. #"))
        (while (and (not (bobp))
                    (not (looking-at prev-change-re)))
          (forward-line -1))
        (move-to-column (if (looking-at prev-change-re) 5 0)))
    ;; else non-filelog buffer using filelog mode
    (let ((c (current-column)))
      (while (and (not (bobp))
                  (or (looking-at "^#") ;; header comment?
                      (get-char-property (point) 'invisible)))
        (forward-line -1))
      (move-to-column c))))


;;; Diff mode:

(defvar p4-diff-mode-map
  (let ((map (p4-make-derived-map p4-basic-mode-map)))
    (define-key map "\t"      'diff-hunk-next)
    (define-key map "n"       'diff-hunk-next)
    (define-key map "p"       'diff-hunk-prev)
    (define-key map [backtab] 'diff-hunk-prev)
    (define-key map "N"       'diff-file-next)
    (define-key map "}"       'diff-file-next)
    (define-key map "P"       'diff-file-prev)
    (define-key map "{"       'diff-file-prev)
    (define-key map "e"       'p4-ediff-file-at-point)
    (define-key map "\C-m"    'p4-buffer-commands)
    (define-key map [mouse-2] 'p4-buffer-commands)
    (define-key map "o"       'p4-buffer-commands)
    map))

(easy-menu-define
  p4-diff-menu p4-diff-mode-map "P4 Diff Menu."
  '("P4Diff"
    ["Next file (N)" diff-file-next]
    ["Prev file (P)" diff-file-prev]
    ["Next hunk (n)" diff-file-next]
    ["Prev hunk (p)" diff-file-prev]
    ["Ediff file at point" p4-ediff-file-at-point]
    ["Open item at point" p4-buffer-commands]))

(defvar p4-diff-font-lock-keywords
  '(("^\\(Change \\([1-9][0-9]*\\) by \\(\\S-+\\)@\\(\\S-+\\) on [0-9]+/.*\\)"
     (2 'p4-change-face) (3 'p4-user-face) (4 'p4-client-face)
     (1 'p4-highlight-face prepend))
    ("^\\(\\S-+\\) on [0-9]+/[0-9]+/[0-9]+ by \\(\\S-+\\).*"
     (1 'p4-job-face) (2 'p4-user-face))
    ("^\t.*" . 'p4-description-face)
    ("^[A-Z].* \\.\\.\\." . 'p4-heading-face)
    ("^\\.\\.\\. \\(//[^# \t\n]+\\).*" (1 'p4-filespec-face))
    ("^==== .* ====" . 'diff-file-header)))

(define-derived-mode p4-diff-mode p4-basic-mode "P4 Diff"
  (diff-minor-mode 1)
  (use-local-map p4-diff-mode-map)
  (set (make-local-variable 'diff-file-header-re)
       (concat "^==== .* ====\\|" diff-file-header-re))
  (setq font-lock-defaults diff-font-lock-defaults)
  (font-lock-add-keywords nil p4-diff-font-lock-keywords))

(defun p4-diff-find-file-name (&optional reverse)
  "Return the filespec where this diff location can be found.
Return the new filespec, or the old filespec if optional argument
REVERSE is non-NIL."
  (save-excursion
    (unless (looking-at diff-file-header-re)
      (or (ignore-errors (diff-beginning-of-file))
          (re-search-forward diff-file-header-re nil t)))
    (cond ((looking-at "^==== \\(//[^#\n]+#[1-9][0-9]*\\).* - \\(//[^#\n]+#[1-9][0-9]*\\).* ====")
           ;; In the output of p4 diff and diff2 both the old and new
           ;; revisions are given.
           (match-string-no-properties (if reverse 1 2)))
          ((looking-at "^==== \\(//[^@#\n]+\\)#\\([1-9][0-9]*\\).* ====")
           ;; The output of p4 describe contains just the new
           ;; revision number: the old revision number is one less.
           (let ((revision (string-to-number (match-string 2))))
             (format "%s#%d" (match-string-no-properties 1)
                     (max 1 (if reverse (1- revision) revision)))))
          ((looking-at "^--- \\(//[^\t\n]+\\)\t\\([1-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\)[.0-9]* \\([+-]?\\)\\([0-9][0-9][0-9][0-9]\\).*\n\\+\\+\\+ \\([^\t\n]+\\)\t")
           (if reverse
               (let ((time (date-to-time (format "%s %s%s" (match-string 2)
                                                 ;; Time zone sense seems to be backwards!
                                                 (if (string-equal (match-string 3) "-") "+" "-")
                                                 (match-string 4)))))
                 (format "%s@%s" (match-string-no-properties 1)
                         (format-time-string "%Y/%m/%d:%H:%M:%S" time t)))
             (match-string-no-properties 5)))
          (t
           (error "Can't find filespec(s) in diff file header")))))

;; This is modeled on diff-find-source-location in diff-mode.el.
(defun p4-diff-find-source-location (&optional reverse)
  "Return (FILESPEC LINE OFFSET) for the corresponding source location.
FILESPEC is the new file, or the old file if optional argument
REVERSE is non-NIL.  The location in the file can be found by
going to line number LINE and then moving forward OFFSET
characters."
  (save-excursion
    (let* ((char-offset (- (point) (diff-beginning-of-hunk t)))
           (_ (diff-sanity-check-hunk))
           (hunk (buffer-substring
                  (point) (save-excursion (diff-end-of-hunk) (point))))
           (old (diff-hunk-text hunk nil char-offset))
           (new (diff-hunk-text hunk t char-offset))
           ;; Find the location specification.
           (line (if (not (looking-at "\\(?:\\*\\{15\\}.*\n\\)?[-@* ]*\\([0-9,]+\\)\\([ acd+]+\\([0-9,]+\\)\\)?"))
                     (error "Can't find the hunk header")
                   (if reverse (match-string 1)
                     (if (match-end 3) (match-string 3)
                       (unless (re-search-forward
                                diff-context-mid-hunk-header-re nil t)
                         (error "Can't find the hunk separator"))
                       (match-string 1)))))
           (file (or (p4-diff-find-file-name reverse)
                     (error "Can't find the file"))))
      (list file (string-to-number line) (cdr (if reverse old new))))))

;; Based on diff-goto-source in diff-mode.el.
(defun p4-diff-goto-source (&optional other-file event)
  "Jump to the corresponding source line.
The old file is visited for removed lines, otherwise the new
file, but a prefix argument reverses this.
Optional:: OTHER-FILE, EVENT."
  (interactive (list current-prefix-arg last-input-event))
  (if event (posn-set-point (event-end event)))
  (let ((reverse (save-excursion (beginning-of-line) (looking-at "[-<]"))))
    (condition-case nil
        (let ((location (p4-diff-find-source-location
                         (diff-xor other-file reverse))))
          (when location
            (apply 'p4-depot-find-file location)))
      ;; If p4-diff-find-source-location has an error ignore it. Consider a p4 describe buffer
      ;; where "RET" ended up here because p4-diff-goto-source was called by p4-buffer-commands.
      (error nil))))


;;; Annotate mode:

(defvar p4-annotate-mode-map
  (let ((map (p4-make-derived-map p4-basic-mode-map)))
    (define-key map "n" 'p4--annotate-next-change-rev)
    (define-key map "p" 'p4--annotate-prev-change-rev)
    (define-key map "l" 'p4--toggle-line-wrap)
    (define-key map "g" 'p4--annotate-goto-source-line)
    map)
  "The key map to use for browsing annotate buffers.")

(define-derived-mode p4-annotate-mode p4-basic-mode "P4 Annotate")

(defun p4--annotate-next-change-rev ()
  "In annotate buffer, move to next change/revision."
  (interactive)
  (let (new-point)
    (save-excursion
      (move-to-column 1)
      (when (re-search-forward "^ *[0-9]+ +#" nil t)
        (setq new-point (point))))
    (when new-point
      (goto-char new-point))))

(defun p4--annotate-prev-change-rev ()
  "In annotate buffer, move to previous change/revision."
  (interactive)
  (let (new-point)
    (save-excursion
      (move-to-column 0)
      (when (re-search-backward "^ *[0-9]+ +#" nil t)
        (re-search-forward "#" nil nil)
        (setq new-point (point))))
    (when new-point
      (goto-char new-point))))

(defun p4--toggle-line-wrap ()
  "Toggle line wrap mode."
  (interactive)
  (setq truncate-lines (not truncate-lines))
  (save-window-excursion
    (recenter)))

(defun p4--annotate-goto-source-line (line)
  "In a p4 annotate buffer, goto source LINE number."
  (declare (interactive-only forward-line))
  (interactive
   (list (read-number "Goto source line: " )))
  (goto-char (point-min))
  (forward-line (- (+ line p4--annotate-source-line-start) 2)))

;;; Grep Mode:

(defvar p4-grep-regexp-alist
  '(("^\\(//.*?#[1-9][0-9]*\\):\\([1-9][0-9]*\\):" 1 2))
  "Regexp used to match p4 grep hits, see `compilation-error-regexp-alist'.")

(eval-when-compile
  (require 'compile) ; silence warning about compilation-error-regexp-alist
  )

(define-derived-mode p4-grep-mode grep-mode "P4 Grep"
  (require 'compile) ; compilation-error-regexp-alist
  (set (make-local-variable 'compilation-error-regexp-alist)
       p4-grep-regexp-alist)
  (set (make-local-variable 'next-error-function)
       'p4-grep-next-error-function))

(defun p4-grep-find-file (marker filename directory &rest formats)
  "Perforce grep find file using MARKER FILENAME DIRECTORY, FORMATS."
  (ignore marker directory formats)
  (p4-depot-find-file-noselect filename))

(defun p4-grep-next-error-function (n &optional reset)
  "Advance to the next error message and visit the file where the error was.
This is the value of `next-error-function' in P4 Grep buffers.
Optional: N, RESET."
  (interactive "p")
  (let ((cff (symbol-function 'compilation-find-file)))
    (unwind-protect
        (progn (fset 'compilation-find-file 'p4-grep-find-file)
               (compilation-next-error-function n reset))
      (fset 'compilation-find-file cff))))

(provide 'p4)
;;; p4.el ends here

;; LocalWords:  Promislow Vaidheeswarran Osterlund Fujii Hironori Filsinger Rees gdr garethrees nxml
;; LocalWords:  comint dired VC defcustom memq nt dn dw dl truename cmds filelog jobspec labelsync
;; LocalWords:  passwd unshelve Keychain filespec defface NNN dolist alist Keymap keymap kbd dwim
;; LocalWords:  ediff fset defun filetype defun's diff's infile funcall defmacro zerop clrhash EDiff
;; LocalWords:  gethash setq puthash cdr IANA euc kr eucjp jp iso koi macosroman shiftjis jis nobom
;; LocalWords:  bom winansi fn progn setf noselect changelevel repeat:filespec mapconcat delq
;; LocalWords:  startfile bobp eobp eql noconfirm subst subst'ed subst'd upcase buf mapcar
;; LocalWords:  stringp defp arglist docstring changenum diff'ing fboundp diffview integerp fontify
;; LocalWords:  cgit reviewboard defalias prev pw sr sync'ing hange isearch noop lsp letf
;; LocalWords:  fontification fontified propertize defconst acd defstruct fspec ztag nondirectory
;; LocalWords:  yyyy gregorian htmlize ol caar incf MVCE nreverse repeat:nil undoc listp
;; LocalWords:  noerror assq minibuffer downcase xtext xbinary af posn print'd pnt unshelved sp
;; LocalWords:  backtab cff
