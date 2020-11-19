;;; orgflow.el --- Navigate many org-files like flowing water. -*- lexical-binding: t; -*-

;; Copyright (C) 2020 Jens Christian Jensen

;; Author: Jens Christian Jensen <jensecj@gmail.com>
;; URL: https://www.github.com/jensecj/orgflow.el
;; Keywords: org
;; Package-Requires ((emacs "28.0.50"))
;; Package-Version: 20200618
;; Version: 0.1.0


;;; Commentary:

;; Parsing results from ripgrep is unfortunately a little clunky, but it works.


;;; Code:

(require 'dash)
(require 's)
(require 'ivy)

(require 'org)
(require 'rx)

;;;; settings

(defvar orgflow-section-sizes '(25 30)
  "List of section sizes used for truncating result.

The first number is the size, in characters, of the first
section, usually the filename, the second number is for the
second section, etc.")

(defvar orgflow-search-types '("org")
  "List of file types to include when searching.")

(defvar orgflow-directory nil
  "Default directory to use for orgflow commands.

if set to `nil' then `default-directory' is preferred instead.

Can be either a string path, or a function which takes no
arguments, and returns a string path.")

(defvar orgflow-filepath-face '((t (:inherit org-level-1)))
  "Face used for the directory part of a full filepath.")

(defvar orgflow-filename-face '((t (:inherit org-level-2)))
  "Face used for the filename part of a full filepath.")

;;;; external helpers

(defun orgflow--cmd (cmd args)
  "Call CMD with ARGS, returning the raw shell output, or
throwing an error on a non-zero return code."
  (let ((buf (generate-new-buffer "*orgflow*")))
    (unwind-protect
        (let* ((proc `(,cmd nil ,buf nil ,@args))
               (result))
          (setq result (apply #'call-process proc))

          (with-current-buffer buf
            (unless (= result 0)
              (error "%s" (buffer-string)))

            (setq result (buffer-string)))

          result)
      (kill-buffer buf))))


(defun orgflow--rg (query &optional dir &rest args)
  "Recursively search DIR for QUERY using `ripgrep', with extra ARGS.

If DIR is nil, fallback to `orgflow-directory' then `default-directory'.

The result should be parsed by `orgflow--rg-parse-result', or
manually depending on the extra ARGS."
  (unless (executable-find "rg")
    (error "`orgflow--rg' requires the system package `rg'."))

  (let* ((dir (expand-file-name (or dir
                                    (if (functionp orgflow-directory)
                                        (funcall orgflow-directory)
                                      orgflow-directory)
                                    default-directory)))
         (args `(,dir
                 "--regexp" ,query ;use instead of positional, to allow empty queries
                 "--no-config"    ;don't load the systems ripgrep config
                 ,@(-flatten (-map (lambda (type) (list "--type" type)) orgflow-search-types))
                 "--no-heading"   ;print each result on its own line, with filename,
                 "--line-number"  ;line-number,
                 "--column"       ;and column-number
                 "--null"         ;separate filename with null-byte
                 ,@args)))
    (orgflow--cmd "rg" args)))

(defun orgflow--fd (&optional dir &rest args)
  "Recursively search DIR using `fd', with extra ARGS.

If DIR is nil, fallback to `orgflow-directory' then `default-directory'."
  (unless (executable-find "fd")
    (error "`orgflow--fd' requires the system package `fd'."))

  (let* ((dir (expand-file-name (or dir
                                    (if (functionp orgflow-directory)
                                        (funcall orgflow-directory)
                                      orgflow-directory)
                                    default-directory)))
         (args `("."
                 ,dir
                 "--absolute-path" ;print absolute paths, instead of relative
                 "--type" "f"     ;only search for files
                 ,@(-flatten (-map (lambda (type) (list "--extension" type)) orgflow-search-types))
                 ,@args)))
    (orgflow--cmd "fd" args)))


;;;; helpers

(defun orgflow--propertize-filepath (filepath)
  "Propertize FILEPATH using `orgflow-filepath-face' and `orgflow-filename-face'."
  (concat
   (propertize (file-relative-name (file-name-directory filepath))
               'face orgflow-filepath-face)
   (propertize (file-name-nondirectory filepath)
               'face orgflow-filename-face)))

(defun orgflow--fit-section (content width)
  "Truncate and pad CONTENT to fit into WIDTH characters."
  (-as-> content $
         (s-collapse-whitespace $)
         (s-truncate width $ "⋯")
         (s-pad-right (+ width 4) " " $)))

(defun orgflow--rg-parse-result (result)
  "Parse RESULT from a `orgflow--rg' search.

The output format depends on the arguments to `orgflow--rg',
which in-turn passes them onto `ripgrep'. "
  (let* ((data (s-match (rx (group (1+ any)) " " ;filename
                            (group (1+ num)) ":"  ;line number
                            (group (1+ num)) ":"  ;column number
                            (group (0+ any)))     ;rest of the match
                        result))
         (filename (nth 1 data))
         (line (string-to-number (nth 2 data)))
         (column (1- (string-to-number (nth 3 data)))) ;ripgrep columns start at 1
         (matched (nth 4 data)))
    (list :file filename :line line :column column :match matched)))

;;;; core

(defun orgflow--extract-links (buf &optional type)
  "Return all org-links from buffer BUF, optionally only return
links of type TYPE."
  ;; TODO: rework extract-links, this is clunky
  (mapcar #'s-trim
          (with-current-buffer buf
            ;; TODO: get list of links using `orgflow--rg', then specialize? may be faster for very big org files
            (org-element-map (org-element-parse-buffer) 'link
              (lambda (link)
                (cond
                 ((eq type 'file)
                  (when (string= "file" (org-element-property :type link))
                    (org-element-property :path link)))
                 ((eq type 'url)
                  (when (s-match (rx (or "http" "https" "fuzzy")) (org-element-property :type link))
                    (s-chop-prefixes
                     '("fuzzy:")
                     (concat (org-element-property :type link) ":" (org-element-property :path link)))))
                 ((not type)
                  (concat (org-element-property :type link) ":" (org-element-property :path link)))))))))

(defun orgflow-visit-linked-url ()
  "Prompt the user to pick a URL from the current buffer, and
visit the selected URL."
  (interactive)
  (if-let* ((links (orgflow--extract-links (current-buffer) 'url))
            (pick (ivy-read "urls: " links
                            :require-match t
                            :sort t
                            :caller #'orgflow-visit-linked-url)))
      (browse-url pick)
    (message "no urls in buffer")))

(defun orgflow-visit-linked-file ()
  "Prompt the user to pick a file-link from the current buffer,
and visit the selected file."
  (interactive)
  (if-let* ((links (orgflow--extract-links (current-buffer) 'file))
            (pick (ivy-read "linked files: " links
                            :require-match t
                            :sort t
                            :caller #'orgflow-visit-linked-file)))
      (find-file-existing pick)
    (message "no file links in buffer")))

(ivy-set-display-transformer #'orgflow-visit-linked-file #'orgflow--propertize-filepath)

(defun orgflow--find-nearby-files (dir)
  "Return a list of files matching `orgflow-search-types' inside
  DIR, or in any sub-directory of DIR.

If DIR is nil, `default-directory' is used."
  (let ((result (orgflow--fd dir)))
    (string-split result)))

(defun orgflow--nearby-files-xf (s)
  "Ivy display-transformer for nearby files."
  (orgflow--propertize-filepath s))

(defun orgflow-visit-nearby-file (&optional dir)
  "Prompt the user to pick a nearby file in DIR, and visit the
selected file.

If DIR is nil, `default-directory' is used."
  (interactive)
  (let* ((dir (or dir (when current-prefix-arg (read-directory-name ""))))
         (files (orgflow--find-nearby-files dir))
         (pick (ivy-read "nearby files: " files
                         :sort t
                         :caller #'orgflow-visit-nearby-file)))
    (find-file pick)))

(ivy-set-display-transformer #'orgflow-visit-nearby-file #'orgflow--nearby-files-xf)

(defun orgflow-insert-link-to-nearby-file (&optional dir)
  "Prompt the user to pick a nearby file from DIR, and insert the
selected file as an org-link.

If DIR is nil, `default-directory' is used."
  (interactive)
  (when-let* ((files (orgflow--find-nearby-files dir))
              (file (ivy-read "nearby files: " files
                              :require-match t
                              :sort t
                              :caller #'orgflow-insert-link-to-nearby-file))
              (filename (file-name-nondirectory file)))
    (insert (format "[[file:%s][%s]]" file filename))))

(ivy-set-display-transformer #'orgflow-insert-link-to-nearby-file #'orgflow--nearby-files-xf)

(defun orgflow--find-nearby-headings (&optional dir)
  "Return a list of headings in DIR, or in any sub-directory of DIR."
  (let* ((heading-re "^(\\*+.+) +(:[[:alpha:]\\|:]+:)?$")
         (result (orgflow--rg heading-re dir "--replace" "$1")))
    (string-split result "\n" t (rx (1+ space)))))

(defun orgflow--heading-xf (s)
  "Ivy display transformer for tagged headings."
  (let* ((data (orgflow--rg-parse-result s))
         (file (plist-get data :file))
         (matched (split-string (plist-get data :match) "" t (rx (1+ space))))
         (heading (car matched))
         (tags (cadr matched)))
    (concat
     (orgflow--fit-section (orgflow--propertize-filepath file)
                           (or (nth 0 orgflow-section-sizes) 25))
     " "
     (orgflow--fit-section heading
                           (or (nth 1 orgflow-section-sizes) 35))
     (when tags (concat " " tags)))))

(defun orgflow-visit-nearby-heading (&optional dir)
  "Prompt the user to pick a nearby heading from DIR, then visit
the selected heading.

If DIR is nil, `default-directory' is used."
  (interactive)
  (let* ((col (orgflow--find-nearby-headings
               (or dir (when current-prefix-arg (read-directory-name ""))))))
    (when-let* ((ivy-re-builders-alist '((t . ivy--regex-ignore-order)))
                (pick (ivy-read "headings: " col
                                :require-match t
                                :caller #'orgflow-visit-nearby-heading))
                (data (orgflow--rg-parse-result pick)))
      (with-current-buffer (find-file-existing (plist-get data :file))
        (goto-line (plist-get data :line))))))

(ivy-set-display-transformer #'orgflow-visit-nearby-heading #'orgflow--heading-xf)

(defun orgflow--find-tagged-headings (&optional dir)
  "Return a list of all headings with tags in DIR, or in any sub-directory of DIR."
  ;; NOTE: can tags be non-alpha characters?

  ;; first capture group is the heading, the second one is the headings tags.  should
  ;; probably move away from using the `--replace' flag, it slows down ripgrep, maybe move
  ;; parsing to the display transformer?
  (let* ((tagged-heading-re "^(\\*+.+) :([[:alpha:]\\|:]+):$")
         (result (orgflow--rg tagged-heading-re dir "--replace" "$1$2")))
    (string-split result "\n" t (rx (1+ space)))))

(defun orgflow-visit-tagged-heading (&optional dir)
  "Prompt the user to pick a nearby tagged heading from DIR, then
visit the selected heading.

If DIR is nil, `default-directory' is used."
  (interactive)
  (let* ((col (orgflow--find-tagged-headings
               (or dir (when current-prefix-arg (read-directory-name ""))))))
    (when-let* ((ivy-re-builders-alist '((t . ivy--regex-ignore-order)))
                (pick (ivy-read "tags: " col
                                :require-match t
                                :sort t
                                :caller #'orgflow-visit-tagged-heading))
                (data (orgflow--rg-parse-result pick)))
      (with-current-buffer (find-file-existing (plist-get data :file))
        (goto-line (plist-get data :line))))))

(ivy-set-display-transformer #'orgflow-visit-tagged-heading #'orgflow--heading-xf)

(defun orgflow-insert-link-to-tagged-heading (&optional dir)
  ""
  (interactive)
  (when-let* ((headings (orgflow--find-tagged-headings dir))
              (pick (ivy-read "tags: " headings
                              :require-match t
                              :sort t
                              :caller #'orgflow-insert-link-to-tagged-heading))
              (data (orgflow--rg-parse-result pick))
              (file (plist-get data :file))
              (filename (file-name-nondirectory file))
              (matched (plist-get data :match))
              (heading (s-replace-regexp "^\*+ +" "" (car (split-string matched "" t (rx (1+ space)))))))
    (insert (format "[[file:%s::*%s][%s::%s]]" file heading filename heading))))

(ivy-set-display-transformer #'orgflow-insert-link-to-tagged-heading #'orgflow--heading-xf)

(defun orgflow--find-backlinks (file &optional dir)
  "Return a list of files matching `orgflow-search-types' in DIR,
or in any sub-directory of DIR, which link to FILE."
  ;; FIXME: probably breaks when multiple files have the same name in nearby directories
  (let* ((filename (file-name-nondirectory file))
         (backlinks-re (concat "\\[\\[.*(?::?|/?)" filename "(?:::.*)?\\]\\[(.*)\\]\\]"))
         (result (orgflow--rg backlinks-re dir)))
    (string-split result "\n" t (rx (1+ space)))))

(defun orgflow--backlinks-xf (s)
  "Ivy display transformer for backlinks."
  (let* ((data (orgflow--rg-parse-result s))
         (file (plist-get data :file))
         (org-link (plist-get data :match))
         (link (nth 1 (s-match (rx "[["(0+ any)"]["(group (0+ any))"]]") org-link))))
    (concat
     (orgflow--fit-section (orgflow--propertize-filepath file)
                           (or (nth 0 orgflow-section-sizes) 25))
     " "
     link)))

(defun orgflow-visit-backlinks (&optional file dir)
  ""
  (interactive)
  (if-let* ((links (orgflow--find-backlinks
                    (or file (buffer-file-name))
                    (or dir (when current-prefix-arg (read-directory-name "")))))
            (pick (ivy-read "backlinks: " links
                            :require-match t
                            :sort t
                            :caller #'orgflow-visit-backlinks))
            (data (orgflow--rg-parse-result pick)))
      (with-current-buffer (find-file-existing (plist-get data :file))
        (goto-line (plist-get data :line))
        (forward-char (plist-get data :column)))
    (message "no backlinks found")))

(ivy-set-display-transformer #'orgflow-visit-backlinks #'orgflow--backlinks-xf)


(provide 'orgflow)
;;; orgflow.el ends here
