;;; rmailmm.el --- MIME decoding and display stuff for RMAIL

;; Copyright (C) 2006, 2007, 2008, 2009, 2010, 2011  Free Software Foundation, Inc.

;; Author: Alexander Pohoyda
;;	Alex Schroeder
;; Maintainer: FSF
;; Keywords: mail

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Essentially based on the design of Alexander Pohoyda's MIME
;; extensions (mime-display.el and mime.el).

;; This file provides two operation modes for viewing a MIME message.

;; (1) When rmail-enable-mime is non-nil (now it is the default), the
;; function `rmail-show-mime' is automatically called.  That function
;; shows a MIME message directly in RMAIL's view buffer.

;; (2) When rmail-enable-mime is nil, the command 'v' (or M-x
;; rmail-mime) shows a MIME message in a new buffer "*RMAIL*".

;; Both operations share the intermediate functions rmail-mime-process
;; and rmail-mime-process-multipart as below.

;; rmail-show-mime
;;   +- rmail-mime-parse
;;   |    +- rmail-mime-process <--+------------+
;;   |         |         +---------+            |
;;   |         + rmail-mime-process-multipart --+
;;   |
;;   + rmail-mime-insert <----------------+
;;       +- rmail-mime-insert-text        |
;;       +- rmail-mime-insert-bulk        |
;;       +- rmail-mime-insert-multipart --+
;;
;; rmail-mime
;;  +- rmail-mime-show <----------------------------------+
;;       +- rmail-mime-process                            | 
;;            +- rmail-mime-handle                        |
;;                 +- rmail-mime-text-handler             |
;;                 +- rmail-mime-bulk-handler             |
;;                 |    + rmail-mime-insert-bulk
;;                 +- rmail-mime-multipart-handler        |
;;                      +- rmail-mime-process-multipart --+

;; In addition, for the case of rmail-enable-mime being non-nil, this
;; file provides two functions rmail-insert-mime-forwarded-message and
;; rmail-insert-mime-resent-message for composing forwarded and resent
;; messages respectively.

;; Todo:

;; Make rmail-mime-media-type-handlers-alist usable in the first
;; operation mode.
;; Handle multipart/alternative in the second operation mode.
;; Offer the option to call external/internal viewers (doc-view, xpdf, etc).

;;; Code:

(require 'rmail)
(require 'mail-parse)
(require 'message)

;;; User options.

(defgroup rmail-mime nil
  "Rmail MIME handling options."
  :prefix "rmail-mime-"
  :group 'rmail)

(defcustom rmail-mime-media-type-handlers-alist
  '(("multipart/.*" rmail-mime-multipart-handler)
    ("text/.*" rmail-mime-text-handler)
    ("text/\\(x-\\)?patch" rmail-mime-bulk-handler)
    ("\\(image\\|audio\\|video\\|application\\)/.*" rmail-mime-bulk-handler))
  "Functions to handle various content types.
This is an alist with elements of the form (REGEXP FUNCTION ...).
The first item is a regular expression matching a content-type.
The remaining elements are handler functions to run, in order of
decreasing preference.  These are called until one returns non-nil.
Note that this only applies to items with an inline Content-Disposition,
all others are handled by `rmail-mime-bulk-handler'.
Note also that this alist is ignored when the variable
`rmail-enable-mime' is non-nil."
  :type '(alist :key-type regexp :value-type (repeat function))
  :version "23.1"
  :group 'rmail-mime)

(defcustom rmail-mime-attachment-dirs-alist
  `(("text/.*" "~/Documents")
    ("image/.*" "~/Pictures")
    (".*" "~/Desktop" "~" ,temporary-file-directory))
  "Default directories to save attachments of various types into.
This is an alist with elements of the form (REGEXP DIR ...).
The first item is a regular expression matching a content-type.
The remaining elements are directories, in order of decreasing preference.
The first directory that exists is used."
  :type '(alist :key-type regexp :value-type (repeat directory))
  :version "23.1"
  :group 'rmail-mime)

