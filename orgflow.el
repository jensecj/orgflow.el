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


(defvar orgflow-section-sizes '(25 30)
  "List of section sizes used for truncating result.

The first number is the size, in characters, of the first
section, usually the filename, the second number is for the
second section, etc.")


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
         (column (1- (string-to-number (nth 3 data)))) ;ripgrep's column start at 1
         (matched (nth 4 data)))
    (list :file filename :line line :column column :match matched)))

(defun orgflow--rg (query &optional dir &rest args)
  "Recursively search DIR for QUERY using `ripgrep', with extra ARGS.

The search is recursive, and searches only .org files.  The
result should be parsed by `orgflow--rg-parse-result', or
manually depending on the extra ARGS."
  ;; TODO: make shell files, for common tasks?
  (unless (executable-find "rg")
    (error "orgflow requires the system package `rg'."))

  (let ((buf (generate-new-buffer "*orgflow-rg*")))
    (unwind-protect
        (let* ((dir (expand-file-name (or dir default-directory)))
               (args `(,dir
                       "--regexp" ,query
                       "--no-config"
                       "--type" "org"
                       "--ignore-case"
                       "--only-matching"
                       "--no-heading"
                       "--line-number"
                       "--column"
                       "--trim"
                       "--null"
                       ,@args))
               (cmd `("rg" nil ,buf nil ,@args))
               (result))
          (setq result (apply #'call-process cmd))

          (with-current-buffer buf
            (unless (= result 0)        ;non-zero return code means ripgrep had an error
              (error "%s" (buffer-string)))

            (setq result (buffer-string)))

          result)
      (kill-buffer buf))))

(defun orgflow--extract-links (buf &optional type)
  "Return all org-links from buffer BUF, optionally only return links of type TYPE."
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
  ""
  (interactive)
  (if-let* ((links (orgflow--extract-links (current-buffer) 'url))
            (pick (completing-read "urls: " links nil t)))
      (browse-url pick)
    (message "no urls in buffer")))

(defun orgflow-visit-linked-file ()
  ""
  (interactive)
  (if-let* ((links (orgflow--extract-links (current-buffer) 'file))
            (pick (completing-read "linked files: " links nil t)))
      (find-file-existing pick)
    (message "no file links in buffer")))

(defun orgflow--find-nearby-files-rg (dir)
  "Return a list of org-files inside DIR, or in any sub-directory of DIR. "
  (let ((result (orgflow--rg "" dir "--files-with-matches")))
    (string-split result " ")))

(defun orgflow--visit-nearby-files-xf (s)
  ""
  (file-relative-name s))

(defun orgflow-visit-nearby-file (&optional dir)
  ""
  (interactive)
  (let* ((dir (or dir (when current-prefix-arg (read-directory-name ""))))
         (files (orgflow--find-nearby-files-rg dir))
         (pick (ivy-read "nearby files: " files
                         :caller #'orgflow-visit-nearby-file)))
    (find-file pick)))

(ivy-set-display-transformer #'orgflow-visit-nearby-file #'orgflow--visit-nearby-files-xf)

(defun orgflow--find-all-tagged-headings-rg (&optional dir)
  "Return a list of all headings with tags in DIR, or in any sub-directory of DIR."
  ;; NOTE: can tags be non-alpha characters?
  (let* ((tagged-heading-re "^(\\*+.+) :([[:alpha:]\\|:]+):$")
         (result (orgflow--rg tagged-heading-re dir "--replace" "$1$2")))
    (string-split result "\n" t (rx (1+ space)))))

(defun orgflow--visit-tagged-heading-xf (s)
  ""
  (let* ((data (orgflow--rg-parse-result s))
         (file (plist-get data :file))
         (matched (split-string (plist-get data :match) "" t (rx (1+ space))))
         (heading (car matched))
         (tags (cadr matched)))
    (concat
     (orgflow--fit-section (file-relative-name file)
                           (or (nth 0 orgflow-section-sizes) 25))
     " "
     (orgflow--fit-section heading
                           (or (nth 1 orgflow-section-sizes) 35))
     " "
     tags)))

(defun orgflow-visit-tagged-heading (&optional dir)
  ""
  (interactive)
  (let* ((col (orgflow--find-all-tagged-headings-rg
               (or dir (when current-prefix-arg (read-directory-name ""))))))
    (when-let* ((ivy-re-builders-alist '((t . ivy--regex-ignore-order)))
                (pick (ivy-read "tags: " col
                                :require-match t
                                :caller #'orgflow-visit-tagged-heading))
                (data (orgflow--rg-parse-result pick)))
      (with-current-buffer (find-file-existing (plist-get data :file))
        (goto-line (plist-get data :line))))))

(ivy-set-display-transformer #'orgflow-visit-tagged-heading #'orgflow--visit-tagged-heading-xf)

(defun orgflow--find-backlinks-rg (file &optional dir)
  "Return a list of org-files in DIR, or in any sub-directory of DIR, which link to FILE."
  ;; FIXME: probably breaks when multiple files have the same name in nearby directories
  (let* ((filename (file-name-nondirectory file))
         (backlinks-re (concat "\\[\\[.*(?::?|/?)" filename "(?:::.*)?\\]\\[(.*)\\]\\]"))
         (result (orgflow--rg backlinks-re dir)))
    (string-split result "\n" t (rx (1+ space)))))

(defun orgflow--visit-backlinks-xf (s)
  ""
  (let* ((data (orgflow--rg-parse-result s))
         (file (plist-get data :file))
         (org-link (plist-get data :match))
         (link (nth 1 (s-match (rx "[["(0+ any)"]["(group (0+ any))"]]") org-link))))
    (concat
     (orgflow--fit-section (file-name-nondirectory file)
                           (or (nth 0 orgflow-section-sizes) 25))
     " "
     link)))

(defun orgflow-visit-backlinks (&optional file dir)
  ""
  (interactive)
  (if-let* ((links (orgflow--find-backlinks-rg
                    (or file (buffer-file-name))
                    (or dir (when current-prefix-arg (read-directory-name "")))))
            (pick (ivy-read "backlinks: " links
                            :require-match t
                            :caller #'orgflow-visit-backlinks))
            (data (orgflow--rg-parse-result pick)))
      (with-current-buffer (find-file-existing (plist-get data :file))
        (goto-line (plist-get data :line))
        (forward-char (plist-get data :column)))
    (message "no backlinks found")))

(ivy-set-display-transformer #'orgflow-visit-backlinks #'orgflow--visit-backlinks-xf)


(provide 'orgflow)
;;; orgflow.el ends here
