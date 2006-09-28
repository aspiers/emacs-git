;;; make-mode.el --- makefile editing commands for Emacs

;; Copyright (C) 1992, 1994, 1999, 2000, 2001, 2002, 2003, 2004, 2005, 2006
;; Free Software Foundation, Inc.

;; Author: Thomas Neumann <tom@smart.bo.open.de>
;;	Eric S. Raymond <esr@snark.thyrsus.com>
;; Maintainer: FSF
;; Adapted-By: ESR
;; Keywords: unix, tools

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; A major mode for editing makefiles.  The mode knows about Makefile
;; syntax and defines M-n and M-p to move to next and previous productions.
;;
;; The keys $, =, : and . are electric; they try to help you fill in a
;; macro reference, macro definition, ordinary target name, or special
;; target name, respectively.  Such names are completed using a list of
;; targets and macro names parsed out of the makefile.  This list is
;; automatically updated, if necessary, whenever you invoke one of
;; these commands.  You can force it to be updated with C-c C-p.
;;
;; The command C-c C-f adds certain filenames in the current directory
;; as targets.  You can filter out filenames by setting the variable
;; makefile-ignored-files-in-pickup-regex.
;;
;; The command C-c C-u grinds for a bit, then pops up a report buffer
;; showing which target names are up-to-date with respect to their
;; prerequisites, which targets are out-of-date, and which have no
;; prerequisites.
;;
;; The command C-c C-b pops up a browser window listing all target and
;; macro names.  You can mark or unmark items with C-c SPC, and insert
;; all marked items back in the Makefile with C-c TAB.
;;
;; The command C-c TAB in the makefile buffer inserts a GNU make builtin.
;; You will be prompted for the builtin's args.
;;
;; There are numerous other customization variables.

;;
;; To Do:
;;
;; * Add missing doc strings, improve terse doc strings.
;; * Eliminate electric stuff entirely.
;; * It might be nice to highlight targets differently depending on
;;   whether they are up-to-date or not.  Not sure how this would
;;   interact with font-lock.
;; * Would be nice to edit the commands in ksh-mode and have
;;   indentation and slashification done automatically.  Hard.
;; * Consider removing browser mode.  It seems useless.
;; * ":" should notice when a new target is made and add it to the
;;   list (or at least set makefile-need-target-pickup).
;; * Make browser into a major mode.
;; * Clean up macro insertion stuff.  It is a mess.
;; * Browser entry and exit is weird.  Normalize.
;; * Browser needs to be rewritten.  Right now it is kind of a crock.
;;   Should at least:
;;    * Act more like dired/buffer menu/whatever.
;;    * Highlight as mouse traverses.
;;    * B2 inserts.
;; * Update documentation above.
;; * Update texinfo manual.
;; * Update files.el.



;;; Code:

