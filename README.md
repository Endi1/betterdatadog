# betterdatadog

A better Datadog client for Emacs.

## Features

- **`betterdatadog-show-dashboard`** — fetch a Datadog dashboard by id and render
  it in an Emacs buffer: title, description, and every widget (recursing into
  group widgets) with the metric queries that power it.
- **Live graphs** — betterdatadog fetches the last hour of data (via the
  Datadog query API) and draws a multi-row Unicode chart (scale-labelled, with
  a `last` value below it). When a widget defines a **formula** (e.g. an
  average rendered as `sum / count`), the formula is evaluated point-by-point
  over its named queries and that result is charted — so you see the real
  value the widget represents, not the raw component series. Template variables
  (e.g. `$model_name`) are resolved from the dashboard's defaults before
  querying. Toggle with `t`; set the size with `betterdatadog-graph-height` and
  `betterdatadog-sparkline-width`.

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

In the dashboard buffer:

| Key | Action                                         |
|-----|------------------------------------------------|
| `g` | Refresh (re-fetch the board and graph data)    |
| `t` | Toggle graphs on/off                           |
| `s` | Toggle the query strings on/off                |
| `w` | Set the graph time window (e.g. `30m`/`4h`)    |
| `q` | Quit the window                                |

`s` hides the metric query text for a clean, graph-only view (controlled
by `betterdatadog-show-queries`, default `t`). Toggling queries or graphs
re-renders instantly by reusing already-fetched data; `g` and `w` discard
the cache and re-fetch.

### Evil

If [Evil](https://github.com/emacs-evil/evil) is loaded, betterdatadog
opens dashboards in Evil **motion state** and overrides it so the keys
above work (otherwise Evil's own `g`/`s`/`w`/`t`/`q` would shadow them);
`j`/`k` and other motions still scroll. This applies to dashboards opened
after Evil is loaded — re-open an already-visible buffer if the keys were
shadowed before.

Graphs are controlled by `betterdatadog-show-graphs` (default `t`),
`betterdatadog-graph-window-seconds` (default `3600`),
`betterdatadog-graph-height` (default `6`), and
`betterdatadog-sparkline-width` (default `72`).

Graph data is fetched **in parallel** before rendering: each distinct
query is requested once (duplicates across widgets are de-duplicated) and
all requests run concurrently, so a board's load time is roughly the
slowest single query rather than the sum of them all.
`betterdatadog-fetch-timeout` (default `30` seconds) bounds the wait;
any query that hasn't responded by then is fetched on demand as the
dashboard renders.

Each graph shows a rolling `now − window … now` range (default the last
hour), the same for every widget; the header line shows the current
window. Press `w` and type a duration like `30m`, `1h`, `4h`, `1d`, or a
bare number of seconds to change it for the current buffer.

## Example output

```
Web Service Overview
────────────────────
Key health metrics for the web tier.

id: abc-def-ghi    layout: ordered    widgets: 4

▸ Time to first token (avg)  [timeseries]
  sum:ttft_seconds.sum{*}.as_count()
  sum:ttft_seconds.count{*}.as_count()
    ↳ query1 / query2
       ▂▃ ▄  ▃           ┈ 0.51
     ▃█████▆█▅▃
  ▂▅████████████▇▅▃▂      ┈ 0.08
  last 0.45

▸ Errors  [group]
  ▸ 5xx count  [query_value]
    sum:trace.http.request.errors{*}
    last 2
  ▸ Top error endpoints  [toplist]
    top(sum:errors{*} by {resource}, 10, "sum", "desc")
```
