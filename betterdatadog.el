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
(require 'svg)

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

(defcustom betterdatadog-graph-style 'auto
  "How graphs are drawn.
`auto' draws SVG images on a graphical display that supports them and
Unicode block charts otherwise (e.g. in a terminal); `svg' and
`unicode' force one or the other."
  :type '(choice (const :tag "SVG when available" auto)
                 (const :tag "SVG images" svg)
                 (const :tag "Unicode block charts" unicode))
  :group 'betterdatadog)

(defcustom betterdatadog-svg-height 140
  "Height in pixels of the plot area of an SVG graph.
Its width is `betterdatadog-sparkline-width' columns of text."
  :type 'integer
  :group 'betterdatadog)

(defcustom betterdatadog-series-colors
  '("#3d9df2" "#f2933d" "#3dc47e" "#c46bd6" "#e6c229"
    "#f25c6e" "#33c4c4" "#8f83f2" "#a3b833" "#f283b0")
  "Colors given in turn to the series drawn on one SVG graph."
  :type '(repeat color)
  :group 'betterdatadog)

(defcustom betterdatadog-graph-include-zero t
  "Non-nil means every graph's y-axis includes zero.
Bar heights are then proportional to the values, as in Datadog's own
graphs.  When nil the axis spans only the data's min..max, which
magnifies small movements in a metric that sits far from zero."
  :type 'boolean
  :group 'betterdatadog)

(defcustom betterdatadog-graph-shared-scale t
  "Non-nil means the series of one grouped query share a y-axis.
The charts of a `by {tag}' query are then directly comparable, at the
cost of flattening series much smaller than the largest.  When nil each
series is scaled to its own range."
  :type 'boolean
  :group 'betterdatadog)

(defcustom betterdatadog-max-series 10
  "Maximum number of series charted for one grouped query.
A `by {tag}' query returns one series per tag combination; when there
are more than this many, only those with the highest averages are drawn
and the rest are counted in a note.  Nil means no limit."
  :type '(choice (const :tag "No limit" nil) integer)
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

(defcustom betterdatadog-logs-buffer-name "*Datadog Logs*"
  "Name of the buffer used to display log search results."
  :type 'string
  :group 'betterdatadog)

(defcustom betterdatadog-log-search-window-seconds 900
  "Length of the time window, in seconds, searched for log events.
Defaults to the last 15 minutes."
  :type 'integer
  :group 'betterdatadog)

(defcustom betterdatadog-log-search-limit 100
  "Maximum number of log events fetched per search.
Datadog caps a single page at 1000."
  :type 'integer
  :group 'betterdatadog)

(defcustom betterdatadog-log-search-history-file
  (locate-user-emacs-file "betterdatadog-log-searches.el")
  "File where log search queries are remembered.
Each query that is searched without error is stored here so
`betterdatadog-search-logs' can offer it for completion next time instead
of requiring you to retype it.  Set to nil to disable persistence
\(queries are then remembered only for the current Emacs session)."
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

(defface betterdatadog-series-face
  '((t :inherit font-lock-variable-name-face))
  "Face for the label naming each charted series."
  :group 'betterdatadog)

(defface betterdatadog-log-error-face
  '((t :inherit error))
  "Face for the status of error/critical log events."
  :group 'betterdatadog)

(defface betterdatadog-log-warn-face
  '((t :inherit warning))
  "Face for the status of warning log events."
  :group 'betterdatadog)

(defface betterdatadog-log-info-face
  '((t :inherit shadow))
  "Face for the status of info/debug log events."
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

(defvar betterdatadog--window-end nil
  "Time (float seconds since the epoch) at which the graph window ends.
Set whenever `betterdatadog--series-cache' is created, i.e. when the
data is fetched; charts place points on a time axis ending here.")
(make-variable-buffer-local 'betterdatadog--window-end)

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

(defun betterdatadog--analytics-buckets (parsed)
  "Return the buckets in analytics aggregate response PARSED.
Each bucket is normalised to (BY . C0): its group-by alist and first
compute value.  Handles both response shapes: logs nest buckets under
`data.buckets' with a `computes' object, while spans return `data' as a
list of buckets carrying `attributes.compute'."
  (let* ((data (alist-get 'data parsed))
         (logs (assq 'buckets data)))
    (mapcar
     (lambda (bucket)
       (let ((attrs (or (alist-get 'attributes bucket) bucket)))
         (cons (alist-get 'by attrs)
               (alist-get 'c0 (or (alist-get 'computes attrs)
                                  (alist-get 'compute attrs))))))
     (if logs (cdr logs) data))))

(defun betterdatadog--analytics-scalar-from-response (parsed)
  "Extract the first scalar compute value from an analytics response PARSED."
  (let ((c0 (cdr (car (betterdatadog--analytics-buckets parsed)))))
    (cond
     ((numberp c0) c0)
     ((and (listp c0) (listp (car c0)))
      (betterdatadog--last-number (mapcar (lambda (p) (alist-get 'value p)) c0)))
     (t nil))))

(defconst betterdatadog--nanosecond-unit
  '(((family . "time") (name . "nanosecond") (short_name . "ns")
     (scale_factor . 1e-9))
    nil)
  "Unit pair for span durations, shaped like a metric series `unit'.")

(defun betterdatadog--analytics-series-from-response (parsed &optional spec)
  "Extract betterdatadog series from an analytics aggregate response PARSED.
Each series mirrors the metric-query shape: a `pointlist', the group
tags as `tag_set', the sample `interval', and a `unit' when SPEC (the
query spec that produced PARSED) measures span durations."
  (let ((unit (and (equal (alist-get 'metric (plist-get spec :compute))
                          "@duration")
                   betterdatadog--nanosecond-unit))
        (interval (max 60 (truncate (/ betterdatadog-graph-window-seconds 60)))))
    (delq nil
          (mapcar
           (lambda (bucket)
             (let* ((c0 (cdr bucket))
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
               (when points
                 `((pointlist . ,points)
                   (tag_set . ,(mapcar (lambda (g)
                                         (format "%s:%s" (car g) (cdr g)))
                                       (car bucket)))
                   (interval . ,interval)
                   (unit . ,unit)))))
           (betterdatadog--analytics-buckets parsed)))))

(defun betterdatadog--fetch-analytics-series (spec)
  "Fetch logs/spans analytics time series for resolved SPEC."
  (let* ((req (betterdatadog--analytics-request spec))
         (parsed (betterdatadog--post-json (car req) (cdr req))))
    (betterdatadog--analytics-series-from-response parsed spec)))

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
                    parser (lambda (parsed)
                             (betterdatadog--analytics-series-from-response
                              parsed spec)))))
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

(defun betterdatadog--numbers (values)
  "Return the numeric entries of VALUES, in order."
  (delq nil (mapcar (lambda (v) (and (numberp v) v)) values)))

(defun betterdatadog--window-bounds ()
  "Return (FROM . TO), the graph window in epoch milliseconds.
The window ends when the current data was fetched, so a re-render from
the cache keeps points and time axis in step."
  (let ((to (* 1000.0 (or betterdatadog--window-end (float-time)))))
    (cons (- to (* 1000.0 betterdatadog-graph-window-seconds)) to)))

(defun betterdatadog--chart-width (group &optional max-width)
  "Return the number of columns used to chart the series in GROUP.
This is MAX-WIDTH (default `betterdatadog-sparkline-width'), narrowed to
one column per
sample when the data is coarser than that, so widely spaced points draw
as a solid chart rather than isolated bars.  The sample spacing comes
from each series' :interval, else from the smallest gap between points."
  (let ((width (max 1 (or max-width betterdatadog-sparkline-width)))
        (step nil))
    (dolist (s group)
      (let ((iv (plist-get s :interval)))
        (when (and (numberp iv) (> iv 0))
          (setq step (if step (min step (* 1000.0 iv)) (* 1000.0 iv))))))
    (unless step
      (dolist (s group)
        (let ((prev nil))
          (dolist (p (plist-get s :points))
            (let ((ts (car p)))
              (when (and prev (> ts prev)
                         (or (null step) (< (- ts prev) step)))
                (setq step (- ts prev)))
              (setq prev ts))))))
    (if step
        (max 1 (min width
                    (round (/ (* 1000.0 betterdatadog-graph-window-seconds)
                              step))))
      width)))

(defun betterdatadog--bucket-points (points from to width)
  "Place POINTS on a WIDTH-column timeline spanning FROM..TO (epoch ms).
POINTS is a list of (TIMESTAMP VALUE).  Return a list of WIDTH entries:
the largest value falling in each column (so short spikes survive
downsampling), or nil for a column with no data (rendered as a gap)."
  (let ((cols (make-vector width nil))
        (span (max 1.0 (- to from))))
    (dolist (p points)
      (let ((v (nth 1 p)))
        (when (numberp v)
          (let* ((i (floor (* width (/ (- (car p) from) span))))
                 (i (max 0 (min (1- width) i)))
                 (old (aref cols i)))
            (aset cols i (if old (max old v) v))))))
    (append cols nil)))

(defun betterdatadog--scale (nums)
  "Return (LO . HI), the y-axis range for charting NUMS.
Honours `betterdatadog-graph-include-zero'."
  (let ((lo (if nums (apply #'min nums) 0))
        (hi (if nums (apply #'max nums) 0)))
    (if betterdatadog-graph-include-zero
        (cons (min 0 lo) (max 0 hi))
      (cons lo hi))))

(defun betterdatadog--spark-chart (values height &optional lo hi)
  "Return a list of HEIGHT strings (top row first) charting VALUES.
Each row contributes 8 levels of vertical resolution; non-numeric
entries render as gaps and numeric points always fill at least one
level so real data is never mistaken for a gap.  The y-axis runs from LO
to HI, defaulting to the range of VALUES."
  (let* ((height (max 1 height))
         (nums (betterdatadog--numbers values))
         (lo (or lo (if nums (apply #'min nums) 0)))
         (hi (or hi (if nums (apply #'max nums) 0)))
         (range (- hi lo))
         (units (* 8 height))
         (levels betterdatadog--spark-levels)
         ;; Per column: total filled levels (0..units), or nil for a gap.
         (cols (mapcar
                (lambda (v)
                  (when (numberp v)
                    (max 1 (cond
                            ((> range 0)
                             (round (* units (/ (- v lo) (float range)))))
                            ;; A flat line: on the baseline at zero,
                            ;; mid-height otherwise.
                            ((zerop v) 1)
                            (t (/ units 2))))))
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
  "Format number N exactly, for a scalar value."
  (cond ((not (numberp n)) "—")
        ((= n (truncate n)) (format "%d" (truncate n)))
        (t (format "%.4g" n))))

(defun betterdatadog--fmt-sig (x)
  "Format X to about three significant digits, without an exponent."
  (let ((a (abs x)))
    (cond
     ((zerop a) "0")
     ((< a 0.001) (format "%.2g" x))
     (t (let ((s (format (cond ((>= a 100) "%.0f")
                               ((>= a 10) "%.1f")
                               ((>= a 1) "%.2f")
                               (t "%.3f"))
                         x)))
          (if (string-match-p "\\." s)
              (replace-regexp-in-string "\\.?0+\\'" "" s)
            s))))))

(defun betterdatadog--fmt-scaled (n steps)
  "Format N using the largest fitting entry of STEPS.
STEPS is a list of (THRESHOLD . SUFFIX) in descending order; N is divided
by the first THRESHOLD it reaches (else the last) and given that SUFFIX."
  (let ((step (or (cl-find-if (lambda (s) (>= (abs n) (car s))) steps)
                  (car (last steps)))))
    (concat (betterdatadog--fmt-sig (/ n (float (car step)))) (cdr step))))

(defun betterdatadog--fmt-compact (n)
  "Format number N compactly, e.g. 1234567 -> \"1.23M\"."
  (if (not (numberp n))
      "—"
    (betterdatadog--fmt-scaled
     n '((1e12 . "T") (1e9 . "B") (1e6 . "M") (1e3 . "K") (1 . "")))))

(defun betterdatadog--fmt-value (n unit)
  "Format number N compactly in UNIT.
UNIT is a Datadog unit pair (UNIT PER-UNIT) as returned with a metric
series, or nil.  Times, byte sizes and CPU cores are rescaled to a
readable magnitude (e.g. 0.0042 second -> \"4.2ms\"); other units are
appended."
  (let* ((u (car-safe unit))
         (per (car-safe (cdr-safe unit)))
         (family (alist-get 'family u))
         (factor (let ((f (alist-get 'scale_factor u))) (if (numberp f) f 1)))
         (short (or (alist-get 'short_name u) (alist-get 'name u)))
         (per-short (and per (or (alist-get 'short_name per)
                                 (alist-get 'name per)))))
    (concat
     (cond
      ((not (numberp n)) "—")
      ((zerop n) "0")
      ((equal family "time")
       (let ((secs (* n factor)))
         (if (>= (abs secs) 1)
             (betterdatadog--fmt-scaled
              secs '((86400 . "d") (3600 . "h") (60 . "min") (1 . "s")))
           (betterdatadog--fmt-scaled
            (* secs 1e9) '((1e6 . "ms") (1e3 . "µs") (1 . "ns"))))))
      ((equal family "bytes")
       (betterdatadog--fmt-scaled
        (* n factor)
        `((,(expt 1024.0 4) . "TiB") (,(expt 1024.0 3) . "GiB")
          (,(expt 1024.0 2) . "MiB") (1024.0 . "KiB") (1 . "B"))))
      ((equal family "cpu")
       (concat (betterdatadog--fmt-compact (* n factor)) " cores"))
      ((member short '("%" "percent")) (concat (betterdatadog--fmt-compact n) "%"))
      (short (concat (betterdatadog--fmt-compact n) " " short))
      (t (betterdatadog--fmt-compact n)))
     (if (and (numberp n) (not (zerop n)) per-short)
         (concat "/" per-short)
       ""))))

(defun betterdatadog--time-axis (width from to)
  "Return (AXIS . LABELS), two strings drawing a WIDTH-column time axis.
FROM and TO are the epoch-millisecond bounds of the chart.  Ticks mark
the start, middle and end, dropping to fewer when WIDTH is too narrow to
label them all."
  (let* ((secs (/ (- to from) 1000.0))
         (fmt (cond ((< secs 600) "%H:%M:%S")
                    ((<= secs 86400) "%H:%M")
                    (t "%b %d %H:%M")))
         (label (lambda (ms) (format-time-string fmt (/ ms 1000.0))))
         (left (funcall label from))
         (mid (funcall label (/ (+ from to) 2.0)))
         (right (funcall label to))
         (n (length right))
         (last (1- width))
         (middle (/ last 2))
         ;; Each tick is (COLUMN LABEL LABEL-START-COLUMN).
         (ticks (cond
                 ((>= width (+ (* 3 n) 4))
                  (list (list 0 left 0)
                        (list middle mid (- middle (/ (length mid) 2)))
                        (list last right (- width n))))
                 ((>= width (+ (* 2 n) 2))
                  (list (list 0 left 0) (list last right (- width n))))
                 (t (list (list last right (max 0 (- width n)))))))
         (axis (make-string width ?─))
         (labels (make-string (max width n) ?\s)))
    (dolist (tick ticks)
      (aset axis (nth 0 tick) ?┬)
      (let ((text (nth 1 tick))
            (start (nth 2 tick)))
        (dotimes (i (length text))
          (aset labels (+ start i) (aref text i)))))
    (cons axis (string-trim-right labels))))

(defun betterdatadog--join-label (&rest parts)
  "Join the non-empty strings in PARTS with a separator, or return nil."
  (let ((parts (cl-remove-if-not
                (lambda (p) (and (stringp p) (not (string-empty-p p))))
                parts)))
    (and parts (string-join parts " · "))))

(defun betterdatadog--insert-note (text indent &optional label)
  "Insert the one-line note TEXT at INDENT, prefixed by LABEL when non-nil."
  (insert (make-string (+ indent 2) ?\s))
  (when label
    (insert (propertize label 'face 'betterdatadog-series-face) "  "))
  (insert (propertize (concat "· (" text ")") 'face 'betterdatadog-meta-face)
          "\n"))

(defun betterdatadog--insert-chart (series width lo hi gutter indent)
  "Draw SERIES as a labelled chart at INDENT spaces.
SERIES is a plist with :points (a chronological list of (TIMESTAMP
VALUE)), :nums (its numeric values), and optionally :label and :unit.
The chart is WIDTH columns wide on a y-axis running LO..HI, whose labels
are right-aligned in GUTTER columns; below it come a time axis and a
min/avg/max/last summary."
  (let* ((pad (make-string (+ indent 2) ?\s))
         (unit (plist-get series :unit))
         (nums (plist-get series :nums))
         (label (plist-get series :label))
         (bounds (betterdatadog--window-bounds))
         (rows (betterdatadog--spark-chart
                (betterdatadog--bucket-points
                 (plist-get series :points) (car bounds) (cdr bounds) width)
                betterdatadog-graph-height lo hi))
         (n (length rows))
         (axis (betterdatadog--time-axis width (car bounds) (cdr bounds)))
         (meta (lambda (s) (propertize s 'face 'betterdatadog-meta-face)))
         (i 0))
    (when label
      (insert pad (propertize label 'face 'betterdatadog-series-face) "\n"))
    (dolist (row rows)
      (let ((tick (cond ((= i 0) (betterdatadog--fmt-value hi unit))
                        ((= i (1- n)) (betterdatadog--fmt-value lo unit)))))
        (insert pad
                (funcall meta (concat (make-string
                                       (max 0 (- gutter (length tick))) ?\s)
                                      tick
                                      (if tick " ┤" " │")))
                (propertize (string-trim-right row)
                            'face 'betterdatadog-graph-face)
                "\n"))
      (setq i (1+ i)))
    (insert pad (funcall meta (concat (make-string (1+ gutter) ?\s) "└"
                                      (car axis)))
            "\n"
            pad (funcall meta (concat (make-string (+ gutter 2) ?\s)
                                      (cdr axis)))
            "\n"
            pad (funcall meta (betterdatadog--stats nums unit))
            "\n")))

(defun betterdatadog--stats (nums unit)
  "Return the min/avg/max/last summary of NUMS, formatted in UNIT."
  (format "min %s · avg %s · max %s · last %s"
          (betterdatadog--fmt-value (apply #'min nums) unit)
          (betterdatadog--fmt-value
           (/ (apply #'+ nums) (float (length nums))) unit)
          (betterdatadog--fmt-value (apply #'max nums) unit)
          (betterdatadog--fmt-value (car (last nums)) unit)))

;;;;; SVG charts
;;
;; On a graphical display each group of series is drawn as one SVG image:
;; the series overlaid as lines (or stacked as areas/bars, following the
;; widget's `display_type'), with gridlines and axis ticks, and a text
;; legend underneath carrying each series' label and summary.

(defvar betterdatadog--display-type nil
  "The `display_type' of the widget request being rendered, or nil.
Bound by `betterdatadog--insert-query'; one of \"line\", \"area\" or
\"bars\" for timeseries widgets.")

(defvar betterdatadog--collector nil
  "When non-nil, a cons (SERIES . DROPPED) gathering series to chart.
`betterdatadog--insert-query' binds it while rendering one widget
request as SVG, so that everything the request plots (all its formulas)
lands on a single chart, as in Datadog, instead of one chart each.
SERIES is the list of series plists so far; DROPPED counts those left
out by `betterdatadog-max-series'.")

(defun betterdatadog--svg-p ()
  "Return non-nil when graphs should be drawn as SVG images.
See `betterdatadog-graph-style'."
  (and (not (eq betterdatadog-graph-style 'unicode))
       (or (eq betterdatadog-graph-style 'svg) (display-graphic-p))
       (image-type-available-p 'svg)))

(defun betterdatadog--hex-color (color fallback)
  "Return COLOR (any Emacs color name) as \"#rrggbb\", else FALLBACK.
SVG renderers do not know X11 names such as \"grey50\"."
  (let ((rgb (and (stringp color) (ignore-errors (color-values color)))))
    (if rgb
        (apply #'format "#%02x%02x%02x" (mapcar (lambda (c) (ash c -8)) rgb))
      fallback)))

(defun betterdatadog--nice-step (range count)
  "Return a round step (1, 2 or 5 times a power of ten) for an axis.
The step divides RANGE into about COUNT intervals."
  (let* ((raw (/ (float range) (max 1 count)))
         (mag (expt 10.0 (floor (log raw 10))))
         (f (/ raw mag)))
    (* mag (cond ((<= f 1) 1) ((<= f 2) 2) ((<= f 5) 5) (t 10)))))

(defun betterdatadog--unit-divisor (hi unit)
  "Return the amount of UNIT that one displayed unit of HI stands for.
`betterdatadog--fmt-value' rescales times and byte sizes (a value of
3e11 nanoseconds reads \"5min\"), so ticks must be round in the
displayed magnitude rather than the raw one.  For other units this is 1."
  (let* ((u (car-safe unit))
         (family (alist-get 'family u))
         (factor (let ((f (alist-get 'scale_factor u)))
                   (if (and (numberp f) (> f 0)) f 1)))
         (x (abs (* hi factor)))
         (steps (cond
                 ((equal family "time") '(86400 3600 60 1 1e-3 1e-6 1e-9))
                 ((equal family "bytes")
                  (list (expt 1024.0 4) (expt 1024.0 3) (expt 1024.0 2)
                        1024.0 1)))))
    (if steps
        (/ (or (cl-find-if (lambda (s) (>= x s)) steps) (car (last steps)))
           (float factor))
      1.0)))

(defun betterdatadog--y-ticks (lo hi &optional unit)
  "Return tick values for a y-axis running LO..HI that read round in UNIT."
  (let* ((d (betterdatadog--unit-divisor hi unit))
         (step (betterdatadog--nice-step (/ (- hi lo) d) 4))
         (v (* step (ceiling (/ lo d step))))
         (ticks '()))
    (while (<= v (+ (/ hi d) (* step 1e-6)))
      (push (* v d) ticks)
      (setq v (+ v step)))
    (nreverse ticks)))

(defconst betterdatadog--time-steps
  '(1 5 10 15 30 60 120 300 600 900 1800 3600 7200 10800 21600 43200
    86400 172800 604800)
  "Candidate spacings, in seconds, between time-axis ticks.")

(defun betterdatadog--time-ticks (from to max-count)
  "Return (FORMAT . TIMES) for a time axis spanning FROM..TO (epoch ms).
TIMES are at most MAX-COUNT epoch-second values on round local clock
times; FORMAT is the `format-time-string' spec that labels them."
  (let* ((from (/ from 1000.0))
         (to (/ to 1000.0))
         (span (- to from))
         (step (or (cl-find-if (lambda (s) (<= (/ span s) max-count))
                               betterdatadog--time-steps)
                   (car (last betterdatadog--time-steps))))
         ;; Align to the local clock, not UTC.
         (offset (or (car (current-time-zone (seconds-to-time from))) 0))
         (tick (- (* step (ceiling (/ (+ from offset) step))) offset))
         (times '()))
    (while (<= tick to)
      (push tick times)
      (setq tick (+ tick step)))
    (cons (cond ((< step 60) "%H:%M:%S")
                ((>= step 86400) "%b %d")
                ((> span 86400) "%a %H:%M")
                (t "%H:%M"))
          (nreverse times))))

(defun betterdatadog--line-segments (cols max-gap)
  "Split COLS into runs of points to join with a line.
COLS is a list of bucket values (nil for an empty bucket).  Return a
list of segments, each a list of (INDEX . VALUE); a new segment starts
wherever more than MAX-GAP consecutive buckets are empty, so short
holes are bridged but real outages show as breaks."
  (let ((segments '()) (current '()) (prev nil) (i 0))
    (dolist (v cols)
      (when (numberp v)
        (when (and prev (> (- i prev) (1+ max-gap)) current)
          (push (nreverse current) segments)
          (setq current '()))
        (push (cons i v) current)
        (setq prev i))
      (setq i (1+ i)))
    (when current (push (nreverse current) segments))
    (nreverse segments)))

(defun betterdatadog--svg-chart (group)
  "Return an SVG image charting the series plists in GROUP together.
Each series needs :points, :nums and :color.  Series are overlaid as
lines, or stacked as areas or bars when `betterdatadog--display-type'
says so, on a shared y-axis labelled in the first series' unit."
  (let* ((type (if (member betterdatadog--display-type '("bars" "area"))
                   betterdatadog--display-type
                 "line"))
         (stacked (not (equal type "line")))
         (unit (plist-get (car group) :unit))
         (fs 11)
         (family (let ((f (face-attribute 'default :family nil t)))
                   (if (and (stringp f) (display-graphic-p)) f "monospace")))
         (fg (betterdatadog--hex-color
              (face-foreground 'betterdatadog-meta-face nil t) "#888888"))
         (bounds (betterdatadog--window-bounds))
         (from (car bounds))
         (to (cdr bounds))
         (plot-w (* (max 8 betterdatadog-sparkline-width)
                    (if (display-graphic-p) (frame-char-width) 8)))
         (plot-h (max 40 betterdatadog-svg-height))
         ;; Bars need room to be seen; lines can use every other pixel.
         (n (betterdatadog--chart-width
             group (max 2 (/ plot-w (if (equal type "bars") 4 2)))))
         (cols (mapcar (lambda (s)
                         (betterdatadog--bucket-points
                          (plist-get s :points) from to n))
                       group))
         ;; For stacked charts, the running total under each series.
         (bases (let ((acc (make-list n 0)) (out '()))
                  (dolist (c cols)
                    (push acc out)
                    (setq acc (cl-mapcar (lambda (a v) (+ a (or v 0))) acc c)))
                  (push acc out)
                  (nreverse out)))
         (scale (if stacked
                    (let ((betterdatadog-graph-include-zero t))
                      (betterdatadog--scale (apply #'append bases)))
                  (betterdatadog--scale
                   (apply #'append
                          (mapcar (lambda (s) (plist-get s :nums)) group)))))
         (lo (car scale))
         (hi (if (> (cdr scale) lo) (cdr scale) (+ lo 1)))
         (y-ticks (betterdatadog--y-ticks lo hi unit))
         (y-labels (mapcar (lambda (v) (betterdatadog--fmt-value v unit))
                           y-ticks))
         (x-ticks (betterdatadog--time-ticks from to (max 2 (/ plot-w 90))))
         ;; Room for half a time label to overhang either end of the axis.
         (overhang (+ 4 (ceiling (* 0.31 fs (length (format-time-string
                                                     (car x-ticks) 0))))))
         (left (max overhang
                    (+ 10 (ceiling (* 0.62 fs (apply #'max 1
                                                     (mapcar #'length
                                                             y-labels)))))))
         (top 8)
         (width (+ left plot-w overhang))
         (height (+ top plot-h fs 12))
         (bottom (+ top plot-h))
         (x-of (lambda (i) (+ left (* plot-w (/ (+ i 0.5) n)))))
         (y-of (lambda (v) (+ top (* plot-h (- 1 (/ (- v lo) (float (- hi lo))))))))
         (text (lambda (svg string x y anchor)
                 (svg-text svg string :x x :y y :font-size fs
                           :font-family family :fill fg :text-anchor anchor)))
         (svg (svg-create width height)))
    ;; Horizontal gridlines with their y labels.
    (cl-mapc
     (lambda (v label)
       (let ((y (funcall y-of v)))
         (svg-line svg left y (+ left plot-w) y
                   :stroke-color fg :stroke-width 1 :stroke-opacity 0.25)
         (funcall text svg label (- left 6) (+ y (* 0.35 fs)) "end")))
     y-ticks y-labels)
    ;; The data.
    (cl-loop
     for s in group
     for c in cols
     for base in bases
     for color = (plist-get s :color)
     do
     (pcase type
       ("bars"
        (let ((bar-w (max 1.0 (- (/ plot-w (float n)) 1)))
              (i 0))
          (cl-mapc
           (lambda (v b)
             (when (and (numberp v) (/= v 0))
               (let ((y0 (funcall y-of b))
                     (y1 (funcall y-of (+ b v))))
                 (svg-rectangle svg (- (funcall x-of i) (/ bar-w 2))
                                (min y0 y1) bar-w (max 1 (abs (- y0 y1)))
                                :fill-color color)))
             (setq i (1+ i)))
           c base)))
       ("area"
        (let ((upper '()) (lower '()) (i 0))
          (cl-mapc
           (lambda (v b)
             (let ((x (funcall x-of i)))
               (push (cons x (funcall y-of (+ b (or v 0)))) upper)
               (push (cons x (funcall y-of b)) lower))
             (setq i (1+ i)))
           c base)
          (svg-polygon svg (append (reverse upper) lower)
                       :fill-color color :fill-opacity 0.45)
          (svg-polyline svg (reverse upper) :fill "none"
                        :stroke-color color :stroke-width 1.2)))
       (_
        (dolist (segment (betterdatadog--line-segments c (max 1 (/ n 8))))
          (let ((points (mapcar (lambda (p)
                                  (cons (funcall x-of (car p))
                                        (funcall y-of (cdr p))))
                                segment)))
            (if (cdr points)
                (progn
                  ;; A lone series gets a soft fill down to the baseline.
                  (unless (cdr group)
                    (svg-polygon
                     svg
                     (append points
                             (list (cons (car (car (last points))) bottom)
                                   (cons (car (car points)) bottom)))
                     :fill-color color :fill-opacity 0.12))
                  (svg-polyline svg points :fill "none"
                                :stroke-color color :stroke-width 1.5
                                :stroke-linejoin "round"))
              ;; An isolated sample would otherwise be invisible.
              (svg-circle svg (car (car points)) (cdr (car points)) 2
                          :fill-color color)))))))
    ;; Time axis.
    (svg-line svg left bottom (+ left plot-w) bottom
              :stroke-color fg :stroke-width 1 :stroke-opacity 0.6)
    (dolist (tick (cdr x-ticks))
      (let ((x (+ left (* plot-w (/ (- (* 1000.0 tick) from) (- to from))))))
        (svg-line svg x bottom x (+ bottom 4)
                  :stroke-color fg :stroke-width 1 :stroke-opacity 0.6)
        (funcall text svg (format-time-string (car x-ticks) tick)
                 x (+ bottom fs 6) "middle")))
    (svg-image svg :ascent 'center)))

(defun betterdatadog--insert-svg-chart (group indent)
  "Insert one SVG chart of the series in GROUP at INDENT, with a legend.
GROUP holds series plists with :nums and :color; series without data
are named in the legend only."
  (let* ((pad (make-string (+ indent 2) ?\s))
         (drawn (cl-remove-if-not (lambda (s) (plist-get s :nums)) group))
         (label-width (apply #'max 0
                             (mapcar (lambda (s)
                                       (length (plist-get s :label)))
                                     group))))
    (when drawn
      (insert pad)
      (insert-image (betterdatadog--svg-chart drawn) "[graph]")
      (insert "\n"))
    (dolist (s group)
      (let ((label (or (plist-get s :label) ""))
            (nums (plist-get s :nums)))
        (insert pad
                (propertize "━━" 'face (list :foreground (plist-get s :color)))
                " ")
        (when (> label-width 0)
          (insert (propertize label 'face 'betterdatadog-series-face)
                  (make-string (+ 2 (- label-width (length label))) ?\s)))
        (insert (propertize (if nums
                                (betterdatadog--stats nums (plist-get s :unit))
                              "· (no data)")
                            'face 'betterdatadog-meta-face)
                "\n")))))

(defun betterdatadog--insert-svg-group (group indent)
  "Draw the series plists in GROUP as SVG at INDENT spaces.
They share one chart, or get one each when
`betterdatadog-graph-shared-scale' is nil."
  (let* ((colors (or betterdatadog-series-colors '("#3399ff")))
         (i -1)
         (group (mapcar (lambda (s)
                          (setq i (1+ i))
                          (append (list :color (nth (% i (length colors)) colors))
                                  s))
                        group)))
    (if betterdatadog-graph-shared-scale
        (betterdatadog--insert-svg-chart group indent)
      (dolist (s group)
        (betterdatadog--insert-svg-chart (list s) indent)))))

(defun betterdatadog--insert-text-group (group indent)
  "Draw the series plists in GROUP as Unicode charts at INDENT spaces."
  (let* ((shared (and betterdatadog-graph-shared-scale
                      (betterdatadog--scale
                       (apply #'append
                              (mapcar (lambda (s) (plist-get s :nums))
                                      group)))))
         ;; Each series paired with its (LO . HI) y-axis range.
         (scaled (mapcar
                  (lambda (s)
                    (cons s (or shared (betterdatadog--scale
                                        (plist-get s :nums)))))
                  group))
         (width (betterdatadog--chart-width group))
         ;; One gutter for the whole group keeps the plots aligned.
         (gutter (apply #'max 0
                        (mapcar
                         (lambda (c)
                           (let ((unit (plist-get (car c) :unit)))
                             (max (length (betterdatadog--fmt-value
                                           (cadr c) unit))
                                  (length (betterdatadog--fmt-value
                                           (cddr c) unit)))))
                         scaled))))
    (dolist (c scaled)
      (if (plist-get (car c) :nums)
          (betterdatadog--insert-chart
           (car c) width (cadr c) (cddr c) gutter indent)
        (betterdatadog--insert-note
         "no data" indent (plist-get (car c) :label))))))

(defun betterdatadog--insert-series-group (group indent)
  "Chart every series in GROUP at INDENT spaces.
GROUP is a list of series plists (see `betterdatadog--insert-chart')
that belong together, e.g. the series of one `by {tag}' query.  They are
drawn as one SVG image or as Unicode charts, per
`betterdatadog-graph-style', and share a y-axis when
`betterdatadog-graph-shared-scale' is set.  At most
`betterdatadog-max-series' are drawn, keeping those with the highest
averages."
  (let* ((group (mapcar
                 (lambda (s)
                   (append
                    (list :nums (betterdatadog--numbers
                                 (mapcar (lambda (p) (nth 1 p))
                                         (plist-get s :points))))
                    s))
                 group))
         (total (length group))
         (limit (and (integerp betterdatadog-max-series)
                     (> betterdatadog-max-series 0)
                     betterdatadog-max-series))
         (avg (lambda (s)
                (let ((nums (plist-get s :nums)))
                  (if nums (/ (apply #'+ nums) (float (length nums))) -1e+INF)))))
    (when (and limit (> total limit))
      (setq group (cl-subseq (cl-sort (copy-sequence group) #'> :key avg)
                             0 limit)))
    (let ((dropped (if limit (max 0 (- total limit)) 0)))
      (cond
       (betterdatadog--collector
        (setcar betterdatadog--collector
                (append (car betterdatadog--collector) group))
        (setcdr betterdatadog--collector
                (+ (cdr betterdatadog--collector) dropped)))
       ((betterdatadog--svg-p)
        (let ((betterdatadog--collector (cons group dropped)))
          (betterdatadog--flush-collector indent)))
       (t
        (betterdatadog--insert-text-group group indent)
        (betterdatadog--insert-dropped-note dropped indent))))))

(defun betterdatadog--insert-dropped-note (dropped indent)
  "Note at INDENT that DROPPED series were left out, when there are any."
  (when (> dropped 0)
    (betterdatadog--insert-note
     (format "%d more series not shown" dropped) indent)))

(defun betterdatadog--flush-collector (indent)
  "Draw the series gathered in `betterdatadog--collector' at INDENT."
  (let ((group (car betterdatadog--collector)))
    (if (cl-some (lambda (s) (plist-get s :nums)) group)
        (betterdatadog--insert-svg-group group indent)
      (dolist (s group)
        (betterdatadog--insert-note "no data" indent (plist-get s :label))))
    (betterdatadog--insert-dropped-note (cdr betterdatadog--collector) indent)))

(defun betterdatadog--series-tags (series)
  "Return the group tags of API SERIES as one string, \"\" when ungrouped."
  (string-join (sort (copy-sequence (alist-get 'tag_set series)) #'string<)
               ", "))

(defun betterdatadog--insert-graph (query indent &optional label)
  "Resolve QUERY, fetch its data, and chart each returned series at INDENT.
Each chart is titled with LABEL (when non-nil) and the series' group
tags.  Errors and empty results degrade to a short note rather than
aborting the surrounding render."
  (condition-case err
      (let ((series (betterdatadog--query-series query)))
        (if (null series)
            (betterdatadog--insert-note "no data" indent label)
          (betterdatadog--insert-series-group
           (mapcar (lambda (s)
                     (list :label (betterdatadog--join-label
                                   label (betterdatadog--series-tags s))
                           :points (alist-get 'pointlist s)
                           :unit (alist-get 'unit s)
                           :interval (alist-get 'interval s)))
                   series)
           indent)))
    (error
     (betterdatadog--insert-note
      (format "graph unavailable: %s" (error-message-string err))
      indent label))))

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

(defun betterdatadog--build-envs (qmap)
  "Fetch every query in QMAP (alist NAME->query spec) and align them.
Return one plist per series group, so a formula over `by {tag}' queries
is evaluated once per tag combination.  Each plist has :label (the group
tags, nil when ungrouped), :timeline (the sorted union of the group's
timestamps), :env (alist NAME->list-of-values aligned to :timeline) and
:interval (the sample spacing in seconds, when known).  An ungrouped
query contributes its single series to every group.  Timestamps are
truncated to integer milliseconds so series from separate requests
align exactly.  Returns nil when nothing has data."
  (let ((per-query '())
        (keys '())
        (interval nil))
    (dolist (pair qmap)
      (let ((groups '()))
        (dolist (s (betterdatadog--query-series (cdr pair)))
          (let ((key (betterdatadog--series-tags s))
                (iv (alist-get 'interval s))
                (h (make-hash-table :test 'eql)))
            (dolist (p (alist-get 'pointlist s))
              (let ((v (nth 1 p)))
                (puthash (truncate (nth 0 p)) (and (numberp v) v) h)))
            (when (and (numberp iv) (> iv 0))
              (setq interval (if interval (min interval iv) iv)))
            (push (cons key h) groups)
            (unless (or (string-empty-p key) (member key keys))
              (push key keys))))
        (push (cons (car pair) (nreverse groups)) per-query)))
    (setq per-query (nreverse per-query))
    (delq
     nil
     (mapcar
      (lambda (key)
        (let* ((maps
                (mapcar
                 (lambda (q)
                   (let ((groups (cdr q)))
                     (cons (car q)
                           (or (cdr (assoc key groups))
                               ;; An ungrouped query applies to every group.
                               (and (= (length groups) 1)
                                    (string-empty-p (caar groups))
                                    (cdar groups))))))
                 per-query))
               (ts-set (make-hash-table :test 'eql))
               (timeline '()))
          (dolist (m maps)
            (when (cdr m)
              (maphash (lambda (k _v) (puthash k t ts-set)) (cdr m))))
          (maphash (lambda (k _v) (push k timeline)) ts-set)
          (setq timeline (sort timeline #'<))
          (when timeline
            (list :label (unless (string-empty-p key) key)
                  :timeline timeline
                  :interval interval
                  :env (mapcar
                        (lambda (m)
                          (cons (car m)
                                (mapcar (lambda (ts)
                                          (and (cdr m) (gethash ts (cdr m))))
                                        timeline)))
                        maps)))))
      (or (nreverse keys) '(""))))))

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

(defun betterdatadog--insert-formula-graph (formula qmap indent &optional label)
  "Evaluate FORMULA over the named queries in QMAP and chart it at INDENT.
QMAP is an alist of NAME->query spec.  Grouped queries yield one chart
per group, each titled with LABEL (when non-nil) and the group's tags.
Failures degrade to a note."
  (condition-case err
      (let ((envs (betterdatadog--build-envs qmap))
            (group '())
            (constant nil)
            (failed nil))
        (dolist (e envs)
          (let ((result (betterdatadog--eval-formula formula (plist-get e :env)))
                (name (betterdatadog--join-label label (plist-get e :label))))
            (cond
             ((null result) (setq failed t))
             ;; A formula of constants only: there is nothing to chart.
             ((numberp result) (setq constant result))
             (t
              (push (list :label name
                          :points (cl-mapcar #'list
                                             (plist-get e :timeline) result)
                          :interval (plist-get e :interval))
                    group)))))
        (cond
         (group (betterdatadog--insert-series-group (nreverse group) indent))
         (constant
          (insert (make-string (+ indent 2) ?\s)
                  (propertize (concat "= " (betterdatadog--fmt constant))
                              'face 'betterdatadog-meta-face)
                  "\n"))
         (failed (betterdatadog--insert-note
                  "could not evaluate formula" indent label))
         ((null envs) (betterdatadog--insert-note "no data" indent label))))
    (error
     (betterdatadog--insert-note
      (format "graph unavailable: %s" (error-message-string err))
      indent label))))

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
  (let ((pad (make-string indent ?\s))
        (betterdatadog--display-type (alist-get 'display_type request)))
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
                          queries)))
             ;; With several queries or formulas, name each one so the
             ;; charts below can be told apart.
             (named (> (length qmap) 1)))
        ;; List each underlying query for transparency.
        (when betterdatadog-show-queries
          (dolist (query queries)
            (let ((spec (betterdatadog--query-spec query))
                  (name (alist-get 'name query)))
              (when spec
                (insert pad)
                (when (and named name)
                  (insert (propertize (concat name " = ")
                                      'face 'betterdatadog-meta-face)))
                (insert (propertize (betterdatadog--spec-query spec)
                                    'face 'betterdatadog-query-face))
                (insert "\n")))))
        (when betterdatadog-show-graphs
          (let ((betterdatadog--collector
                 (and (not scalar-window) (betterdatadog--svg-p)
                      (cons nil 0))))
            (if (and formulas qmap)
                ;; Chart the widget's actual formula(s), not the raw queries.
                (dolist (f formulas)
                  (let* ((fs (alist-get 'formula f))
                         (alias (alist-get 'alias f))
                         (alias (and (stringp alias)
                                     (not (string-empty-p alias))
                                     alias))
                         ;; A formula that is just a query name plots that query
                         ;; directly (so multi-series `by {tag}` queries keep
                         ;; all their series and units); anything else is
                         ;; evaluated.
                         (bare (and fs (assoc (string-trim fs) qmap)))
                         ;; Title the chart with the widget's alias, spelling
                         ;; out a computed formula when queries are shown.
                         (label (cond
                                 ((null fs) nil)
                                 ((null alias)
                                  (and (or (not bare) named (cdr formulas))
                                       (string-trim fs)))
                                 ((and (not bare) betterdatadog-show-queries)
                                  (format "%s = %s" alias (string-trim fs)))
                                 (t alias))))
                    (cond
                     ((null fs) nil)
                     (scalar-window
                      (when (and (not bare) betterdatadog-show-queries)
                        (insert (propertize (concat pad "  ↳ " fs "\n")
                                            'face 'betterdatadog-meta-face)))
                      (if bare
                          (betterdatadog--insert-scalar
                           (cdr bare) indent scalar-window)
                        (betterdatadog--insert-formula-scalar
                         fs qmap indent scalar-window)))
                     (bare
                      (betterdatadog--insert-graph (cdr bare) indent label))
                     (t
                      (betterdatadog--insert-formula-graph
                       fs qmap indent label)))))
              ;; No formulas: chart each query directly.
              (dolist (query queries)
                (let ((spec (betterdatadog--query-spec query)))
                  (when spec
                    (if scalar-window
                        (betterdatadog--insert-scalar spec indent scalar-window)
                      (betterdatadog--insert-graph
                       spec indent
                       (and named (alist-get 'name query))))))))
            (when betterdatadog--collector
              (betterdatadog--flush-collector indent))))))
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
      (setq betterdatadog--series-cache (make-hash-table :test 'equal)
            betterdatadog--window-end (float-time)))
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

;;;; Log search

(defvar betterdatadog--log-search-history nil
  "List of remembered log search query strings, most recent first.
Populated from `betterdatadog-log-search-history-file' on first use and
updated whenever a search runs successfully.")

(defvar betterdatadog--log-search-loaded nil
  "Non-nil once `betterdatadog-log-search-history-file' has been read.")

(defvar betterdatadog--log-search-prompt-history nil
  "Minibuffer history of log search queries entered this session.")

(defun betterdatadog--load-log-searches ()
  "Load remembered log searches from `betterdatadog-log-search-history-file'.
Reads the file at most once per session; a missing or unreadable file is
treated as an empty history.  Returns `betterdatadog--log-search-history'."
  (unless betterdatadog--log-search-loaded
    (setq betterdatadog--log-search-loaded t)
    (when (and betterdatadog-log-search-history-file
               (file-readable-p betterdatadog-log-search-history-file))
      (with-demoted-errors "betterdatadog: could not read log searches: %S"
        (with-temp-buffer
          (insert-file-contents betterdatadog-log-search-history-file)
          (let ((data (read (current-buffer))))
            (when (listp data)
              (setq betterdatadog--log-search-history data)))))))
  betterdatadog--log-search-history)

(defun betterdatadog--save-log-searches ()
  "Write `betterdatadog--log-search-history' to its history file."
  (when betterdatadog-log-search-history-file
    (with-demoted-errors "betterdatadog: could not save log searches: %S"
      (let ((dir (file-name-directory betterdatadog-log-search-history-file)))
        (when (and dir (not (file-directory-p dir)))
          (make-directory dir t)))
      (with-temp-file betterdatadog-log-search-history-file
        (insert ";; betterdatadog log search history -*- lexical-binding: t; -*-\n")
        (insert ";; Auto-generated; edit at your own risk.\n")
        (prin1 betterdatadog--log-search-history (current-buffer))
        (insert "\n")))))

(defun betterdatadog--remember-log-search (query)
  "Record that log search QUERY ran successfully.
Moves QUERY to the front of the history and persists it."
  (betterdatadog--load-log-searches)
  (setq betterdatadog--log-search-history
        (cons query (delete query betterdatadog--log-search-history)))
  (betterdatadog--save-log-searches))

(defun betterdatadog--read-log-search ()
  "Prompt for a log search query, offering remembered ones for completion.
Free input is allowed, so a brand-new query can still be typed in."
  (betterdatadog--load-log-searches)
  (let ((history betterdatadog--log-search-history))
    (string-trim
     (completing-read
      (if history
          "Datadog log search (TAB for past searches, empty for all): "
        "Datadog log search (empty for all): ")
      history
      nil nil nil
      'betterdatadog--log-search-prompt-history))))

(defun betterdatadog--search-logs (query limit window-seconds)
  "Search Datadog logs for QUERY over the last WINDOW-SECONDS.
Return up to LIMIT events (a list of API alists), newest first."
  (let ((body `((filter . ((query . ,query)
                           (from . ,(format "now-%ds" window-seconds))
                           (to . "now")))
                (sort . "-timestamp")
                (page . ((limit . ,limit))))))
    (alist-get 'data
               (betterdatadog--post-json "/api/v2/logs/events/search" body))))

(defun betterdatadog--log-field (attrs key)
  "Return KEY from a log event's ATTRS, falling back to its nested attributes.
Datadog nests the parsed log content under an inner `attributes' map while
exposing common fields like `service' at the top level, so check both."
  (or (alist-get key attrs)
      (alist-get key (alist-get 'attributes attrs))))

(defun betterdatadog--log-status-face (status)
  "Return the face for a log STATUS string."
  (pcase (and (stringp status) (downcase status))
    ((or "emergency" "alert" "critical" "error") 'betterdatadog-log-error-face)
    ((or "warning" "warn" "notice") 'betterdatadog-log-warn-face)
    (_ 'betterdatadog-log-info-face)))

(defun betterdatadog--format-log-time (timestamp)
  "Format an ISO TIMESTAMP as a local time string, or return it unchanged."
  (if (stringp timestamp)
      (condition-case nil
          (format-time-string "%Y-%m-%d %H:%M:%S" (date-to-time timestamp))
        (error timestamp))
    "—"))

(defun betterdatadog--insert-log-event (event)
  "Insert a single log EVENT alist as one or more lines.
The whole entry carries EVENT as a text property so
`betterdatadog-logs-show-detail' can recover it from point."
  (let* ((attrs (alist-get 'attributes event))
         (status (or (betterdatadog--log-field attrs 'status) ""))
         (service (or (betterdatadog--log-field attrs 'service) ""))
         (host (betterdatadog--log-field attrs 'host))
         (time (betterdatadog--format-log-time
                (betterdatadog--log-field attrs 'timestamp)))
         (message (or (betterdatadog--log-field attrs 'message) ""))
         (start (point)))
    (insert (propertize (format "%-19s " time) 'face 'betterdatadog-meta-face))
    (insert (propertize (format "%-9s" (upcase status))
                        'face (betterdatadog--log-status-face status)))
    (insert " ")
    (insert (propertize service 'face 'betterdatadog-widget-title-face))
    (when (and host (stringp host) (> (length host) 0))
      (insert (propertize (concat " @" host) 'face 'betterdatadog-meta-face)))
    (insert "\n")
    (when (and message (stringp message) (> (length (string-trim message)) 0))
      (insert (replace-regexp-in-string
               "^" "    " (string-trim-right message))
              "\n"))
    (add-text-properties
     start (point)
     (list 'betterdatadog-log-event event
           'help-echo "RET: show this event's fields and attributes"))))

(defun betterdatadog--render-logs (query events window-seconds)
  "Render log search results EVENTS for QUERY into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (let ((heading (if (string-empty-p query) "(all logs)" query)))
      (insert (propertize heading 'face 'betterdatadog-title-face) "\n")
      (insert (propertize (make-string (max 8 (length heading)) ?─)
                          'face 'betterdatadog-meta-face)
              "\n"))
    (insert (propertize
             (format "events: %d    window: last %s"
                     (length events)
                     (betterdatadog--format-duration window-seconds))
             'face 'betterdatadog-meta-face)
            "\n\n")
    (if (null events)
        (insert (propertize "(no matching log events)\n"
                            'face 'betterdatadog-meta-face))
      (dolist (event events)
        (betterdatadog--insert-log-event event)))
    (goto-char (point-min))))

(defvar betterdatadog--log-detail-buffer-name "*Datadog Log*"
  "Name of the buffer used to show a single log event's details.")

(defun betterdatadog--alist-p (value)
  "Return non-nil if VALUE looks like a parsed JSON object (an alist).
Detects a list whose first element is a (SYMBOL . _) cons, as produced by
`json-read' with `json-object-type' set to `alist'."
  (and (consp value)
       (consp (car value))
       (symbolp (caar value))))

(defun betterdatadog--log-leaf-string (value)
  "Render a non-collection log VALUE as a display string."
  (cond
   ((stringp value) value)
   ((numberp value) (format "%s" value))
   ((eq value t) "true")
   ((eq value :json-false) "false")
   ((null value) "—")
   ((symbolp value) (symbol-name value))
   (t (format "%S" value))))

(defun betterdatadog--insert-log-node (label value indent)
  "Insert a log detail node for VALUE at INDENT, prefixed by optional LABEL.
Recurses into nested objects (alists) and arrays (lists); any other value
is printed as a single field, with continuation lines kept aligned."
  (let ((pad (make-string indent ?\s)))
    (cond
     ;; Nested object: print the label, then each pair one level deeper.
     ((betterdatadog--alist-p value)
      (when label
        (insert pad (propertize (concat label ":")
                                'face 'betterdatadog-widget-title-face)
                "\n"))
      (dolist (pair value)
        (betterdatadog--insert-log-node (symbol-name (car pair)) (cdr pair)
                                        (if label (+ indent 2) indent))))
     ;; Non-empty array.
     ((consp value)
      (when label
        (insert pad (propertize (concat label ":")
                                'face 'betterdatadog-widget-title-face)
                "\n"))
      (let ((item-indent (if label (+ indent 2) indent)))
        (dolist (item value)
          (if (consp item)
              (betterdatadog--insert-log-node nil item item-indent)
            (insert (make-string item-indent ?\s)
                    "- " (betterdatadog--log-leaf-string item) "\n")))))
     ;; Leaf value.
     (t
      (insert pad)
      (when label
        (insert (propertize (concat label ": ") 'face 'betterdatadog-meta-face)))
      (insert (replace-regexp-in-string
               "\n" (concat "\n" pad "  ")
               (betterdatadog--log-leaf-string value))
              "\n")))))

(defun betterdatadog--render-log-detail (event)
  "Render the full fields and attributes of log EVENT into the current buffer."
  (let* ((inhibit-read-only t)
         (attrs (alist-get 'attributes event))
         (service (or (betterdatadog--log-field attrs 'service) "(log event)"))
         (status (or (betterdatadog--log-field attrs 'status) ""))
         (time (betterdatadog--format-log-time
                (betterdatadog--log-field attrs 'timestamp)))
         (heading (string-trim (format "%s    %s    %s"
                                       time (upcase status) service))))
    (erase-buffer)
    (insert (propertize heading 'face 'betterdatadog-title-face) "\n")
    (insert (propertize (make-string (max 8 (length heading)) ?─)
                        'face 'betterdatadog-meta-face)
            "\n\n")
    (betterdatadog--insert-log-node nil event 0)
    (goto-char (point-min))))

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

;; `betterdatadog-set-window' is defined at the end of the file, after the
;; log-search entry points, so it can dispatch on either buffer type.

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

(defvar betterdatadog--current-log-query nil
  "The log search query currently displayed in the buffer, for refresh.")
(make-variable-buffer-local 'betterdatadog--current-log-query)

(defvar betterdatadog-logs-mode-map (make-sparse-keymap)
  "Keymap for `betterdatadog-logs-mode'.

Intentionally empty, like `betterdatadog-mode-map': betterdatadog ships no
key bindings of its own.  Standard `special-mode' keys remain available
\(e.g. \\`q' to quit, \\`g' to re-run the search).  To open the event at
point in a detail buffer, bind `betterdatadog-logs-show-detail', e.g.:

  (with-eval-after-load \\='betterdatadog
    (define-key betterdatadog-logs-mode-map (kbd \"RET\")
                #\\='betterdatadog-logs-show-detail))")

(define-derived-mode betterdatadog-logs-mode special-mode "Datadog Logs"
  "Major mode for viewing Datadog log search results.

\\{betterdatadog-logs-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (when betterdatadog--current-log-query
                  (betterdatadog-search-logs betterdatadog--current-log-query))))
  (setq truncate-lines nil))

;;;###autoload
(defun betterdatadog-search-logs (query)
  "Search Datadog logs for QUERY and display the matching events.

Prompts for the search interactively, offering previously-used searches
for completion (an empty query matches everything).  The search is run
over the last `betterdatadog-log-search-window-seconds' and at most
`betterdatadog-log-search-limit' events are shown, newest first.

Queries that run successfully are remembered in
`betterdatadog-log-search-history-file' and offered for completion on
subsequent calls."
  (interactive (list (betterdatadog--read-log-search)))
  (setq query (string-trim query))
  (message "betterdatadog: searching logs%s..."
           (if (string-empty-p query) "" (format " for %s" query)))
  (let ((events (betterdatadog--search-logs
                 query
                 betterdatadog-log-search-limit
                 betterdatadog-log-search-window-seconds))
        (buffer (get-buffer-create betterdatadog-logs-buffer-name)))
    ;; The search succeeded, so remember a non-empty query for next time.
    (unless (string-empty-p query)
      (betterdatadog--remember-log-search query))
    (with-current-buffer buffer
      (unless (derived-mode-p 'betterdatadog-logs-mode)
        (betterdatadog-logs-mode))
      (setq betterdatadog--current-log-query query)
      (betterdatadog--render-logs
       query events betterdatadog-log-search-window-seconds))
    (pop-to-buffer buffer)
    (message "betterdatadog: %d log event%s" (length events)
             (if (= (length events) 1) "" "s"))))

(defun betterdatadog-logs-show-detail ()
  "Show the full fields and attributes of the log event at point.
Run in a `betterdatadog-logs-mode' buffer (e.g. bound to RET); the event
under point is rendered as an indented field tree in a separate buffer."
  (interactive)
  (let ((event (or (get-text-property (point) 'betterdatadog-log-event)
                   (get-text-property (line-beginning-position)
                                      'betterdatadog-log-event))))
    (unless event
      (user-error "No log event at point"))
    (let ((buffer (get-buffer-create betterdatadog--log-detail-buffer-name)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'special-mode)
          (special-mode))
        (betterdatadog--render-log-detail event))
      (pop-to-buffer buffer))))

(defun betterdatadog--current-window-seconds ()
  "Return the time window in seconds relevant to the current buffer.
A logs buffer uses the log search window; anything else (a dashboard) uses
the graph window."
  (if (derived-mode-p 'betterdatadog-logs-mode)
      betterdatadog-log-search-window-seconds
    betterdatadog-graph-window-seconds))

(defun betterdatadog-set-window (window)
  "Set the time window for this buffer to WINDOW and refresh.
In a dashboard buffer this is the graph window; in a logs buffer it is the
window the log search covers.  WINDOW is duration shorthand like \"30m\",
\"1h\", \"4h\", or \"1d\"; a bare number is seconds.

The change is buffer-local, and the buffer is refreshed over the new
window: a dashboard re-renders from its cached definition (only graph data
is re-fetched), a logs buffer re-runs its current search."
  (interactive
   (list (read-string
          (format "Time window (e.g. 30m, 1h, 4h, 1d) [current %s]: "
                  (betterdatadog--format-duration
                   (betterdatadog--current-window-seconds))))))
  (let ((secs (betterdatadog--parse-duration window)))
    (when (<= secs 0)
      (user-error "Window must be positive"))
    (cond
     ((derived-mode-p 'betterdatadog-logs-mode)
      (unless betterdatadog--current-log-query
        (user-error "No log search associated with this buffer"))
      (setq-local betterdatadog-log-search-window-seconds secs)
      (betterdatadog-search-logs betterdatadog--current-log-query))
     (t
      (setq-local betterdatadog-graph-window-seconds secs)
      ;; The window changed, so cached series no longer match; force a refetch.
      (setq betterdatadog--series-cache nil)
      (if betterdatadog--current-dashboard
          (betterdatadog--render-dashboard betterdatadog--current-dashboard)
        (betterdatadog-refresh))))
    (message "betterdatadog: window set to %s"
             (betterdatadog--format-duration secs))))

(provide 'betterdatadog)

;;; betterdatadog.el ends here