(defcustom rmail-mime-show-images 'button
  "What to do with image attachments that Emacs is capable of displaying.
If nil, do nothing special.  If `button', add an extra button
that when pushed displays the image in the buffer.  If a number,
automatically show images if they are smaller than that size (in
bytes), otherwise add a display button.  Anything else means to
automatically display the image in the buffer."
  :type '(choice (const :tag "Add button to view image" button)
		 (const :tag "No special treatment" nil)
		 (number :tag "Show if smaller than certain size")
		 (other :tag "Always show" show))
  :version "23.2"
  :group 'rmail-mime)

;;; End of user options.

;;; Global variables that always have let-binding when referred.

(defvar rmail-mime-mbox-buffer nil
  "Buffer containing the mbox data.
The value is usually nil, and bound to a proper value while
processing MIME.")

(defvar rmail-mime-view-buffer nil
  "Buffer showing a message.
The value is usually nil, and bound to a proper value while
processing MIME.")

(defvar rmail-mime-coding-system nil
  "The first coding-system used for decoding a MIME entity.
The value is usually nil, and bound to non-nil while inserting
MIME entities.")

;;; MIME-entity object

(defun rmail-mime-entity (type disposition transfer-encoding
			       display header tagline body children handler)
  "Retrun a newly created MIME-entity object from arguments.

A MIME-entity is a vector of 9 elements:

  [TYPE DISPOSITION TRANSFER-ENCODING DISPLAY HEADER TAGLINE BODY
   CHILDREN HANDLER]
  
TYPE and DISPOSITION correspond to MIME headers Content-Type and
Cotent-Disposition respectively, and has this format:

  \(VALUE (ATTRIBUTE . VALUE) (ATTRIBUTE . VALUE) ...)

VALUE is a string and ATTRIBUTE is a symbol.

Consider the following header, for example:

Content-Type: multipart/mixed;
	boundary=\"----=_NextPart_000_0104_01C617E4.BDEC4C40\"

The corresponding TYPE argument must be:

\(\"multipart/mixed\"
  \(\"boundary\" . \"----=_NextPart_000_0104_01C617E4.BDEC4C40\"))

TRANSFER-ENCODING corresponds to MIME header
Content-Transfer-Encoding, and is a lowercased string.

DISPLAY is a vector [CURRENT NEW], where CURRENT indicates how
the header, tagline, and body of the entity are displayed now,
and NEW indicates how their displaying should be updated.
Both elements are vector [HEADER-DISPLAY TAGLINE-DISPLAY BODY-DISPLAY],
where each element is a symbol for the corresponding item that
has these values:
  nil: not displayed
  t: displayed by the decoded presentation form
  raw: displayed by the raw MIME data (for the header and body only)

HEADER and BODY are vectors [BEG END DISPLAY-FLAG], where BEG and
END specify the region of the header or body lines in RMAIL's
data (mbox) buffer, and DISPLAY-FLAG non-nil means that the
header or body is, by default, displayed by the decoded
presentation form.

TAGLINE is a vector [TAG BULK-DATA DISPLAY-FLAG], where TAG is a
string indicating the depth and index number of the entity,
BULK-DATA is a cons (SIZE . TYPE) indicating the size and type of
an attached data, DISPLAY-FLAG non-nil means that the tagline is,
by default, displayed.

CHILDREN is a list of child MIME-entities.  A \"multipart/*\"
entity have one or more children.  A \"message/rfc822\" entity
has just one child.  Any other entity has no child.

HANDLER is a function to insert the entity according to DISPLAY.
It is called with one argument ENTITY."
  (vector type disposition transfer-encoding
	  display header tagline body children handler))

;; Accessors for a MIME-entity object.
(defsubst rmail-mime-entity-type (entity) (aref entity 0))
(defsubst rmail-mime-entity-disposition (entity) (aref entity 1))
(defsubst rmail-mime-entity-transfer-encoding (entity) (aref entity 2))
(defsubst rmail-mime-entity-display (entity) (aref entity 3))
(defsubst rmail-mime-entity-header (entity) (aref entity 4))
(defsubst rmail-mime-entity-tagline (entity) (aref entity 5))
(defsubst rmail-mime-entity-body (entity) (aref entity 6))
(defsubst rmail-mime-entity-children (entity) (aref entity 7))
(defsubst rmail-mime-entity-handler (entity) (aref entity 8))

(defsubst rmail-mime-message-p ()
  "Non-nil if and only if the current message is a MIME."
  (or (get-text-property (point) 'rmail-mime-entity)
      (get-text-property (point-min) 'rmail-mime-entity)))

;;; Buttons

(defun rmail-mime-save (button)
  "Save the attachment using info in the BUTTON."
  (let* ((rmail-mime-mbox-buffer rmail-view-buffer)
	 (filename (button-get button 'filename))
	 (directory (button-get button 'directory))
	 (data (button-get button 'data))
	 (ofilename filename))
    (setq filename (expand-file-name
		    (read-file-name (format "Save as (default: %s): " filename)
				    directory
				    (expand-file-name filename directory))
		    directory))
    ;; If arg is just a directory, use the default file name, but in
    ;; that directory (copied from write-file).
    (if (file-directory-p filename)
	(setq filename (expand-file-name
			(file-name-nondirectory ofilename)
			(file-name-as-directory filename))))
    (with-temp-buffer
      (set-buffer-file-coding-system 'no-conversion)
      ;; Needed e.g. by jka-compr, so if the attachment is a compressed
      ;; file, the magic signature compares equal with the unibyte
      ;; signature string recorded in jka-compr-compression-info-list.
      (set-buffer-multibyte nil)
      (setq buffer-undo-list t)
      (if (stringp data)
	  (insert data)
	;; DATA is a MIME-entity object.
	(let ((transfer-encoding (rmail-mime-entity-transfer-encoding data))
	      (body (rmail-mime-entity-body data)))
	  (insert-buffer-substring rmail-mime-mbox-buffer
				   (aref body 0) (aref body 1))
	  (cond ((string= transfer-encoding "base64")
		 (ignore-errors (base64-decode-region (point-min) (point-max))))
		((string= transfer-encoding "quoted-printable")
		 (quoted-printable-decode-region (point-min) (point-max))))))
      (write-region nil nil filename nil nil nil t))))

(define-button-type 'rmail-mime-save 'action 'rmail-mime-save)

(defun rmail-mime-entity-segment (pos &optional entity)
  "Return a vector describing the displayed region of a MIME-entity at POS.
Optional 2nd argument ENTITY is the MIME-entity at POS.
The value is a vector [ INDEX HEADER TAGLINE BODY END], where
  INDEX: index into the returned vector indicating where POS is (1..3).
  HEADER: the position of the beginning of a header
  TAGLINE: the position of the beginning of a tagline
  BODY: the position of the beginning of a body
  END: the position of the end of the entity."
  (save-excursion
    (or entity
	(setq entity (get-text-property pos 'rmail-mime-entity)))
    (if (not entity)
	(vector 1 (point) (point) (point) (point))
      (let ((current (aref (rmail-mime-entity-display entity) 0))
	    (beg (if (and (> pos (point-min))
			  (eq (get-text-property (1- pos) 'rmail-mime-entity)
			      entity))
		     (previous-single-property-change pos 'rmail-mime-entity
						      nil (point-min))
		   pos))
	    (index 1)
	    tagline-beg body-beg end)
	(goto-char beg)
	(if (aref current 0)
	    (search-forward "\n\n" nil t))
	(setq tagline-beg (point))
	(if (>= pos tagline-beg)
	    (setq index 2))
	(if (aref current 1)
	    (forward-line 1))
	(setq body-beg (point))
	(if (>= pos body-beg)
	    (setq index 3))
	(if (aref current 2)
	    (let ((tag (aref (rmail-mime-entity-tagline entity) 0))
		  tag2)
	      (setq end (next-single-property-change beg 'rmail-mime-entity
						     nil (point-max)))
	      (while (and (< end (point-max))
			  (setq entity (get-text-property end 'rmail-mime-entity)
				tag2 (aref (rmail-mime-entity-tagline entity) 0))
			  (and (> (length tag2) 0)
			       (eq (string-match tag tag2) 0)))
		(setq end (next-single-property-change end 'rmail-mime-entity
						       nil (point-max)))))
	  (setq end body-beg))
	(vector index beg tagline-beg body-beg end)))))

(defun rmail-mime-shown-mode (entity)
  "Make MIME-entity ENTITY displayed by the default way."
  (let ((new (aref (rmail-mime-entity-display entity) 1)))
    (aset new 0 (aref (rmail-mime-entity-header entity) 2))
    (aset new 1 (aref (rmail-mime-entity-tagline entity) 2))
    (aset new 2 (aref (rmail-mime-entity-body entity) 2)))
  (dolist (child (rmail-mime-entity-children entity))
    (rmail-mime-shown-mode child)))
  
(defun rmail-mime-hidden-mode (entity)
  "Make MIME-entity ENTITY displayed in the hidden mode."
  (let ((new (aref (rmail-mime-entity-display entity) 1)))
    (aset new 0 nil)
    (aset new 1 t)
    (aset new 2 nil))
  (dolist (child (rmail-mime-entity-children entity))
    (rmail-mime-hidden-mode child)))

(defun rmail-mime-raw-mode (entity)
  "Make MIME-entity ENTITY displayed in the raw mode."
  (let ((new (aref (rmail-mime-entity-display entity) 1)))
    (aset new 0 'raw)
    (aset new 1 nil)
    (aset new 2 'raw))
  (dolist (child (rmail-mime-entity-children entity))
    (rmail-mime-raw-mode child)))

(defun rmail-mime-toggle-raw (entity)
  "Toggle on and off the raw display mode of MIME-entity ENTITY."
  (let* ((pos (if (eobp) (1- (point-max)) (point)))
	 (entity (get-text-property pos 'rmail-mime-entity))
	 (current (aref (rmail-mime-entity-display entity) 0))
	 (segment (rmail-mime-entity-segment pos entity)))
    (if (not (eq (aref current 0) 'raw))
	;; Enter the raw mode.
	(rmail-mime-raw-mode entity)
      ;; Enter the shown mode.
      (rmail-mime-shown-mode entity))
    (let ((inhibit-read-only t)
	  (modified (buffer-modified-p)))
      (save-excursion
	(goto-char (aref segment 1))
	(rmail-mime-insert entity)
	(restore-buffer-modified-p modified)))))

(defun rmail-mime-toggle-hidden ()
  "Hide or show the body of MIME-entity at point."
  (interactive)
  (when (rmail-mime-message-p)
    (let* ((rmail-mime-mbox-buffer rmail-view-buffer)
	   (rmail-mime-view-buffer (current-buffer))
	   (pos (if (eobp) (1- (point-max)) (point)))
	   (entity (get-text-property pos 'rmail-mime-entity))
	   (current (aref (rmail-mime-entity-display entity) 0))
	   (segment (rmail-mime-entity-segment pos entity)))
      (if (aref current 2)
	  ;; Enter the hidden mode.
	  (progn
	    ;; If point is in the body part, move it to the tagline
	    ;; (or the header if tagline is not displayed).
	    (if (= (aref segment 0) 3)
		(goto-char (aref segment 2)))
	    (rmail-mime-hidden-mode entity)
	    ;; If the current entity is the topmost one, display the
	    ;; header.
	    (if (and rmail-mime-mbox-buffer (= (aref segment 1) (point-min)))
		(let ((new (aref (rmail-mime-entity-display entity) 1)))
		  (aset new 0 t))))
	;; Enter the shown mode.
	(rmail-mime-shown-mode entity)
	;; Force this body shown.
	(aset (aref (rmail-mime-entity-display entity) 1) 2 t))
      (let ((inhibit-read-only t)
	    (modified (buffer-modified-p))
	    (rmail-mime-mbox-buffer rmail-view-buffer)
	    (rmail-mime-view-buffer rmail-buffer))
	(save-excursion
	  (goto-char (aref segment 1))
	  (rmail-mime-insert entity)
	  (restore-buffer-modified-p modified))))))

(define-key rmail-mode-map "\t" 'forward-button)
(define-key rmail-mode-map [backtab] 'backward-button)
(define-key rmail-mode-map "\r" 'rmail-mime-toggle-hidden)

;;; Handlers

(defun rmail-mime-insert-tagline (entity &rest item-list)
  "Insert a tag line for MIME-entity ENTITY.
ITEM-LIST is a list of strings or button-elements (list) to be added
to the tag line."
  (insert "[")
  (let ((tag (aref (rmail-mime-entity-tagline entity) 0)))
    (if (> (length tag) 0) (insert (substring tag 1) ":")))
  (insert (car (rmail-mime-entity-type entity)) " ")
  (insert-button (let ((new (aref (rmail-mime-entity-display entity) 1)))
		   (if (aref new 2) "Hide" "Show"))
		 :type 'rmail-mime-toggle
		 'help-echo "mouse-2, RET: Toggle show/hide")
  (dolist (item item-list)
    (when item
      (if (stringp item)
	  (insert item)
	(apply 'insert-button item))))
  (insert "]\n"))
  
(defun rmail-mime-update-tagline (entity)
  "Update the current tag line for MIME-entity ENTITY."
  (let ((inhibit-read-only t)
	(modified (buffer-modified-p))
	;; If we are going to show the body, the new button label is
	;; "Hide".  Otherwise, it's "Show".
	(label (if (aref (aref (rmail-mime-entity-display entity) 1) 2) "Hide"
		 "Show"))
	(button (next-button (point))))
    ;; Go to the second character of the button "Show" or "Hide".
    (goto-char (1+ (button-start button)))
    (setq button (button-at (point)))
    (save-excursion
      (insert label)
      (delete-region (point) (button-end button)))
    (delete-region (button-start button) (point))
    (put-text-property (point) (button-end button) 'rmail-mime-entity entity)
    (restore-buffer-modified-p modified)
    (forward-line 1)))

(defun rmail-mime-insert-header (header)
  "Decode and insert a MIME-entity header HEADER in the current buffer.
HEADER is a vector [BEG END DEFAULT-STATUS].
See `rmail-mime-entity' for the detail."
  (let ((pos (point))
	(last-coding-system-used nil))
    (save-restriction
      (narrow-to-region pos pos)
      (with-current-buffer rmail-mime-mbox-buffer
	(let ((rmail-buffer rmail-mime-mbox-buffer)
	      (rmail-view-buffer rmail-mime-view-buffer))
	  (save-excursion
	    (goto-char (aref header 0))
	    (rmail-copy-headers (point) (aref header 1)))))
      (rfc2047-decode-region pos (point))
      (if (and last-coding-system-used (not rmail-mime-coding-system))
	  (setq rmail-mime-coding-system (cons last-coding-system-used nil)))
      (goto-char (point-min))
      (rmail-highlight-headers)
      (goto-char (point-max))
      (insert "\n"))))

