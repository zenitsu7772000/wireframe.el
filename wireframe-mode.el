;;; wireframe-mode.el --- Keyboard-first wireframe prototyping -*- lexical-binding: t; -*-

;; Author: wireframe.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, hypermedia
;; URL: https://github.com/zenitsu7772000/wireframe.el

;;; Commentary:
;; Minimal, functional wireframe UI prototyping in Emacs.
;;
;; DSL example:
;;   (screen home
;;     (header "Logo" "Menu")
;;     (section
;;       (title "Hero Title")
;;       (button "Get Started"))
;;     (card-list 3))
;;
;; Main features:
;; - Parse Lisp DSL into internal tree
;; - Render HTML + CSS wireframe output
;; - Live preview update on save
;; - Major mode with basic syntax highlight and editing commands

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'thingatpt)
(require 'browse-url)
(require 'json)

(defgroup wireframe nil
  "Keyboard-first wireframe prototyping."
  :group 'tools)

(defcustom wireframe-preview-file
  (expand-file-name "wireframe-preview.html" temporary-file-directory)
  "File used for live preview output."
  :type 'file
  :group 'wireframe)

(defcustom wireframe-export-file "wireframe-export.html"
  "Default export file name used by `wireframe-export-html'."
  :type 'string
  :group 'wireframe)

(defcustom wireframe-auto-open-preview t
  "If non-nil, `wireframe-preview' opens preview in browser/xwidget."
  :type 'boolean
  :group 'wireframe)

(defcustom wireframe-preview-split-size 0.5
  "Size used by `wireframe-preview-split`.
This is window width fraction for the right-side split."
  :type 'number
  :group 'wireframe)

(defvar-local wireframe--preview-opened nil)
(defvar wireframe--xwidget-buffer-name "*wireframe-eww-preview*")
(defvar wireframe--preview-buffer nil)
(defvar wireframe--html-buffer-name "*wireframe-preview-html*")
(defvar-local wireframe--prefer-split-preview nil)
(defvar wireframe--preview-window nil)
(defconst wireframe--known-components
  '(screen header section container horizontal vertical title paragraph text button image-placeholder card-list)
  "Known DSL component symbols.")

;;;; DSL parser

(defun wireframe--plist-from-keywords (items)
  "Return plist parsed from keyword-value ITEMS."
  (let (plist)
    (while (and items (keywordp (car items)))
      (let ((k (pop items))
            (v (pop items)))
        (setq plist (plist-put plist k v))))
    plist))

(defun wireframe--split-head-attrs-children (args)
  "Split ARGS into (head attrs children).
HEAD is non-keyword first arg when present."
  (let ((head nil)
        (rest args))
    (when (and rest (not (keywordp (car rest)))
               (or (atom (car rest))
                   (and (listp (car rest)) (not (keywordp (caar rest))))))
      (setq head (pop rest)))
    (let ((attrs (wireframe--plist-from-keywords rest)))
      (while (and rest (keywordp (car rest)))
        (pop rest) (pop rest))
      (list head attrs rest))))

(defun wireframe--node (type &optional attrs children text)
  "Create a standard internal node.
TYPE is symbol, ATTRS plist, CHILDREN list, TEXT string/symbol/number."
  (list :type type :attrs attrs :children children :text text))

(defun wireframe--parse-form (form)
  "Parse DSL FORM into internal node tree."
  (pcase form
    ((pred atom)
     (wireframe--node 'raw nil nil (format "%s" form)))
    (`(screen ,name . ,children)
     (wireframe--node 'screen
                      (list :name (format "%s" name))
                      (mapcar #'wireframe--parse-form children)))
    (`(header ,left ,right . ,rest)
     (wireframe--node 'header
                      (wireframe--plist-from-keywords rest)
                      nil
                      (list left right)))
    (`(section . ,args)
     (cl-destructuring-bind (_ attrs kids) (wireframe--split-head-attrs-children args)
       (wireframe--node 'section attrs (mapcar #'wireframe--parse-form kids))))
    (`(container . ,args)
     (let ((attrs (wireframe--plist-from-keywords args))
           (kids args))
       (while (and kids (keywordp (car kids)))
         (pop kids) (pop kids))
       (wireframe--node 'container attrs (mapcar #'wireframe--parse-form kids))))
    (`(title ,txt . ,rest)
     (wireframe--node 'title (wireframe--plist-from-keywords rest) nil txt))
    (`(paragraph ,txt . ,rest)
     (wireframe--node 'paragraph (wireframe--plist-from-keywords rest) nil txt))
    (`(text ,txt . ,rest)
     (wireframe--node 'paragraph (wireframe--plist-from-keywords rest) nil txt))
    (`(button ,label . ,rest)
     (wireframe--node 'button (wireframe--plist-from-keywords rest) nil label))
    (`(image-placeholder . ,args)
     (let ((dims (if (and args (numberp (car args)))
                     (list :width (pop args) :height (or (pop args) 120))
                   nil)))
       (wireframe--node 'image-placeholder
                        (append dims (wireframe--plist-from-keywords args))
                        nil
                        "Image")))
    (`(card-list ,count . ,rest)
     (wireframe--node 'card-list
                      (append (list :count count) (wireframe--plist-from-keywords rest))
                      nil))
    (`(horizontal . ,children)
     (wireframe--node 'container (list :direction 'horizontal)
                      (mapcar #'wireframe--parse-form children)))
    (`(vertical . ,children)
     (wireframe--node 'container (list :direction 'vertical)
                      (mapcar #'wireframe--parse-form children)))
    (`(,kind . ,args)
     ;; Generic fallback custom component
     (let ((attrs (wireframe--plist-from-keywords args))
           (kids args))
       (while (and kids (keywordp (car kids)))
         (pop kids) (pop kids))
       (wireframe--node kind attrs (mapcar #'wireframe--parse-form kids))))))

(defun wireframe-parse-buffer ()
  "Parse current buffer and return list of root nodes."
  (save-excursion
    (goto-char (point-min))
    (let (forms)
      (condition-case err
          (while t
            (skip-chars-forward " \t\n\r")
            (push (read (current-buffer)) forms))
        (end-of-file nil)
        (error (user-error "Parse error: %s" (error-message-string err))))
      (mapcar #'wireframe--parse-form (nreverse forms)))))

;;;; HTML/CSS rendering

(defun wireframe--escape (s)
  "HTML-escape S."
  (let ((txt (format "%s" s)))
    (setq txt (replace-regexp-in-string "&" "&amp;" txt))
    (setq txt (replace-regexp-in-string "<" "&lt;" txt))
    (replace-regexp-in-string ">" "&gt;" txt)))

(defun wireframe--style-attrs (attrs)
  "Build inline style from ATTRS.
Supports spacing plus basic visual style keys."
  (let (parts)
    (when-let ((p (plist-get attrs :padding)))
      (push (format "padding:%spx" p) parts))
    (when-let ((m (plist-get attrs :margin)))
      (push (format "margin:%spx" m) parts))
    (when-let ((g (plist-get attrs :gap)))
      (push (format "gap:%spx" g) parts))
    (when-let ((bg (plist-get attrs :bg)))
      (push (format "background:%s" bg) parts))
    (when-let ((fg (plist-get attrs :color)))
      (push (format "color:%s" fg) parts))
    (when-let ((bd (plist-get attrs :border)))
      (push (format "border:%s" bd) parts))
    (when-let ((br (plist-get attrs :radius)))
      (push (format "border-radius:%spx" br) parts))
    (when-let ((fs (plist-get attrs :font-size)))
      (push (format "font-size:%spx" fs) parts))
    (when-let ((fw (plist-get attrs :font-weight)))
      (push (format "font-weight:%s" fw) parts))
    (when-let ((w (plist-get attrs :width)))
      (unless (plist-get attrs :height) ; image-placeholder handles explicit width/height separately
        (push (format "width:%spx" w) parts)))
    (when-let ((h (plist-get attrs :height)))
      (unless (plist-get attrs :width)
        (push (format "height:%spx" h) parts)))
    (when parts
      (format " style=\"%s\"" (string-join (nreverse parts) ";")))))

(defun wireframe--render-node (node)
  "Render NODE to HTML snippet."
  (let* ((type (plist-get node :type))
         (attrs (plist-get node :attrs))
         (children (plist-get node :children))
         (text (plist-get node :text))
         (style (or (wireframe--style-attrs attrs) "")))
    (pcase type
      ('screen
       (format "<main class=\"wf-screen\" data-screen=\"%s\">%s</main>"
               (wireframe--escape (or (plist-get attrs :name) "screen"))
               (mapconcat #'wireframe--render-node children "\n")))
      ('header
       (pcase-let ((`(,left ,right) text))
         (format "<header class=\"wf-header wf-box\"%s><div>%s</div><div>%s</div></header>"
                 style (wireframe--escape left) (wireframe--escape right))))
      ('section
       (format "<section class=\"wf-section wf-box\"%s>%s</section>"
               style
               (mapconcat #'wireframe--render-node children "\n")))
      ('container
       (let ((dir (if (eq (plist-get attrs :direction) 'horizontal) "row" "column")))
         (format "<div class=\"wf-container wf-box\" style=\"display:flex;flex-direction:%s;%s\">%s</div>"
                 dir
                 (or (and style (substring style 8 (1- (length style)))) "")
                 (mapconcat #'wireframe--render-node children "\n"))))
      ('title
       (format "<h1 class=\"wf-title\"%s>%s</h1>" style (wireframe--escape text)))
      ('paragraph
       (format "<p class=\"wf-paragraph\"%s>%s</p>" style (wireframe--escape text)))
      ('button
       (format "<button class=\"wf-button\"%s>%s</button>" style (wireframe--escape text)))
      ('image-placeholder
       (format "<div class=\"wf-image wf-box\" style=\"width:%spx;height:%spx;display:flex;align-items:center;justify-content:center;\">%s</div>"
               (or (plist-get attrs :width) 240)
               (or (plist-get attrs :height) 120)
               (wireframe--escape text)))
      ('card-list
       (let* ((n (max 1 (or (plist-get attrs :count) 3)))
              (cards (mapconcat (lambda (i)
                                  (format "<article class=\"wf-card wf-box\"><h3>Card %d</h3><p>Placeholder copy.</p><button class=\"wf-button\">Action</button></article>"
                                          i))
                                (number-sequence 1 n)
                                "\n")))
         (format "<div class=\"wf-card-list\"%s>%s</div>" style cards)))
      ('raw (format "<pre class=\"wf-raw\">%s</pre>" (wireframe--escape text)))
      (_
       (format "<div class=\"wf-custom wf-box\" data-kind=\"%s\"%s>%s</div>"
               (wireframe--escape (symbol-name type))
               style
               (mapconcat #'wireframe--render-node children "\n"))))))

(defun wireframe--base-css ()
  "Return base wireframe CSS."
  "
:root {
  --ink:#202838;
  --line:#8d98aa;
  --muted:#5e6a81;
  --bg:#eef2f7;
  --card:#ffffff;
  --accent:#1f6feb;
  --chip:#f8fbff;
}
* { box-sizing: border-box; }
body {
  margin:0;
  font-family: \"Iosevka Aile\", \"JetBrains Mono\", \"Fira Sans\", sans-serif;
  background: radial-gradient(circle at 12% 8%, #f9fcff 0, #eef2f7 45%, #e9edf5 100%);
  color: var(--ink);
}
.wf-screen {
  max-width: 1100px;
  margin: 32px auto;
  padding: 22px;
  border: 2px solid #6d7a8d;
  border-radius: 14px;
  background: linear-gradient(180deg, #fff, #fdfefe);
  box-shadow: 0 20px 50px rgba(43, 58, 88, .08);
  display:flex;
  flex-direction:column;
  gap:16px;
}
.wf-box {
  border:1px solid var(--line);
  background: var(--chip);
  border-radius: 10px;
}
.wf-header {
  display:flex;
  justify-content:space-between;
  padding:12px 16px;
  font-weight:700;
  letter-spacing:.3px;
  background: linear-gradient(90deg, #f7fbff, #f2f7ff);
}
.wf-section { padding:16px; display:flex; flex-direction:column; gap:10px; background:#fff; }
.wf-container { padding:12px; gap:10px; background:#f8fbff; }
.wf-title { margin:0; font-size: 30px; letter-spacing: .2px; }
.wf-paragraph { margin:0; color:var(--muted); line-height:1.5; }
.wf-button {
  border:1px solid #7a8dab;
  background: linear-gradient(180deg, #f7faff, #edf3ff);
  color: #23324a;
  padding:8px 12px;
  border-radius: 8px;
  font-weight: 600;
  cursor:pointer;
}
.wf-button:hover { border-color: var(--accent); }
.wf-image {
  border-style:dashed;
  background: repeating-linear-gradient(-45deg,#eef3fb,#eef3fb 8px,#fbfdff 8px,#fbfdff 16px);
  color:#586980;
}
.wf-card-list { display:grid; grid-template-columns: repeat(auto-fit,minmax(180px,1fr)); gap:12px; }
.wf-card { padding:12px; display:flex; flex-direction:column; gap:10px; background:#fff; }
.wf-card h3 { margin:0; font-size:16px; color:#2e3b52; }
.wf-card p { margin:0; font-size:14px; color:var(--muted); }
.wf-custom { padding:10px; background:#fff; }
")

(defun wireframe-render-html (&optional nodes)
  "Render NODES to full HTML string.
If NODES is nil, parse current buffer first."
  (let* ((tree (or nodes (wireframe-parse-buffer)))
         (body (mapconcat #'wireframe--render-node tree "\n")))
    (concat "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            "<title>Wireframe Preview</title>\n<style>"
            (wireframe--base-css)
            "</style></head><body>\n"
            body
            "\n</body></html>\n")))

;;;; Preview / export

(defun wireframe--write-html (path)
  "Render current DSL buffer and write HTML to PATH."
  (let ((html (wireframe-render-html)))
    (with-temp-file path
      (insert html))
    path))

(defun wireframe--xwidget-preview (file)
  "Show FILE in xwidget webkit if available."
  (when (fboundp 'xwidget-webkit-browse-url)
    (xwidget-webkit-browse-url (concat "file://" (expand-file-name file)) t)
    t))

(defun wireframe--eww-preview (file &optional split-window)
  "Show FILE in an eww preview buffer.
When SPLIT-WINDOW is non-nil, display it in a side window."
  (when (require 'eww nil t)
    (let* ((source-win (selected-window))
           (source-buf (window-buffer source-win))
           (target-buf (or (and (buffer-live-p wireframe--preview-buffer)
                                wireframe--preview-buffer)
                           (get-buffer-create wireframe--xwidget-buffer-name)))
           (right-win
            (if split-window
                (cond
                 ((window-live-p wireframe--preview-window)
                  wireframe--preview-window)
                 ((get-buffer-window target-buf t)
                  (setq wireframe--preview-window (get-buffer-window target-buf t)))
                 (t
                  (setq wireframe--preview-window
                        (split-window source-win
                                      (floor (* (window-total-width source-win)
                                                (- 1 wireframe-preview-split-size)))
                                      'right))))
              (or (and (window-live-p wireframe--preview-window) wireframe--preview-window)
                  (get-buffer-window target-buf t)
                  source-win)))
           rendered-buf)
      (with-selected-window right-win
        (let ((eww-buffer-name (buffer-name target-buf)))
          (eww-open-file file)
          (setq rendered-buf (current-buffer))))
      (setq wireframe--preview-buffer rendered-buf)
      (set-window-buffer right-win wireframe--preview-buffer)
      (set-window-dedicated-p right-win t)
      ;; Ensure editor stays on the left/source window.
      (when (window-live-p source-win)
        (set-window-buffer source-win source-buf)
        (select-window source-win))
      ;; Remove duplicate preview windows outside the dedicated right pane.
      (dolist (w (window-list nil 'nomini))
        (when (and (not (eq w right-win))
                   (eq (window-buffer w) wireframe--preview-buffer))
          (set-window-buffer w source-buf))))
    t))

(defun wireframe--fallback-html-buffer (file)
  "Show FILE contents in a plain Emacs buffer as final fallback preview."
  (let ((buf (get-buffer-create wireframe--html-buffer-name)))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert-file-contents file)
      (html-mode)
      (goto-char (point-min))
      (setq buffer-read-only t))
    (display-buffer buf)
    t))

(defun wireframe-preview ()
  "Render current buffer to `wireframe-preview-file` and open preview."
  (interactive)
  (let ((file (wireframe--write-html wireframe-preview-file)))
    (setq wireframe--prefer-split-preview nil)
    (when (buffer-live-p wireframe--preview-buffer)
      (wireframe--eww-preview file nil))
    (when (or wireframe-auto-open-preview (not wireframe--preview-opened))
      (unless (or (wireframe--xwidget-preview file)
                  (ignore-errors (browse-url-of-file file) t)
                  (wireframe--eww-preview file t)
                  (wireframe--fallback-html-buffer file))
        (user-error "No preview backend available (xwidget/eww/browser)"))
      (setq wireframe--preview-opened t))
    (message "wireframe: preview updated -> %s" file)))

(defun wireframe-preview-split ()
  "Render current buffer and show live preview in a right split using eww."
  (interactive)
  (setq wireframe--prefer-split-preview t)
  (let ((file (wireframe--write-html wireframe-preview-file)))
    (unless (wireframe--eww-preview file t)
      (user-error "eww is not available in this Emacs build"))
    (message "wireframe: right split preview updated -> %s (note: eww ignores most CSS)" file)))

(defun wireframe-export-html (&optional file)
  "Export current wireframe to FILE.
When FILE is nil, prompt with `wireframe-export-file` default."
  (interactive)
  (let* ((target (or file (read-file-name "Export HTML: " nil wireframe-export-file)))
         (written (wireframe--write-html target)))
    (message "wireframe: exported HTML -> %s" written)))

(defun wireframe-export-jsx (&optional file)
  "Optional bonus export: write very basic JSX wrapper using rendered HTML string."
  (interactive)
  (let* ((target (or file (read-file-name "Export JSX: " nil "wireframe-export.jsx")))
         (html (wireframe-render-html))
         (jsx (format "export default function Wireframe() {\n  return (\n    <div dangerouslySetInnerHTML={{ __html: %S }} />\n  );\n}\n" html)))
    (with-temp-file target
      (insert jsx))
    (message "wireframe: exported JSX -> %s" target)))

(defun wireframe--after-save-hook ()
  "Auto-render preview after save in `wireframe-mode`."
  (when (derived-mode-p 'wireframe-mode)
    (condition-case err
        (if wireframe--prefer-split-preview
            (wireframe-preview-split)
          (wireframe-preview))
      (error (message "wireframe: preview failed: %s" (error-message-string err))))))

;;;; Editing helpers

(defconst wireframe-component-templates
  '(("screen" . "(screen new-screen\n  (section\n    (title \"Title\")\n    (paragraph \"Description\")))")
    ("header" . "(header \"Logo\" \"Menu\")")
    ("section" . "(section\n  (title \"Section\")\n  (paragraph \"Body\"))")
    ("container-vertical" . "(container :direction vertical\n  (paragraph \"Item 1\")\n  (paragraph \"Item 2\"))")
    ("container-horizontal" . "(container :direction horizontal\n  (button \"Primary\")\n  (button \"Secondary\"))")
    ("title" . "(title \"New Title\")")
    ("paragraph" . "(paragraph \"Lorem ipsum\")")
    ("button" . "(button \"Click\")")
    ("image-placeholder" . "(image-placeholder 240 120)")
    ("card-list" . "(card-list 3)"))
  "Templates inserted by `wireframe-add-component`.")

(defun wireframe-add-component (name)
  "Insert a component template by NAME."
  (interactive
   (list (completing-read "Component: " (mapcar #'car wireframe-component-templates) nil t)))
  (let ((tpl (alist-get name wireframe-component-templates nil nil #'string=)))
    (unless tpl
      (user-error "Unknown component: %s" name))
    (end-of-line)
    (newline-and-indent)
    (insert tpl)
    (indent-region (save-excursion (backward-sexp) (point)) (point))))

(defun wireframe-delete-component ()
  "Delete component sexp at point."
  (interactive)
  (save-excursion
    (unless (or (looking-at-p "(") (ignore-errors (backward-up-list) t))
      (user-error "Point is not in a component"))
    (when (not (looking-at-p "("))
      (backward-up-list))
    (kill-sexp 1)
    (just-one-space 0)))

(defun wireframe-clone-component ()
  "Duplicate component sexp at point below itself."
  (interactive)
  (save-excursion
    (backward-up-list)
    (let ((beg (point)))
      (forward-sexp)
      (let ((snippet (buffer-substring-no-properties beg (point))))
        (newline-and-indent)
        (insert snippet)
        (indent-region beg (point))))))

(defun wireframe--move-sexp (dir)
  "Move current component by DIR, where DIR is -1 for up, +1 for down."
  (save-excursion
    (backward-up-list)
    (let ((beg (point)))
      (forward-sexp)
      (let ((end (point)))
        (if (> dir 0)
            (progn
              (skip-chars-forward " \t\n")
              (transpose-sexps 1)
              (goto-char beg)
              (indent-region beg (point-max)))
          (goto-char beg)
          (transpose-sexps -1)
          (indent-region (point-min) end))))))

(defun wireframe-move-component-up ()
  "Move current component up among siblings."
  (interactive)
  (condition-case err
      (wireframe--move-sexp -1)
    (error (user-error "Cannot move up: %s" (error-message-string err)))))

(defun wireframe-move-component-down ()
  "Move current component down among siblings."
  (interactive)
  (condition-case err
      (wireframe--move-sexp 1)
    (error (user-error "Cannot move down: %s" (error-message-string err)))))

(defun wireframe--set-spacing-prop (prop value)
  "Set PROP keyword to VALUE in current list form."
  (save-excursion
    (backward-up-list)
    (let* ((beg (point))
           (end (save-excursion (forward-sexp) (point)))
           (sexp-str (buffer-substring-no-properties beg end))
           (form (read sexp-str))
           (head (car form))
           (args (cdr form))
           (new-args nil)
           (seen nil))
      (while args
        (let ((x (pop args)))
          (if (and (keywordp x) (eq x prop))
              (progn
                (setq seen t)
                (pop args)
                (setq new-args (append new-args (list x value))))
            (setq new-args (append new-args (list x))))))
      (unless seen
        (setq new-args (append new-args (list prop value))))
      (delete-region beg end)
      (insert (pp-to-string (cons head new-args))))))

(defun wireframe-adjust-padding (value)
  "Set :padding VALUE on component at point."
  (interactive "nPadding (px): ")
  (wireframe--set-spacing-prop :padding value)
  (indent-pp-sexp))

(defun wireframe-adjust-margin (value)
  "Set :margin VALUE on component at point."
  (interactive "nMargin (px): ")
  (wireframe--set-spacing-prop :margin value)
  (indent-pp-sexp))

(defun wireframe-adjust-gap (value)
  "Set :gap VALUE on component at point."
  (interactive "nGap (px): ")
  (wireframe--set-spacing-prop :gap value)
  (indent-pp-sexp))

(defun wireframe--read-sexp-at-point ()
  "Return (BEG END FORM) for sexp at point."
  (save-excursion
    (backward-up-list)
    (let* ((beg (point))
           (end (save-excursion (forward-sexp) (point)))
           (form (read (buffer-substring-no-properties beg end))))
      (list beg end form))))

(defun wireframe-wrap-in-container (&optional horizontal)
  "Wrap current component in a container.
If HORIZONTAL is non-nil, use horizontal direction."
  (interactive "P")
  (pcase-let ((`(,beg ,end ,form) (wireframe--read-sexp-at-point)))
    (delete-region beg end)
    (insert (pp-to-string
             `(container :direction ,(if horizontal 'horizontal 'vertical)
                         ,form)))
    (indent-region beg (point))))

(defun wireframe-unwrap-component ()
  "If point is on a container, replace it with its first child."
  (interactive)
  (pcase-let ((`(,beg ,end ,form) (wireframe--read-sexp-at-point)))
    (unless (and (listp form) (eq (car form) 'container))
      (user-error "Current form is not a container"))
    (let* ((args (cdr form))
           (children (seq-drop-while #'keywordp args))
           (children (if (numberp (car children)) (cdr children) children))
           (child (car children)))
      (unless child
        (user-error "Container has no child to unwrap"))
      (delete-region beg end)
      (insert (pp-to-string child))
      (indent-region beg (point)))))

(defun wireframe--bump-spacing (prop delta)
  "Bump PROP by DELTA on component at point."
  (pcase-let ((`(,_beg ,_end ,form) (wireframe--read-sexp-at-point)))
    (let* ((args (cdr form))
           (cur (or (plist-get args prop) 0)))
      (wireframe--set-spacing-prop prop (max 0 (+ cur delta)))
      (indent-pp-sexp)
      (message "wireframe: %s=%d" prop (max 0 (+ cur delta))))))

(defun wireframe-spacing-bump-up ()
  "Increase :padding by 4."
  (interactive)
  (wireframe--bump-spacing :padding 4))

(defun wireframe-spacing-bump-down ()
  "Decrease :padding by 4."
  (interactive)
  (wireframe--bump-spacing :padding -4))

(defun wireframe-promote-component ()
  "Move current component one level up in tree."
  (interactive)
  (save-excursion
    (pcase-let* ((`(,beg ,end ,form) (wireframe--read-sexp-at-point))
                 (text (buffer-substring-no-properties beg end)))
      (delete-region beg end)
      (backward-up-list 2)
      (forward-sexp)
      (newline-and-indent)
      (insert text)
      (indent-region (point-min) (point-max)))))

(defun wireframe-demote-component ()
  "Move current component into previous sibling as its child."
  (interactive)
  (save-excursion
    (pcase-let* ((`(,beg ,end ,_form) (wireframe--read-sexp-at-point))
                 (text (buffer-substring-no-properties beg end)))
      (delete-region beg end)
      (backward-sexp)
      (forward-sexp)
      (newline-and-indent)
      (insert text)
      (indent-region (point-min) (point-max)))))

(defun wireframe-lint-buffer ()
  "Lint current wireframe buffer and report findings."
  (interactive)
  (let ((issues nil))
    (save-excursion
      (goto-char (point-min))
      (condition-case err
          (while t
            (skip-chars-forward " \t\n\r")
            (let ((start (point))
                  (form (read (current-buffer))))
              (when (listp form)
                (setq issues (nconc (wireframe--lint-form form start) issues)))))
        (end-of-file nil)
        (error (push (format "Parse error near %d: %s" (point) (error-message-string err)) issues))))
    (if issues
        (with-current-buffer (get-buffer-create "*wireframe-lint*")
          (erase-buffer)
          (insert "Wireframe lint findings:\n\n")
          (dolist (i (nreverse issues)) (insert "- " i "\n"))
          (display-buffer (current-buffer)))
      (message "wireframe: no lint issues"))))

(defun wireframe--lint-form (form pos)
  "Lint FORM at POS and return a list of findings."
  (let ((issues nil))
  (let ((head (car-safe form))
        (args (cdr-safe form)))
    (unless (memq head wireframe--known-components)
      (push (format "Unknown component `%s` at %d" head pos) issues))
    (while (keywordp (car args))
      (let ((k (pop args)) (_v (pop args)))
        (unless (memq k '(:padding :margin :gap :direction :count :width :height :name
                                   :bg :color :border :radius :font-size :font-weight))
          (push (format "Unknown attribute `%s` at %d" k pos) issues))))
    (dolist (a args)
      (when (listp a)
        (setq issues (nconc (wireframe--lint-form a pos) issues)))))
    issues))

(defun wireframe-command-menu ()
  "Show a command palette for common wireframe actions."
  (interactive)
  (let* ((choices '(("Add component" . wireframe-add-component)
                    ("Clone component" . wireframe-clone-component)
                    ("Delete component" . wireframe-delete-component)
                    ("Wrap in vertical container" . wireframe-wrap-in-container)
                    ("Wrap in horizontal container" . wireframe-wrap-in-horizontal-container)
                    ("Unwrap container" . wireframe-unwrap-component)
                    ("Move up" . wireframe-move-component-up)
                    ("Move down" . wireframe-move-component-down)
                    ("Promote component" . wireframe-promote-component)
                    ("Demote component" . wireframe-demote-component)
                    ("Lint buffer" . wireframe-lint-buffer)
                    ("Preview split" . wireframe-preview-split)
                    ("Export HTML" . wireframe-export-html)))
         (picked (completing-read "Wireframe action: " (mapcar #'car choices) nil t)))
    (call-interactively (alist-get picked choices nil nil #'string=))))

(defun wireframe-wrap-in-horizontal-container ()
  "Wrap current component in horizontal container."
  (interactive)
  (wireframe-wrap-in-container t))

;;;; Major mode

(defvar wireframe-font-lock-keywords
  '(("(\\(screen\\|header\\|section\\|container\\|horizontal\\|vertical\\|title\\|paragraph\\|text\\|button\\|image-placeholder\\|card-list\\)\\_>" 1 font-lock-keyword-face)
    ("\\_<:[a-zA-Z0-9-]+\\_>" . font-lock-builtin-face)
    ("\\_<[0-9]+\\_>" . font-lock-constant-face))
  "Syntax highlighting for `wireframe-mode'.")

(defvar wireframe-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a") #'wireframe-add-component)
    (define-key map (kbd "C-c C-d") #'wireframe-delete-component)
    (define-key map (kbd "M-<up>") #'wireframe-move-component-up)
    (define-key map (kbd "M-<down>") #'wireframe-move-component-down)
    (define-key map (kbd "C-c C-p") #'wireframe-adjust-padding)
    (define-key map (kbd "C-c C-m") #'wireframe-adjust-margin)
    (define-key map (kbd "C-c C-g") #'wireframe-adjust-gap)
    (define-key map (kbd "C-c +") #'wireframe-spacing-bump-up)
    (define-key map (kbd "C-c -") #'wireframe-spacing-bump-down)
    (define-key map (kbd "C-c C-k") #'wireframe-clone-component)
    (define-key map (kbd "C-c C-w") #'wireframe-wrap-in-container)
    (define-key map (kbd "C-c C-u") #'wireframe-unwrap-component)
    (define-key map (kbd "C-c <left>") #'wireframe-promote-component)
    (define-key map (kbd "C-c <right>") #'wireframe-demote-component)
    (define-key map (kbd "C-c C-l") #'wireframe-lint-buffer)
    (define-key map (kbd "C-c w") #'wireframe-command-menu)
    (define-key map (kbd "C-c C-v") #'wireframe-preview)
    (define-key map (kbd "C-c C-s") #'wireframe-preview-split)
    (define-key map (kbd "C-c C-e") #'wireframe-export-html)
    (define-key map (kbd "C-c C-j") #'wireframe-export-jsx)
    map)
  "Keymap for `wireframe-mode'.")

;;;###autoload
(define-derived-mode wireframe-mode emacs-lisp-mode "Wireframe"
  "Major mode for keyboard-first wireframe DSL editing."
  (setq-local font-lock-defaults '(wireframe-font-lock-keywords))
  (add-hook 'after-save-hook #'wireframe--after-save-hook nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.wire\\'" . wireframe-mode))

(provide 'wireframe-mode)

;;; wireframe-mode.el ends here
