# betterdatadog

A better Datadog client for Emacs.

## Features

- **`betterdatadog-show-dashboard`** — fetch a Datadog dashboard by id and render
  it in an Emacs buffer: title, description, and every widget (recursing into
  group widgets) with the metric queries that power it.
- **Live graphs** — betterdatadog fetches the last hour of data (via the
  Datadog query API) and charts it: as an inline **SVG image** in graphical
  Emacs (lines, stacked areas or bars following the widget's display type,
  all of a widget request's series overlaid in colour), or as multi-row
  **Unicode block charts** in a terminal. Either way you get a labelled
  y-axis, a time axis, and a `min · avg · max · last` summary per series,
  each named by the widget's alias and, for `by {tag}` queries, its tags. When a widget defines a **formula** (e.g. an
  average rendered as `sum / count`), the formula is evaluated point-by-point
  over its named queries (once per tag group) and that result is charted — so
  you see the real value the widget represents, not the raw component series.
  Template variables
  (e.g. `$model_name`) are resolved from the dashboard's defaults before
  querying. Toggle with `betterdatadog-toggle-graphs`; set the size with
  `betterdatadog-graph-height` and `betterdatadog-sparkline-width`.

- **Remembered dashboard ids** — every id that fetches successfully is saved
  (with its title) to `betterdatadog-history-file`, so next time
  `betterdatadog-show-dashboard` offers it for completion — `TAB` to pick a
  remembered dashboard instead of pasting the id again. Set the variable to
  `nil` to disable persistence.

- **`betterdatadog-search-logs`** — search Datadog logs from Emacs. It prompts
  for a query, runs it against the Logs Search API, and lists the matching
  events (timestamp, status, service, host, and message) newest-first in a
  buffer. Every query that runs successfully is saved to
  `betterdatadog-log-search-history-file`, so next time you can hit `TAB` at the
  prompt and pick a past search instead of retyping it (an empty query matches
  everything). The window (`betterdatadog-log-search-window-seconds`, default
  the last 15 minutes) and page size (`betterdatadog-log-search-limit`, default
  `100`) are configurable.

More to come (monitors, metric explorer).

## Install

`betterdatadog` has no external dependencies (it uses the built-in `url.el` and
`json.el`). Put `betterdatadog.el` on your `load-path` and:

```elisp
(require 'betterdatadog)
```

## Configure

Set the site (region) for your account, and provide an API key + application key.

```elisp
(setq betterdatadog-site "datadoghq.com")  ;; or us3.datadoghq.com, datadoghq.eu, ...
(setq betterdatadog-api-key "...")
(setq betterdatadog-app-key "...")
```

Prefer not to put keys in your init file? Leave them `nil` and store them via
`auth-source` (e.g. `~/.authinfo.gpg`):

```
machine api.datadoghq.com login DD-API-KEY password <your-api-key>
machine api.datadoghq.com login DD-APPLICATION-KEY password <your-app-key>
```

(Use the host matching `betterdatadog-site`, prefixed with `api.`.)

## Use

```
M-x betterdatadog-show-dashboard RET <dashboard-id> RET
```

The dashboard id is the slug in the dashboard URL, e.g. the `abc-def-ghi` in
`https://app.datadoghq.com/dashboard/abc-def-ghi/`.

Once an id has been fetched successfully it is remembered, so on later calls
you can hit `TAB` at the prompt and pick it (each candidate is annotated with
the dashboard title) instead of pasting the id again.

The dashboard buffer derives from `special-mode`, so the usual read-only
keys apply (`q` quits, `g` reverts/refreshes, `SPC`/`DEL` scroll).

### Searching logs

```
M-x betterdatadog-search-logs RET <query> RET
```

