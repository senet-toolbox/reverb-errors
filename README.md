# reverb-errors

Crash reports from [vapor](https://github.com/senet-toolbox/vapor) apps,
kept in the app's own Postgres. Part of the
[Senet](https://github.com/senet-toolbox) toolbox:

- the app's [reverb](https://github.com/senet-toolbox/reverb) backend
  creates the tables and installs a route its vapor frontend posts
  crashes to;
- a dashboard reads them back. [ryven](https://github.com/vic-Rokx/ryven)'s
  `/errors` page is built on `read`.

Nothing leaves your infrastructure: the reports go from your frontend to
your backend, into your database.

## Use it

```zig
// build.zig.zon: `zig fetch --save git+https://github.com/senet-toolbox/reverb-errors#<commit>`
const reverb_errors = @import("reverb_errors");

// At start, after opening the pool: creates whatever tables and indexes
// are missing, so it is safe every time.
try reverb_errors.migrate(pool);

// POST /errors/report, recorded on a worker of its own.
try reverb_errors.install(&server, pool, .{
    .allowed_origin = "https://app.example",
}, gpa, io);
defer reverb_errors.deinit(); // after `listen` returns, before `server.deinit`
```

`Options`: `path` (`/errors/report`), `allowed_origin`, `threads` (1) and
`queue` (64; past it a report answers 503).

The route answers `201 {"group_id": "...", "report_id": "..."}`, `400` for
a body that is not a report, `403` for a browser on another origin, and
`500` when the database fails.

## What is kept

A report is the JSON in `src/Report.zig`: the error (`type`, `message`,
whether it was a wasm trap, the crash site and the stack), the events
before it, the route, URL, session, release and environment, the crashed
callback's arguments, and the request in flight.

Reports of the same error at the same place share a group, by
fingerprint: SHA-256 of the type, crash function, file, line and message.
A group seen again counts once more; a resolved one becomes `regressed`,
and an ignored one stays ignored.

The tables are `error_groups`, `error_reports`, `stack_frames` and
`trace_events`, as pg-orm models in `src/schema.zig`. Deleting a group
deletes its reports, and theirs.

## Security

Anyone can post to the route, as with any crash reporter. What it protects
is the database:

- each report is cut to `Report.limits`: 64 frames, the last 100 events,
  and 8 KB or 1 KB per string;
- it is written in one transaction, with bound parameters only;
- with `allowed_origin`, browsers on other sites are refused. Requests
  without an `Origin` (not from a browser) are let through.

Set your server's `max_body_size` for the largest report you accept, and
rate-limit the route in front of it if made-up reports are a concern.

## Tests

```sh
TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres zig build test
```

They work in a schema of their own, `reverb_errors_test`, and drop it.
One of them runs reverb's original SQL (`src/testdata`) beside `migrate`
and checks the two schemas match column for column, constraint for
constraint and index for index. Without a database they skip, saying so.

## License

MIT