;; Sadly we need this for a macro.
(eval-when-compile
  (require 'imenu)
  (require 'dabbrev)
  (require 'add-log))

;;; ------------------------------------------------------------
;;; Configurable stuff
;;; ------------------------------------------------------------

(defgroup makefile nil
  "Makefile editing commands for Emacs."
  :link '(custom-group-link :tag "Font Lock Faces group" font-lock-faces)
  :group 'tools
  :prefix "makefile-")

(defface makefile-space
  '((((class color)) (:background  "hotpink"))
    (t (:reverse-video t)))
  "Face to use for highlighting leading spaces in Font-Lock mode."
  :group 'makefile)
(put 'makefile-space-face 'face-alias 'makefile-space)

(defface makefile-targets
  ;; This needs to go along both with foreground and background colors (i.e. shell)
  '((t (:inherit font-lock-function-name-face)))
  "Face to use for additionally highlighting rule targets in Font-Lock mode."
  :group 'makefile
  :version "22.1")

(defface makefile-shell
  ()
  ;;'((((class color) (min-colors 88) (background light)) (:background  "seashell1"))
  ;;  (((class color) (min-colors 88) (background dark)) (:background  "seashell4")))
  "Face to use for additionally highlighting Shell commands in Font-Lock mode."
  :group 'makefile
  :version "22.1")

(defface makefile-makepp-perl
  '((((class color) (background light)) (:background  "LightBlue1")) ; Camel Book
    (((class color) (background dark)) (:background  "DarkBlue"))
    (t (:reverse-video t)))
  "Face to use for additionally highlighting Perl code in Font-Lock mode."
  :group 'makefile
  :version "22.1")

(defcustom makefile-browser-buffer-name "*Macros and Targets*"
  "*Name of the macro- and target browser buffer."
  :type 'string
  :group 'makefile)

(defcustom makefile-target-colon ":"
  "*String to append to all target names inserted by `makefile-insert-target'.
\":\" or \"::\" are common values."
  :type 'string
  :group 'makefile)

(defcustom makefile-macro-assign " = "
  "*String to append to all macro names inserted by `makefile-insert-macro'.
The normal value should be \" = \", since this is what
standard make expects.  However, newer makes such as dmake
allow a larger variety of different macro assignments, so you
might prefer to use \" += \" or \" := \" ."
  :type 'string
  :group 'makefile)

(defcustom makefile-electric-keys nil
  "*If non-nil, Makefile mode should install electric keybindings.
Default is nil."
  :type 'boolean
  :group 'makefile)

(defcustom makefile-use-curly-braces-for-macros-p nil
  "*Controls the style of generated macro references.
Non-nil means macro references should use curly braces, like `${this}'.
nil means use parentheses, like `$(this)'."
  :type 'boolean
  :group 'makefile)

(defcustom makefile-tab-after-target-colon t
  "*If non-nil, insert a TAB after a target colon.
Otherwise, a space is inserted.
The default is t."
  :type 'boolean
  :group 'makefile)

(defcustom makefile-browser-leftmost-column 10
  "*Number of blanks to the left of the browser selection mark."
  :type 'integer
  :group 'makefile)

(defcustom makefile-browser-cursor-column 10
  "*Column the cursor goes to when it moves up or down in the Makefile browser."
  :type 'integer
  :group 'makefile)

(defcustom makefile-backslash-column 48
  "*Column in which `makefile-backslash-region' inserts backslashes."
  :type 'integer
  :group 'makefile)

(defcustom makefile-backslash-align t
  "*If non-nil, `makefile-backslash-region' will align backslashes."
  :type 'boolean
  :group 'makefile)

(defcustom makefile-browser-selected-mark "+  "
  "*String used to mark selected entries in the Makefile browser."
  :type 'string
  :group 'makefile)

(defcustom makefile-browser-unselected-mark "   "
  "*String used to mark unselected entries in the Makefile browser."
  :type 'string
  :group 'makefile)

(defcustom makefile-browser-auto-advance-after-selection-p t
  "*If non-nil, cursor will move after item is selected in Makefile browser."
  :type 'boolean
  :group 'makefile)

(defcustom makefile-pickup-everything-picks-up-filenames-p nil
  "*If non-nil, `makefile-pickup-everything' picks up filenames as targets.
This means it calls `makefile-pickup-filenames-as-targets'.
Otherwise filenames are omitted."
  :type 'boolean
  :group 'makefile)

(defcustom makefile-cleanup-continuations nil
  "*If non-nil, automatically clean up continuation lines when saving.
A line is cleaned up by removing all whitespace following a trailing
backslash.  This is done silently.
IMPORTANT: Please note that enabling this option causes Makefile mode
to MODIFY A FILE WITHOUT YOUR CONFIRMATION when \"it seems necessary\"."
  :type 'boolean
  :group 'makefile)

(defcustom makefile-mode-hook nil
  "*Normal hook run by `makefile-mode'."
  :type 'hook
  :group 'makefile)

(defvar makefile-browser-hook '())

;;
;; Special targets for DMake, Sun's make ...
;;
(defcustom makefile-special-targets-list
  '(("DEFAULT")      ("DONE")        ("ERROR")        ("EXPORT")
    ("FAILED")       ("GROUPEPILOG") ("GROUPPROLOG")  ("IGNORE")
    ("IMPORT")       ("INCLUDE")     ("INCLUDEDIRS")  ("INIT")
    ("KEEP_STATE")   ("MAKEFILES")   ("MAKE_VERSION") ("NO_PARALLEL")
    ("PARALLEL")     ("PHONY")       ("PRECIOUS")     ("REMOVE")
    ("SCCS_GET")     ("SILENT")      ("SOURCE")       ("SUFFIXES")
    ("WAIT")         ("c.o")         ("C.o")          ("m.o")
    ("el.elc")       ("y.c")         ("s.o"))
  "*List of special targets.
You will be offered to complete on one of those in the minibuffer whenever
you enter a \".\" at the beginning of a line in `makefile-mode'."
  :type '(repeat (list string))
  :group 'makefile)
(put 'makefile-special-targets-list 'risky-local-variable t)

(defcustom makefile-runtime-macros-list
  '(("@") ("&") (">") ("<") ("*") ("^") ("+") ("?") ("%") ("$"))
  "*List of macros that are resolved by make at runtime.
If you insert a macro reference using `makefile-insert-macro-ref', the name
of the macro is checked against this list.  If it can be found its name will
not be enclosed in { } or ( )."
  :type '(repeat (list string))
  :group 'makefile)

;; Note that the first big subexpression is used by font lock.  Note
;; that if you change this regexp you might have to fix the imenu
;; index in makefile-imenu-generic-expression.
(defvar makefile-dependency-regex
  ;; Allow for two nested levels $(v1:$(v2:$(v3:a=b)=c)=d)
  "^\\(\\(?:\\$\\(?:[({]\\(?:\\$\\(?:[({]\\(?:\\$\\(?:[^({]\\|.[^\n$#})]+?[})]\\)\\|[^\n$#)}]\\)+?[})]\\|[^({]\\)\\|[^\n$#)}]\\)+?[})]\\|[^({]\\)\\|[^\n$#:=]\\)+?\\)\\(:\\)\\(?:[ \t]*$\\|[^=\n]\\(?:[^#\n]*?;[ \t]*\\(.+\\)\\)?\\)"
  "Regex used to find dependency lines in a makefile.")

(defconst makefile-bsdmake-dependency-regex
  (progn (string-match (regexp-quote "\\(:\\)") makefile-dependency-regex)
	 (replace-match "\\([:!]\\)" t t makefile-dependency-regex))
  "Regex used to find dependency lines in a BSD makefile.")

(defvar makefile-dependency-skip "^:"
  "Characters to skip to find a line that might be a dependency.")

(defvar makefile-rule-action-regex
  "^\t[ \t]*\\([-@]*\\)[ \t]*\\(\\(?:.*\\\\\n\\)*.*\\)"
  "Regex used to highlight rule action lines in font lock mode.")

(defconst makefile-makepp-rule-action-regex
  ;; Don't care about initial tab, but I don't know how to font-lock correctly without.
  "^\t[ \t]*\\(\\(?:\\(?:noecho\\|ignore[-_]error\\|[-@]+\\)[ \t]*\\)*\\)\\(\\(&\\S +\\)?\\(?:.*\\\\\n\\)*.*\\)"
  "Regex used to highlight makepp rule action lines in font lock mode.")

(defconst makefile-bsdmake-rule-action-regex
  (progn (string-match "-@" makefile-rule-action-regex)
	 (replace-match "-+@" t t makefile-rule-action-regex))
  "Regex used to highlight BSD rule action lines in font lock mode.")

;; Note that the first and second subexpression is used by font lock.  Note
;; that if you change this regexp you might have to fix the imenu index in
;; makefile-imenu-generic-expression.
(defconst makefile-macroassign-regex
  ;; We used to match not just the varname but also the whole value
  ;; (spanning potentially several lines).
  ;; "^ *\\([^ \n\t][^:#= \t\n]*\\)[ \t]*\\(?:!=[ \t]*\\(\\(?:.+\\\\\n\\)*.+\\)\\|[*:+]?[:?]?=[ \t]*\\(\\(?:.*\\\\\n\\)*.*\\)\\)"
  ;; What about the define statement?  What about differentiating this for makepp?
  "\\(?:^\\|^export\\|^override\\|:\\|: *override\\) *\\([^ \n\t][^:#= \t\n]*\\)[ \t]*\\(?:!=\\|[*:+]?[:?]?=\\)"
  "Regex used to find macro assignment lines in a makefile.")

(defconst makefile-var-use-regex
  "[^$]\\$[({]\\([-a-zA-Z0-9_.]+\\|[@%<?^+*][FD]?\\)"
  "Regex used to find $(macro) uses in a makefile.")

(defconst makefile-ignored-files-in-pickup-regex
  "\\(^\\..*\\)\\|\\(.*~$\\)\\|\\(.*,v$\\)\\|\\(\\.[chy]\\)"
  "Regex for filenames that will NOT be included in the target list.")

(defvar makefile-space 'makefile-space
  "Face to use for highlighting leading spaces in Font-Lock mode.")

;; These lists were inspired by the old solution.  But they are silly, because
;; you can't differentiate what follows.  They need to be split up.
(defconst makefile-statements '("include")
  "List of keywords understood by standard make.")

(defconst makefile-automake-statements
  `("if" "else" "endif" ,@makefile-statements)
  "List of keywords understood by automake.")

(defconst makefile-gmake-statements
  `("-sinclude" "sinclude" "vpath"	; makefile-makepp-statements takes rest
    "ifdef" "ifndef" "ifeq" "ifneq" "-include" "define" "endef" "export"
    "override define" "override" "unexport"
    ,@(cdr makefile-automake-statements))
  "List of keywords understood by gmake.")

;; These are even more silly, because you can have more spaces in between.
(defconst makefile-makepp-statements
  `("and ifdef" "and ifndef" "and ifeq" "and ifneq" "and ifperl"
    "and ifmakeperl" "and ifsys" "and ifnsys" "build_cache" "build_check"
    "else ifdef" "else ifndef" "else ifeq" "else ifneq" "else ifperl"
    "else ifmakeperl" "else ifsys" "else ifnsys" "enddef" "global"
    "load_makefile" "ifperl" "ifmakeperl" "ifsys" "ifnsys" "_include"
    "makeperl" "makesub" "no_implicit_load" "perl" "perl-begin" "perl_begin"
    "perl-end" "perl_end" "prebuild" "or ifdef" "or ifndef" "or ifeq"
    "or ifneq" "or ifperl" "or ifmakeperl" "or ifsys" "or ifnsys"
    "override export" "override global" "register_command_parser"
    "register_scanner" "repository" "runtime" "signature" "sub"
    ,@(nthcdr 3 makefile-gmake-statements))
  "List of keywords understood by gmake.")

(defconst makefile-bsdmake-statements
  `(".elif" ".elifdef" ".elifmake" ".elifndef" ".elifnmake" ".else" ".endfor"
    ".endif" ".for" ".if" ".ifdef" ".ifmake" ".ifndef" ".ifnmake" ".undef")
  "List of keywords understood by BSD make.")

(defun makefile-make-font-lock-keywords (var keywords space
					     &optional negation
					     &rest font-lock-keywords)
  `(;; Do macro assignments.  These get the "variable-name" face.
    (,makefile-macroassign-regex
     (1 font-lock-variable-name-face)
     ;; This is for after !=
     (2 'makefile-shell prepend t)
     ;; This is for after normal assignment
     (3 'font-lock-string-face prepend t))

    ;; Rule actions.
    (makefile-match-action
     (1 font-lock-type-face)
     (2 'makefile-shell prepend)
     ;; Only makepp has builtin commands.
     (3 font-lock-builtin-face prepend t))

    ;; Variable references even in targets/strings/comments.
    (,var 1 font-lock-variable-name-face prepend)

    ;; Automatic variable references and single character variable references,
    ;; but not shell variables references.
    ("[^$]\\$\\([@%<?^+*_]\\|[a-zA-Z0-9]\\>\\)"
     1 font-lock-constant-face prepend)
    ("[^$]\\(\\$[@%*]\\)"
     1 'makefile-targets append)

    ;; Fontify conditionals and includes.
    (,(concat "^\\(?: [ \t]*\\)?"
	      (regexp-opt keywords t)
	      "\\>[ \t]*\\([^: \t\n#]*\\)")
     (1 font-lock-keyword-face) (2 font-lock-variable-name-face))

    ,@(if negation
	  `((,negation (1 font-lock-negation-char-face prepend)
		       (2 font-lock-negation-char-face prepend t))))

    ,@(if space
	  '(;; Highlight lines that contain just whitespace.
	    ;; They can cause trouble, especially if they start with a tab.
	    ("^[ \t]+$" . makefile-space)

	    ;; Highlight shell comments that Make treats as commands,
	    ;; since these can fool people.
	    ("^\t+#" 0 makefile-space t)

	    ;; Highlight spaces that precede tabs.
	    ;; They can make a tab fail to be effective.
	    ("^\\( +\\)\t" 1 makefile-space)))

    ,@font-lock-keywords

    ;; Do dependencies.
    (makefile-match-dependency
     (1 'makefile-targets prepend)
     (3 'makefile-shell prepend t))))

(defconst makefile-font-lock-keywords
  (makefile-make-font-lock-keywords
   makefile-var-use-regex
   makefile-statements
   t))

(defconst makefile-automake-font-lock-keywords
  (makefile-make-font-lock-keywords
   makefile-var-use-regex
   makefile-automake-statements
   t))

(defconst makefile-gmake-font-lock-keywords
  (makefile-make-font-lock-keywords
   makefile-var-use-regex
   makefile-gmake-statements
   t
   "^\\(?: [ \t]*\\)?if\\(n\\)\\(?:def\\|eq\\)\\>"

   '("[^$]\\(\\$[({][@%*][DF][})]\\)"
     1 'makefile-targets append)

   ;; $(function ...) ${function ...}
   '("[^$]\\$[({]\\([-a-zA-Z0-9_.]+\\s \\)"
     1 font-lock-function-name-face prepend)

   ;; $(shell ...) ${shell ...}
   '("[^$]\\$\\([({]\\)shell[ \t]+"
     makefile-match-function-end nil nil
     (1 'makefile-shell prepend t))))

(defconst makefile-makepp-font-lock-keywords
  (makefile-make-font-lock-keywords
   makefile-var-use-regex
   makefile-makepp-statements
   nil
   "^\\(?: [ \t]*\\)?\\(?:and[ \t]+\\|else[ \t]+\\|or[ \t]+\\)?if\\(n\\)\\(?:def\\|eq\\|sys\\)\\>"

   '("[^$]\\(\\$[({]\\(?:output\\|stem\\|target\\)s?\\_>.*?[})]\\)"
     1 'makefile-targets append)

   ;; Colon modifier keywords.
   '("\\(:\\s *\\)\\(build_c\\(?:ache\\|heck\\)\\|env\\(?:ironment\\)?\\|foreach\\|signature\\|scanner\\|quickscan\\|smartscan\\)\\>\\([^:\n]*\\)"
     (1 font-lock-type-face t)
     (2 font-lock-keyword-face t)
     (3 font-lock-variable-name-face t))

   ;; $(function ...) $((function ...)) ${function ...} ${{function ...}}
   '("[^$]\\$\\(?:((?\\|{{?\\)\\([-a-zA-Z0-9_.]+\\s \\)"
     1 font-lock-function-name-face prepend)

   ;; $(shell ...) $((shell ...)) ${shell ...} ${{shell ...}}
   '("[^$]\\$\\(((?\\|{{?\\)shell\\(?:[-_]\\(?:global[-_]\\)?once\\)?[ \t]+"
     makefile-match-function-end nil nil
     (1 'makefile-shell prepend t))

   ;; $(perl ...) $((perl ...)) ${perl ...} ${{perl ...}}
   '("[^$]\\$\\(((?\\|{{?\\)makeperl[ \t]+"
     makefile-match-function-end nil nil
     (1 'makefile-makepp-perl prepend t))
   '("[^$]\\$\\(((?\\|{{?\\)perl[ \t]+"
     makefile-match-function-end nil nil
     (1 'makefile-makepp-perl t t))

   ;; Can we unify these with (if (match-end 1) 'prepend t)?
   '("ifmakeperl\\s +\\(.*\\)" 1 'makefile-makepp-perl prepend)
   '("ifperl\\s +\\(.*\\)" 1 'makefile-makepp-perl t)

   ;; Perl block single- or multiline, as statement or rule action.
   ;; Don't know why the initial newline in 2nd variant of group 2 doesn't get skipped.
   '("\\<make\\(?:perl\\|sub\\s +\\S +\\)\\s *\n?\\s *{\\(?:{\\s *\n?\\(\\(?:.*\n\\)+?\\)\\s *}\\|\\s *\\(\\(?:.*?\\|\n?\\(?:.*\n\\)+?\\)\\)\\)}"
     (1 'makefile-makepp-perl prepend t)
     (2 'makefile-makepp-perl prepend t))
   '("\\<\\(?:perl\\|sub\\s +\\S +\\)\\s *\n?\\s *{\\(?:{\\s *\n?\\(\\(?:.*\n\\)+?\\)\\s *}\\|\\s *\\(\\(?:.*?\\|\n?\\(?:.*\n\\)+?\\)\\)\\)}"
     (1 'makefile-makepp-perl t t)
     (2 'makefile-makepp-perl t t))

   ;; Statement style perl block.
   '("perl[-_]begin\\s *\\(?:\\s #.*\\)?\n\\(\\(?:.*\n\\)+?\\)\\s *perl[-_]end\\>"
     1 'makefile-makepp-perl t)))

(defconst makefile-bsdmake-font-lock-keywords
  (makefile-make-font-lock-keywords
   ;; A lot more could be done for variables here:
   makefile-var-use-regex
   makefile-bsdmake-statements
   t
   "^\\(?: [ \t]*\\)?\\.\\(?:el\\)?if\\(n?\\)\\(?:def\\|make\\)?\\>[ \t]*\\(!?\\)"
   '("^[ \t]*\\.for[ \t].+[ \t]\\(in\\)\\>" 1 font-lock-keyword-face)))

(defconst makefile-imake-font-lock-keywords
  (append 
   (makefile-make-font-lock-keywords
    makefile-var-use-regex
    makefile-statements
    t
    nil
    '("^XCOMM.*$" . font-lock-comment-face)
    '("XVAR\\(?:use\\|def\\)[0-9]" 0 font-lock-keyword-face prepend)
    '("@@" . font-lock-preprocessor-face)
    )
   cpp-font-lock-keywords))


(defconst makefile-font-lock-syntactic-keywords
  ;; From sh-script.el.
  ;; A `#' begins a comment in sh when it is unquoted and at the beginning
  ;; of a word.  In the shell, words are separated by metacharacters.
  ;; The list of special chars is taken from the single-unix spec of the
  ;; shell command language (under `quoting') but with `$' removed.
  '(("[^|&;<>()`\\\"' \t\n]\\(#+\\)" 1 "_")
    ;; Change the syntax of a quoted newline so that it does not end a comment.
    ("\\\\\n" 0 ".")))

(defvar makefile-imenu-generic-expression
  `(("Dependencies" makefile-previous-dependency 1)
    ("Macro Assignment" ,makefile-macroassign-regex 1))
  "Imenu generic expression for Makefile mode.  See `imenu-generic-expression'.")

;;; ------------------------------------------------------------
;;; The following configurable variables are used in the
;;; up-to-date overview .
;;; The standard configuration assumes that your `make' program
;;; can be run in question/query mode using the `-q' option, this
;;; means that the command
;;;
;;;    make -q foo
;;;
;;; should return an exit status of zero if the target `foo' is
;;; up to date and a nonzero exit status otherwise.
;;; Many makes can do this although the docs/manpages do not mention
;;; it. Try it with your favourite one.  GNU make, System V make, and
;;; Dennis Vadura's DMake have no problems.
;;; Set the variable `makefile-brave-make' to the name of the
;;; make utility that does this on your system.
;;; To understand what this is all about see the function definition
;;; of `makefile-query-by-make-minus-q' .
;;; ------------------------------------------------------------

(defcustom makefile-brave-make "make"
  "*How to invoke make, for `makefile-query-targets'.
This should identify a `make' command that can handle the `-q' option."
  :type 'string
  :group 'makefile)

(defcustom makefile-query-one-target-method-function
  'makefile-query-by-make-minus-q
  "*Function to call to determine whether a make target is up to date.
The function must satisfy this calling convention:

* As its first argument, it must accept the name of the target to
  be checked, as a string.

* As its second argument, it may accept the name of a makefile
  as a string.  Depending on what you're going to do you may
  not need this.

* It must return the integer value 0 (zero) if the given target
  should be considered up-to-date in the context of the given
  makefile, any nonzero integer value otherwise."
  :type 'function
  :group 'makefile)
(defvaralias 'makefile-query-one-target-method
  'makefile-query-one-target-method-function)

(defcustom makefile-up-to-date-buffer-name "*Makefile Up-to-date overview*"
  "*Name of the Up-to-date overview buffer."
  :type 'string
  :group 'makefile)

;;; --- end of up-to-date-overview configuration ------------------

(defvar makefile-mode-abbrev-table nil
  "Abbrev table in use in Makefile buffers.")
(if makefile-mode-abbrev-table
    ()
  (define-abbrev-table 'makefile-mode-abbrev-table ()))

(defvar makefile-mode-map
  (let ((map (make-sparse-keymap)))
    ;; set up the keymap
    (define-key map "\C-c:" 'makefile-insert-target-ref)
    (if makefile-electric-keys
	(progn
	  (define-key map "$" 'makefile-insert-macro-ref)
	  (define-key map ":" 'makefile-electric-colon)
	  (define-key map "=" 'makefile-electric-equal)
	  (define-key map "." 'makefile-electric-dot)))
    (define-key map "\C-c\C-f" 'makefile-pickup-filenames-as-targets)
    (define-key map "\C-c\C-b" 'makefile-switch-to-browser)
    (define-key map "\C-c\C-c" 'comment-region)
    (define-key map "\C-c\C-p" 'makefile-pickup-everything)
    (define-key map "\C-c\C-u" 'makefile-create-up-to-date-overview)
    (define-key map "\C-c\C-i" 'makefile-insert-gmake-function)
    (define-key map "\C-c\C-\\" 'makefile-backslash-region)
    (define-key map "\C-c\C-m\C-a" 'makefile-automake-mode)
    (define-key map "\C-c\C-m\C-b" 'makefile-bsdmake-mode)
    (define-key map "\C-c\C-m\C-g" 'makefile-gmake-mode)
    (define-key map "\C-c\C-m\C-i" 'makefile-imake-mode)
    (define-key map "\C-c\C-m\C-m" 'makefile-mode)
    (define-key map "\C-c\C-m\C-p" 'makefile-makepp-mode)
    (define-key map "\M-p"     'makefile-previous-dependency)
    (define-key map "\M-n"     'makefile-next-dependency)
    (define-key map "\e\t"     'makefile-complete)

    ;; Make menus.
    (define-key map [menu-bar makefile-mode]
      (cons "Makefile" (make-sparse-keymap "Makefile")))

    (define-key map [menu-bar makefile-mode browse]
      '("Pop up Makefile Browser" . makefile-switch-to-browser))
    (define-key map [menu-bar makefile-mode complete]
      '("Complete Target or Macro" . makefile-complete))
    (define-key map [menu-bar makefile-mode pickup]
      '("Find Targets and Macros" . makefile-pickup-everything))

    (define-key map [menu-bar makefile-mode prev]
      '("Move to Previous Dependency" . makefile-previous-dependency))
    (define-key map [menu-bar makefile-mode next]
      '("Move to Next Dependency" . makefile-next-dependency))
    map)
  "The keymap that is used in Makefile mode.")


(defvar makefile-browser-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n"    'makefile-browser-next-line)
    (define-key map "\C-n" 'makefile-browser-next-line)
    (define-key map "p"    'makefile-browser-previous-line)
    (define-key map "\C-p" 'makefile-browser-previous-line)
    (define-key map " "    'makefile-browser-toggle)
    (define-key map "i"    'makefile-browser-insert-selection)
    (define-key map "I"    'makefile-browser-insert-selection-and-quit)
    (define-key map "\C-c\C-m" 'makefile-browser-insert-continuation)
    (define-key map "q"    'makefile-browser-quit)
    ;; disable horizontal movement
    (define-key map "\C-b" 'undefined)
    (define-key map "\C-f" 'undefined)
    map)
  "The keymap that is used in the macro- and target browser.")


(defvar makefile-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?\( "()    " st)
    (modify-syntax-entry ?\) ")(    " st)
    (modify-syntax-entry ?\[ "(]    " st)
    (modify-syntax-entry ?\] ")[    " st)
    (modify-syntax-entry ?\{ "(}    " st)
    (modify-syntax-entry ?\} "){    " st)
    (modify-syntax-entry ?\' "\"    " st)
    (modify-syntax-entry ?\` "\"    " st)
    (modify-syntax-entry ?#  "<     " st)
    (modify-syntax-entry ?\n ">     " st)
    st))

(defvar makefile-imake-mode-syntax-table (copy-syntax-table
					  makefile-mode-syntax-table))
(if makefile-imake-mode-syntax-table
    ()
  (modify-syntax-entry ?/  ". 14" makefile-imake-mode-syntax-table)
  (modify-syntax-entry ?*  ". 23" makefile-imake-mode-syntax-table)
  (modify-syntax-entry ?#  "'" makefile-imake-mode-syntax-table)
  (modify-syntax-entry ?\n ". b" makefile-imake-mode-syntax-table))


;;; ------------------------------------------------------------
;;; Internal variables.
;;; You don't need to configure below this line.
;;; ------------------------------------------------------------

(defvar makefile-target-table nil
  "Table of all target names known for this buffer.")
(put 'makefile-target-table 'risky-local-variable t)

(defvar makefile-macro-table nil
  "Table of all macro names known for this buffer.")
(put 'makefile-macro-table 'risky-local-variable t)

(defvar makefile-browser-client
  "A buffer in Makefile mode that is currently using the browser.")

(defvar makefile-browser-selection-vector nil)
(defvar makefile-has-prereqs nil)
(defvar makefile-need-target-pickup t)
(defvar makefile-need-macro-pickup t)

(defvar makefile-mode-hook '())

;; Each element looks like '("GNU MAKE FUNCTION" "ARG" "ARG" ... )
;; Each "ARG" is used as a prompt for a required argument.
(defconst makefile-gnumake-functions-alist
  '(
    ;; Text functions
    ("subst" "From" "To" "In")
    ("patsubst" "Pattern" "Replacement" "In")
    ("strip" "Text")
    ("findstring" "Find what" "In")
    ("filter" "Pattern" "Text")
    ("filter-out" "Pattern" "Text")
    ("sort" "List")
    ;; Filename functions
    ("dir" "Names")
    ("notdir" "Names")
    ("suffix" "Names")
    ("basename" "Names")
    ("addprefix" "Prefix" "Names")
    ("addsuffix" "Suffix" "Names")
    ("join" "List 1" "List 2")
    ("word" "Index" "Text")
    ("words" "Text")
    ("firstword" "Text")
    ("wildcard" "Pattern")
    ;; Misc functions
    ("foreach" "Variable" "List" "Text")
    ("origin" "Variable")
    ("shell" "Command")))


;;; ------------------------------------------------------------
;;; The mode function itself.
;;; ------------------------------------------------------------

;;;###autoload
(defun makefile-mode ()
  "Major mode for editing standard Makefiles.

If you are editing a file for a different make, try one of the
variants `makefile-automake-mode', `makefile-gmake-mode',
`makefile-makepp-mode', `makefile-bsdmake-mode' or,
`makefile-imake-mode'.  All but the last should be correctly
chosen based on the file name, except if it is *.mk.  This
function ends by invoking the function(s) `makefile-mode-hook'.

It is strongly recommended to use `font-lock-mode', because that
provides additional parsing information.  This is used for
example to see that a rule action `echo foo: bar' is a not rule
dependency, despite the colon.

\\{makefile-mode-map}

In the browser, use the following keys:

\\{makefile-browser-map}

Makefile mode can be configured by modifying the following variables:

`makefile-browser-buffer-name':
    Name of the macro- and target browser buffer.

`makefile-target-colon':
    The string that gets appended to all target names
    inserted by `makefile-insert-target'.
    \":\" or \"::\" are quite common values.

`makefile-macro-assign':
   The string that gets appended to all macro names
   inserted by `makefile-insert-macro'.
   The normal value should be \" = \", since this is what
   standard make expects.  However, newer makes such as dmake
   allow a larger variety of different macro assignments, so you
   might prefer to use \" += \" or \" := \" .

`makefile-tab-after-target-colon':
   If you want a TAB (instead of a space) to be appended after the
   target colon, then set this to a non-nil value.

`makefile-browser-leftmost-column':
   Number of blanks to the left of the browser selection mark.

`makefile-browser-cursor-column':
   Column in which the cursor is positioned when it moves
   up or down in the browser.

`makefile-browser-selected-mark':
   String used to mark selected entries in the browser.

`makefile-browser-unselected-mark':
   String used to mark unselected entries in the browser.

`makefile-browser-auto-advance-after-selection-p':
   If this variable is set to a non-nil value the cursor
   will automagically advance to the next line after an item
   has been selected in the browser.

`makefile-pickup-everything-picks-up-filenames-p':
   If this variable is set to a non-nil value then
   `makefile-pickup-everything' also picks up filenames as targets
   (i.e. it calls `makefile-pickup-filenames-as-targets'), otherwise
   filenames are omitted.

`makefile-cleanup-continuations':
   If this variable is set to a non-nil value then Makefile mode
   will assure that no line in the file ends with a backslash
   (the continuation character) followed by any whitespace.
   This is done by silently removing the trailing whitespace, leaving
   the backslash itself intact.
   IMPORTANT: Please note that enabling this option causes Makefile mode
   to MODIFY A FILE WITHOUT YOUR CONFIRMATION when \"it seems necessary\".

`makefile-browser-hook':
   A function or list of functions to be called just before the
   browser is entered. This is executed in the makefile buffer.

`makefile-special-targets-list':
   List of special targets. You will be offered to complete
   on one of those in the minibuffer whenever you enter a `.'.
   at the beginning of a line in Makefile mode."

  (interactive)
  (kill-all-local-variables)
  (add-hook 'write-file-functions
	    'makefile-warn-suspicious-lines nil t)
  (add-hook 'write-file-functions
	    'makefile-warn-continuations nil t)
  (add-hook 'write-file-functions
	    'makefile-cleanup-continuations nil t)
  (make-local-variable 'makefile-target-table)
  (make-local-variable 'makefile-macro-table)
  (make-local-variable 'makefile-has-prereqs)
  (make-local-variable 'makefile-need-target-pickup)
  (make-local-variable 'makefile-need-macro-pickup)

  ;; Font lock.
  (make-local-variable 'font-lock-defaults)
  (setq font-lock-defaults
	;; SYNTAX-BEGIN set to backward-paragraph to avoid slow-down
	;; near the end of a large buffer, due to parse-partial-sexp's
	;; trying to parse all the way till the beginning of buffer.
 	'(makefile-font-lock-keywords
 	  nil nil
 	  ((?$ . "."))
 	  backward-paragraph
	  (font-lock-syntactic-keywords
	   . makefile-font-lock-syntactic-keywords)))

  ;; Add-log.
  (make-local-variable 'add-log-current-defun-function)
  (setq add-log-current-defun-function 'makefile-add-log-defun)

  ;; Imenu.
  (make-local-variable 'imenu-generic-expression)
  (setq imenu-generic-expression makefile-imenu-generic-expression)

  ;; Dabbrev.
  (make-local-variable 'dabbrev-abbrev-skip-leading-regexp)
  (setq dabbrev-abbrev-skip-leading-regexp "\\$")

  ;; Other abbrevs.
  (setq local-abbrev-table makefile-mode-abbrev-table)

  ;; Filling.
  (make-local-variable 'fill-paragraph-function)
  (setq fill-paragraph-function 'makefile-fill-paragraph)

  ;; Comment stuff.
  (make-local-variable 'comment-start)
  (setq comment-start "#")
  (make-local-variable 'comment-end)
  (setq comment-end "")
  (make-local-variable 'comment-start-skip)
  (setq comment-start-skip "#+[ \t]*")

  ;; Make sure TAB really inserts \t.
  (set (make-local-variable 'indent-line-function) 'indent-to-left-margin)

  ;; become the current major mode
  (setq major-mode 'makefile-mode)
  (setq mode-name "Makefile")

  ;; Activate keymap and syntax table.
  (use-local-map makefile-mode-map)
  (set-syntax-table makefile-mode-syntax-table)

  ;; Real TABs are important in makefiles
  (setq indent-tabs-mode t)
  (run-mode-hooks 'makefile-mode-hook))

;; These should do more than just differentiate font-lock.
;;;###autoload
(define-derived-mode makefile-automake-mode makefile-mode "Makefile.am"
  "An adapted `makefile-mode' that knows about automake."
  (setq font-lock-defaults
	`(makefile-automake-font-lock-keywords ,@(cdr font-lock-defaults))))

;;;###autoload
(define-derived-mode makefile-gmake-mode makefile-mode "GNUmakefile"
  "An adapted `makefile-mode' that knows about gmake."
  (setq font-lock-defaults
	`(makefile-gmake-font-lock-keywords ,@(cdr font-lock-defaults))))

;;;###autoload
(define-derived-mode makefile-makepp-mode makefile-mode "Makeppfile"
  "An adapted `makefile-mode' that knows about makepp."
  (set (make-local-variable 'makefile-rule-action-regex)
       makefile-makepp-rule-action-regex)
  (setq font-lock-defaults
	`(makefile-makepp-font-lock-keywords ,@(cdr font-lock-defaults))
	imenu-generic-expression
	`(("Functions" "^[ \t]*\\(?:make\\)?sub[ \t]+\\([A-Za-z0-9_]+\\)" 1)
	  ,@imenu-generic-expression)))

;;;###autoload
(define-derived-mode makefile-bsdmake-mode makefile-mode "BSDmakefile"
  "An adapted `makefile-mode' that knows about BSD make."
  (set (make-local-variable 'makefile-dependency-regex)
       makefile-bsdmake-dependency-regex)
  (set (make-local-variable 'makefile-dependency-skip) "^:!")
  (set (make-local-variable 'makefile-rule-action-regex)
       makefile-bsdmake-rule-action-regex)
  (setq font-lock-defaults
	`(makefile-bsdmake-font-lock-keywords ,@(cdr font-lock-defaults))))

;;;###autoload
(define-derived-mode makefile-imake-mode makefile-mode "Imakefile"
  "An adapted `makefile-mode' that knows about imake."
  :syntax-table makefile-imake-mode-syntax-table
  (let ((base `(makefile-imake-font-lock-keywords ,@(cdr font-lock-defaults)))
	new)
    ;; Remove `font-lock-syntactic-keywords' entry from font-lock-defaults.
    (mapc (lambda (elt)
	    (unless (and (consp elt)
			 (eq (car elt) 'font-lock-syntactic-keywords))
	      (setq new (cons elt new))))
	  base)
    (setq font-lock-defaults (nreverse new))))



;;; Motion code.

(defun makefile-next-dependency ()
  "Move point to the beginning of the next dependency line."
  (interactive)
  (let ((here (point)))
    (end-of-line)
    (if (makefile-match-dependency nil)
	(progn (beginning-of-line) t)	; indicate success
      (goto-char here) nil)))

(defun makefile-previous-dependency ()
  "Move point to the beginning of the previous dependency line."
  (interactive)
  (let ((pt (point)))
    (beginning-of-line)
    ;; makefile-match-dependency done backwards:
    (catch 'found
      (while (progn (skip-chars-backward makefile-dependency-skip)
		    (not (bobp)))
	(or (prog1 (eq (char-after) ?=)
	      (backward-char))
	    (get-text-property (point) 'face)
	    (beginning-of-line)
	    (if (> (point) (+ (point-min) 2))
		(eq (char-before (1- (point))) ?\\))
	    (if (looking-at makefile-dependency-regex)
		(throw 'found t))))
      (goto-char pt)
      nil)))



;;; Electric keys.  Blech.

(defun makefile-electric-dot (arg)
  "Prompt for the name of a special target to insert.
Only does electric insertion at beginning of line.
Anywhere else just self-inserts."
  (interactive "p")
  (if (bolp)
      (makefile-insert-special-target)
    (self-insert-command arg)))

(defun makefile-insert-special-target ()
  "Prompt for and insert a special target name.
Uses `makefile-special-targets' list."
  (interactive)
  (makefile-pickup-targets)
  (let ((special-target
	 (completing-read "Special target: "
			  makefile-special-targets-list nil nil nil)))
    (if (zerop (length special-target))
	()
      (insert "." special-target ":")
      (makefile-forward-after-target-colon))))

(defun makefile-electric-equal (arg)
  "Prompt for name of a macro to insert.
Only does prompting if point is at beginning of line.
Anywhere else just self-inserts."
  (interactive "p")
  (makefile-pickup-macros)
  (if (bolp)
      (call-interactively 'makefile-insert-macro)
    (self-insert-command arg)))

(defun makefile-insert-macro (macro-name)
  "Prepare definition of a new macro."
  (interactive "sMacro Name: ")
  (makefile-pickup-macros)
  (if (not (zerop (length macro-name)))
      (progn
	(beginning-of-line)
	(insert macro-name makefile-macro-assign)
	(setq makefile-need-macro-pickup t)
	(makefile-remember-macro macro-name))))

(defun makefile-insert-macro-ref (macro-name)
  "Complete on a list of known macros, then insert complete ref at point."
  (interactive
   (list
    (progn
      (makefile-pickup-macros)
      (completing-read "Refer to macro: " makefile-macro-table nil nil nil))))
  (makefile-do-macro-insertion macro-name))

(defun makefile-insert-target (target-name)
  "Prepare definition of a new target (dependency line)."
  (interactive "sTarget: ")
  (if (not (zerop (length target-name)))
      (progn
	(beginning-of-line)
	(insert target-name makefile-target-colon)
	(makefile-forward-after-target-colon)
	(end-of-line)
	(setq makefile-need-target-pickup t)
	(makefile-remember-target target-name))))

(defun makefile-insert-target-ref (target-name)
  "Complete on a list of known targets, then insert TARGET-NAME at point."
  (interactive
   (list
    (progn
     (makefile-pickup-targets)
     (completing-read "Refer to target: " makefile-target-table nil nil nil))))
   (if (not (zerop (length target-name)))
       (insert target-name " ")))

(defun makefile-electric-colon (arg)
  "Prompt for name of new target.
Prompting only happens at beginning of line.
Anywhere else just self-inserts."
  (interactive "p")
  (if (bolp)
      (call-interactively 'makefile-insert-target)
    (self-insert-command arg)))



;;; ------------------------------------------------------------
;;; Extracting targets and macros from an existing makefile
;;; ------------------------------------------------------------

(defun makefile-pickup-targets ()
  "Notice names of all target definitions in Makefile."
  (interactive)
  (when makefile-need-target-pickup
    (setq makefile-need-target-pickup nil
	  makefile-target-table nil
	  makefile-has-prereqs nil)
    (save-excursion
      (goto-char (point-min))
      (while (makefile-match-dependency nil)
	(goto-char (match-beginning 1))
	(while (let ((target-name
		      (buffer-substring-no-properties (point)
						      (progn
							(skip-chars-forward "^ \t:#")
							(point))))
		     (has-prereqs
		      (not (looking-at ":[ \t]*$"))))
		 (if (makefile-remember-target target-name has-prereqs)
		     (message "Picked up target \"%s\" from line %d"
			      target-name (line-number-at-pos)))
		 (skip-chars-forward " \t")
		 (not (or (eolp) (eq (char-after) ?:)))))
	(forward-line)))
    (message "Read targets OK.")))

(defun makefile-pickup-macros ()
  "Notice names of all macro definitions in Makefile."
  (interactive)
  (when makefile-need-macro-pickup
    (setq makefile-need-macro-pickup nil
	  makefile-macro-table nil)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward makefile-macroassign-regex nil t)
	(goto-char (match-beginning 1))
	(let ((macro-name (buffer-substring-no-properties (point)
							  (progn
							    (skip-chars-forward "^ \t:#=*")
							    (point)))))
	  (if (makefile-remember-macro macro-name)
	      (message "Picked up macro \"%s\" from line %d"
		       macro-name (line-number-at-pos))))
	(forward-line)))
    (message "Read macros OK.")))

(defun makefile-pickup-everything (arg)
  "Notice names of all macros and targets in Makefile.
Prefix arg means force pickups to be redone."
  (interactive "P")
  (if arg
      (setq makefile-need-target-pickup t
	    makefile-need-macro-pickup t))
  (makefile-pickup-macros)
  (makefile-pickup-targets)
  (if makefile-pickup-everything-picks-up-filenames-p
      (makefile-pickup-filenames-as-targets)))

(defun makefile-pickup-filenames-as-targets ()
  "Scan the current directory for filenames to use as targets.
Checks each filename against `makefile-ignored-files-in-pickup-regex'
and adds all qualifying names to the list of known targets."
  (interactive)
  (mapc (lambda (name)
	  (or (file-directory-p name)
	      (string-match makefile-ignored-files-in-pickup-regex name)
	      (if (makefile-remember-target name)
		  (message "Picked up file \"%s\" as target" name))))
	(file-name-all-completions "" (or (file-name-directory (buffer-file-name)) ""))))



;;; Completion.

(defun makefile-complete ()
  "Perform completion on Makefile construct preceding point.
Can complete variable and target names.
The context determines which are considered."
  (interactive)
  (let* ((beg (save-excursion
		(skip-chars-backward "^$(){}:#= \t\n")
		(point)))
	 (try (buffer-substring beg (point)))
	 (do-macros nil)
	 (paren nil))

    (save-excursion
      (goto-char beg)
      (let ((pc (preceding-char)))
	(cond
	 ;; Beginning of line means anything.
	 ((bolp)
	  ())

	 ;; Preceding "$" means macros only.
	 ((= pc ?$)
	  (setq do-macros t))

	 ;; Preceding "$(" or "${" means macros only.
	 ((and (or (= pc ?{)
		   (= pc ?\())
	       (progn
		 (setq paren pc)
		 (backward-char)
		 (and (not (bolp))
		      (= (preceding-char) ?$))))
	  (setq do-macros t)))))

    ;; Try completion.
    (let* ((table (append (if do-macros
			      '()
			    makefile-target-table)
			  makefile-macro-table))
	   (completion (try-completion try table)))
      (cond
       ;; Exact match, so insert closing paren or colon.
       ((eq completion t)
	(insert (if do-macros
		    (if (eq paren ?{)
			?}
		      ?\))
		  (if (save-excursion
			(goto-char beg)
			(bolp))
		      ":"
		    " "))))

       ;; No match.
       ((null completion)
	(message "Can't find completion for \"%s\"" try)
	(ding))

       ;; Partial completion.
       ((not (string= try completion))
	;; FIXME it would be nice to supply the closing paren if an
	;; exact, unambiguous match were found.  That is not possible
	;; right now.  Ditto closing ":" for targets.
	(delete-region beg (point))

	;; DO-MACROS means doing macros only.  If not that, then check
	;; to see if this completion is a macro.  Special insertion
	;; must be done for macros.
	(if (or do-macros
		(assoc completion makefile-macro-table))
	    (let ((makefile-use-curly-braces-for-macros-p
		   (or (eq paren ?{)
		       makefile-use-curly-braces-for-macros-p)))
	      (delete-backward-char 2)
	      (makefile-do-macro-insertion completion)
	      (delete-backward-char 1))

	  ;; Just insert targets.
	  (insert completion)))

       ;; Can't complete any more, so make completion list.  FIXME
       ;; this doesn't do the right thing when the completion is
       ;; actually inserted.  I don't think there is an easy way to do
       ;; that.
       (t
	(message "Making completion list...")
	(let ((list (all-completions try table)))
	  (with-output-to-temp-buffer "*Completions*"
	    (display-completion-list list try)))
	(message "Making completion list...done"))))))



;; Backslashification.  Stolen from cc-mode.el.

(defun makefile-backslash-region (from to delete-flag)
  "Insert, align, or delete end-of-line backslashes on the lines in the region.
With no argument, inserts backslashes and aligns existing backslashes.
With an argument, deletes the backslashes.

This function does not modify the last line of the region if the region ends
right at the start of the following line; it does not modify blank lines
at the start of the region.  So you can put the region around an entire macro
definition and conveniently use this command."
  (interactive "r\nP")
  (save-excursion
    (goto-char from)
    (let ((column makefile-backslash-column)
          (endmark (make-marker)))
      (move-marker endmark to)
      ;; Compute the smallest column number past the ends of all the lines.
      (if makefile-backslash-align
	  (progn
	    (if (not delete-flag)
		(while (< (point) to)
		  (end-of-line)
		  (if (= (preceding-char) ?\\)
		      (progn (forward-char -1)
			     (skip-chars-backward " \t")))
		  (setq column (max column (1+ (current-column))))
		  (forward-line 1)))
	    ;; Adjust upward to a tab column, if that doesn't push
	    ;; past the margin.
	    (if (> (% column tab-width) 0)
		(let ((adjusted (* (/ (+ column tab-width -1) tab-width)
				   tab-width)))
		  (if (< adjusted (window-width))
		      (setq column adjusted))))))
      ;; Don't modify blank lines at start of region.
      (goto-char from)
      (while (and (< (point) endmark) (eolp))
        (forward-line 1))
      ;; Add or remove backslashes on all the lines.
      (while (and (< (point) endmark)
                  ;; Don't backslashify the last line
                  ;; if the region ends right at the start of the next line.
                  (save-excursion
                    (forward-line 1)
                    (< (point) endmark)))
        (if (not delete-flag)
            (makefile-append-backslash column)
          (makefile-delete-backslash))
        (forward-line 1))
      (move-marker endmark nil))))

(defun makefile-append-backslash (column)
  (end-of-line)
  ;; Note that "\\\\" is needed to get one backslash.
  (if (= (preceding-char) ?\\)
      (progn (forward-char -1)
             (delete-horizontal-space)
             (indent-to column (if makefile-backslash-align nil 1)))
    (indent-to column (if makefile-backslash-align nil 1))
    (insert "\\")))

(defun makefile-delete-backslash ()
  (end-of-line)
  (or (bolp)
      (progn
 	(forward-char -1)
 	(if (looking-at "\\\\")
 	    (delete-region (1+ (point))
 			   (progn (skip-chars-backward " \t") (point)))))))



;; Filling

(defun makefile-fill-paragraph (arg)
  ;; Fill comments, backslashed lines, and variable definitions
  ;; specially.
  (save-excursion
    (beginning-of-line)
    (cond
     ((looking-at "^#+\\s-*")
      ;; Found a comment.  Return nil to let normal filling take place.
      nil)

     ;; Must look for backslashed-region before looking for variable
     ;; assignment.
     ((or (eq (char-before (line-end-position 1)) ?\\)
	  (eq (char-before (line-end-position 0)) ?\\))
      ;; A backslash region.  Find beginning and end, remove
      ;; backslashes, fill, and then reapply backslahes.
      (end-of-line)
      (let ((beginning
	     (save-excursion
	       (end-of-line 0)
	       (while (= (preceding-char) ?\\)
		 (end-of-line 0))
	       (forward-char)
	       (point)))
	    (end
	     (save-excursion
	       (while (= (preceding-char) ?\\)
		 (end-of-line 2))
	       (point))))
	(save-restriction
	  (narrow-to-region beginning end)
	  (makefile-backslash-region (point-min) (point-max) t)
	  (let ((fill-paragraph-function nil))
	    (fill-paragraph nil))
	  (makefile-backslash-region (point-min) (point-max) nil)
	  (goto-char (point-max))
	  (if (< (skip-chars-backward "\n") 0)
	      (delete-region (point) (point-max)))))
      ;; Return non-nil to indicate it's been filled.
      t)

     ((looking-at makefile-macroassign-regex)
      ;; Have a macro assign.  Fill just this line, and then backslash
      ;; resulting region.
      (save-restriction
	(narrow-to-region (point) (line-beginning-position 2))
	(let ((fill-paragraph-function nil))
	  (fill-paragraph nil))
	(makefile-backslash-region (point-min) (point-max) nil))
      ;; Return non-nil to indicate it's been filled.
      t)

     (t
      ;; Return non-nil so we don't fill anything else.
      t))))



;;; ------------------------------------------------------------
;;; Browser mode.
;;; ------------------------------------------------------------

(defun makefile-browser-format-target-line (target selected)
  (format
   (concat (make-string makefile-browser-leftmost-column ?\ )
	   (if selected
	       makefile-browser-selected-mark
	     makefile-browser-unselected-mark)
	   "%s%s")
   target makefile-target-colon))

(defun makefile-browser-format-macro-line (macro selected)
  (format
   (concat (make-string makefile-browser-leftmost-column ?\ )
	   (if selected
	       makefile-browser-selected-mark
	     makefile-browser-unselected-mark)
	   (makefile-format-macro-ref macro))))

(defun makefile-browser-fill (targets macros)
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (erase-buffer)
    (mapconcat
     (function
      (lambda (item) (insert (makefile-browser-format-target-line (car item) nil) "\n")))
     targets
     "")
    (mapconcat
     (function
      (lambda (item) (insert (makefile-browser-format-macro-line (car item) nil) "\n")))
     macros
     "")
    (sort-lines nil (point-min) (point-max))
    (goto-char (1- (point-max)))
    (delete-char 1)			; remove unnecessary newline at eob
    (goto-char (point-min))
    (forward-char makefile-browser-cursor-column)))

;;;
;;; Moving up and down in the browser
;;;

(defun makefile-browser-next-line ()
  "Move the browser selection cursor to the next line."
  (interactive)
  (if (not (makefile-last-line-p))
      (progn
	(forward-line 1)
	(forward-char makefile-browser-cursor-column))))

(defun makefile-browser-previous-line ()
  "Move the browser selection cursor to the previous line."
  (interactive)
  (if (not (makefile-first-line-p))
      (progn
	(forward-line -1)
	(forward-char makefile-browser-cursor-column))))

;;;
;;; Quitting the browser (returns to client buffer)
;;;

(defun makefile-browser-quit ()
  "Leave the browser and return to the makefile buffer."
  (interactive)
  (let ((my-client makefile-browser-client))
    (setq makefile-browser-client nil)	; we quitted, so NO client!
    (set-buffer-modified-p nil)
    (quit-window t)
    (pop-to-buffer my-client)))

;;;
;;; Toggle state of a browser item
;;;

(defun makefile-browser-toggle ()
  "Toggle the selection state of the browser item at the cursor position."
  (interactive)
  (let ((this-line (count-lines (point-min) (point))))
    (setq this-line (max 1 this-line))
    (makefile-browser-toggle-state-for-line this-line)
    (goto-line this-line)
    (let ((inhibit-read-only t))
      (beginning-of-line)
      (if (makefile-browser-on-macro-line-p)
	  (let ((macro-name (makefile-browser-this-line-macro-name)))
	    (delete-region (point) (progn (end-of-line) (point)))
	    (insert
	     (makefile-browser-format-macro-line
		macro-name
		(makefile-browser-get-state-for-line this-line))))
	(let ((target-name (makefile-browser-this-line-target-name)))
	  (delete-region (point) (progn (end-of-line) (point)))
	  (insert
	   (makefile-browser-format-target-line
	      target-name
	      (makefile-browser-get-state-for-line this-line))))))
    (beginning-of-line)
    (forward-char makefile-browser-cursor-column)
    (if makefile-browser-auto-advance-after-selection-p
	(makefile-browser-next-line))))

;;;
;;; Making insertions into the client buffer
;;;

(defun makefile-browser-insert-continuation ()
  "Insert a makefile continuation.
In the makefile buffer, go to (end-of-line), insert a \'\\\'
character, insert a new blank line, go to that line and indent by one TAB.
This is most useful in the process of creating continued lines when copying
large dependencies from the browser to the client buffer.
\(point) advances accordingly in the client buffer."
  (interactive)
  (with-current-buffer makefile-browser-client
    (end-of-line)
    (insert "\\\n\t")))

(defun makefile-browser-insert-selection ()
  "Insert all selected targets and/or macros in the makefile buffer.
Insertion takes place at point."
  (interactive)
  (save-excursion
    (goto-line 1)
    (let ((current-line 1))
      (while (not (eobp))
	(if (makefile-browser-get-state-for-line current-line)
	    (makefile-browser-send-this-line-item))
	(forward-line 1)
	(setq current-line (1+ current-line))))))

(defun makefile-browser-insert-selection-and-quit ()
  (interactive)
  (makefile-browser-insert-selection)
  (makefile-browser-quit))

(defun makefile-browser-send-this-line-item ()
  (if (makefile-browser-on-macro-line-p)
      (save-excursion
	(let ((macro-name (makefile-browser-this-line-macro-name)))
	  (set-buffer makefile-browser-client)
	  (insert (makefile-format-macro-ref macro-name) " ")))
    (save-excursion
      (let ((target-name (makefile-browser-this-line-target-name)))
	(set-buffer makefile-browser-client)
	(insert target-name " ")))))

(defun makefile-browser-start-interaction ()
  (use-local-map makefile-browser-map)
  (setq buffer-read-only t))

(defun makefile-browse (targets macros)
  (interactive)
  (if (zerop (+ (length targets) (length macros)))
      (progn
	(beep)
	(message "No macros or targets to browse! Consider running 'makefile-pickup-everything\'"))
    (let ((browser-buffer (get-buffer-create makefile-browser-buffer-name)))
	(pop-to-buffer browser-buffer)
	(makefile-browser-fill targets macros)
	(shrink-window-if-larger-than-buffer)
	(set (make-local-variable 'makefile-browser-selection-vector)
	     (make-vector (+ (length targets) (length macros)) nil))
	(makefile-browser-start-interaction))))

(defun makefile-switch-to-browser ()
  (interactive)
  (run-hooks 'makefile-browser-hook)
  (setq makefile-browser-client (current-buffer))
  (makefile-pickup-targets)
  (makefile-pickup-macros)
  (makefile-browse makefile-target-table makefile-macro-table))



;;; ------------------------------------------------------------
;;; Up-to-date overview buffer
;;; ------------------------------------------------------------

(defun makefile-create-up-to-date-overview ()
  "Create a buffer containing an overview of the state of all known targets.
Known targets are targets that are explicitly defined in that makefile;
in other words, all targets that appear on the left hand side of a
dependency in the makefile."
  (interactive)
  (if (y-or-n-p "Are you sure that the makefile being edited is consistent? ")
      ;;
      ;; The rest of this function operates on a temporary makefile, created by
      ;; writing the current contents of the makefile buffer.
      ;;
      (let ((saved-target-table makefile-target-table)
	    (this-buffer (current-buffer))
	    (makefile-up-to-date-buffer
	     (get-buffer-create makefile-up-to-date-buffer-name))
	    (filename (makefile-save-temporary))
	    ;;
	    ;; Forget the target table because it may contain picked-up filenames
	    ;; that are not really targets in the current makefile.
	    ;; We don't want to query these, so get a new target-table with just the
	    ;; targets that can be found in the makefile buffer.
	    ;; The 'old' target table will be restored later.
	    ;;
	    (real-targets (progn
			    (makefile-pickup-targets)
			    makefile-target-table))
	    (prereqs makefile-has-prereqs)
	    )

	(set-buffer makefile-up-to-date-buffer)
	(setq buffer-read-only nil)
	(erase-buffer)
	(makefile-query-targets filename real-targets prereqs)
	(if (zerop (buffer-size))		; if it did not get us anything
	    (progn
	      (kill-buffer (current-buffer))
	      (message "No overview created!")))
	(set-buffer this-buffer)
	(setq makefile-target-table saved-target-table)
	(if (get-buffer makefile-up-to-date-buffer-name)
	    (progn
	      (pop-to-buffer (get-buffer makefile-up-to-date-buffer-name))
	      (shrink-window-if-larger-than-buffer)
	      (sort-lines nil (point-min) (point-max))
	      (setq buffer-read-only t))))))

(defun makefile-save-temporary ()
  "Create a temporary file from the current makefile buffer."
  (let ((filename (makefile-generate-temporary-filename)))
    (write-region (point-min) (point-max) filename nil 0)
    filename))				; return the filename

(defun makefile-generate-temporary-filename ()
  "Create a filename suitable for use in `makefile-save-temporary'.
Be careful to allow brain-dead file systems (DOS, SYSV ...) to cope
with the generated name!"
  (let ((my-name (user-login-name))
	(my-uid (int-to-string (user-uid))))
    (concat "mktmp"
	  (if (> (length my-name) 3)
	      (substring my-name 0 3)
	    my-name)
	  "."
	  (if (> (length my-uid) 3)
	      (substring my-uid 0 3)
	    my-uid))))

(defun makefile-query-targets (filename target-table prereq-list)
  "Fill the up-to-date overview buffer.
Checks each target in TARGET-TABLE using
`makefile-query-one-target-method-function'
and generates the overview, one line per target name."
  (insert
   (mapconcat
    (function (lambda (item)
		(let* ((target-name (car item))
		       (no-prereqs (not (member target-name prereq-list)))
		       (needs-rebuild (or no-prereqs
					  (funcall
					   makefile-query-one-target-method-function
					   target-name
					   filename))))
		  (format "\t%s%s"
			  target-name
			  (cond (no-prereqs "  .. has no prerequisites")
				(needs-rebuild "  .. NEEDS REBUILD")
				(t "  .. is up to date"))))
		))
    target-table "\n"))
  (goto-char (point-min))
  (delete-file filename))		; remove the tmpfile

(defun makefile-query-by-make-minus-q (target &optional filename)
  (not (eq 0
	(call-process makefile-brave-make nil nil nil
		      "-f" filename "-q" target))))



;;; ------------------------------------------------------------
;;; Continuation cleanup
;;; ------------------------------------------------------------

(defun makefile-cleanup-continuations ()
  (if (eq major-mode 'makefile-mode)
      (if (and makefile-cleanup-continuations
	       (not buffer-read-only))
	  (save-excursion
	    (goto-char (point-min))
	    (while (re-search-forward "\\\\[ \t]+$" nil t)
	      (replace-match "\\" t t))))))


;;; ------------------------------------------------------------
;;; Warn of suspicious lines
;;; ------------------------------------------------------------

(defun makefile-warn-suspicious-lines ()
  ;; Returning non-nil cancels the save operation
  (if (eq major-mode 'makefile-mode)
      (save-excursion
	(goto-char (point-min))
	(if (re-search-forward "^\\(\t+$\\| +\t\\)" nil t)
	    (not (y-or-n-p
		  (format "Suspicious line %d. Save anyway? "
			  (count-lines (point-min) (point)))))))))

(defun makefile-warn-continuations ()
  (if (eq major-mode 'makefile-mode)
      (save-excursion
	(goto-char (point-min))
	(if (re-search-forward "\\\\[ \t]+$" nil t)
	    (not (y-or-n-p
		  (format "Suspicious continuation in line %d. Save anyway? "
			  (count-lines (point-min) (point)))))))))


;;; ------------------------------------------------------------
;;; GNU make function support
;;; ------------------------------------------------------------

(defun makefile-insert-gmake-function ()
  "Insert a GNU make function call.
Asks for the name of the function to use (with completion).
Then prompts for all required parameters."
  (interactive)
  (let* ((gm-function-name (completing-read
			     "Function: "
			     makefile-gnumake-functions-alist
			     nil t nil))
	 (gm-function-prompts
	  (cdr (assoc gm-function-name makefile-gnumake-functions-alist))))
    (if (not (zerop (length gm-function-name)))
	(insert (makefile-format-macro-ref
		 (concat gm-function-name " "
			 (makefile-prompt-for-gmake-funargs
			    gm-function-name gm-function-prompts)))
		" "))))

(defun makefile-prompt-for-gmake-funargs (function-name prompt-list)
  (mapconcat
   (function (lambda (one-prompt)
	       (read-string (format "[%s] %s: " function-name one-prompt)
			    nil)))
   prompt-list
   ","))



;;; ------------------------------------------------------------
;;; Utility functions
;;; ------------------------------------------------------------

(defun makefile-match-function-end (end)
  "To be called as an anchored matcher by font-lock.
The anchor must have matched the opening parens in the first group."
  (let ((s (match-string-no-properties 1)))
    (setq s (cond ((string= s "(") "\\(.*?\\)[ \t]*)")
		  ((string= s "{") "\\(.*?\\)[ \t]*}")
		  ((string= s "((") "\\(.*?\\)[ \t]*))")
		  ((string= s "{{") "\\(.*?\\)[ \t]*}}")))
    (if s (looking-at s))))

(defun makefile-match-dependency (bound)
  "Search for `makefile-dependency-regex' up to BOUND.
Checks that the colon has not already been fontified, else we
matched in a rule action."
  (catch 'found
    (let ((pt (point)))
      (while (progn (skip-chars-forward makefile-dependency-skip bound)
		    (< (point) (or bound (point-max))))
	(forward-char)
	(or (eq (char-after) ?=)
	    (get-text-property (1- (point)) 'face)
	    (if (> (line-beginning-position) (+ (point-min) 2))
		(eq (char-before (line-end-position 0)) ?\\))
	    (when (save-excursion
		    (beginning-of-line)
		    (looking-at makefile-dependency-regex))
	      (save-excursion
		(let ((deps-end (match-end 1))
		      (match-data (match-data)))
		  (goto-char deps-end)
		  (skip-chars-backward " \t")
		  (setq deps-end (point))
		  (beginning-of-line)
		  (skip-chars-forward " \t")
		  ;; Alter the bounds recorded for subexp 1,
		  ;; which is what is supposed to match the targets.
		  (setcar (nthcdr 2 match-data) (point))
		  (setcar (nthcdr 3 match-data) deps-end)
		  (store-match-data match-data)))
	      (end-of-line)
	      (throw 'found (point)))))
      (goto-char pt))
    nil))

(defun makefile-match-action (bound)
  (catch 'found
    (while (re-search-forward makefile-rule-action-regex bound t)
      (or (eq ?\\ (char-after (- (match-beginning 0) 2)))
	  (throw 'found t)))))

(defun makefile-do-macro-insertion (macro-name)
  "Insert a macro reference."
  (if (not (zerop (length macro-name)))
      (if (assoc macro-name makefile-runtime-macros-list)
	  (insert "$" macro-name)
	(insert (makefile-format-macro-ref macro-name)))))

(defun makefile-remember-target (target-name &optional has-prereqs)
  "Remember a given target if it is not already remembered for this buffer."
  (if (not (zerop (length target-name)))
      (progn
      (if (not (assoc target-name makefile-target-table))
	  (setq makefile-target-table
		(cons (list target-name) makefile-target-table)))
      (if has-prereqs
	  (setq makefile-has-prereqs
		(cons target-name makefile-has-prereqs))))))

(defun makefile-remember-macro (macro-name)
  "Remember a given macro if it is not already remembered for this buffer."
  (if (not (zerop (length macro-name)))
      (if (not (assoc macro-name makefile-macro-table))
	  (setq makefile-macro-table
		(cons (list macro-name) makefile-macro-table)))))

(defun makefile-forward-after-target-colon ()
  "Move point forward after inserting the terminating colon of a target.
This acts according to the value of `makefile-tab-after-target-colon'."
  (if makefile-tab-after-target-colon
      (insert "\t")
    (insert " ")))

(defun makefile-browser-on-macro-line-p ()
  "Determine if point is on a macro line in the browser."
  (save-excursion
    (beginning-of-line)
    (re-search-forward "\\$[{(]" (line-end-position) t)))

(defun makefile-browser-this-line-target-name ()
  "Extract the target name from a line in the browser."
  (save-excursion
    (end-of-line)
    (skip-chars-backward "^ \t")
    (buffer-substring (point) (1- (line-end-position)))))

(defun makefile-browser-this-line-macro-name ()
  "Extract the macro name from a line in the browser."
  (save-excursion
    (beginning-of-line)
    (re-search-forward "\\$[{(]" (line-end-position) t)
    (let ((macro-start (point)))
      (skip-chars-forward "^})")
      (buffer-substring macro-start (point)))))

(defun makefile-format-macro-ref (macro-name)
  "Format a macro reference.
Uses `makefile-use-curly-braces-for-macros-p'."
  (if (or (char-equal ?\( (string-to-char macro-name))
	  (char-equal ?\{ (string-to-char macro-name)))
      (format "$%s" macro-name)
    (if makefile-use-curly-braces-for-macros-p
	(format "${%s}" macro-name)
      (format "$(%s)" macro-name))))

(defun makefile-browser-get-state-for-line (n)
  (aref makefile-browser-selection-vector (1- n)))

(defun makefile-browser-set-state-for-line (n to-state)
  (aset makefile-browser-selection-vector (1- n) to-state))

(defun makefile-browser-toggle-state-for-line (n)
  (makefile-browser-set-state-for-line n (not (makefile-browser-get-state-for-line n))))

(defun makefile-last-line-p ()
  (= (line-end-position) (point-max)))

(defun makefile-first-line-p ()
  (= (line-beginning-position) (point-min)))



;;; Support for other packages, like add-log.

(defun makefile-add-log-defun ()
  "Return name of target or variable assignment that point is in.
If it isn't in one, return nil."
  (save-excursion
    (let (found)
      (beginning-of-line)
      ;; Scan back line by line, noticing when we come to a
      ;; variable or rule definition, and giving up when we see
      ;; a line that is not part of either of those.
      (while (not (or (setq found
			    (when (or (looking-at makefile-macroassign-regex)
				      (looking-at makefile-dependency-regex))
			      (match-string-no-properties 1)))
		      ;; Don't keep looking across a blank line or comment.
		      (looking-at "$\\|#")
		      (not (zerop (forward-line -1))))))
      ;; Remove leading and trailing whitespace.
      (when found
	(setq found (replace-regexp-in-string "[ \t]+\\'" "" found))
	(setq found (replace-regexp-in-string "\\`[ \t]+" "" found)))
      found)))

(provide 'make-mode)

;; arch-tag: bd23545a-de91-44fb-b1b2-feafbb2635a0
;;; make-mode.el ends here
