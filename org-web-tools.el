;;; Code:

;;;; Requirements

(require 'cl-lib)
(require 'dash)
(require 'dom)
(require 'eww)
(require 'org)
(require 's)
(require 'url)

;;;; Commands

;;;###autoload
(defun org-web-tools-insert-link-for-url (url)
  "Insert Org link to URL using title of HTML page at URL.
If URL is not given, look for first URL in kill-ring."
  (interactive (list (org-web-tools--get-first-url)))
  (let* ((html (org-web-tools--get-url url))
         (title (org-web-tools--html-title html))
         (link (org-make-link-string url title)))
    (insert link)))

;;;###autoload
(defun org-web-tools-insert-web-page-as-entry (url)
  "Insert web page contents as Org sibling entry.
Page is processed with `eww-readable'."
  (interactive (list (org-web-tools--get-first-url)))
  (let* ((capture-fn #'org-web-tools--url-as-readable-org)
         (content (s-trim (funcall capture-fn url))))
    (beginning-of-line) ; Necessary for org-paste-subtree to choose the right heading level
    (org-paste-subtree nil content)))

;;;###autoload
(defun org-web-tools-read-url-as-org (url)
  "Read URL's readable content in an Org buffer."
  (interactive (list (org-web-tools--get-first-url)))
  (let ((entry (org-web-tools--url-as-readable-org url)))
    (when entry
      (switch-to-buffer url)
      (org-mode)
      (insert entry)
      ;; Set buffer title
      (goto-char (point-min))
      (rename-buffer (cdr (org-web-tools--read-org-bracket-link))))))

;;;###autoload
(defun org-web-tools-convert-url-list-to-page-entries ()
  "Convert list of URLs into Org entries containing page content processed with `eww-readable'.
All URLs in the current entry (i.e. this does not look deeper in
the subtree, or outside of it) will be converted."
  (interactive)
  (let ((level (org-outline-level))
        (beg (org-entry-beginning-position))
        url-beg url new-entry)
    (while (progn
             (goto-char beg)
             (goto-char (org-entry-end-position))  ; Work from the bottom of the list to the top, makes it simpler
             (setq url-beg (re-search-backward (rx "http" (optional "s") "://") beg 'no-error)))
      (setq url (buffer-substring (line-beginning-position) (line-end-position)))
      ;; TODO: Needs error handling
      (when (setq new-entry (org-web-tools--url-as-readable-org url))
        ;; FIXME: If a URL fails to fetch, this should skip it, but
        ;; that means the failed URL will become part of the next
        ;; entry's contents.  Might need to read the whole list at
        ;; once, use markers to track the list's position, then
        ;; replace the whole list with any errored URLs after it's
        ;; done.
        (goto-char url-beg) ; This should NOT be necessary!  But it is, because the point moves back down a line!  Why?!
        (delete-region (line-beginning-position) (line-end-position))
        (org-paste-subtree level new-entry)))))

;;;; Functions

(defun org-web-tools--eww-readable (html)
  "Return \"readable\" part of HTML with title.
Returns list (HTML . TITLE).  Based on `eww-readable'."
  (let* ((dom (with-temp-buffer
                (insert html)
                (libxml-parse-html-region (point-min) (point-max))))
         (title (caddr (car (dom-by-tag dom 'title)))))
    (eww-score-readability dom)
    (cons (with-temp-buffer
            (shr-dom-print (eww-highest-readability dom))
            (buffer-string))
          title)))

(defun org-web-tools--get-url (url)
  "Return content for URL as string.
This uses `url-retrieve-synchronously' to make a request with the
URL, then returns the response body.  Since that function returns
the entire response, including headers, we must remove the
headers ourselves. "
  (let* ((response-buffer (url-retrieve-synchronously url nil t))
         (encoded-html (with-current-buffer response-buffer
                         (pop-to-buffer response-buffer)
                         ;; Skip HTTP headers
                         (re-search-forward (rx (repeat 2 (or "\n" "\r"))) nil t)
                         (delete-region (point-min) (point))
                         (buffer-string))))
    (kill-buffer response-buffer)     ; Not sure if necessary to avoid leaking buffer
    (with-temp-buffer
      ;; For some reason, running `decode-coding-region' in the
      ;; response buffer has no effect, so we have to do it in a
      ;; temp buffer.
      (insert encoded-html)
      (condition-case nil
          ;; Fix undecoded text
          (decode-coding-region (point-min) (point-max) 'utf-8)
        (coding-system-error nil))
      (buffer-string))))

(defun org-web-tools--html-title (html)
  "Return title of HTML page.
Uses the `dom' library."
  ;; Based on `eww-readable'
  ;; TODO: Maybe use regexp instead of parsing whole DOM, should be faster
  (let* ((dom (with-temp-buffer
                (insert html)
                (libxml-parse-html-region (point-min) (point-max))))
         (title (caddr (car (dom-by-tag dom 'title)))))
    title))

(defun org-web-tools--html-to-org-with-pandoc (html)
  "Return string of HTML converted to Org with Pandoc."
  (with-temp-buffer
    (insert html)
    (unless (= 0 (call-process-region (point-min) (point-max) "pandoc" t t nil "--no-wrap" "-f" "html" "-t" "org"))
      (error "Pandoc failed."))
    (org-web-tools--remove-dos-crlf)
    (buffer-string)))

(defun org-web-tools--url-as-readable-org (url)
  "Return string containing Org entry of URL's web page content.
Content is processed with `eww-readable' and Pandoc.  Entry will
be a top-level heading, with article contents below a
second-level \"Article\" heading, and a timestamp in the
first-level entry for writing comments."
  (-let* ((html (org-web-tools--get-url url))
          ((readable . title) (org-web-tools--eww-readable html))
          (converted (org-web-tools--html-to-org-with-pandoc readable))
          (link (org-make-link-string url title))
          (timestamp (format-time-string (concat "[" (substring (cdr org-time-stamp-formats) 1 -1) "]"))))
    (with-temp-buffer
      (org-mode)
      ;; Insert article text
      (insert converted)
      ;; Demote in-article headings
      (org-web-tools--demote-headings-below 2)
      ;; Insert headings at top
      (goto-char (point-min))
      (insert "* " link " :website" "\n\n"
              timestamp "\n\n"
              "** Article" "\n\n")
      (buffer-string))))

;;;;; Misc

(defun org-web-tools--demote-headings-below (level &optional skip)
  "If any headings in current buffer are at or above LEVEL, demote all headings in buffer so the highest level is below LEVEL.
If SKIP is non-nil, it is passed to `org-map-entries', which see.  Note that \"highest level\" has the lowest number of stars."
  (let* ((buffer-highest-level (progn
                                 (goto-char (point-min))
                                 (when (org-before-first-heading-p)
                                   (outline-next-heading))
                                 (cl-loop while (org-at-heading-p)
                                          collect (org-outline-level) into result
                                          do (outline-next-heading)
                                          finally return (seq-min result))))
         (difference (- buffer-highest-level level))
         (adjust-by (when (<= difference 0)
                      (1+ (* -1 difference)))))
    (when difference
      ;; Demote headings in buffer
      (org-map-entries
       (lambda ()
         (dotimes (i adjust-by)
           (org-demote)))
       t nil skip))))

(defun org-web-tools--get-first-url ()
  "Return URL in clipboard, or first URL in kill-ring, or nil if none."
  (cl-loop for item in (append (list (gui-get-selection 'CLIPBOARD))
                               kill-ring)
           if (string-match (rx bol "http" (optional "s") "://") item)
           return item))

(defun org-web-tools--read-org-bracket-link (&optional link)
  "Return (TARGET . DESCRIPTION) for Org bracket LINK or next link on current line."
  ;; Searching to the end of the line seems the simplest way
  (save-excursion
    (let (target desc)
      (if link
          ;; Link passed as arg
          (when (string-match org-bracket-link-regexp link)
            (setq target (match-string-no-properties 1 link)
                  desc (match-string-no-properties 3 link)))
        ;; No arg; get link from buffer
        (when (re-search-forward org-bracket-link-regexp (point-at-eol) t)
          (setq target (match-string-no-properties 1)
                desc (match-string-no-properties 3))))
      (when (and target desc)
        ;; Link found; return parts
        (cons target desc)))))

(defun org-web-tools--remove-dos-crlf ()
  "Remove all DOS CRLF (^M) in buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (search-forward (string ?\C-m) nil t)
      (replace-match ""))))
