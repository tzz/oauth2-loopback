;;; oauth2-loopback.el --- Loopback redirect listener for oauth2.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Teodor Zlatanov

;; Author: Teodor Zlatanov <tzz@lifelogs.com>
;; Maintainer: Teodor Zlatanov <tzz@lifelogs.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (oauth2 "0.19"))
;; Keywords: comm, oauth
;; URL: https://github.com/tzz/oauth2-loopback

;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;;; Commentary:

;; Teaches `oauth2-request-authorization' (used by oauth2.el and therefore
;; by auth-source-xoauth2-plugin / Gnus) to catch the OAuth2 authorization
;; code automatically when the redirect URI is a loopback address such as
;; http://localhost:8999.  Instead of prompting "Enter the code your browser
;; displayed", it opens a tiny HTTP server on that port, waits for Google to
;; redirect the browser there, grabs ?code=..., shows a "you can close this
;; tab" page, and returns the code.  Non-loopback redirect URIs fall back to
;; the original behaviour.
;;
;; It also opens the consent page in a real GUI browser instead of eww
;; (Google rejects eww with a "signin/rejected" page).  By default you are
;; asked once per session which browser to use: the system default is
;; listed first, followed by GUI browsers detected on this machine (macOS
;; apps via `open -Ra`, Linux/BSD executables on PATH or flatpaks), with
;; `oauth2-loopback-preferred-browser' (Chrome) as the default answer.
;; Set `oauth2-loopback-browser' to a name like "Google Chrome Beta" to
;; skip the prompt.  `M-x oauth2-loopback-choose-browser' changes it later.
;;
;; To test from scratch, `M-x oauth2-loopback-reset' wipes the stored
;; tokens, the auth-source cache, open Gnus servers and the browser choice.
;;
;; Usage:
;;   (require 'oauth2-loopback)      ; after oauth2.el is on the load-path
;;   ;; optional: (setq oauth2-loopback-browser "Google Chrome")
;;
;; Your auth-source entry should carry the loopback URI, e.g.
;;   :redirect-uri "http://localhost:8999"
;; and that same URI must be acceptable to the OAuth client (for Google
;; "Desktop app" clients any http://localhost:PORT is allowed; for "Web
;; application" clients register it explicitly).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'browse-url)

;; Defined by oauth2.el versions that carry their own loopback listener
;; (see the patch in this repository); declared so the `let' below is
;; dynamic on an oauth2.el without it.
(defvar oauth2-browse-url-function)

