;;; external-dict.el --- Query external dictionary like goldendict, Bob.app etc  -*- lexical-binding: t; -*-

;; Authors: stardiviner <numbchild@gmail.com>
;; Package-Requires: ((emacs "25.1"))
;; Package-Version: 1.0
;; Keywords: wp processes
;; homepage: https://repo.or.cz/external-dict.el.git
;; SPDX-License-Identifier: GPL-2.0-or-later

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Usage:
;;
;; (global-set-key (kbd "C-x d") 'external-dict-dwim)
;; If invoke with [C-u] prefix, then it will raise the main window.

;;; Code:

(declare-function ns-do-applescript "nsfns.m" t)
(require 'url) ; for `url-retrieve-synchronously'
(require 'url-http) ; for `url-http-end-of-headers'
(require 'json)

(defgroup external-dict nil
  "Use external dictionary in Emacs."
  :prefix "external-dict-"
  :group 'dictionary)

(defcustom external-dict-cmd
  (cl-case system-type
    (gnu/linux
     (cond
      ((executable-find "goldendict")
       '(:dict-program "goldendict" :command-p t))))
    (darwin
     (cond
      ((and (file-exists-p "/Applications/Bob.app")
            (not (string-empty-p (shell-command-to-string "pidof Bob"))))
       '(:dict-program "Bob.app" :command-p nil))
      ((and (file-exists-p "/Applications/Easydict.app")
            (not (string-empty-p (shell-command-to-string "pidof Easydict"))))
       '(:dict-program "Easydict.app" :command-p nil))
      ((file-exists-p "/Applications/GoldenDict.app")
       '(:dict-program "GoldenDict.app" :command-p t))
      (t '(:dict-program "Dictionary.app" :command-p t)))))
  "Specify external dictionary command."
  :type 'string
  :group 'external-dict)

(defcustom external-dict-read-cmd
  (cl-case system-type
    (darwin
     (pcase (plist-get external-dict-cmd :dict-program)
       ("Bob.app" "say")
       ("GoldenDict.app" "say")
       ("Dictionary.app" "say")))
    (gnu/linux
     (pcase (plist-get external-dict-cmd :dict-program)
       ("goldendict" nil)
       (_ (cond
           ((executable-find "festival") "festival")
           ((executable-find "espeak") "espeak"))))))
  "Specify external tool command to read the query word.
If the value is nil, let dictionary handle it without invoke the command.
If the value is a command string, invoke the command to read the word."
  :type 'string
  :safe #'stringp
  :group 'external-dict)

(defcustom external-dict-read-query
  (cl-case system-type
    (darwin
     (pcase (plist-get external-dict-cmd :dict-program)
       ("Bob.app" nil)
       ("GoldenDict.app" t)
       ("Dictionary.app" t)))
    (gnu/linux
     (pcase (plist-get external-dict-cmd :dict-program)
       ("goldendict" nil)
       (_ t))))
  "Whether read the query text."
  :type 'boolean
  :safe #'booleanp
  :group 'external-dict)

(defun external-dict--get-text ()
  "Get word or text from region selected, `thing-at-point', or interactive input."
  (cond
   ((region-active-p)
    (let ((text (buffer-substring-no-properties (mark) (point))))
      (deactivate-mark)
      `(:type :text :text ,text)))
   ((and (thing-at-point 'word)
         (not (string-blank-p (substring-no-properties (thing-at-point 'word)))))
    (let ((word (substring-no-properties (thing-at-point 'word))))
      `(:type :word, :text ,word)))
   (t (let ((word (read-string "[external-dict.el] Query word: ")))
        `(:type :word :text ,word)))))

;;;###autoload
(defun external-dict-read-word (word)
  "Auto pronounce the query WORD."
  (interactive)
  (when external-dict-read-query
    (sit-for 1)
    (pcase external-dict-read-cmd
      ("say"
       (shell-command (concat "say " (shell-quote-argument word))))
      ("festival"
       (shell-command (concat "festival --tts " (shell-quote-argument word))))
      ("espeak"
       (shell-command (concat "espeak " (shell-quote-argument word)))))))

;;; [ macOS Dictionary.app ]

;;;###autoload
(defun external-dict-Dictionary.app (word)
  "Query WORD at point or region selected or input with macOS Dictionary.app."
  (interactive
   (list (cond
          ((region-active-p)
           (buffer-substring-no-properties (mark) (point)))
          ((not (string-blank-p (substring-no-properties (thing-at-point 'word))))
           (substring-no-properties (thing-at-point 'word)))
          (t (read-string "[external-dict.el] Query word in macOS Dictionary.app: ")))))
  (deactivate-mark)
  (shell-command (format "open dict://\"%s\"" word))
  (external-dict-read-word word))

;;; [ Goldendict ]

(defun external-dict-goldendict--ensure-running ()
  "Ensure goldendict program is running."
  (unless (string-match "goldendict" (shell-command-to-string "ps -C 'goldendict' | sed -n '2p'"))
    (start-process-shell-command
     "*goldendict*"
     " *goldendict*"
     "goldendict")))

;;;###autoload
(defun external-dict-goldendict (word)
  "Query WORD at point or region selected with goldendict.
If you invoke command with `RAISE-MAIN-WINDOW' prefix \\<universal-argument>,
it will raise external dictionary main window."
  (interactive (list (plist-get (external-dict--get-text) :text)))
  (external-dict-goldendict--ensure-running)
  (let ((goldendict-cmd (cl-case system-type
                          (gnu/linux (executable-find "goldendict"))
                          (darwin (or (executable-find "GoldenDict") (executable-find "goldendict")))
                          (t (plist-get external-dict-cmd :dict-program)))))
    (if current-prefix-arg
        (save-excursion
          (call-process goldendict-cmd nil nil nil))
      (save-excursion
        ;; pass the selection to shell command goldendict.
        ;; use Goldendict API: "Scan Popup"
        (call-process goldendict-cmd nil nil nil word))
      (external-dict-read-word word)
      (deactivate-mark))))

;;; alias for `external-dict-cmd' property `:dict-program' name under macOS.
(defalias 'external-dict-GoldenDict.app 'external-dict-goldendict)

;;; [ Bob.app ]

;;;###autoload
(defun external-dict-Bob.app-translate (text)
  "Translate TEXT in Bob.app."
  (if (version<=
       (ns-do-applescript
        "tell application \"Bob\"
version
end tell")
       "1.5.0")
      (ns-do-applescript
       (format "tell application id \"com.hezongyidev.Bob\"
	launch
	translate \"%s\"
end tell" text))
    (let ((path "translate")
          (action "translateText")
          (text text))
      (ns-do-applescript
       (format "use scripting additions
use framework \"Foundation\"
on toJson(recordValue)
(((current application's NSString)'s alloc)'s initWithData:((current application's NSJSONSerialization)'s dataWithJSONObject:recordValue options:1 |error|:(missing value)) encoding:4) as string
end toJson

set theRecord to {|path|: \"%s\", body: {action: \"%s\", |text|: \"%s\", windowLocation: \"center\", inputBoxState: \"alwaysUnfold\"}}
set theParameter to toJson(theRecord)
tell application id \"com.hezongyidev.Bob\" to request theParameter
"
               path action text)))))

(defun external-dict-Bob.app-dictionary (word)
  "Query WORD in macOS Bob.app."
  (ns-do-applescript
   (format
    "tell application \"Bob\"
 launch
 translate \"%s\"
 end tell" word))
  (external-dict-read-word word))

(defun external-dict-Bob.app ()
  "Translate text with Bob.app on macOS."
  (interactive)
  (let* ((return-plist (external-dict--get-text))
         (type (plist-get return-plist :type))
         (text (plist-get return-plist :text)))
    (cond
     ((eq type :word)
      (external-dict-Bob.app-dictionary text))
     ((eq type :text)
      (external-dict-Bob.app-translate text)))))

;;; [ Easydict.app ]

(defun external-dict-Easydict.app--http-api (text &optional target-language service-type apple-dictionary-names &rest args)
  "Translate TEXT in Easydict local HTTP server translate API.

- TARGET-LANGUAGE: specify translated text target language.
- SERVICE-TYPE: specify service type available in Easydict.
- ARGS: extra arguments like appleDictionaryNames vector in HTTP API."
  (if-let ((ping-connection (ignore-errors (open-network-stream "ping-localhost" "*ping localhost*" "localhost" 8080))))
      (let* ((url-request-method "POST")
             (url-request-extra-headers '(("Content-Type" . "application/json")))
             ;; POST JSON data `url-request-data'
             (service-type (or service-type
                               (completing-read "[Easydict] serviceType: " '("AppleDictionary" "Apple" "CustomOpenAI"))))
             (target-language (or target-language
                                  (completing-read "[Easydict] targetLanguage: " '("zh-Hans" "en"))))
             (apple-dictionary-names (when (string-equal service-type "AppleDictionary")
                                       (or apple-dictionary-names
                                           (completing-read-multiple "[Easydict] multiple appleDictionaryNames (separated by ,) : "
                                                                     ;; TODO: auto read a list of dictionaries in ~/Library/Dictionaries/
                                                                     '("简明英汉字典" "牛津高阶英汉双解词典" "现代汉语规范词典" "汉语成语词典" "现代汉语同义词典" "大辞海"
                                                                       "Oxford Dictionary of English" "New Oxford American Dictionary" "Oxford Thesaurus of English"
                                                                       "Oxford American Writer’s Thesaurus")))))
             (url-request-data (encode-coding-string (json-encode
                                                      `(,(cons 'text text)
                                                        ,(cons 'targetLanguage target-language)
                                                        ,(cons 'serviceType service-type)
                                                        ,@(when apple-dictionary-names
                                                            (list (cons 'appleDictionaryNames apple-dictionary-names)))))
                                                     'utf-8)))
        (with-current-buffer (url-retrieve-synchronously
                              (let ((host "localhost")
                                    (port 8080)
                                    (api (if (member service-type '("CustomOpenAI" "Ollama"))
                                             "streamTranslate"
                                           "translate")))
                                (format "http://%s:%s/%s" host port api)))
          (let* ((result-alist (json-read-from-string
                                (buffer-substring-no-properties (1+ url-http-end-of-headers) (point-max))))
                 (translated-text (decode-coding-string (alist-get 'translatedText result-alist) 'utf-8)))
            (delete-process ping-connection)
            (message translated-text))))
    (user-error "[external-dict] Easydict local HTTP server is not available. Please enable it in settings")))

(defun external-dict-Easydict.app--http-api-translate-service-apple-dictionary (text)
  "Translate TEXT in Easydict in translate API with service Apple Dictionary."
  (external-dict-Easydict.app--http-api text nil "AppleDictionary"))

(defun external-dict-Easydict.app--http-api-translate-service-apple (text)
  "Translate TEXT in Easydict in translate API with service Apple."
  (external-dict-Easydict.app--http-api text nil "Apple"))

(defun external-dict-Easydict.app--http-api-translate-service-custom-openai (text)
  "Translate TEXT in Easydict in translate API with service CustomOpenAI."
  (external-dict-Easydict.app--http-api text nil "CustomOpenAI"))

;;; TEST:
;; (external-dict-Easydict.app--http-api "good ending")
;; (external-dict-Easydict.app--http-api "世界")
;; (external-dict-Easydict.app--http-api-translate-service-apple-dictionary "world")

(defun external-dict-Easydict.app--macos-url-call-query (word)
  "Query WORD in Easydict.app on macOS system through URL scheme."
  (make-process
   :name "external-dict Easydict.app"
   :command (list "open" (format "easydict://query?text=%s" (url-encode-url word)))))

;;;###autoload
(defun external-dict-Easydict.app ()
  "Translate text with Easydict.app on macOS.
Easydict.app URL scheme easydict://query?text=good%20girl
You can open the URL scheme with shell command:
$ open \"easydict://query?text=good%20girl\""
  (interactive)
  (let* ((return-plist (external-dict--get-text))
         (type (plist-get return-plist :type))
         (text (plist-get return-plist :text)))
    (cond
     ((eq type :word)
      (external-dict-Easydict.app--macos-url-call-query text)
      ;; (external-dict-Easydict.app--http-api-translate-service-apple-dictionary text)
      (external-dict-read-word text))
     ((eq type :text)
      ;; HTTP API
      (if-let ((ping-connection (ignore-errors (open-network-stream "ping-localhost" "*ping localhost*" "localhost" 8080))))
          (progn
            (external-dict-Easydict.app--http-api text)
            (delete-process ping-connection))
        ;; URL scheme
        (external-dict-Easydict.app--macos-url-call-query text))))))

;;;###autoload
(defun external-dict-dwim ()
  "Query current word at point or region selected with external dictionary."
  (interactive)
  (let ((dict-program (plist-get external-dict-cmd :dict-program)))
    (call-interactively (intern (format "external-dict-%s" dict-program)))))



(provide 'external-dict)

;;; external-dict.el ends here