(defun rmail-mime-find-header-encoding (header)
  "Retun the last coding system used to decode HEADER.
HEADER is a header component of a MIME-entity object (see
`rmail-mime-entity')."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (with-current-buffer rmail-mime-mbox-buffer
	(let ((last-coding-system-used nil)
	      (rmail-buffer rmail-mime-mbox-buffer)
	      (rmail-view-buffer buf))
	  (save-excursion
	    (goto-char (aref header 0))
	    (rmail-copy-headers (point) (aref header 1)))))
      (rfc2047-decode-region (point-min) (point-max))
      last-coding-system-used)))

(defun rmail-mime-text-handler (content-type
				content-disposition
				content-transfer-encoding)
  "Handle the current buffer as a plain text MIME part."
  (rmail-mime-insert-text
   (rmail-mime-entity content-type content-disposition
		      content-transfer-encoding
		      (vector (vector nil nil nil) (vector nil nil t))
		      (vector nil nil nil) (vector "" (cons nil nil) t)
		      (vector nil nil nil) nil 'rmail-mime-insert-text))
  t)

(defun rmail-mime-insert-decoded-text (entity)
  "Decode and insert the text body of MIME-entity ENTITY."
  (let* ((content-type (rmail-mime-entity-type entity))
	 (charset (cdr (assq 'charset (cdr content-type))))
	 (coding-system (if charset
			    (coding-system-from-name charset)))
	 (body (rmail-mime-entity-body entity))
	 (pos (point)))
    (or (and coding-system (coding-system-p coding-system))
	(setq coding-system 'undecided))
    (if (stringp (aref body 0))
	(insert (aref body 0))
      (let ((transfer-encoding (rmail-mime-entity-transfer-encoding entity)))
	(insert-buffer-substring rmail-mime-mbox-buffer
				 (aref body 0) (aref body 1))
	(cond ((string= transfer-encoding "base64")
	       (ignore-errors (base64-decode-region pos (point))))
	      ((string= transfer-encoding "quoted-printable")
	       (quoted-printable-decode-region pos (point))))))
    (decode-coding-region pos (point) coding-system)
    (if (and
	 (or (not rmail-mime-coding-system) (consp rmail-mime-coding-system))
	 (not (eq (coding-system-base coding-system) 'us-ascii)))
	(setq rmail-mime-coding-system coding-system))
    (or (bolp) (insert "\n"))))

(defun rmail-mime-insert-text (entity)
  "Presentation handler for a plain text MIME entity."
  (let ((current (aref (rmail-mime-entity-display entity) 0))
	(new (aref (rmail-mime-entity-display entity) 1))
	(header (rmail-mime-entity-header entity))
	(tagline (rmail-mime-entity-tagline entity))
	(body (rmail-mime-entity-body entity))
	(beg (point))
	(segment (rmail-mime-entity-segment (point) entity)))

    (or (integerp (aref body 0))
	(let ((data (buffer-string)))
	  (aset body 0 data)
	  (delete-region (point-min) (point-max))))

    ;; header
    (if (eq (aref current 0) (aref new 0))
	(goto-char (aref segment 2))
      (if (aref current 0)
	  (delete-char (- (aref segment 2) (aref segment 1))))
      (if (aref new 0)
	  (rmail-mime-insert-header header)))
    ;; tagline
    (if (eq (aref current 1) (aref new 1))
	(if (or (not (aref current 1))
		(eq (aref current 2) (aref new 2)))
	    (forward-char (- (aref segment 3) (aref segment 2)))
	  (rmail-mime-update-tagline entity))
      (if (aref current 1)
	  (delete-char (- (aref segment 3) (aref segment 2))))
      (if (aref new 1)
	  (rmail-mime-insert-tagline entity)))
    ;; body
    (if (eq (aref current 2) (aref new 2))
	(forward-char (- (aref segment 4) (aref segment 3)))
      (if (aref current 2)
	  (delete-char (- (aref segment 4) (aref segment 3))))
      (if (aref new 2)
	  (rmail-mime-insert-decoded-text entity)))
    (put-text-property beg (point) 'rmail-mime-entity entity)))

;; FIXME move to the test/ directory?
(defun test-rmail-mime-handler ()
  "Test of a mail using no MIME parts at all."
  (let ((mail "To: alex@gnu.org
Content-Type: text/plain; charset=koi8-r
Content-Transfer-Encoding: 8bit
MIME-Version: 1.0

\372\304\322\301\327\323\324\327\325\312\324\305\41"))
    (switch-to-buffer (get-buffer-create "*test*"))
    (erase-buffer)
    (set-buffer-multibyte nil)
    (insert mail)
    (rmail-mime-show t)
    (set-buffer-multibyte t)))


(defun rmail-mime-insert-image (entity)
  "Decode and insert the image body of MIME-entity ENTITY."
  (let* ((content-type (car (rmail-mime-entity-type entity)))
	 (bulk-data (aref (rmail-mime-entity-tagline entity) 1))
	 (body (rmail-mime-entity-body entity))
	 data)
    (if (stringp (aref body 0))
	(setq data (aref body 0))
      (let ((rmail-mime-mbox-buffer rmail-view-buffer)
	    (transfer-encoding (rmail-mime-entity-transfer-encoding entity)))
	(with-temp-buffer
	  (set-buffer-multibyte nil)
	  (setq buffer-undo-list t)
	  (insert-buffer-substring rmail-mime-mbox-buffer
				   (aref body 0) (aref body 1))
	  (cond ((string= transfer-encoding "base64")
		 (ignore-errors (base64-decode-region (point-min) (point-max))))
		((string= transfer-encoding "quoted-printable")
		 (quoted-printable-decode-region (point-min) (point-max))))
	  (setq data
		(buffer-substring-no-properties (point-min) (point-max))))))
    (insert-image (create-image data (cdr bulk-data) t))
    (insert "\n")))

(defun rmail-mime-toggle-button (button)
  "Hide or show the body of the MIME-entity associated with BUTTON."
  (save-excursion
    (goto-char (button-start button))
    (rmail-mime-toggle-hidden)))

(define-button-type 'rmail-mime-toggle 'action 'rmail-mime-toggle-button)


(defun rmail-mime-bulk-handler (content-type
				content-disposition
				content-transfer-encoding)
  "Handle the current buffer as an attachment to download.
For images that Emacs is capable of displaying, the behavior
depends upon the value of `rmail-mime-show-images'."
  (rmail-mime-insert-bulk
   (rmail-mime-entity content-type content-disposition content-transfer-encoding
		      (vector (vector nil nil nil) (vector nil t nil))
		      (vector nil nil nil) (vector "" (cons nil nil) t)
		      (vector nil nil nil) nil 'rmail-mime-insert-bulk)))

(defun rmail-mime-set-bulk-data (entity)
  "Setup the information about the attachment object for MIME-entity ENTITY.
The value is non-nil if and only if the attachment object should be shown
directly."
  (let ((content-type (car (rmail-mime-entity-type entity)))
	(size (cdr (assq 'size (cdr (rmail-mime-entity-disposition entity)))))
	(bulk-data (aref (rmail-mime-entity-tagline entity) 1))
	(body (rmail-mime-entity-body entity))
	type to-show)
    (cond (size
	   (setq size (string-to-number size)))
	  ((stringp (aref body 0))
	   (setq size (length (aref body 0))))
	  (t
	   ;; Rough estimation of the size.
	   (let ((encoding (rmail-mime-entity-transfer-encoding entity)))
	     (setq size (- (aref body 1) (aref body 0)))
	     (cond ((string= encoding "base64")
		    (setq size (/ (* size 3) 4)))
		   ((string= encoding "quoted-printable")
		    (setq size (/ (* size 7) 3)))))))

    (cond
     ((string-match "text/" content-type)
      (setq type 'text))
     ((string-match "image/\\(.*\\)" content-type)
      (setq type (image-type-from-file-name
		  (concat "." (match-string 1 content-type))))
      (if (and (memq type image-types)
	       (image-type-available-p type))
	  (if (and rmail-mime-show-images
		   (not (eq rmail-mime-show-images 'button))
		   (or (not (numberp rmail-mime-show-images))
		       (< size rmail-mime-show-images)))
	      (setq to-show t))
	(setq type nil))))
    (setcar bulk-data size)
    (setcdr bulk-data type)
    to-show))

(defun rmail-mime-insert-bulk (entity)
  "Presentation handler for an attachment MIME entity."
  (let* ((content-type (rmail-mime-entity-type entity))
	 (content-disposition (rmail-mime-entity-disposition entity))
	 (current (aref (rmail-mime-entity-display entity) 0))
	 (new (aref (rmail-mime-entity-display entity) 1))
	 (header (rmail-mime-entity-header entity))
	 (tagline (rmail-mime-entity-tagline entity))
	 (bulk-data (aref tagline 1))
	 (body (rmail-mime-entity-body entity))
	 ;; Find the default directory for this media type.
	 (directory (catch 'directory
		      (dolist (entry rmail-mime-attachment-dirs-alist)
			(when (string-match (car entry) (car content-type))
			  (dolist (dir (cdr entry))
			    (when (file-directory-p dir)
			      (throw 'directory dir)))))))
	 (filename (or (cdr (assq 'name (cdr content-type)))
		       (cdr (assq 'filename (cdr content-disposition)))
		       "noname"))
	 (units '(B kB MB GB))
	 (segment (rmail-mime-entity-segment (point) entity))
	 beg data size)

    (if (integerp (aref body 0))
	(setq data entity
	      size (car bulk-data))
      (if (stringp (aref body 0))
	  (setq data (aref body 0))
	(setq data (string-as-unibyte (buffer-string)))
	(aset body 0 data)
	(rmail-mime-set-bulk-data entity)
	(delete-region (point-min) (point-max)))
      (setq size (length data)))
    (while (and (> size 1024.0) ; cribbed from gnus-agent-expire-done-message
		(cdr units))
      (setq size (/ size 1024.0)
	    units (cdr units)))

    (setq beg (point))

    ;; header
    (if (eq (aref current 0) (aref new 0))
	(goto-char (aref segment 2))
      (if (aref current 0)
	  (delete-char (- (aref segment 2) (aref segment 1))))
      (if (aref new 0)
	  (rmail-mime-insert-header header)))

    ;; tagline
    (if (eq (aref current 1) (aref new 1))
	(if (or (not (aref current 1))
		(eq (aref current 2) (aref new 2)))
	    (forward-char (- (aref segment 3) (aref segment 2)))
	  (rmail-mime-update-tagline entity))
      (if (aref current 1)
	  (delete-char (- (aref segment 3) (aref segment 2))))
      (if (aref new 1)
	  (rmail-mime-insert-tagline
	   entity
	   " Save:"
	   (list filename
		 :type 'rmail-mime-save
		 'help-echo "mouse-2, RET: Save attachment"
		 'filename filename
		 'directory (file-name-as-directory directory)
		 'data data)
	   (format " (%.0f%s)" size (car units))
	   ;; We don't need this button because the "type" string of a
	   ;; tagline is the button to do this.
	   ;; (if (cdr bulk-data)
	   ;;     " ")
	   ;; (if (cdr bulk-data)
	   ;;     (list "Toggle show/hide"
	   ;; 	     :type 'rmail-mime-image
	   ;; 	     'help-echo "mouse-2, RET: Toggle show/hide"
	   ;; 	     'image-type (cdr bulk-data)
	   ;; 	     'image-data data))
	   )))
    ;; body
    (if (eq (aref current 2) (aref new 2))
	(forward-char (- (aref segment 4) (aref segment 3)))
      (if (aref current 2)
	  (delete-char (- (aref segment 4) (aref segment 3))))
      (if (aref new 2)
	  (cond ((eq (cdr bulk-data) 'text)
		 (rmail-mime-insert-decoded-text entity))
		((cdr bulk-data)
		 (rmail-mime-insert-image entity))
		(t
		 ;; As we don't know how to display the body, just
		 ;; insert it as a text.
		 (rmail-mime-insert-decoded-text entity)))))
    (put-text-property beg (point) 'rmail-mime-entity entity)))

(defun test-rmail-mime-bulk-handler ()
  "Test of a mail used as an example in RFC 2183."
  (let ((mail "Content-Type: image/jpeg
Content-Disposition: attachment; filename=genome.jpeg;
  modification-date=\"Wed, 12 Feb 1997 16:29:51 -0500\";
Content-Description: a complete map of the human genome
Content-Transfer-Encoding: base64

iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAMAAABg3Am1AAAABGdBTUEAALGPC/xhBQAAAAZQ
TFRF////AAAAVcLTfgAAAPZJREFUeNq9ldsOwzAIQ+3//+l1WlvA5ZLsoUiTto4TB+ISoAjy
+ITfRBfcAmgRFFeAm+J6uhdKdFhFWUgDkFsK0oUp/9G2//Kj7Jx+5tSKOdBscgUYiKHRS/me
WATQdRUvAK0Bnmshmtn79PpaLBbbOZkjKvRnjRZoRswOkG1wFchKew2g9wXVJVZL/m4+B+vv
9AxQQR2Q33SgAYJzzVACdAWjAfRYzYFO9n6SLnydtQHSMxYDMAKqZ/8FS/lTK+zuq3CtK64L
UDwbgUEAUmk2Zyg101d6PhCDySgAvTvDgKiuOrc4dLxUb7UMnhGIexyI+d6U+ABuNAP4Simx
lgAAAABJRU5ErkJggg==
"))
    (switch-to-buffer (get-buffer-create "*test*"))
    (erase-buffer)
    (insert mail)
    (rmail-mime-show)))

(defun rmail-mime-multipart-handler (content-type
				     content-disposition
				     content-transfer-encoding)
  "Handle the current buffer as a multipart MIME body.
The current buffer should be narrowed to the body.  CONTENT-TYPE,
CONTENT-DISPOSITION, and CONTENT-TRANSFER-ENCODING are the values
of the respective parsed headers.  See `rmail-mime-handle' for their
format."
  (rmail-mime-process-multipart
   content-type content-disposition content-transfer-encoding nil)
  t)

(defun rmail-mime-process-multipart (content-type
				     content-disposition
				     content-transfer-encoding
				     parse-tag)
  "Process the current buffer as a multipart MIME body.

If PARSE-TAG is nil, modify the current buffer directly for
showing the MIME body and return nil.

Otherwise, PARSE-TAG is a string indicating the depth and index
number of the entity.  In this case, parse the current buffer and
return a list of MIME-entity objects.

The other arguments are the same as `rmail-mime-multipart-handler'."
  ;; Some MUAs start boundaries with "--", while it should start
  ;; with "CRLF--", as defined by RFC 2046:
  ;;    The boundary delimiter MUST occur at the beginning of a line,
  ;;    i.e., following a CRLF, and the initial CRLF is considered to
  ;;    be attached to the boundary delimiter line rather than part
  ;;    of the preceding part.
  ;; We currently don't handle that.
  (let ((boundary (cdr (assq 'boundary content-type)))
	(subtype (cadr (split-string (car content-type) "/")))
	(index 0)
	beg end next entities)
    (unless boundary
      (rmail-mm-get-boundary-error-message
       "No boundary defined" content-type content-disposition
       content-transfer-encoding))
    (setq boundary (concat "\n--" boundary))
    ;; Hide the body before the first bodypart
    (goto-char (point-min))
    (when (and (search-forward boundary nil t)
	       (looking-at "[ \t]*\n"))
      (if parse-tag
	  (narrow-to-region (match-end 0) (point-max))
	(delete-region (point-min) (match-end 0))))

    ;; Change content-type to the proper default one for the children.
    (cond ((string-match "mixed" subtype)
	   (setq content-type '("text/plain")))
	  ((string-match "digest" subtype)
	   (setq content-type '("message/rfc822")))
	  (t
	   (setq content-type nil)))

    ;; Loop over all body parts, where beg points at the beginning of
    ;; the part and end points at the end of the part.  next points at
    ;; the beginning of the next part.  The current point is just
    ;; after the boundary tag.
    (setq beg (point-min))
    (while (search-forward boundary nil t)
      (setq end (match-beginning 0))
      ;; If this is the last boundary according to RFC 2046, hide the
      ;; epilogue, else hide the boundary only.  Use a marker for
      ;; `next' because `rmail-mime-show' may change the buffer.
      (cond ((looking-at "--[ \t]*$")
	     (setq next (point-max-marker)))
	    ((looking-at "[ \t]*\n")
	     (setq next (copy-marker (match-end 0) t)))
	    (t
	     ;; The original code signalled an error as below, but
	     ;; this line may be a boundary of nested multipart.  So,
	     ;; we just set `next' to nil to skip this line
	     ;; (rmail-mm-get-boundary-error-message
	     ;;  "Malformed boundary" content-type content-disposition
	     ;;  content-transfer-encoding)
	     (setq next nil)))

      (when next
	(setq index (1+ index))
	;; Handle the part.
	(if parse-tag
	    (save-restriction
	      (narrow-to-region beg end)
	      (let ((child (rmail-mime-process
			    nil (format "%s/%d" parse-tag index)
			    content-type content-disposition)))
		;; Display a tagline.
		(aset (aref (rmail-mime-entity-display child) 1) 1
		      (aset (rmail-mime-entity-tagline child) 2 t))
		(push child entities)))

	  (delete-region end next)
	  (save-restriction
	    (narrow-to-region beg end)
	    (rmail-mime-show)))
	(goto-char (setq beg next))))

    (when parse-tag
      (setq entities (nreverse entities))
      (if (string-match "alternative" subtype)
	  ;; Find the best entity to show, and hide all the others.
	  (let (best second)
	    (dolist (child entities)
	      (if (string= (or (car (rmail-mime-entity-disposition child))
			       (car content-disposition))
			   "inline")
		  (if (string-match "text/plain"
				    (car (rmail-mime-entity-type child)))
		      (setq best child)
		    (if (string-match "text/.*"
				      (car (rmail-mime-entity-type child)))
			(setq second child)))))
	    (or best (not second) (setq best second))
	    (dolist (child entities)
	      (unless (eq best child)
		(aset (rmail-mime-entity-body child) 2 nil)
		(rmail-mime-hidden-mode child)))))
      entities)))

(defun test-rmail-mime-multipart-handler ()
  "Test of a mail used as an example in RFC 2046."
  (let ((mail "From: Nathaniel Borenstein <nsb@bellcore.com>
To: Ned Freed <ned@innosoft.com>
Date: Sun, 21 Mar 1993 23:56:48 -0800 (PST)
Subject: Sample message
MIME-Version: 1.0
Content-type: multipart/mixed; boundary=\"simple boundary\"

This is the preamble.  It is to be ignored, though it
is a handy place for composition agents to include an
explanatory note to non-MIME conformant readers.

--simple boundary

This is implicitly typed plain US-ASCII text.
It does NOT end with a linebreak.
--simple boundary
Content-type: text/plain; charset=us-ascii

This is explicitly typed plain US-ASCII text.
It DOES end with a linebreak.

--simple boundary--

This is the epilogue.  It is also to be ignored."))
    (switch-to-buffer (get-buffer-create "*test*"))
    (erase-buffer)
    (insert mail)
    (rmail-mime-show t)))

(defun rmail-mime-insert-multipart (entity)
  "Presentation handler for a multipart MIME entity."
  (let ((current (aref (rmail-mime-entity-display entity) 0))
	(new (aref (rmail-mime-entity-display entity) 1))
	(header (rmail-mime-entity-header entity))
	(tagline (rmail-mime-entity-tagline entity))
	(body (rmail-mime-entity-body entity))
	(beg (point))
	(segment (rmail-mime-entity-segment (point) entity)))
    ;; header
    (if (eq (aref current 0) (aref new 0))
	(goto-char (aref segment 2))
      (if (aref current 0)
	  (delete-char (- (aref segment 2) (aref segment 1))))
      (if (aref new 0)
	  (rmail-mime-insert-header header)))
    ;; tagline
    (if (eq (aref current 1) (aref new 1))
	(if (or (not (aref current 1))
		(eq (aref current 2) (aref new 2)))
	    (forward-char (- (aref segment 3) (aref segment 2)))
	  (rmail-mime-update-tagline entity))
      (if (aref current 1)
	  (delete-char (- (aref segment 3) (aref segment 2))))
      (if (aref new 1)
	  (rmail-mime-insert-tagline entity)))

    (put-text-property beg (point) 'rmail-mime-entity entity)

    ;; body
    (if (eq (aref current 2) (aref new 2))
	(forward-char (- (aref segment 4) (aref segment 3)))
      (dolist (child (rmail-mime-entity-children entity))
	(rmail-mime-insert child)))
    entity))

;;; Main code

(defun rmail-mime-handle (content-type
			  content-disposition
			  content-transfer-encoding)
  "Handle the current buffer as a MIME part.
The current buffer should be narrowed to the respective body, and
point should be at the beginning of the body.

CONTENT-TYPE, CONTENT-DISPOSITION, and CONTENT-TRANSFER-ENCODING
are the values of the respective parsed headers.  The latter should
be downcased.  The parsed headers for CONTENT-TYPE and CONTENT-DISPOSITION
have the form

  \(VALUE . ALIST)

In other words:

  \(VALUE (ATTRIBUTE . VALUE) (ATTRIBUTE . VALUE) ...)

VALUE is a string and ATTRIBUTE is a symbol.

Consider the following header, for example:

Content-Type: multipart/mixed;
	boundary=\"----=_NextPart_000_0104_01C617E4.BDEC4C40\"

The parsed header value:

\(\"multipart/mixed\"
  \(\"boundary\" . \"----=_NextPart_000_0104_01C617E4.BDEC4C40\"))"
  ;; Handle the content transfer encodings we know.  Unknown transfer
  ;; encodings will be passed on to the various handlers.
  (cond ((string= content-transfer-encoding "base64")
	 (when (ignore-errors
		 (base64-decode-region (point) (point-max)))
	   (setq content-transfer-encoding nil)))
	((string= content-transfer-encoding "quoted-printable")
	 (quoted-printable-decode-region (point) (point-max))
	 (setq content-transfer-encoding nil))
	((string= content-transfer-encoding "8bit")
	 ;; FIXME: Is this the correct way?
         ;; No, of course not, it just means there's no decoding to do.
	 ;; (set-buffer-multibyte nil)
         (setq content-transfer-encoding nil)
         ))
  ;; Inline stuff requires work.  Attachments are handled by the bulk
  ;; handler.
  (if (string= "inline" (car content-disposition))
      (let ((stop nil))
	(dolist (entry rmail-mime-media-type-handlers-alist)
	  (when (and (string-match (car entry) (car content-type)) (not stop))
	    (progn
	      (setq stop (funcall (cadr entry) content-type
				  content-disposition
				  content-transfer-encoding))))))
    ;; Everything else is an attachment.
    (rmail-mime-bulk-handler content-type
		       content-disposition
		       content-transfer-encoding))
  (save-restriction
    (widen)
    (let ((entity (get-text-property (1- (point)) 'rmail-mime-entity))
	  current new)
      (when entity
	(setq current (aref (rmail-mime-entity-display entity) 0)
	      new (aref (rmail-mime-entity-display entity) 1))
	(dotimes (i 3)
	  (aset current i (aref new i)))))))

(defun rmail-mime-show (&optional show-headers)
  "Handle the current buffer as a MIME message.
If SHOW-HEADERS is non-nil, then the headers of the current part
will shown as usual for a MIME message.  The headers are also
shown for the content type message/rfc822.  This function will be
called recursively if multiple parts are available.

The current buffer must contain a single message.  It will be
modified."
  (rmail-mime-process show-headers nil))

(defun rmail-mime-process (show-headers parse-tag &optional
					default-content-type
					default-content-disposition)
  (let ((end (point-min))
	content-type
	content-transfer-encoding
	content-disposition)
    ;; `point-min' returns the beginning and `end' points at the end
    ;; of the headers.
    (goto-char (point-min))
    ;; If we're showing a part without headers, then it will start
    ;; with a newline.
    (if (eq (char-after) ?\n)
	(setq end (1+ (point)))
      (when (search-forward "\n\n" nil t)
	(setq end (match-end 0))
	(save-restriction
	  (narrow-to-region (point-min) end)
	  ;; FIXME: Default disposition of the multipart entities should
	  ;; be inherited.
	  (setq content-type
		(mail-fetch-field "Content-Type")
		content-transfer-encoding
		(mail-fetch-field "Content-Transfer-Encoding")
		content-disposition
		(mail-fetch-field "Content-Disposition")))))
    ;; Per RFC 2045, C-T-E is case insensitive (bug#5070), but the others
    ;; are not completely so.  Hopefully mail-header-parse-* DTRT.
    (if content-transfer-encoding
	(setq content-transfer-encoding (downcase content-transfer-encoding)))
    (setq content-type
	  (if content-type
	      (or (mail-header-parse-content-type content-type)
		  '("text/plain"))
	    (or default-content-type '("text/plain"))))
    (setq content-disposition
	  (if content-disposition
	      (mail-header-parse-content-disposition content-disposition)
	    ;; If none specified, we are free to choose what we deem
	    ;; suitable according to RFC 2183.  We like inline.
	    (or default-content-disposition '("inline"))))
    ;; Unrecognized disposition types are to be treated like
    ;; attachment according to RFC 2183.
    (unless (member (car content-disposition) '("inline" "attachment"))
      (setq content-disposition '("attachment")))

    (if parse-tag
	(let* ((is-inline (string= (car content-disposition) "inline"))
	       (header (vector (point-min) end nil))
	       (tagline (vector parse-tag (cons nil nil) t))
	       (body (vector end (point-max) is-inline))
	       (new (vector (aref header 2) (aref tagline 2) (aref body 2)))
	       children handler entity)
	  (cond ((string-match "multipart/.*" (car content-type))
		 (save-restriction
		   (narrow-to-region (1- end) (point-max))
		   (setq children (rmail-mime-process-multipart
				   content-type
				   content-disposition
				   content-transfer-encoding
				   parse-tag)
			 handler 'rmail-mime-insert-multipart)))
		((string-match "message/rfc822" (car content-type))
		 (save-restriction
		   (narrow-to-region end (point-max))
		   (let* ((msg (rmail-mime-process t parse-tag
						   '("text/plain") '("inline")))
			  (msg-new (aref (rmail-mime-entity-display msg) 1)))
		     ;; Show header of the child.
		     (aset msg-new 0 t)
		     (aset (rmail-mime-entity-header msg) 2 t)
		     ;; Hide tagline of the child.
		     (aset msg-new 1 nil)
		     (aset (rmail-mime-entity-tagline msg) 2 nil)
		     (setq children (list msg)
			   handler 'rmail-mime-insert-multipart))))
		((and is-inline (string-match "text/" (car content-type)))
		 ;; Don't need a tagline.
		 (aset new 1 (aset tagline 2 nil))
		 (setq handler 'rmail-mime-insert-text))
		(t
		 ;; Force hidden mode.
		 (aset new 1 (aset tagline 2 t))
		 (aset new 2 (aset body 2 nil))
		 (setq handler 'rmail-mime-insert-bulk)))
	  (setq entity (rmail-mime-entity content-type
					  content-disposition
					  content-transfer-encoding
					  (vector (vector nil nil nil) new)
					  header tagline body children handler))
	  (if (and (eq handler 'rmail-mime-insert-bulk)
		   (rmail-mime-set-bulk-data entity))
	      ;; Show the body.
	      (aset new 2 (aset body 2 t)))
	  entity)

      ;; Hide headers and handle the part.
      (put-text-property (point-min) (point-max) 'rmail-mime-entity
			 (rmail-mime-entity 
			 content-type content-disposition
			 content-transfer-encoding
			 (vector (vector 'raw nil 'raw) (vector 'raw nil 'raw))
			 (vector nil nil 'raw) (vector "" (cons nil nil) nil)
			 (vector nil nil 'raw) nil nil))
      (save-restriction
	(cond ((string= (car content-type) "message/rfc822")
	       (narrow-to-region end (point-max)))
	      ((not show-headers)
	       (delete-region (point-min) end)))
	(rmail-mime-handle content-type content-disposition
			   content-transfer-encoding)))))

(defun rmail-mime-parse ()
  "Parse the current Rmail message as a MIME message.
The value is a MIME-entiy object (see `rmail-mime-entity').
If an error occurs, return an error message string."
  (let ((rmail-mime-mbox-buffer (if (rmail-buffers-swapped-p)
				    rmail-view-buffer
				  (current-buffer))))
    (condition-case err
	(with-current-buffer rmail-mime-mbox-buffer
	  (save-excursion
	    (goto-char (point-min))
	    (let* ((entity (rmail-mime-process t ""
					       '("text/plain") '("inline")))
		   (new (aref (rmail-mime-entity-display entity) 1)))
	      ;; Show header.
	      (aset new 0 (aset (rmail-mime-entity-header entity) 2 t))
	      ;; Show tagline if and only if body is not shown.
	      (if (aref new 2)
		  (aset new 1 (aset (rmail-mime-entity-tagline entity) 2 nil))
		(aset new 1 (aset (rmail-mime-entity-tagline entity) 2 t)))
	      entity)))
      (error (format "%s" err)))))

(defun rmail-mime-insert (entity)
  "Insert a MIME-entity ENTITY in the current buffer.

This function will be called recursively if multiple parts are
available."
  (let ((current (aref (rmail-mime-entity-display entity) 0))
	(new (aref (rmail-mime-entity-display entity) 1)))
    (if (not (eq (aref new 0) 'raw))
	;; Not a raw-mode.  Each handler should handle it.
	(funcall (rmail-mime-entity-handler entity) entity)
      (let ((header (rmail-mime-entity-header entity))
	    (tagline (rmail-mime-entity-tagline entity))
	    (body (rmail-mime-entity-body entity))
	    (beg (point))
	    (segment (rmail-mime-entity-segment (point) entity)))
	;; header
	(if (eq (aref current 0) (aref new 0))
	    (goto-char (aref segment 2))
	  (if (aref current 0)
	      (delete-char (- (aref segment 2) (aref segment 1))))
	  (insert-buffer-substring rmail-mime-mbox-buffer
				     (aref header 0) (aref header 1)))
	;; tagline
	(if (aref current 1)
	    (delete-char (- (aref segment 3) (aref segment 2))))
	;; body
	(let ((children (rmail-mime-entity-children entity)))
	  (if children
	      (progn
		(put-text-property beg (point) 'rmail-mime-entity entity)
		(dolist (child children)
		  (rmail-mime-insert child)))
	    (if (eq (aref current 2) (aref new 2))
		(forward-char (- (aref segment 4) (aref segment 3)))
	      (if (aref current 2)
		(delete-char (- (aref segment 4) (aref segment 3))))
	      (insert-buffer-substring rmail-mime-mbox-buffer
				       (aref body 0) (aref body 1))
	      (or (bolp) (insert "\n")))
	    (put-text-property beg (point) 'rmail-mime-entity entity)))))
    (dotimes (i 3)
      (aset current i (aref new i)))))

(define-derived-mode rmail-mime-mode fundamental-mode "RMIME"
  "Major mode used in `rmail-mime' buffers."
  (setq font-lock-defaults '(rmail-font-lock-keywords t t nil nil)))

;;;###autoload
(defun rmail-mime (&optional arg)
  "Toggle displaying of a MIME message.

The actualy behavior depends on the value of `rmail-enable-mime'.

If `rmail-enable-mime' is t (default), this command change the
displaying of a MIME message between decoded presentation form
and raw data.

With ARG, toggle the displaying of the current MIME entity only.

If `rmail-enable-mime' is nil, this creates a temporary
\"*RMAIL*\" buffer holding a decoded copy of the message.  Inline
content-types are handled according to
`rmail-mime-media-type-handlers-alist'.  By default, this
displays text and multipart messages, and offers to download
attachments as specfied by `rmail-mime-attachment-dirs-alist'."
  (interactive "P")
  (if rmail-enable-mime
      (with-current-buffer rmail-buffer
	(if (rmail-mime-message-p)
	    (let ((rmail-mime-mbox-buffer rmail-view-buffer)
		  (rmail-mime-view-buffer rmail-buffer)
		  (entity (get-text-property (point) 'rmail-mime-entity)))
	      (if arg
		  (if entity
		      (rmail-mime-toggle-raw entity))
		(goto-char (point-min))
		(rmail-mime-toggle-raw
		 (get-text-property (point) 'rmail-mime-entity))))
	  (message "Not a MIME message")))
    (let* ((data (rmail-apply-in-message rmail-current-message 'buffer-string))
	   (buf (get-buffer-create "*RMAIL*"))
	   (rmail-mime-mbox-buffer rmail-view-buffer)
	   (rmail-mime-view-buffer buf))
      (set-buffer buf)
      (setq buffer-undo-list t)
      (let ((inhibit-read-only t))
	;; Decoding the message in fundamental mode for speed, only
	;; switching to rmail-mime-mode at the end for display.  Eg
	;; quoted-printable-decode-region gets very slow otherwise (Bug#4993).
	(fundamental-mode)
	(erase-buffer)
	(insert data)
	(rmail-mime-show t)
	(rmail-mime-mode)
	(set-buffer-modified-p nil))
      (view-buffer buf))))

(defun rmail-mm-get-boundary-error-message (message type disposition encoding)
  "Return MESSAGE with more information on the main mime components."
  (error "%s; type: %s; disposition: %s; encoding: %s"
	 message type disposition encoding))

(defun rmail-show-mime ()
  "Function to set in `rmail-show-mime-function' (which see)."
  (let ((entity (rmail-mime-parse))
	(rmail-mime-mbox-buffer rmail-buffer)
	(rmail-mime-view-buffer rmail-view-buffer)
	(rmail-mime-coding-system nil))
    (if (vectorp entity)
	(with-current-buffer rmail-mime-view-buffer
	  (erase-buffer)
	  (rmail-mime-insert entity)
	  (if (consp rmail-mime-coding-system)
	      ;; Decoding is done by rfc2047-decode-region only for a
	      ;; header.  But, as the used coding system may have been
	      ;; overriden by mm-charset-override-alist, we can't
	      ;; trust (car rmail-mime-coding-system).  So, here we
	      ;; try the decoding again with mm-charset-override-alist
	      ;; bound to nil.
	      (let ((mm-charset-override-alist nil))
		(setq rmail-mime-coding-system
		      (rmail-mime-find-header-encoding
		       (rmail-mime-entity-header entity)))))
	  (set-buffer-file-coding-system
	   (if rmail-mime-coding-system
	       (coding-system-base rmail-mime-coding-system)
	     'undecided)
	   t t))
      ;; Decoding failed.  ENTITY is an error message.  Insert the
      ;; original message body as is, and show warning.
      (let ((region (with-current-buffer rmail-mime-mbox-buffer
		      (goto-char (point-min))
		      (re-search-forward "^$" nil t)
		      (forward-line 1)
		      (vector (point-min) (point) (point-max)))))
	(with-current-buffer rmail-mime-view-buffer
	  (let ((inhibit-read-only t))
	    (erase-buffer)
	    (rmail-mime-insert-header region)
	    (insert-buffer-substring rmail-mime-mbox-buffer
				     (aref region 1) (aref region 2))))
	(set-buffer-file-coding-system 'no-conversion t t)
	(message "MIME decoding failed: %s" entity)))))

(setq rmail-show-mime-function 'rmail-show-mime)

(defun rmail-insert-mime-forwarded-message (forward-buffer)
  "Function to set in `rmail-insert-mime-forwarded-message-function' (which see)."
  (let ((rmail-mime-mbox-buffer
	 (with-current-buffer forward-buffer rmail-view-buffer)))
    (save-restriction
      (narrow-to-region (point) (point))
      (message-forward-make-body-mime rmail-mime-mbox-buffer))))

(setq rmail-insert-mime-forwarded-message-function
      'rmail-insert-mime-forwarded-message)

(defun rmail-insert-mime-resent-message (forward-buffer)
  "Function to set in `rmail-insert-mime-resent-message-function' (which see)."
  (insert-buffer-substring
   (with-current-buffer forward-buffer rmail-view-buffer))
  (goto-char (point-min))
  (when (looking-at "From ")
    (forward-line 1)
    (delete-region (point-min) (point))))

(setq rmail-insert-mime-resent-message-function
      'rmail-insert-mime-resent-message)

(defun rmail-search-mime-message (msg regexp)
  "Function to set in `rmail-search-mime-message-function' (which see)."
  (save-restriction
    (narrow-to-region (rmail-msgbeg msg) (rmail-msgend msg))
    (let* ((rmail-mime-mbox-buffer (current-buffer))
	   (rmail-mime-view-buffer rmail-view-buffer)
	   (header-end (save-excursion
			 (re-search-forward "^$" nil 'move) (point)))
	   (body-end (point-max))
	   (entity (rmail-mime-parse)))
      (or 
       ;; At first, just search the headers.
       (with-temp-buffer
	 (insert-buffer-substring rmail-mime-mbox-buffer nil header-end)
	 (rfc2047-decode-region (point-min) (point))
	 (goto-char (point-min))
	 (re-search-forward regexp nil t))
       ;; Next, search the body.
       (if (and entity
		(let* ((content-type (rmail-mime-entity-type entity))
		       (charset (cdr (assq 'charset (cdr content-type)))))
		  (or (not (string-match "text/.*" (car content-type))) 
		      (and charset
			   (not (string= (downcase charset) "us-ascii"))))))
	   ;; Search the decoded MIME message.
	   (with-temp-buffer
	     (rmail-mime-insert entity)
	     (goto-char (point-min))
	     (re-search-forward regexp nil t))
	 ;; Search the body without decoding.
	 (goto-char header-end)
	 (re-search-forward regexp nil t))))))

(setq rmail-search-mime-message-function 'rmail-search-mime-message)

(provide 'rmailmm)

;; Local Variables:
;; generated-autoload-file: "rmail.el"
;; End:

;; arch-tag: 3f2c5e5d-1aef-4512-bc20-fd737c9d5dd9
;;; rmailmm.el ends here
