# CLAUDE.md

This file provides guidance to coding agents (claude.ai/code) when working with code in this repository.

## What this is

`betterdatadog` is a single-file Emacs Lisp package (`betterdatadog.el`) that
fetches Datadog dashboards over the HTTP API and renders them — title,
description, widgets (recursing into group widgets), the metric queries behind
each widget, and live Unicode sparkline graphs — inside an Emacs buffer. It has
no external dependencies beyond built-in Emacs libraries (`url`, `json`,
`auth-source`, `subr-x`, `cl-lib`); minimum Emacs is 27.1.

## Commands

There is no build system, package manager, or test suite. Everything is the one
`.el` file. The only mechanical check is byte-compilation, which surfaces
warnings (free variables, unused locals, arity errors):

```sh
emacs -Q --batch -L . -f batch-byte-compile betterdatadog.el && rm -f betterdatadog.elc
```

Smoke-test pure (non-network) functions by loading the file in batch mode and
calling them via `--eval`, pointing any file-writing customs at `/tmp`, e.g.:

```sh
emacs -Q --batch -L . -l betterdatadog --eval '(progn (setq betterdatadog-history-file "/tmp/h.el") ...)'
```

Anything touching `betterdatadog--get` / `--prefetch` hits the live Datadog API
and needs real credentials, so it can't run headless without keys.

## Architecture

The file is organized top-to-bottom by `;;;;` section headers, and the runtime
flows through them in order:

1. **Authentication / configuration helpers** — `betterdatadog--api-key` /
   `--app-key` resolve credentials, preferring the `betterdatadog-api-key` /
   `-app-key` customs and falling back to `auth-source` (host `api.<site>`,
   logins `DD-API-KEY` / `DD-APPLICATION-KEY`). `betterdatadog-site` selects the
   region and therefore the API host.
2. **HTTP** — `betterdatadog--get` is the single synchronous GET primitive. It
   parses JSON into alists (`json-object-type 'alist`, `json-array-type 'list`)
   and signals a `user-error` on any non-2xx response or transport failure. A
   failed fetch never returns — callers downstream of it only run on success.
3. **Querying & sparklines** — the data-fetch pipeline. `--collect-queries`
   walks the widget tree (recursing into groups, skipping notes) and returns the
   de-duplicated list of *resolved* queries. `--prefetch` fires all of them
   concurrently via async `url-retrieve` into `betterdatadog--series-cache` (a
   hash table), pumping the event loop until they return or
   `betterdatadog-fetch-timeout` elapses; misses fall back to synchronous fetch
   at render time via `--query-series`. This parallelism is why a board loads in
   roughly the time of its slowest single query.
4. **Formula evaluation** — widgets can define formulas over named queries
   (e.g. `sum / count`). The formula is evaluated point-by-point across the
   component series so the chart shows the value the widget actually represents,
   not the raw components.
5. **Rendering** — draws the buffer: title, widgets, optional query strings,
   and multi-row sparklines.
6. **Dashboard id history** — `--load-history` / `--save-history` /
   `--remember-dashboard` persist successfully-fetched ids (with titles) to
   `betterdatadog-history-file`, loaded lazily once per session.
   `--read-dashboard-id` offers them via `completing-read` for the interactive
   prompt while still accepting free input.
7. **Mode and entry points** — `betterdatadog-mode` (derives from
   `special-mode`) and the user commands.

### Key cross-cutting concepts

- **Template variables** (e.g. `$model_name`) are resolved from the dashboard's
  defaults before querying. `betterdatadog--resolve-query` is the chokepoint;
  `--collect-queries` and the cache key both operate on *resolved* query
  strings, so resolution must happen before anything keys on a query.
- **`betterdatadog--series-cache`** is the contract between prefetch and render.
  A present-but-empty value is a valid cached result (honoured, not refetched);
  `'miss` means not yet fetched. Operations that invalidate the data — an
  explicit refresh, or changing the time window — set the cache to `nil` to
  force a refetch. Toggling graphs/queries deliberately *keeps* the cache and
  the cached dashboard alist (`betterdatadog--current-dashboard`) so re-renders
  are instant.
- **Buffer-local state**: `betterdatadog--current-dashboard-id`,
  `--current-dashboard`, and the display toggles (`-show-graphs`,
  `-show-queries`, `-graph-window-seconds`) are set buffer-locally by commands
  so each dashboard buffer is independent.

## Conventions

- The package **ships no key bindings** — `betterdatadog-mode-map` is
  intentionally empty so it never clobbers a user's setup. Don't add default
  bindings; document example bindings in the README instead (note the README's
  Evil section: Evil state maps shadow major-mode single-key bindings).
- Private functions/vars use the `betterdatadog--` (double-dash) prefix; public
  ones use a single dash. Every public symbol is a `defcustom`, `defface`,
  interactive command, or the autoloaded entry point.
- User-facing failures use `user-error` (not `error`), and messages are
  prefixed `betterdatadog: `.
- Keep the README in sync when adding customs or commands — it documents the
  full surface (customs, command table, graph behavior, example output).
