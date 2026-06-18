;;; betterdatadog.el --- A better Datadog client for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Endi Sukaj <endi.sukaj@yahooinc.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, datadog, monitoring
;; URL: https://github.com/esukaj/betterdatadog

;;; Commentary:

;; betterdatadog is an Emacs interface to Datadog.
;;
;; The first feature is the ability to fetch a Datadog dashboard via the
;; Datadog HTTP API and render its structure inside an Emacs buffer:
;; the dashboard title, description, and every widget (recursing into
;; group widgets) together with the metric queries that power it.
;;
;; Setup:
;;
;;   (require 'betterdatadog)
;;   (setq betterdatadog-site "datadoghq.com")        ;; or datadoghq.eu, etc.
;;   (setq betterdatadog-api-key "...")               ;; optional, see below
;;   (setq betterdatadog-app-key "...")
;;
;; Rather than setting the keys directly you can leave them nil and store
;; them via `auth-source'.  Add a line to ~/.authinfo.gpg like:
;;
;;   machine api.datadoghq.com login DD-API-KEY password <your-api-key>
;;   machine api.datadoghq.com login DD-APPLICATION-KEY password <your-app-key>
;;
;; Usage:
;;
;;   M-x betterdatadog-show-dashboard RET <dashboard-id> RET

;;; Code:

(require 'url)
(require 'json)
(require 'auth-source)
(require 'subr-x)
(require 'cl-lib)

(defgroup betterdatadog nil
  "A better Datadog client for Emacs."
  :group 'tools
  :prefix "betterdatadog-")

(defcustom betterdatadog-site "datadoghq.com"
  "The Datadog site (region) to talk to.
Common values: \"datadoghq.com\", \"us3.datadoghq.com\",
\"us5.datadoghq.com\", \"datadoghq.eu\", \"ddog-gov.com\"."
  :type 'string
  :group 'betterdatadog)

(defcustom betterdatadog-api-key nil
  "Datadog API key.
If nil, `betterdatadog' looks the key up via `auth-source' using the
host `api.SITE' and login \"DD-API-KEY\"."
  :type '(choice (const :tag "Use auth-source" nil) string)
  :group 'betterdatadog)

(defcustom betterdatadog-app-key nil
  "Datadog application key.
If nil, `betterdatadog' looks the key up via `auth-source' using the
host `api.SITE' and login \"DD-APPLICATION-KEY\"."
  :type '(choice (const :tag "Use auth-source" nil) string)
  :group 'betterdatadog)

(defcustom betterdatadog-buffer-name "*Datadog Dashboard*"
  "Name of the buffer used to display a dashboard."
  :type 'string
  :group 'betterdatadog)

(defcustom betterdatadog-show-graphs t
  "When non-nil, fetch each query's data and draw a sparkline under it.
This issues one synchronous Datadog query per metric query in the
dashboard, so rendering is slower than the structure-only view.  Toggle
it per-buffer with \\<betterdatadog-mode-map>\\[betterdatadog-toggle-graphs]."
  :type 'boolean
  :group 'betterdatadog)

(defcustom betterdatadog-show-queries t
  "When non-nil, show the metric query strings under each widget.
Set to nil (or toggle per-buffer with
\\<betterdatadog-mode-map>\\[betterdatadog-toggle-queries]) for a clean,
graph-only view."
  :type 'boolean
  :group 'betterdatadog)

(defcustom betterdatadog-graph-window-seconds 3600
  "Length of the time window, in seconds, fetched for each sparkline.
Defaults to the last hour."
  :type 'integer
  :group 'betterdatadog)

(defcustom betterdatadog-sparkline-width 72
  "Maximum number of columns in a rendered graph."
  :type 'integer
  :group 'betterdatadog)

(defcustom betterdatadog-graph-height 6
  "Number of text rows used to draw each graph.
A height of 1 yields a compact single-row sparkline; taller values give
more vertical resolution (8 levels per row)."
  :type 'integer
  :group 'betterdatadog)

(defcustom betterdatadog-fetch-timeout 30
  "Seconds to wait for the parallel prefetch of graph data to complete.
Queries that have not responded by then are fetched synchronously, on
demand, as the dashboard renders."
  :type 'number
  :group 'betterdatadog)

(defcustom betterdatadog-history-file
  (locate-user-emacs-file "betterdatadog-history.el")
  "File where successfully fetched dashboard ids are remembered.
Each id that is fetched without error is stored here, together with the
dashboard title, so `betterdatadog-show-dashboard' can offer it for
completion next time instead of requiring you to paste the id again.
Set to nil to disable persistence (ids are then remembered only for the
current Emacs session)."
  :type '(choice (const :tag "Do not persist" nil) file)
  :group 'betterdatadog)

;;;; Faces

(defface betterdatadog-title-face
  '((t :inherit font-lock-function-name-face :weight bold :height 1.3))
  "Face for the dashboard title."
  :group 'betterdatadog)

(defface betterdatadog-widget-title-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a widget title."
  :group 'betterdatadog)

(defface betterdatadog-widget-type-face
  '((t :inherit font-lock-type-face))
  "Face for a widget type."
  :group 'betterdatadog)

(defface betterdatadog-query-face
  '((t :inherit font-lock-string-face))
  "Face for a metric query."
  :group 'betterdatadog)

(defface betterdatadog-meta-face
  '((t :inherit shadow))
  "Face for secondary metadata."
  :group 'betterdatadog)

(defface betterdatadog-graph-face
  '((t :inherit font-lock-constant-face))
  "Face for the sparkline glyphs."
  :group 'betterdatadog)

;;;; Authentication / configuration helpers

(defun betterdatadog--api-host ()
  "Return the API host for the configured site."
  (concat "api." betterdatadog-site))

(defun betterdatadog--secret (explicit login)
  "Return EXPLICIT if non-nil, else look up LOGIN via `auth-source'."
  (or explicit
      (let ((found (car (auth-source-search :host (betterdatadog--api-host)
                                            :user login
                                            :require '(:secret)
                                            :max 1))))
        (when found
          (let ((secret (plist-get found :secret)))
            (if (functionp secret) (funcall secret) secret))))))

(defun betterdatadog--api-key ()
  "Return the resolved Datadog API key or signal an error."
  (or (betterdatadog--secret betterdatadog-api-key "DD-API-KEY")
      (user-error "No Datadog API key: set `betterdatadog-api-key' or add it to auth-source")))

(defun betterdatadog--app-key ()
  "Return the resolved Datadog application key or signal an error."
  (or (betterdatadog--secret betterdatadog-app-key "DD-APPLICATION-KEY")
      (user-error "No Datadog app key: set `betterdatadog-app-key' or add it to auth-source")))

;;;; HTTP

(defun betterdatadog--get (path)
  "Perform a GET request against the Datadog API at PATH.
PATH should begin with a slash, e.g. \"/api/v1/dashboard/abc-123\".
Return the parsed JSON body as an alist.  Signal a `user-error' on a
non-2xx response or a transport failure."
  (let* ((url (concat "https://" (betterdatadog--api-host) path))
         (url-request-method "GET")
         (url-request-extra-headers
          `(("DD-API-KEY" . ,(betterdatadog--api-key))
            ("DD-APPLICATION-KEY" . ,(betterdatadog--app-key))
            ("Accept" . "application/json")))
         (buffer (url-retrieve-synchronously url t t 30)))
    (unless buffer
      (user-error "betterdatadog: request to %s failed (no response)" url))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (let ((status (if (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                            (string-to-number (match-string 1))
                          0)))
            ;; Skip past the headers to the body.
            (goto-char (point-min))
            (unless (re-search-forward "\n\n\\|\r\n\r\n" nil t)
              (user-error "betterdatadog: malformed HTTP response from %s" url))
            (let* ((body (decode-coding-string
                          (buffer-substring-no-properties (point) (point-max))
                          'utf-8))
                   (json-object-type 'alist)
                   (json-array-type 'list)
                   (json-key-type 'symbol)
                   (parsed (when (> (length (string-trim body)) 0)
                             (ignore-errors (json-read-from-string body)))))
              (unless (and (>= status 200) (< status 300))
                (user-error "betterdatadog: HTTP %s from %s%s"
                            status url
                            (let ((errs (and (listp parsed) (alist-get 'errors parsed))))
                              (if errs (format " — %s" (string-join (mapcar #'format-message
                                                                            (if (listp errs) errs (list errs)))
                                                                    "; "))
                                ""))))
              parsed)))
      (kill-buffer buffer))))

;;;; Querying & sparklines

(defvar betterdatadog--template-vars nil
  "Alist of (NAME . REPLACEMENT) for the current dashboard's template variables.
Set while rendering and consulted by `betterdatadog--resolve-query'.")
(make-variable-buffer-local 'betterdatadog--template-vars)

(defvar betterdatadog--series-cache nil
  "Per-render hash of resolved-query string -> series list.
Populated up front in parallel by `betterdatadog--prefetch' and read by
`betterdatadog--query-series' so each distinct query is fetched once.")
(make-variable-buffer-local 'betterdatadog--series-cache)

(defconst betterdatadog--spark-levels "▁▂▃▄▅▆▇█"
  "Block-glyph ramp, lowest to highest, used to draw sparklines.")

(defun betterdatadog--build-template-vars (dashboard)
  "Return an alist of (NAME . REPLACEMENT) from DASHBOARD's template variables.
A variable with a prefix expands to PREFIX:VALUE; without one, to VALUE.
A missing or empty default becomes \"*\" (i.e. match everything).  The
alist is sorted by descending name length so longer names are
substituted before any that are a prefix of them."
  (let ((vars (alist-get 'template_variables dashboard))
        (map '()))
    (dolist (v vars)
      (let* ((name (alist-get 'name v))
             (prefix (alist-get 'prefix v))
             (default (alist-get 'default v))
             (val (if (and (stringp default) (not (string-empty-p default)))
                      default
                    "*"))
             (replacement
              (if (and (stringp prefix) (not (string-empty-p prefix)))
                  (format "%s:%s" prefix val)
                val)))
        (when (and (stringp name) (not (string-empty-p name)))
          ;; Datadog dashboard JSON may use either "$var" (which expands to
          ;; the dashboard's prefixed form, e.g. "service:api") or
          ;; "$var.value" inside an already-prefixed query like
          ;; "service:$service.value".  Handle both before the generic
          ;; unresolved-variable fallback eats the dotted reference.
          (push (cons (concat name ".value") val) map)
          (push (cons name replacement) map))))
    (sort map (lambda (a b) (> (length (car a)) (length (car b)))))))

(defun betterdatadog--resolve-query (query)
  "Substitute template variables in QUERY using `betterdatadog--template-vars'.
Any variable reference left unresolved is replaced with \"*\"."
  (let ((q query))
    (dolist (pair betterdatadog--template-vars)
      (setq q (replace-regexp-in-string
               (regexp-quote (concat "$" (car pair)))
               (cdr pair) q t t)))
    (replace-regexp-in-string "\\$[A-Za-z0-9_.-]+" "*" q t t)))

(defconst betterdatadog--duration-units
  '(("s" . 1) ("m" . 60) ("h" . 3600) ("d" . 86400) ("w" . 604800))
  "Suffix-to-seconds map for duration shorthand like \"30m\" or \"4h\".")

(defun betterdatadog--parse-duration (s)
  "Parse duration string S like \"90s\", \"30m\", \"4h\", \"1d\", \"1w\".
A bare number is treated as seconds.  Return the number of seconds, or
signal a `user-error' when S cannot be parsed."
  (let ((s (string-trim s)))
    (if (string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\s-*\\([a-zA-Z]?\\)\\'" s)
        (let* ((n (string-to-number (match-string 1 s)))
               (unit (downcase (match-string 2 s)))
               (mult (if (string-empty-p unit)
                         1
                       (or (cdr (assoc unit betterdatadog--duration-units))
                           (user-error "Unknown duration unit %S (use s/m/h/d/w)"
                                       unit)))))
          (truncate (* n mult)))
      (user-error "Invalid duration: %S (try 30m, 1h, 4h, 1d)" s))))

(defun betterdatadog--format-duration (secs)
  "Render SECS as a compact duration string (e.g. 3600 -> \"1h\")."
  (cond ((<= secs 0) "0s")
        ((zerop (% secs 604800)) (format "%dw" (/ secs 604800)))
        ((zerop (% secs 86400)) (format "%dd" (/ secs 86400)))
        ((zerop (% secs 3600)) (format "%dh" (/ secs 3600)))
        ((zerop (% secs 60)) (format "%dm" (/ secs 60)))
        (t (format "%ds" secs))))

(defun betterdatadog--query-path (query)
  "Return the API path that fetches resolved QUERY over the current window."
  (let* ((to (truncate (float-time)))
         (from (- to betterdatadog-graph-window-seconds)))
    (format "/api/v1/query?from=%d&to=%d&query=%s"
            from to (url-hexify-string query))))

(defun betterdatadog--post-json (path data)
  "POST DATA as JSON to PATH and return the parsed JSON response."
  (let* ((url (concat "https://" (betterdatadog--api-host) path))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("DD-API-KEY" . ,(betterdatadog--api-key))
            ("DD-APPLICATION-KEY" . ,(betterdatadog--app-key))
            ("Accept" . "application/json")
            ("Content-Type" . "application/json")))
         (url-request-data (json-encode data))
         (buffer (url-retrieve-synchronously url t t 30)))
    (unless buffer
      (user-error "betterdatadog: request to %s failed (no response)" url))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (let ((status (if (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                            (string-to-number (match-string 1))
                          0)))
            (goto-char (point-min))
            (unless (re-search-forward "\n\n\\|\r\n\r\n" nil t)
              (user-error "betterdatadog: malformed HTTP response from %s" url))
            (let* ((body (decode-coding-string
                          (buffer-substring-no-properties (point) (point-max))
                          'utf-8))
                   (json-object-type 'alist)
                   (json-array-type 'list)
                   (json-key-type 'symbol)
                   (parsed (when (> (length (string-trim body)) 0)
                             (ignore-errors (json-read-from-string body)))))
              (unless (and (>= status 200) (< status 300))
                (user-error "betterdatadog: HTTP %s from %s%s"
                            status url
                            (let ((errs (and (listp parsed) (alist-get 'errors parsed))))
                              (if errs (format " — %s"
                                               (string-join
                                                (mapcar #'format-message
                                                        (if (listp errs) errs (list errs)))
                                                "; "))
                                ""))))
              parsed)))
      (kill-buffer buffer))))

(defun betterdatadog--query-spec (query)
  "Return an internal query spec from a dashboard QUERY alist."
  (let ((q (or (alist-get 'query query)
               (alist-get 'q query)
               (alist-get 'query (alist-get 'search query))))
        (ds (alist-get 'data_source query)))
    (when (and q (stringp q))
      (if (and ds (not (member ds '("metrics" "metric"))))
          (list :data-source ds
                :query q
                :compute (alist-get 'compute query)
                :group-by (alist-get 'group_by query))
        q))))

(defun betterdatadog--spec-query (spec)
  "Return the human-readable query string in SPEC."
  (if (stringp spec) spec (plist-get spec :query)))

(defun betterdatadog--resolve-spec (spec)
  "Resolve template variables in SPEC."
  (if (stringp spec)
      (betterdatadog--resolve-query spec)
    (let ((copy (copy-sequence spec)))
      (plist-put copy :query (betterdatadog--resolve-query (plist-get copy :query)))
      copy)))

(defun betterdatadog--query-cache-key (spec)
  "Return the cache key for resolved SPEC."
  (if (stringp spec) spec (prin1-to-string spec)))

(defun betterdatadog--fetch-series (query)
  "Synchronously fetch the series for resolved QUERY (no cache)."
  (alist-get 'series (betterdatadog--get (betterdatadog--query-path query))))

(defun betterdatadog--analytics-interval ()
  "Return a Datadog analytics interval string for the current graph window."
  (format "%ds" (max 60 (truncate (/ betterdatadog-graph-window-seconds 60)))))

(defun betterdatadog--analytics-compute (compute &optional scalar)
  "Return a logs/spans analytics compute object from dashboard COMPUTE.
When SCALAR is non-nil, omit timeseries-only fields so Datadog returns a
single aggregate value."
  (let ((aggregation (or (alist-get 'aggregation compute) "count"))
        (metric (alist-get 'metric compute)))
    (append `((aggregation . ,aggregation))
            (unless scalar
              `((interval . ,(betterdatadog--analytics-interval))
                (type . "timeseries")))
            (when metric `((metric . ,metric))))))

(defun betterdatadog--parse-iso-ms (s)
  "Parse ISO timestamp S and return milliseconds since the epoch."
  (* 1000.0 (float-time (date-to-time s))))

(defun betterdatadog--json-array (list)
  "Return LIST as a JSON array value."
  (and list (vconcat list)))

(defun betterdatadog--analytics-group-by (group-by)
  "Return GROUP-BY adjusted for the analytics aggregate API."
  (betterdatadog--json-array
   (mapcar (lambda (g)
             ;; Dashboard sort objects can use UI-only fields that the public
             ;; analytics aggregate API rejects for timeseries queries.  The
             ;; API still returns the limited buckets without an explicit sort.
             (assq-delete-all 'sort (copy-sequence g)))
           group-by)))

(defun betterdatadog--analytics-request (spec &optional scalar window-seconds)
  "Return (PATH . BODY) for resolved logs/spans analytics SPEC.
When SCALAR is non-nil, request a single aggregate over WINDOW-SECONDS."
  (let* ((ds (plist-get spec :data-source))
         (path (pcase ds
                 ("logs" "/api/v2/logs/analytics/aggregate")
                 ("spans" "/api/v2/spans/analytics/aggregate")
                 (_ (user-error "unsupported data_source %s" ds))))
         (attrs `((filter . ((query . ,(plist-get spec :query))
                             (from . ,(format "now-%ds"
                                             (or window-seconds
                                                 betterdatadog-graph-window-seconds)))
                             (to . "now")))
                  (compute . ,(vector (betterdatadog--analytics-compute
                                        (plist-get spec :compute) scalar)))))
         (group-by (betterdatadog--analytics-group-by (plist-get spec :group-by)))
         (body (if (equal ds "spans")
                   `((data . ((type . "aggregate_request")
                              (attributes . ,(append attrs (when group-by `((group_by . ,group-by))))))))
                 (append attrs (when group-by `((group_by . ,group-by)))))))
    (cons path body)))

(defun betterdatadog--analytics-scalar-from-response (parsed)
  "Extract the first scalar compute value from an analytics response PARSED."
  (let* ((data (alist-get 'data parsed))
         (buckets (alist-get 'buckets (if (and (listp data) (alist-get 'attributes data))
                                          (alist-get 'attributes data)
                                        data)))
         (computes (alist-get 'computes (car buckets)))
         (c0 (alist-get 'c0 computes)))
    (cond
     ((numberp c0) c0)
     ((and (listp c0) (listp (car c0)))
      (betterdatadog--last-number (mapcar (lambda (p) (alist-get 'value p)) c0)))
     (t nil))))

(defun betterdatadog--analytics-series-from-response (parsed)
  "Extract betterdatadog series from an analytics aggregate response PARSED."
  (let* ((data (alist-get 'data parsed))
         (buckets (alist-get 'buckets (if (and (listp data) (alist-get 'attributes data))
                                          (alist-get 'attributes data)
                                        data))))
    (delq nil
          (mapcar
           (lambda (bucket)
             (let* ((computes (alist-get 'computes bucket))
                    (c0 (alist-get 'c0 computes))
                    (points (cond
                             ((and (listp c0) (listp (car c0)))
                              (mapcar (lambda (p)
                                        (list (betterdatadog--parse-iso-ms
                                               (alist-get 'time p))
                                              (alist-get 'value p)))
                                      c0))
                             ((numberp c0)
                              (list (list (* 1000.0 (float-time)) c0)))
                             (t nil))))
               (when points `((pointlist . ,points)))))
           buckets))))

(defun betterdatadog--fetch-analytics-series (spec)
  "Fetch logs/spans analytics time series for resolved SPEC."
  (let* ((req (betterdatadog--analytics-request spec))
         (parsed (betterdatadog--post-json (car req) (cdr req))))
    (betterdatadog--analytics-series-from-response parsed)))

(defun betterdatadog--fetch-series-for-spec (spec)
  "Synchronously fetch series for resolved SPEC (no cache)."
  (if (stringp spec)
      (betterdatadog--fetch-series spec)
    (betterdatadog--fetch-analytics-series spec)))

(defun betterdatadog--fetch-scalar-for-spec (spec window-seconds)
  "Synchronously fetch a scalar value for resolved SPEC over WINDOW-SECONDS."
  (if (stringp spec)
      (betterdatadog--series-last-number (betterdatadog--fetch-series spec))
    (let* ((req (betterdatadog--analytics-request spec t window-seconds))
           (parsed (betterdatadog--post-json (car req) (cdr req))))
      (betterdatadog--analytics-scalar-from-response parsed))))

(defun betterdatadog--query-scalar (spec window-seconds)
  "Return scalar value for SPEC over WINDOW-SECONDS, using the cache."
  (let* ((resolved (betterdatadog--resolve-spec spec))
         (key (format "scalar:%s:%s"
                      window-seconds (betterdatadog--query-cache-key resolved))))
    (if betterdatadog--series-cache
        (let ((v (gethash key betterdatadog--series-cache 'miss)))
          (if (eq v 'miss)
              (let ((value (betterdatadog--fetch-scalar-for-spec
                            resolved window-seconds)))
                (puthash key value betterdatadog--series-cache)
                value)
            v))
      (betterdatadog--fetch-scalar-for-spec resolved window-seconds))))

(defun betterdatadog--query-series (spec)
  "Return the series for resolved SPEC (each with a `pointlist'), or nil.
Reads from `betterdatadog--series-cache' when active, falling back to a
synchronous fetch on a cache miss (e.g. a request that timed out during
prefetch).  A present-but-empty result is cached and honoured."
  (let* ((resolved (betterdatadog--resolve-spec spec))
         (key (betterdatadog--query-cache-key resolved)))
    (if betterdatadog--series-cache
        (let ((v (gethash key betterdatadog--series-cache 'miss)))
          (if (eq v 'miss)
              (let ((series (betterdatadog--fetch-series-for-spec resolved)))
                (puthash key series betterdatadog--series-cache)
                series)
            v))
      (betterdatadog--fetch-series-for-spec resolved))))

(defun betterdatadog--collect-queries (widgets)
  "Return the de-duplicated list of resolved metric queries used by WIDGETS.
Recurses into group widgets and skips notes.  Drives parallel prefetch."
  (let ((seen (make-hash-table :test 'equal))
        (out '()))
    (cl-labels
        ((add (spec)
           (when spec
             (let* ((r (betterdatadog--resolve-spec spec))
                    (key (betterdatadog--query-cache-key r)))
               (unless (gethash key seen)
                 (puthash key t seen)
                 (push r out)))))
         (collect-req (req)
           (add (alist-get 'q req))
           (dolist (query (alist-get 'queries req))
             (add (betterdatadog--query-spec query))))
         (walk (ws)
           (dolist (w ws)
             (let* ((def (alist-get 'definition w))
                    (type (alist-get 'type def)))
               (cond
                ((equal type "group") (walk (alist-get 'widgets def)))
                ((member type '("note" "query_value")) nil)
                (t (let ((reqs (alist-get 'requests def)))
                     (when (listp reqs)
                       (dolist (req reqs) (collect-req req))))))))))
      (walk widgets))
    (nreverse out)))

(defun betterdatadog--prefetch (queries)
  "Fetch resolved QUERIES in parallel into `betterdatadog--series-cache'.
Fires every request asynchronously, then pumps the event loop until all
responses arrive or `betterdatadog-fetch-timeout' elapses.  Queries still
missing afterward are fetched synchronously on demand at render time."
  (when betterdatadog--series-cache
    ;; Only fetch queries not already cached from an earlier render.
    (setq queries
          (cl-remove-if-not
           (lambda (q) (eq 'miss (gethash (betterdatadog--query-cache-key q)
                                          betterdatadog--series-cache 'miss)))
           queries)))
  (when (and queries betterdatadog--series-cache)
    (message "betterdatadog: fetching graph data (%d queries)..."
             (length queries))
    (let* ((to (truncate (float-time)))
           (from (- to betterdatadog-graph-window-seconds))
           (cache betterdatadog--series-cache)
           (host (betterdatadog--api-host))
           (api (betterdatadog--api-key))
           (app (betterdatadog--app-key))
           (remaining (vector (length queries))))
      (dolist (spec queries)
        (let* ((key (betterdatadog--query-cache-key spec))
               (url-request-extra-headers
                `(("DD-API-KEY" . ,api)
                  ("DD-APPLICATION-KEY" . ,app)
                  ("Accept" . "application/json")))
               (url-request-method "GET")
               (url-request-data nil)
               url parser)
          (if (stringp spec)
              (setq url (format "https://%s/api/v1/query?from=%d&to=%d&query=%s"
                                host from to (url-hexify-string spec))
                    parser (lambda (parsed) (alist-get 'series parsed)))
            (let ((req (betterdatadog--analytics-request spec)))
              (setq url (concat "https://" host (car req))
                    url-request-method "POST"
                    url-request-extra-headers
                    (append url-request-extra-headers
                            '(("Content-Type" . "application/json")))
                    url-request-data (json-encode (cdr req))
                    parser #'betterdatadog--analytics-series-from-response)))
          (url-retrieve
           url
           (lambda (status cache-key parse-fn)
             (unwind-protect
                 (unless (plist-get status :error)
                   (goto-char (point-min))
                   (when (re-search-forward "\n\n\|\r\n\r\n" nil t)
                     (let* ((json-object-type 'alist)
                            (json-array-type 'list)
                            (json-key-type 'symbol)
                            (body (decode-coding-string
                                   (buffer-substring-no-properties
                                    (point) (point-max))
                                   'utf-8))
                            (parsed (ignore-errors (json-read-from-string body))))
                       (when parsed
                         (puthash cache-key (funcall parse-fn parsed) cache)))))
               (aset remaining 0 (1- (aref remaining 0)))
               (kill-buffer (current-buffer))))
           (list key parser) t t)))
      (let ((deadline (+ (float-time) betterdatadog-fetch-timeout)))
        (while (and (> (aref remaining 0) 0) (< (float-time) deadline))
          (accept-process-output nil 0.05))))))

(defun betterdatadog--downsample (values width)
  "Reduce VALUES to at most WIDTH buckets, averaging the numbers in each.
Buckets with no numeric values become nil (rendered as a gap)."
  (let ((len (length values)))
    (if (or (<= len width) (<= width 0))
        values
      (let ((vec (vconcat values))
            (out '())
            (i 0))
        (while (< i width)
          (let* ((start (floor (/ (* i len) (float width))))
                 (end (max (1+ start)
                           (floor (/ (* (1+ i) len) (float width)))))
                 (sum 0) (cnt 0) (j start))
            (while (and (< j end) (< j len))
              (let ((v (aref vec j)))
                (when (numberp v) (setq sum (+ sum v) cnt (1+ cnt))))
              (setq j (1+ j)))
            (push (if (> cnt 0) (/ sum (float cnt)) nil) out))
          (setq i (1+ i)))
        (nreverse out)))))

(defun betterdatadog--spark-chart (values height)
  "Return a list of HEIGHT strings (top row first) charting VALUES.
Each row contributes 8 levels of vertical resolution; non-numeric
entries render as gaps and numeric points always fill at least one
level so real data is never mistaken for a gap."
  (let* ((height (max 1 height))
         (nums (delq nil (mapcar (lambda (v) (and (numberp v) v)) values)))
         (lo (if nums (apply #'min nums) 0))
         (hi (if nums (apply #'max nums) 0))
         (range (- hi lo))
         (units (* 8 height))
         (levels betterdatadog--spark-levels)
         ;; Per column: total filled levels (0..units), or nil for a gap.
         (cols (mapcar
                (lambda (v)
                  (when (numberp v)
                    (max 1 (if (= range 0)
                               (/ units 2)
                             (round (* units (/ (- v lo) (float range))))))))
                values))
         (rows '()))
    (dotimes (i height)
      ;; Row 0 is the top; the bottom row sits on the baseline.
      (let* ((floor-level (* (- height 1 i) 8))
             (row (mapconcat
                   (lambda (u)
                     (if (null u)
                         " "
                       (let ((cell (max 0 (min 8 (- u floor-level)))))
                         (if (= cell 0)
                             " "
                           (char-to-string (aref levels (1- cell)))))))
                   cols "")))
        (push row rows)))
    (nreverse rows)))

(defun betterdatadog--fmt (n)
  "Format number N compactly for a summary line."
  (cond ((not (numberp n)) "—")
        ((= n (truncate n)) (format "%d" (truncate n)))
        (t (format "%.4g" n))))

(defun betterdatadog--insert-chart-rows (vals indent)
  "Draw a multi-row chart for the series VALS at INDENT spaces.
VALS is a chronological list of numbers (nil entries are gaps).  The top
and bottom rows are labelled with the max and min, and a `last' value is
printed below."
  (let* ((pad (make-string (+ indent 2) ?\s))
         (nums (delq nil (mapcar (lambda (v) (and (numberp v) v)) vals))))
    (if (null nums)
        (insert (propertize (concat pad "· (no data)\n")
                            'face 'betterdatadog-meta-face))
      (let* ((rows (betterdatadog--spark-chart
                    (betterdatadog--downsample vals betterdatadog-sparkline-width)
                    betterdatadog-graph-height))
             (n (length rows))
             (hi (apply #'max nums))
             (lo (apply #'min nums))
             (i 0))
        (dolist (row rows)
          (insert pad)
          (insert (propertize row 'face 'betterdatadog-graph-face))
          (cond
           ((= i 0)
            (insert (propertize (format "  ┈ %s" (betterdatadog--fmt hi))
                                'face 'betterdatadog-meta-face)))
           ((= i (1- n))
            (insert (propertize (format "  ┈ %s" (betterdatadog--fmt lo))
                                'face 'betterdatadog-meta-face))))
          (insert "\n")
          (setq i (1+ i)))
        (insert pad)
        (insert (propertize (format "last %s"
                                    (betterdatadog--fmt (car (last nums))))
                            'face 'betterdatadog-meta-face))
        (insert "\n")))))

(defun betterdatadog--insert-graph (query indent)
  "Resolve QUERY, fetch its data, and chart each returned series at INDENT.
Errors and empty results degrade to a short note rather than aborting
the surrounding render."
  (let ((pad (make-string (+ indent 2) ?\s)))
    (condition-case err
        (let ((series (betterdatadog--query-series query)))
          (if (null series)
              (insert (propertize (concat pad "· (no data)\n")
                                  'face 'betterdatadog-meta-face))
            (dolist (s series)
              (betterdatadog--insert-chart-rows
               (mapcar (lambda (p) (nth 1 p)) (alist-get 'pointlist s))
               indent))))
      (error
       (insert (propertize
                (format "%s· (graph unavailable: %s)\n"
                        pad (error-message-string err))
                'face 'betterdatadog-meta-face))))))

(defun betterdatadog--last-number (values)
  "Return the last numeric value in VALUES, or nil."
  (car (last (delq nil (mapcar (lambda (v) (and (numberp v) v)) values)))))

(defun betterdatadog--series-last-number (series)
  "Return the last numeric value from the first SERIES pointlist."
  (when series
    (betterdatadog--last-number
     (mapcar (lambda (p) (nth 1 p)) (alist-get 'pointlist (car series))))))

(defun betterdatadog--insert-scalar (query indent window-seconds)
  "Resolve QUERY, fetch its scalar value, and insert it at INDENT."
  (let ((pad (make-string (+ indent 2) ?\s)))
    (condition-case err
        (let ((v (betterdatadog--query-scalar query window-seconds)))
          (insert (propertize (concat pad "= " (betterdatadog--fmt v) "\n")
                              'face 'betterdatadog-meta-face)))
      (error
       (insert (propertize
                (format "%s· (value unavailable: %s)\n"
                        pad (error-message-string err))
                'face 'betterdatadog-meta-face))))))

;;;; Formula evaluation
;;
;; Modern dashboard widgets express each plotted line as a `formula' (e.g.
;; "a / b") over named `queries'.  Plotting the raw component queries would
;; show, say, summed seconds and request counts instead of the average the
;; widget is meant to display, so we fetch each named query, align the
;; series on a common timeline, and evaluate the formula point by point.

(defun betterdatadog--fetch-pointmap (query)
  "Fetch resolved QUERY and return a hash of TIMESTAMP -> value (first series).
Timestamps are truncated to integer milliseconds so series from separate
requests align exactly.  Returns nil when there is no data."
  (let ((series (betterdatadog--query-series query)))
    (when series
      (let ((h (make-hash-table :test 'eql)))
        (dolist (p (alist-get 'pointlist (car series)))
          (let ((v (nth 1 p)))
            (puthash (truncate (nth 0 p)) (and (numberp v) v) h)))
        h))))

(defun betterdatadog--build-env (qmap)
  "Fetch every query in QMAP (alist NAME->query-string) and align them.
Return (TIMELINE . ENV): TIMELINE is the sorted union of all timestamps,
and ENV is an alist NAME->list-of-values aligned to TIMELINE.  Returns
nil when nothing has data."
  (let ((maps '())
        (ts-set (make-hash-table :test 'eql)))
    (dolist (pair qmap)
      (let ((h (betterdatadog--fetch-pointmap (cdr pair))))
        (push (cons (car pair) h) maps)
        (when h (maphash (lambda (k _v) (puthash k t ts-set)) h))))
    (let ((timeline '()))
      (maphash (lambda (k _v) (push k timeline)) ts-set)
      (setq timeline (sort timeline #'<))
      (when timeline
        (cons timeline
              (mapcar
               (lambda (m)
                 (cons (car m)
                       (mapcar (lambda (ts) (and (cdr m) (gethash ts (cdr m))))
                               timeline)))
               maps))))))

(defun betterdatadog--num-op (op a b)
  "Apply arithmetic OP to numbers A and B, propagating nil and /0 as nil."
  (if (or (not (numberp a)) (not (numberp b)))
      nil
    (pcase op
      ("+" (+ a b))
      ("-" (- a b))
      ("*" (* a b))
      ("/" (if (zerop b) nil (/ a (float b))))
      (_ nil))))

(defun betterdatadog--val-op (op a b)
  "Apply OP to values A and B, each a number or an aligned list of numbers.
Lists combine elementwise; a scalar broadcasts across a list."
  (cond
   ((and (listp a) (listp b))
    (let ((out '()))
      (while (and a b)
        (push (betterdatadog--num-op op (car a) (car b)) out)
        (setq a (cdr a) b (cdr b)))
      (nreverse out)))
   ((listp a) (mapcar (lambda (x) (betterdatadog--num-op op x b)) a))
   ((listp b) (mapcar (lambda (x) (betterdatadog--num-op op a x)) b))
   (t (betterdatadog--num-op op a b))))

(defun betterdatadog--apply-fn (name args)
  "Apply formula function NAME to ARGS (a list of values).
Knows `default_zero' and `abs'; any other function is treated as the
identity on its first argument so unknown wrappers degrade gracefully."
  (let ((a (car args)))
    (pcase name
      ("default_zero"
       (if (listp a) (mapcar (lambda (x) (if (numberp x) x 0)) a)
         (if (numberp a) a 0)))
      ("abs"
       (if (listp a) (mapcar (lambda (x) (and (numberp x) (abs x))) a)
         (and (numberp a) (abs a))))
      (_ a))))

(defun betterdatadog--tokenize (s)
  "Tokenize formula string S into (TYPE . VALUE) cons cells."
  (let ((tokens '()) (i 0) (n (length s)))
    (while (< i n)
      (let ((c (aref s i)))
        (cond
         ((memq c '(?\s ?\t)) (setq i (1+ i)))
         ((memq c '(?+ ?- ?* ?/ ?\( ?\) ?\,))
          (push (cons 'op (char-to-string c)) tokens)
          (setq i (1+ i)))
         ((or (and (>= c ?0) (<= c ?9)) (= c ?.))
          (let ((start i))
            (while (and (< i n)
                        (let ((d (aref s i)))
                          (or (and (>= d ?0) (<= d ?9))
                              (memq d '(?. ?e ?E))
                              (and (memq d '(?+ ?-)) (> i start)
                                   (memq (aref s (1- i)) '(?e ?E))))))
              (setq i (1+ i)))
            (push (cons 'num (string-to-number (substring s start i))) tokens)))
         ((or (and (>= c ?a) (<= c ?z)) (and (>= c ?A) (<= c ?Z)) (= c ?_))
          (let ((start i))
            (while (and (< i n)
                        (let ((d (aref s i)))
                          (or (and (>= d ?a) (<= d ?z))
                              (and (>= d ?A) (<= d ?Z))
                              (and (>= d ?0) (<= d ?9))
                              (= d ?_))))
              (setq i (1+ i)))
            (push (cons 'id (substring s start i)) tokens)))
         (t (setq i (1+ i))))))
    (nreverse tokens)))

(defun betterdatadog--eval-formula (formula env)
  "Evaluate FORMULA against ENV (alist NAME->aligned value list).
Return the resulting value (a list of numbers or a scalar), or nil if the
formula cannot be parsed or references an unknown query."
  (let* ((tokens (vconcat (betterdatadog--tokenize formula)))
         (len (length tokens))
         (pos 0))
    (cl-labels
        ((peek () (and (< pos len) (aref tokens pos)))
         (advance () (prog1 (aref tokens pos) (setq pos (1+ pos))))
         (is-op (s) (let ((tk (peek)))
                      (and tk (eq (car tk) 'op) (string= (cdr tk) s))))
         (parse-expr ()
           (let ((v (parse-term)))
             (while (or (is-op "+") (is-op "-"))
               (let ((op (cdr (advance))))
                 (setq v (betterdatadog--val-op op v (parse-term)))))
             v))
         (parse-term ()
           (let ((v (parse-factor)))
             (while (or (is-op "*") (is-op "/"))
               (let ((op (cdr (advance))))
                 (setq v (betterdatadog--val-op op v (parse-factor)))))
             v))
         (parse-factor ()
           (let ((tk (peek)))
             (cond
              ((null tk) (error "unexpected end of formula"))
              ((is-op "-") (advance)
               (betterdatadog--val-op "-" 0 (parse-factor)))
              ((is-op "(") (advance)
               (let ((v (parse-expr)))
                 (unless (is-op ")") (error "missing )"))
                 (advance) v))
              ((eq (car tk) 'num) (cdr (advance)))
              ((eq (car tk) 'id)
               (let ((name (cdr (advance))))
                 (if (is-op "(")
                     (progn
                       (advance)
                       (let ((args (list (parse-expr))))
                         (while (is-op ",")
                           (advance)
                           (push (parse-expr) args))
                         (unless (is-op ")") (error "missing )"))
                         (advance)
                         (betterdatadog--apply-fn name (nreverse args))))
                   (let ((cell (assoc name env)))
                     (if cell (cdr cell)
                       (error "unknown query %s" name))))))
              (t (error "unexpected token"))))))
      (condition-case _
          (let ((v (parse-expr)))
            (if (< pos len) nil v))
        (error nil)))))

(defun betterdatadog--insert-formula-graph (formula qmap indent)
  "Evaluate FORMULA over the named queries in QMAP and chart it at INDENT.
QMAP is an alist of NAME->query-string.  Failures degrade to a note."
  (let ((pad (make-string (+ indent 2) ?\s)))
    (condition-case err
        (let ((built (betterdatadog--build-env qmap)))
          (if (null built)
              (insert (propertize (concat pad "· (no data)\n")
                                  'face 'betterdatadog-meta-face))
            (let ((result (betterdatadog--eval-formula formula (cdr built))))
              (cond
               ((null result)
                (insert (propertize (concat pad "· (could not evaluate formula)\n")
                                    'face 'betterdatadog-meta-face)))
               ((numberp result)
                (insert pad)
                (insert (propertize (format "= %s" (betterdatadog--fmt result))
                                    'face 'betterdatadog-meta-face))
                (insert "\n"))
               (t
                (betterdatadog--insert-chart-rows result indent))))))
      (error
       (insert (propertize
                (format "%s· (graph unavailable: %s)\n"
                        pad (error-message-string err))
                'face 'betterdatadog-meta-face))))))

(defun betterdatadog--build-scalar-env (qmap window-seconds)
  "Fetch every query in QMAP as a scalar over WINDOW-SECONDS."
  (mapcar (lambda (pair)
            (cons (car pair) (betterdatadog--query-scalar
                              (cdr pair) window-seconds)))
          qmap))

(defun betterdatadog--insert-formula-scalar (formula qmap indent window-seconds)
  "Evaluate FORMULA over scalar QMAP values and insert the result."
  (let ((pad (make-string (+ indent 2) ?\s)))
    (condition-case err
        (let* ((env (betterdatadog--build-scalar-env qmap window-seconds))
               (v (betterdatadog--eval-formula formula env)))
          (insert (propertize (concat pad "= " (betterdatadog--fmt v) "\n")
                              'face 'betterdatadog-meta-face)))
      (error
       (insert (propertize
                (format "%s· (value unavailable: %s)\n"
                        pad (error-message-string err))
                'face 'betterdatadog-meta-face))))))

;;;; Rendering

(defun betterdatadog--title-duration (title)
  "Return duration in seconds from TITLE text like \"(15m)\", or nil."
  (and (stringp title)
       (string-match "(\\([0-9]+[smhdw]\\))" title)
       (betterdatadog--parse-duration (match-string 1 title))))

(defun betterdatadog--group-scalar-window (widgets)
  "Return the first explicit query_value duration among WIDGETS."
  (catch 'found
    (dolist (w widgets)
      (let* ((def (alist-get 'definition w))
             (type (alist-get 'type def)))
        (cond
         ((equal type "query_value")
          (let ((duration (betterdatadog--title-duration
                           (alist-get 'title def))))
            (when duration (throw 'found duration))))
         ((equal type "group")
          (let ((duration (betterdatadog--group-scalar-window
                           (alist-get 'widgets def))))
            (when duration (throw 'found duration)))))))))

(defun betterdatadog--scalar-window-for-widget (type title inherited-window)
  "Return scalar query window in seconds for widget TYPE and TITLE."
  (when (string= type "query_value")
    (or (betterdatadog--title-duration title)
        inherited-window
        betterdatadog-graph-window-seconds)))

(defun betterdatadog--insert-query (request indent &optional scalar-window)
  "Insert the query/queries found in REQUEST alist at INDENT spaces.
When SCALAR-WINDOW is non-nil, render values as numbers over that window
instead of charts."
  (let ((pad (make-string indent ?\s)))
    (cond
     ;; Classic single-query form: { "q": "avg:system.cpu..." }
     ((alist-get 'q request)
      (let ((q (alist-get 'q request)))
        (when betterdatadog-show-queries
          (insert pad)
          (insert (propertize q 'face 'betterdatadog-query-face))
          (insert "\n"))
        (when betterdatadog-show-graphs
          (if scalar-window
              (betterdatadog--insert-scalar q indent scalar-window)
            (betterdatadog--insert-graph q indent)))))
     ;; Formula/query form: { "queries": [...], "formulas": [...] }
     ((alist-get 'queries request)
      (let* ((queries (alist-get 'queries request))
             (formulas (alist-get 'formulas request))
             (qmap (delq nil
                         (mapcar
                          (lambda (query)
                            (let ((name (alist-get 'name query))
                                  (spec (betterdatadog--query-spec query)))
                              (when (and name spec) (cons name spec))))
                          queries))))
        ;; List each underlying query for transparency.
        (when betterdatadog-show-queries
          (dolist (query queries)
            (let ((spec (betterdatadog--query-spec query)))
              (when spec
                (insert pad)
                (insert (propertize (betterdatadog--spec-query spec)
                                    'face 'betterdatadog-query-face))
                (insert "\n")))))
        (when betterdatadog-show-graphs
          (if (and formulas qmap)
              ;; Chart the widget's actual formula(s), not the raw queries.
              (dolist (f formulas)
                (let* ((fs (alist-get 'formula f))
                       ;; A formula that is just a query name plots that query
                       ;; directly (so multi-series `by {tag}` queries keep
                       ;; all their series); anything else is evaluated.
                       (bare (and fs (assoc (string-trim fs) qmap))))
                  (cond
                   ((null fs) nil)
                   (bare
                    (if scalar-window
                        (betterdatadog--insert-scalar (cdr bare) indent scalar-window)
                      (betterdatadog--insert-graph (cdr bare) indent)))
                   (t
                    (when betterdatadog-show-queries
                      (insert (propertize (concat pad "  ↳ " fs "\n")
                                          'face 'betterdatadog-meta-face)))
                    (if scalar-window
                        (betterdatadog--insert-formula-scalar fs qmap indent scalar-window)
                      (betterdatadog--insert-formula-graph fs qmap indent))))))
            ;; No formulas: chart each query directly.
            (dolist (query queries)
              (let ((spec (betterdatadog--query-spec query)))
                (when spec
                  (if scalar-window
                      (betterdatadog--insert-scalar spec indent scalar-window)
                    (betterdatadog--insert-graph spec indent)))))))))
     ;; Log/event style: { "log_query": { "search": { "query": "..." } } }
     (betterdatadog-show-queries
      (dolist (key '(log_query rum_query apm_query process_query network_query
                     event_query security_query))
        (let ((sub (alist-get key request)))
          (when sub
            (let ((q (or (alist-get 'query (alist-get 'search sub))
                         (alist-get 'query sub))))
              (when (and q (stringp q) (> (length q) 0))
                (insert pad)
                (insert (propertize (format "[%s] %s" key q)
                                    'face 'betterdatadog-query-face))
                (insert "\n"))))))))))

(defun betterdatadog--insert-widget (widget depth &optional scalar-window-context)
  "Insert WIDGET at nesting DEPTH.
SCALAR-WINDOW-CONTEXT is inherited by query_value children without their
own explicit duration in the title."
  (let* ((def (alist-get 'definition widget))
         (type (or (alist-get 'type def) "unknown"))
         (title (or (alist-get 'title def) ""))
         (indent (* depth 2))
         (pad (make-string indent ?\s)))
    (insert pad)
    (insert (propertize (concat "▸ " (if (string-empty-p title) "(untitled)" title))
                        'face 'betterdatadog-widget-title-face))
    (insert "  ")
    (insert (propertize (format "[%s]" type) 'face 'betterdatadog-widget-type-face))
    (insert "\n")
    (cond
     ;; Group widgets nest more widgets.
     ((string= type "group")
      (let ((group-window (or scalar-window-context
                              (betterdatadog--group-scalar-window
                               (alist-get 'widgets def)))))
        (dolist (child (alist-get 'widgets def))
          (betterdatadog--insert-widget child (1+ depth) group-window))))
     ;; Note widgets carry markdown content.
     ((string= type "note")
      (let ((content (alist-get 'content def)))
        (when content
          (insert (propertize (replace-regexp-in-string
                               "^" (make-string (+ indent 2) ?\s)
                               (string-trim content))
                              'face 'betterdatadog-meta-face))
          (insert "\n"))))
     ;; Everything else: render its requests/queries.
     (t
      (let ((requests (alist-get 'requests def))
            (scalar-window (betterdatadog--scalar-window-for-widget
                            type title scalar-window-context)))
        (cond
         ((listp requests)
          (dolist (req requests)
            (betterdatadog--insert-query req (+ indent 2) scalar-window)))
         (requests
          (betterdatadog--insert-query requests (+ indent 2) scalar-window))))))))

(defun betterdatadog--render-dashboard (dashboard)
  "Render DASHBOARD (parsed API alist) into the current buffer."
  (let ((inhibit-read-only t))
    (setq betterdatadog--template-vars
          (betterdatadog--build-template-vars dashboard))
    ;; Reuse any cache built earlier in this buffer so display-only toggles
    ;; (queries/graphs) re-render without re-fetching; `g'/`w' reset it.
    (unless betterdatadog--series-cache
      (setq betterdatadog--series-cache (make-hash-table :test 'equal)))
    (when betterdatadog-show-graphs
      (betterdatadog--prefetch
       (betterdatadog--collect-queries (alist-get 'widgets dashboard))))
    (erase-buffer)
    (let ((title (or (alist-get 'title dashboard) "(untitled dashboard)"))
          (desc (alist-get 'description dashboard))
          (id (alist-get 'id dashboard))
          (layout (alist-get 'layout_type dashboard))
          (url (alist-get 'url dashboard))
          (widgets (alist-get 'widgets dashboard)))
      (insert (propertize title 'face 'betterdatadog-title-face) "\n")
      (insert (propertize (make-string (max 8 (length title)) ?─)
                          'face 'betterdatadog-meta-face)
              "\n")
      (when (and desc (stringp desc) (> (length (string-trim desc)) 0))
        (insert (propertize (string-trim desc) 'face 'betterdatadog-meta-face) "\n\n"))
      (insert (propertize
               (string-join
                (delq nil
                      (list (when id (format "id: %s" id))
                            (when layout (format "layout: %s" layout))
                            (format "widgets: %d" (length widgets))
                            (when betterdatadog-show-graphs
                              (format "window: last %s"
                                      (betterdatadog--format-duration
                                       betterdatadog-graph-window-seconds)))))
                "    ")
               'face 'betterdatadog-meta-face)
              "\n")
      (when (and url (stringp url))
        (insert (propertize (concat "https://" betterdatadog-site url)
                            'face 'betterdatadog-meta-face)
                "\n"))
      (insert "\n")
      (if (null widgets)
          (insert (propertize "(no widgets)\n" 'face 'betterdatadog-meta-face))
        (dolist (widget widgets)
          (betterdatadog--insert-widget widget 0)
          (insert "\n"))))
    (goto-char (point-min))))

;;;; Dashboard id history

(defvar betterdatadog--dashboard-history nil
  "Alist of remembered dashboards, mapping id (string) to title (string).
Most recently fetched first.  Populated from `betterdatadog-history-file'
on first use and updated whenever a dashboard is fetched successfully.")

(defvar betterdatadog--history-loaded nil
  "Non-nil once `betterdatadog-history-file' has been read this session.")

(defvar betterdatadog--id-prompt-history nil
  "Minibuffer history of dashboard ids entered this session.")

(defun betterdatadog--load-history ()
  "Load remembered dashboard ids from `betterdatadog-history-file'.
Reads the file at most once per session; a missing or unreadable file is
treated as an empty history.  Returns `betterdatadog--dashboard-history'."
  (unless betterdatadog--history-loaded
    (setq betterdatadog--history-loaded t)
    (when (and betterdatadog-history-file
               (file-readable-p betterdatadog-history-file))
      (with-demoted-errors "betterdatadog: could not read history: %S"
        (with-temp-buffer
          (insert-file-contents betterdatadog-history-file)
          (let ((data (read (current-buffer))))
            (when (listp data)
              (setq betterdatadog--dashboard-history data)))))))
  betterdatadog--dashboard-history)

(defun betterdatadog--save-history ()
  "Write `betterdatadog--dashboard-history' to `betterdatadog-history-file'."
  (when betterdatadog-history-file
    (with-demoted-errors "betterdatadog: could not save history: %S"
      (let ((dir (file-name-directory betterdatadog-history-file)))
        (when (and dir (not (file-directory-p dir)))
          (make-directory dir t)))
      (with-temp-file betterdatadog-history-file
        (insert ";; betterdatadog dashboard id history -*- lexical-binding: t; -*-\n")
        (insert ";; Auto-generated; edit at your own risk.\n")
        (prin1 betterdatadog--dashboard-history (current-buffer))
        (insert "\n")))))

(defun betterdatadog--remember-dashboard (id title)
  "Record that dashboard ID (with TITLE) was fetched successfully.
Moves ID to the front of the history and persists it."
  (betterdatadog--load-history)
  (setq betterdatadog--dashboard-history
        (cons (cons id (or title ""))
              (assoc-delete-all id betterdatadog--dashboard-history)))
  (betterdatadog--save-history))

(defun betterdatadog--read-dashboard-id ()
  "Prompt for a dashboard id, offering remembered ids for completion.
Each candidate is annotated with the dashboard title.  Free input is
allowed, so a brand-new id can still be pasted in."
  (betterdatadog--load-history)
  (let* ((history betterdatadog--dashboard-history)
         (annotation (lambda (id)
                       (let ((title (cdr (assoc id history))))
                         (if (and title (not (string-empty-p title)))
                             (concat "  " title)
                           ""))))
         (completion-extra-properties
          (list :annotation-function annotation)))
    (string-trim
     (completing-read
      (if history
          "Datadog dashboard id (TAB to complete remembered ids): "
        "Datadog dashboard id: ")
      (mapcar #'car history)
      nil nil nil
      'betterdatadog--id-prompt-history))))

;;;; Mode and entry points

(defvar betterdatadog--current-dashboard-id nil
  "The dashboard id currently displayed in the buffer, for `revert-buffer'.")
(make-variable-buffer-local 'betterdatadog--current-dashboard-id)

(defvar betterdatadog--current-dashboard nil
  "The most recently fetched dashboard alist, cached for re-rendering.")
(make-variable-buffer-local 'betterdatadog--current-dashboard)

(defun betterdatadog-refresh ()
  "Re-fetch and re-render the dashboard shown in the current buffer."
  (interactive)
  (unless betterdatadog--current-dashboard-id
    (user-error "No dashboard associated with this buffer"))
  (betterdatadog-show-dashboard betterdatadog--current-dashboard-id))

(defun betterdatadog-toggle-graphs ()
  "Toggle sparkline rendering in this buffer and re-render.
Re-renders from the cached dashboard definition when available, so only
graph data (not the dashboard structure) is re-fetched."
  (interactive)
  (setq-local betterdatadog-show-graphs (not betterdatadog-show-graphs))
  (if betterdatadog--current-dashboard
      (betterdatadog--render-dashboard betterdatadog--current-dashboard)
    (betterdatadog-refresh))
  (message "betterdatadog: graphs %s"
           (if betterdatadog-show-graphs "on" "off")))

(defun betterdatadog-toggle-queries ()
  "Toggle display of the metric query strings in this buffer and re-render.
Re-renders from the cached dashboard and graph data, so this is instant."
  (interactive)
  (setq-local betterdatadog-show-queries (not betterdatadog-show-queries))
  (if betterdatadog--current-dashboard
      (betterdatadog--render-dashboard betterdatadog--current-dashboard)
    (betterdatadog-refresh))
  (message "betterdatadog: queries %s"
           (if betterdatadog-show-queries "shown" "hidden")))

(defun betterdatadog-set-window (window)
  "Set the graph time window to WINDOW (this buffer) and re-render.
WINDOW is duration shorthand like \"30m\", \"1h\", \"4h\", or \"1d\"; a
bare number is seconds.  Re-renders from the cached dashboard when
available, so only graph data is re-fetched."
  (interactive
   (list (read-string
          (format "Graph window (e.g. 30m, 1h, 4h, 1d) [current %s]: "
                  (betterdatadog--format-duration
                   betterdatadog-graph-window-seconds)))))
  (let ((secs (betterdatadog--parse-duration window)))
    (when (<= secs 0)
      (user-error "Window must be positive"))
    (setq-local betterdatadog-graph-window-seconds secs)
    ;; The window changed, so cached series no longer match; force a refetch.
    (setq betterdatadog--series-cache nil)
    (if betterdatadog--current-dashboard
        (betterdatadog--render-dashboard betterdatadog--current-dashboard)
      (betterdatadog-refresh))
    (message "betterdatadog: graph window set to %s"
             (betterdatadog--format-duration secs))))

(defvar betterdatadog-mode-map (make-sparse-keymap)
  "Keymap for `betterdatadog-mode'.

Intentionally empty: betterdatadog ships no key bindings of its own so it
does not clobber your setup.  Bind the interactive commands yourself, for
example:

  (with-eval-after-load \\='betterdatadog
    (define-key betterdatadog-mode-map (kbd \"g\") #\\='betterdatadog-refresh)
    (define-key betterdatadog-mode-map (kbd \"t\") #\\='betterdatadog-toggle-graphs)
    (define-key betterdatadog-mode-map (kbd \"s\") #\\='betterdatadog-toggle-queries)
    (define-key betterdatadog-mode-map (kbd \"w\") #\\='betterdatadog-set-window))

The commands are `betterdatadog-refresh', `betterdatadog-toggle-graphs',
`betterdatadog-toggle-queries', and `betterdatadog-set-window'.  Standard
`special-mode' keys (e.g. \\`q' to quit, \\`g' to revert) remain available
from the parent map unless you rebind them.")

(define-derived-mode betterdatadog-mode special-mode "Datadog"
  "Major mode for viewing a Datadog dashboard.

\\{betterdatadog-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (betterdatadog-refresh)))
  (setq truncate-lines nil))

;;;###autoload
(defun betterdatadog-show-dashboard (dashboard-id)
  "Fetch the Datadog dashboard with DASHBOARD-ID and display it.

Prompts for the dashboard id interactively.  The id is the string
that appears in the dashboard URL, e.g. the \"abc-def-ghi\" in
https://app.datadoghq.com/dashboard/abc-def-ghi/.

Ids that fetch successfully are remembered in `betterdatadog-history-file'
and offered for completion on subsequent calls."
  (interactive (list (betterdatadog--read-dashboard-id)))
  (setq dashboard-id (string-trim dashboard-id))
  (when (string-empty-p dashboard-id)
    (user-error "A dashboard id is required"))
  (let* ((message-text (format "betterdatadog: fetching dashboard %s..." dashboard-id))
         (_ (message "%s" message-text))
         (dashboard (betterdatadog--get
                     (concat "/api/v1/dashboard/" (url-hexify-string dashboard-id))))
         (buffer (get-buffer-create betterdatadog-buffer-name)))
    ;; The fetch succeeded, so remember the id for next time.
    (betterdatadog--remember-dashboard dashboard-id (alist-get 'title dashboard))
    (with-current-buffer buffer
      (unless (derived-mode-p 'betterdatadog-mode)
        (betterdatadog-mode))
      (setq betterdatadog--current-dashboard-id dashboard-id)
      (setq betterdatadog--current-dashboard dashboard)
      ;; An explicit (re-)fetch should pull fresh graph data, not reuse cache.
      (setq betterdatadog--series-cache nil)
      (betterdatadog--render-dashboard dashboard))
    (pop-to-buffer buffer)
    (message "betterdatadog: showing dashboard %s" dashboard-id)))

(provide 'betterdatadog)

;;; betterdatadog.el ends here