The query is a Datadog [log search](https://docs.datadoghq.com/logs/explorer/search_syntax/)
string, e.g. `service:web status:error`; leave it empty to match everything.
Results open in a `special-mode` buffer (so `q` quits and `g` re-runs the
search), one entry per event. Past searches are remembered and offered for
completion (`TAB`) on later calls.

To inspect a single event, put point on its entry and run
`betterdatadog-logs-show-detail` — it opens a buffer with the event's full
fields and attributes (including nested objects, tags, and the parsed log
content) as an indented tree. Like the rest of the package it ships no
binding, so wire it up yourself, e.g. to `RET`:

```elisp
(with-eval-after-load 'betterdatadog
  (define-key betterdatadog-logs-mode-map (kbd "RET")
              #'betterdatadog-logs-show-detail))
```

The search covers the last `betterdatadog-log-search-window-seconds` (default
15 minutes). Change it for the current buffer with `betterdatadog-set-window`
(the same command used for dashboard graphs — it adapts to the buffer it's run
in) and type a duration like `15m`, `1h`, `4h`, `1d`, or a bare number of
seconds; the search re-runs over the new window.

### Commands and key bindings

betterdatadog **ships no key bindings of its own** — bind the commands
however you like. The interactive commands are:

| Command                          | Action                                  |
|----------------------------------|-----------------------------------------|
| `betterdatadog-refresh`          | Re-fetch the board and graph data       |
| `betterdatadog-toggle-graphs`    | Toggle graphs on/off                    |
| `betterdatadog-toggle-queries`   | Toggle the query strings on/off         |
| `betterdatadog-set-window`       | Set the time window (`30m`/`4h`…)        |
| `betterdatadog-search-logs`      | Search logs and list matching events    |
| `betterdatadog-logs-show-detail` | Show the log event at point's full fields|

`betterdatadog-toggle-queries` hides the metric query text for a clean,
graph-only view (`betterdatadog-show-queries`, default `t`). Toggling
queries or graphs re-renders instantly by reusing already-fetched data;
`betterdatadog-refresh` and `betterdatadog-set-window` discard the cache
and re-fetch.

Example bindings:

```elisp
(with-eval-after-load 'betterdatadog
  (define-key betterdatadog-mode-map (kbd "g") #'betterdatadog-refresh)
  (define-key betterdatadog-mode-map (kbd "t") #'betterdatadog-toggle-graphs)
  (define-key betterdatadog-mode-map (kbd "s") #'betterdatadog-toggle-queries)
  (define-key betterdatadog-mode-map (kbd "w") #'betterdatadog-set-window))
```

#### Evil

Evil's state keymaps shadow a major mode's own single-key bindings, so
under [Evil](https://github.com/emacs-evil/evil) you'll want to bind into
a state and/or mark the map as overriding yourself, e.g.:

```elisp
(with-eval-after-load 'evil
  (evil-set-initial-state 'betterdatadog-mode 'motion)   ; keep j/k scrolling
  (evil-define-key 'motion betterdatadog-mode-map
    (kbd "t") #'betterdatadog-toggle-graphs
    (kbd "s") #'betterdatadog-toggle-queries
    (kbd "w") #'betterdatadog-set-window
    (kbd "gr") #'betterdatadog-refresh))
```

Graphs are controlled by `betterdatadog-show-graphs` (default `t`),
`betterdatadog-graph-window-seconds` (default `3600`),
`betterdatadog-graph-height` (default `6`), and
`betterdatadog-sparkline-width` (default `72`).

`betterdatadog-graph-style` (default `auto`) picks the renderer: `auto`
draws SVG images when Emacs is running graphically with SVG support and
Unicode charts otherwise; `svg` and `unicode` force one or the other.

**SVG graphs.** Everything one widget request plots — all its formulas and
all the series of a `by {tag}` query — shares a single chart, as in Datadog.
The request's `display_type` decides the shape: lines are overlaid, while
`area` and `bars` are stacked. Short holes in a line are bridged and longer
outages show as breaks. A legend under the image gives each series its colour
(from `betterdatadog-series-colors`), label and summary as ordinary,
searchable text. The plot is `betterdatadog-sparkline-width` text columns
wide and `betterdatadog-svg-height` pixels tall (default `140`). Axis colours
come from `betterdatadog-meta-face` when the chart is drawn, so after
switching theme run `betterdatadog-toggle-graphs` twice (or refresh) to
redraw. With `betterdatadog-graph-shared-scale` set to `nil`, each series gets
its own chart.

**Unicode graphs** draw one chart per series:

```
  provider:gemma
  15.7/s ┤          ▄▁ ▁▅  ▂▇▅▁▃▂▁▂▆▂▃▁ ▁ █▄▂▂ ▂▃
         │       ▆▇▇██▄██▇▅████████████▇█▃████▇██
       0 ┤▂▂█▅████▆██████████████████████████████
         └┬─────────────────┬──────────────────┬
          23:16           23:46            00:16
  min 0.05/s · avg 10.9/s · max 15.7/s · last 7.9/s
```

Common to both:

- **Y-axis** — labelled top and bottom, with compact values (`1.23K`,
  `4.5M`) in the metric's unit where Datadog reports one (`145ms`,
  `30.7GiB`, `1.5K req/s`). It includes zero by default, like Datadog's own
  graphs; set `betterdatadog-graph-include-zero` to `nil` to span only the
  data's min..max instead.
- **Time axis** — points are placed by timestamp across the whole window, so
  a series that only reported for part of it appears in the right place, and
  every chart on the board lines up. Columns with no data are left blank.
- **Downsampling** — when there are more points than columns, each column
  shows the largest value that falls in it, so short spikes stay visible.
- **Grouped queries** — the series of a `by {tag}` query are each labelled
  with their tags and share a y-axis so they can be compared; set
  `betterdatadog-graph-shared-scale` to `nil` to scale each series on its
  own. At most `betterdatadog-max-series` (default `10`) are drawn per query
  — the ones with the highest averages — and the rest are counted in a note;
  set it to `nil` for no limit.
- **Colours** — customize `betterdatadog-series-face` (series labels),
  `betterdatadog-graph-face` (Unicode bars) and `betterdatadog-series-colors`
  (SVG series).

Graph data is fetched **in parallel** before rendering: each distinct
query is requested once (duplicates across widgets are de-duplicated) and
all requests run concurrently, so a board's load time is roughly the
slowest single query rather than the sum of them all.
`betterdatadog-fetch-timeout` (default `30` seconds) bounds the wait;
any query that hasn't responded by then is fetched on demand as the
dashboard renders.

Each graph shows a rolling `now − window … now` range (default the last
hour), the same for every widget; the header line shows the current
window. Use `betterdatadog-set-window` and type a duration like `30m`,
`1h`, `4h`, `1d`, or a bare number of seconds to change it for the
current buffer.

## Example output

```
Web Service Overview
────────────────────
Key health metrics for the web tier.

id: abc-def-ghi    layout: ordered    widgets: 4

▸ Time to first token (avg)  [timeseries]
  query1 = sum:ttft_seconds.sum{*}.as_count()
  query2 = sum:ttft_seconds.count{*}.as_count()
    [SVG line chart]
    ━━ ttft = query1 / query2  min 0.08 · avg 0.31 · max 0.51 · last 0.45

▸ Errors  [group]
  ▸ 5xx count  [query_value]
    sum:trace.http.request.errors{*}
    last 2
  ▸ Top error endpoints  [toplist]
    top(sum:errors{*} by {resource}, 10, "sum", "desc")
```