(defgroup oauth2-loopback nil
  "Loopback redirect listener for oauth2.el."
  :group 'oauth2)

(defcustom oauth2-loopback-timeout 300
  "Seconds to wait for the browser to hit the loopback redirect URI."
  :type 'integer)

(defcustom oauth2-loopback-hosts '("localhost" "127.0.0.1" "::1")
  "Redirect-URI hosts treated as loopback (handled by the listener)."
  :type '(repeat string))

(defcustom oauth2-loopback-success-page
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>Emacs OAuth2</title>
<style>body{font-family:system-ui,sans-serif;margin:4em auto;max-width:32em;text-align:center}</style></head>
<body><h1>Authorization complete</h1><p>You can close this tab and return to Emacs.</p></body></html>"
  "HTML returned to the browser after a successful redirect."
  :type 'string)

(defcustom oauth2-loopback-error-page
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>Emacs OAuth2</title></head>
<body><h1>Authorization failed</h1><p>%s</p><p>Return to Emacs for details.</p></body></html>"
  "HTML returned when the provider reports an error.
A `format' template with one %s for the message."
  :type 'string)

(defcustom oauth2-loopback-browser 'ask
  "Which browser opens the OAuth2 consent page.
`ask' prompts (with `completing-read') among the browsers found on this
machine, preferring `oauth2-loopback-preferred-browser'.  A string names
one of those detected browsers directly (e.g. \"Google Chrome\").  A
function is used as `browse-url-browser-function' verbatim."
  :type '(choice (const :tag "Ask each time (remembered for the session)" ask)
                 (string :tag "Browser name")
                 (function :tag "browse-url function")))

(defcustom oauth2-loopback-preferred-browser "Google Chrome"
  "Browser offered as the default answer when `oauth2-loopback-browser' is `ask'.
Must match a name produced by `oauth2-loopback--browser-candidates'."
  :type 'string)

(defcustom oauth2-loopback-remember-browser t
  "When non-nil, the browser answer is kept for the session, so you are asked once.
It is stored in `oauth2-loopback--chosen-browser'."
  :type 'boolean)

(defvar oauth2-loopback--chosen-browser nil
  "Function selected via the browser prompt for this session, or nil.")

(defvar oauth2-loopback--result nil
  "Plist (:code CODE :error ERR :state STATE) set by the listener, or nil.")

;;;; Browser selection

(defconst oauth2-loopback--browser-table
  ;; NAME  macOS-app  Linux/BSD executables  flatpak-id
  '(("Google Chrome"        "Google Chrome"        ("google-chrome" "google-chrome-stable" "chrome") "com.google.Chrome")
    ("Google Chrome Beta"   "Google Chrome Beta"   ("google-chrome-beta")                            nil)
    ("Google Chrome Dev"    "Google Chrome Dev"    ("google-chrome-unstable")                        "com.google.ChromeDev")
    ("Google Chrome Canary" "Google Chrome Canary" ()                                                nil)
    ("Chromium"             "Chromium"             ("chromium" "chromium-browser")                   "org.chromium.Chromium")
    ("Brave Browser"        "Brave Browser"        ("brave-browser" "brave")                         "com.brave.Browser")
    ("Microsoft Edge"       "Microsoft Edge"       ("microsoft-edge" "microsoft-edge-stable")        "com.microsoft.Edge")
    ("Firefox"              "Firefox"              ("firefox" "firefox-esr")                          "org.mozilla.firefox")
    ("Arc"                  "Arc"                  ()                                                nil)
    ("Safari"               "Safari"               ()                                                nil))
  "Known GUI browsers and how to find them on each platform.
Each entry is (NAME MAC-APP LINUX-EXECUTABLES FLATPAK-ID).")

(defun oauth2-loopback--mac-app-p (app)
  "Non-nil if macOS application APP (e.g. \"Google Chrome\") is installed."
  (and (eq system-type 'darwin)
       (executable-find "open")
       (eql 0 (call-process "open" nil nil nil "-Ra" app))))

(defun oauth2-loopback--mac-opener (app)
  "Return a `browse-url' function that opens URLs in macOS application APP."
  (lambda (url &rest _)
    (call-process "open" nil 0 nil "-a" app url)))

(defun oauth2-loopback--exe-opener (exe &rest pre-args)
  "Return a `browse-url' function running EXE with PRE-ARGS and the URL."
  (lambda (url &rest _)
    (let ((process-connection-type nil))
      (apply #'start-process (concat "oauth2-browser-" (file-name-nondirectory exe))
             nil exe (append pre-args (list url))))))

(defun oauth2-loopback--flatpak-p (id)
  "Non-nil if flatpak application ID is installed."
  (and id
       (executable-find "flatpak")
       (eql 0 (call-process "flatpak" nil nil nil "info" id))))

(defun oauth2-loopback--gui-session-p ()
  "Non-nil if there is a graphical session to launch browsers into."
  (or (display-graphic-p)
      (getenv "DISPLAY")
      (getenv "WAYLAND_DISPLAY")))

(defun oauth2-loopback--system-default ()
  "Return the (NAME . FUNCTION) entry for the operating system's default browser.
This is the OS's choice (Launch Services on macOS, xdg on Linux), not
Emacs's `browse-url-browser-function', which may well be eww."
  (cond
   ((eq system-type 'darwin)
    ;; `open URL' with no -a asks Launch Services for the default handler.
    (cons "System default browser (macOS)" #'browse-url-default-macosx-browser))
   ((memq system-type '(windows-nt cygwin))
    (cons "System default browser (Windows)" #'browse-url-default-windows-browser))
   ((and (memq system-type '(gnu/linux berkeley-unix))
         (executable-find "xdg-open")
         (oauth2-loopback--gui-session-p))
    (cons "System default browser (xdg-open)" #'browse-url-xdg-open))
   ((and (memq system-type '(gnu/linux berkeley-unix))
         (executable-find "wslview"))          ; WSL → Windows browser
    (cons "System default browser (Windows via wslview)"
          (oauth2-loopback--exe-opener "wslview")))
   (t (cons "System default browser" #'browse-url-default-browser))))

(defun oauth2-loopback--browser-candidates ()
  "Return an alist (NAME . FUNCTION) of browsers usable on this machine.
The system default browser comes first, then external GUI browsers found
on this machine in the order of `oauth2-loopback--browser-table', then
eww as a last resort."
  (let (cands)
    (pcase-dolist (`(,name ,mac-app ,exes ,flatpak) oauth2-loopback--browser-table)
      (pcase system-type
        ('darwin
         (when (oauth2-loopback--mac-app-p mac-app)
           (push (cons name (oauth2-loopback--mac-opener mac-app)) cands)))
        ((or 'gnu/linux 'berkeley-unix)
         (if-let* ((exe (seq-some #'executable-find exes)))
             (push (cons name (oauth2-loopback--exe-opener exe)) cands)
           (when (oauth2-loopback--flatpak-p flatpak)
             (push (cons (concat name " (flatpak)")
                         (oauth2-loopback--exe-opener "flatpak" "run" flatpak))
                   cands))))))
    (append (list (oauth2-loopback--system-default))
            (nreverse cands)
            (when (fboundp 'eww-browse-url)
              (list (cons "eww (inside Emacs; Google may reject it)" #'eww-browse-url))))))

(defun oauth2-loopback--prompt-browser (cands)
  "Ask the user to pick from CANDS; return the chosen function."
  (let* ((names (mapcar #'car cands))
         (default (cond ((member oauth2-loopback-preferred-browser names)
                         oauth2-loopback-preferred-browser)
                        (t (car names))))
         (choice (completing-read
                  (format "Open OAuth2 consent page with (default %s): " default)
                  names nil t nil nil default)))
    (cdr (assoc choice cands))))

(defun oauth2-loopback--browser-function ()
  "Resolve `oauth2-loopback-browser' to a `browse-url' function."
  (let ((cands (oauth2-loopback--browser-candidates)))
    (cond
     ((functionp oauth2-loopback-browser) oauth2-loopback-browser)
     ((stringp oauth2-loopback-browser)
      (or (cdr (assoc oauth2-loopback-browser cands))
          (progn (message "oauth2-loopback: browser %S not found; asking"
                          oauth2-loopback-browser)
                 (oauth2-loopback--prompt-browser cands))))
     ((and oauth2-loopback-remember-browser oauth2-loopback--chosen-browser)
      oauth2-loopback--chosen-browser)
     (t
      (let ((fn (oauth2-loopback--prompt-browser cands)))
        (when oauth2-loopback-remember-browser
          (setq oauth2-loopback--chosen-browser fn))
        fn)))))

;;;###autoload
(defun oauth2-loopback-choose-browser ()
  "Interactively (re)select the browser used for OAuth2 consent pages."
  (interactive)
  (setq oauth2-loopback--chosen-browser
        (oauth2-loopback--prompt-browser (oauth2-loopback--browser-candidates)))
  (message "oauth2-loopback: browser set for this session"))

;;;; HTTP plumbing

(defun oauth2-loopback--parse-request (request)
  "Return the query parameters of the first line of HTTP REQUEST as an alist."
  (when (string-match "\\`\\(?:GET\\|POST\\) \\([^ \r\n]+\\) HTTP/" request)
    (let* ((target (match-string 1 request))
           (qpos (string-search "?" target)))
      (when qpos
        ;; `url-parse-query-string' returns ((KEY VALUE ...) ...), already unhexified.
        (url-parse-query-string (substring target (1+ qpos)))))))

(defun oauth2-loopback--respond (proc status body)
  "Send an HTTP response with STATUS and HTML BODY on PROC, then close it."
  (let* ((bytes (encode-coding-string body 'utf-8))
         (reason (pcase status (200 "OK") (404 "Not Found") (_ "Bad Request")))
         (head (format (concat "HTTP/1.1 %d %s\r\n"
                               "Content-Type: text/html; charset=utf-8\r\n"
                               "Content-Length: %d\r\n"
                               "Cache-Control: no-store\r\n"
                               "Connection: close\r\n\r\n")
                       status reason (length bytes))))
    (ignore-errors
      (process-send-string proc head)
      (process-send-string proc bytes)
      (process-send-eof proc))
    ;; Give the kernel a moment to flush before tearing the socket down.
    (run-at-time 1 nil (lambda () (ignore-errors (delete-process proc))))))

(defun oauth2-loopback--filter (proc string)
  "Accumulate STRING from PROC; once headers are complete, extract the code."
  (let ((data (concat (or (process-get proc :data) "") string)))
    (if (not (string-match-p "\r\n\r\n\\|\n\n" data))
        (process-put proc :data data)
      (process-put proc :data nil)
      (let* ((params (oauth2-loopback--parse-request data))
             (code  (cadr (assoc "code"  params)))
             (err   (cadr (assoc "error" params)))
             (state (cadr (assoc "state" params))))
        (cond
         (code
          (setq oauth2-loopback--result (list :code code :state state))
          (oauth2-loopback--respond proc 200 oauth2-loopback-success-page))
         (err
          (setq oauth2-loopback--result (list :error err :state state))
          (oauth2-loopback--respond proc 200 (format oauth2-loopback-error-page
                                                     (url-insert-entities-in-string err))))
         (t
          ;; Browsers also ask for /favicon.ico etc.  Ignore politely.
          (oauth2-loopback--respond proc 404 "Not found")))))))

(defun oauth2-loopback--start-servers (port)
  "Listen on loopback PORT over IPv4 and, when possible, IPv6.
Return the list of server processes.  Signal an error if neither binds."
  (let (servers)
    (dolist (spec '(("127.0.0.1" . ipv4) ("::1" . ipv6)))
      (condition-case err
          (push (make-network-process
                 :name "oauth2-loopback"
                 :server t
                 :host (car spec)
                 :family (cdr spec)
                 :service port
                 :coding 'binary
                 :noquery t
                 :filter #'oauth2-loopback--filter)
                servers)
        (error
         (when (eq (cdr spec) 'ipv4)
           (error "Oauth2-loopback: cannot listen on 127.0.0.1:%d: %s"
                  port (error-message-string err))))))
    servers))

(defun oauth2-loopback--wait (port)
  "Block until the listener on PORT receives a code; return it or signal."
  (setq oauth2-loopback--result nil)
  (let ((deadline (+ (float-time) oauth2-loopback-timeout)))
    (while (and (null oauth2-loopback--result) (< (float-time) deadline))
      (message "oauth2-loopback: waiting for browser redirect on localhost:%d (C-g to abort)…" port)
      (accept-process-output nil 0.5)))
  (let ((r oauth2-loopback--result))
    (setq oauth2-loopback--result nil)
    (cond
     ((null r)
      (error "Oauth2-loopback: timed out after %ds waiting on localhost:%d"
             oauth2-loopback-timeout port))
     ((plist-get r :error)
      (error "Oauth2-loopback: provider returned error: %s" (plist-get r :error)))
     (t
      (message "oauth2-loopback: authorization code received")
      (plist-get r :code)))))

;;;; Hook into oauth2.el

(defun oauth2-loopback--redirect-port (args)
  "The port of the loopback URI in ARGS of `oauth2-request-authorization', or nil."
  (cl-loop for a in args
           when (and (stringp a) (string-prefix-p "http://" a))
           do (let* ((u (url-generic-parse-url a))
                     (host (url-host u)))
                (when (member host oauth2-loopback-hosts)
                  (cl-return (url-port u))))))

(defun oauth2-loopback--around (orig &rest args)
  "Around-advice for `oauth2-request-authorization', called with ARGS.
Runs ORIG unchanged (so it builds and opens the exact URL oauth2.el would),
but routes its `browse-url' call to the chosen GUI browser and replaces its
`read-string' prompt with the loopback listener."
  (let* ((port (oauth2-loopback--redirect-port args))
         ;; Pick the browser first, while the minibuffer is still free.
         (browser (oauth2-loopback--browser-function))
         (browse-url-browser-function browser)
         ;; A patched oauth2.el has its own picker; hand it our choice so
         ;; the user is not asked twice.
         (oauth2-browse-url-function browser)
         ;; Newer browse-url consults handlers before the browser function;
         ;; clear them so nothing (e.g. an eww handler) intercepts the URL.
         (browse-url-handlers nil)
         (browse-url-default-handlers nil))
    (if (or (null port) (< port 1024)
            ;; If oauth2.el itself has the loopback listener (see the
            ;; upstream patch shipped with this file), let it do the work and
            ;; only contribute the browser choice.
            (fboundp 'oauth2--loopback-wait-for-code))
        (apply orig args)                ; not loopback (or unbindable) → old behaviour
      (let ((servers (oauth2-loopback--start-servers port)))
        (unwind-protect
            (cl-letf (((symbol-function 'read-string)
                       (lambda (&rest _) (oauth2-loopback--wait port))))
              (apply orig args))
          (mapc (lambda (p) (ignore-errors (delete-process p))) servers))))))

;;;; Resetting state for testing

(defvar oauth2-token-file)              ; oauth2.el

;;;###autoload
(defun oauth2-loopback-reset (&optional keep-plstore)
  "Forget all OAuth2 state so the next connection re-runs the consent flow.
Deletes the oauth2 plstore (unless KEEP-PLSTORE, the prefix arg, is
non-nil), clears the auth-source cache, closes all Gnus servers, and
forgets the remembered browser choice.  Meant for testing this library."
  (interactive "P")
  (let* ((file (expand-file-name
                (if (boundp 'oauth2-token-file)
                    oauth2-token-file
                  (concat user-emacs-directory "oauth2.plstore"))))
         (buf (get-file-buffer file)))
    (unless keep-plstore
      (when buf
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (if (file-exists-p file)
          (progn (delete-file file)
                 (message "oauth2-loopback: deleted %s" file))
        (message "oauth2-loopback: no plstore at %s" file))))
  (when (fboundp 'auth-source-forget-all-cached)
    (auth-source-forget-all-cached))
  (when (fboundp 'gnus-close-all-servers)
    (ignore-errors (gnus-close-all-servers)))
  (setq oauth2-loopback--chosen-browser nil
        oauth2-loopback--result nil)
  (message "oauth2-loopback: state reset; reopen the server (e.g. `g' in *Group*) to reauthorize"))

;;;###autoload
(defun oauth2-loopback-enable ()
  "Install the loopback listener advice on `oauth2-request-authorization'."
  (interactive)
  (advice-add 'oauth2-request-authorization :around #'oauth2-loopback--around))

;;;###autoload
(defun oauth2-loopback-disable ()
  "Remove the loopback listener advice."
  (interactive)
  (advice-remove 'oauth2-request-authorization #'oauth2-loopback--around))

(with-eval-after-load 'oauth2 (oauth2-loopback-enable))
;; If oauth2 is already loaded, the form above ran immediately.

(provide 'oauth2-loopback)
;;; oauth2-loopback.el ends here
