# concurrency/24-concurrent-rest — back-pressure and overload shedding

Compendium reference:
[Doc 24 — Concurrent REST Endpoints](../../../_docs/24-concurrent-rest-endpoints.md)

The runnable companion to compendium Doc 24. The one-line takeaway:
**an async server that can accept work faster than it can finish it needs
an explicit, cheap rejection path** — a bounded in-flight-request counter
and an HTTP 503 answered straight from that counter, before a handler ever
runs, so the act of shedding load never consumes the capacity it's
protecting.

## What it demonstrates

Two binaries, both built from the same minimal Boost.Asio/Beast,
C++20-coroutine stack as Doc 24's session code:

- [`src/rest_server.cpp`](src/rest_server.cpp) — an async HTTP server
  bound to `127.0.0.1:18080`. Every accepted connection is handled by one
  `boost::asio::awaitable` coroutine (`co_spawn`'d from the acceptor loop),
  matching the chapter's session pattern exactly: read the request, decide,
  write the response, close (this demo always sends `Connection: close` —
  one request per connection, by design, so graceful shutdown never has to
  wait out an idle keep-alive connection). A small in-flight-request cap
  (`--cap`, default 16) is enforced with a single `std::atomic<int>`:
  incremented optimistically when a request is read, decremented
  immediately if that pushed the count over the cap (the shed path), or
  held until the response is written if it didn't (the accepted path). A
  short simulated-work delay (`--work-ms`, default 15 — an async
  `steady_timer`, never a blocking sleep) stands in for real handler work,
  just long enough that concurrent requests actually overlap instead of
  draining one at a time faster than the cap could ever be observed.
  `SIGINT`/`SIGTERM` closes the acceptor and lets `io_context::run()`
  return once every in-flight session finishes, draining the server and
  exiting with code 0.
- [`src/rest_client.cpp`](src/rest_client.cpp) — a concurrent HTTP load
  generator on the same stack, used in place of `wrk`/`hey` so the whole
  demo builds from one `conanfile.txt`. `--concurrency` worker coroutines
  each claim one unit of work at a time from a shared atomic counter and
  issue one GET over a fresh connection; the number of requests actually
  in flight against the server at any instant is bounded by
  `--concurrency`, which is the knob this demo turns above and below the
  server's `--cap`.
- [`src/cli.hpp`](src/cli.hpp) — the tiny `--flag value` parser both
  binaries share, so the two CLIs don't drift.

Both binaries print one `key=value`-style summary line — `rest_client`'s
is the one `verify.lua` parses:

```
SUMMARY requests=400 status_200=210 status_503=190 other_errors=0 min_ms=0.512 median_ms=16.204 max_ms=42.881
```

This is the project's **first example to use Boost** (`boost/1.84.0`, for
Asio + Beast). See [`conanfile.txt`](conanfile.txt) for why most of Boost
is disabled via `without_<lib>` before the first build — Asio and Beast
are both header-only, so the only compiled piece either needs is
Boost.System, and the trimmed option set was verified with
`conan graph info` to resolve to Boost + its `b2` build tool only, with no
transitive `zlib`/`bzip2`/`libiconv`/`libbacktrace`.

## Verification: verify.lua

Unlike the batch-binary demos in this project, this `verify.lua` is an
orchestrator, not just an assertion runner: it starts `rest_server` in the
background, polls for its readiness file, drives it through two
`rest_client` phases, then shuts it down and checks the result.

1. **Warmup (hard assertion).** `--concurrency` set *below* `--cap`, so
   the number of requests in flight against the server can never exceed
   the cap. Every response must be `200`; a single `503` here is a FAIL,
   since it would mean the server is shedding below capacity.
2. **Overload (hard assertion).** `--concurrency` set well *above*
   `--cap`. Every response must still be `200` or `503` — `other_errors`
   (a connect/write/read failure, a timeout, or any other status) must be
   exactly `0`, proving no request was dropped, reset, or left hanging.
   At least one `503` is required (proof the cap was actually exceeded)
   and at least one `200` is required (proof the server still did the
   accepted work, not just shedding everything).
3. **Clean shutdown (hard assertion).** `verify.lua` reads the server's
   PID file, sends `SIGTERM`, and asserts the process exits with code `0`
   — the graceful-drain path from Doc 24's "Running in a container"
   section. A background `SIGKILL` watchdog (default 8s) turns a stuck
   drain into a FAIL instead of an indefinite hang.
4. **Latency (soft).** Min/median/max latency for `200` responses in each
   phase is printed for information; nothing in `verify.lua` asserts on
   its value.

`verify.lua` exits `0` on pass and non-zero on any hard failure, printing
a readable summary of both client phases and the server shutdown either
way.

### Why the two-phase design, not just one overload run

A single run at high concurrency can show 503s appearing, but it can't by
itself prove they *only* appear once the cap is exceeded — a server that
sheds randomly, or always, would also produce a mix of 200s and 503s under
one noisy run. Running warmup strictly below the cap first establishes a
deterministic zero-503 baseline (bounded by client concurrency, not by
timing or host load), so the overload phase's 503s can only be explained
by the cap actually having been exceeded.

## Running it

```bash
./demo.sh            # build + run rest_server + rest_client + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-24-concurrent-rest.sh`](../../../scripts/test-concurrency-demo-24-concurrent-rest.sh).

No host port mapping is needed or used: `rest_server` binds
`127.0.0.1:18080` and `rest_client` runs in the same container, both
started and torn down by `verify.lua`.

### Tuning via environment variables

| Variable                      | Default | Meaning                                  |
|--------------------------------|---------|-------------------------------------------|
| `REST_PORT`                   | 18080   | Server listen port                        |
| `REST_CAP`                    | 16      | In-flight-request shed threshold          |
| `REST_WORK_MS`                | 15      | Simulated per-accepted-request work (ms)  |
| `REST_WARMUP_CONCURRENCY`     | 8       | Client concurrency, warmup phase          |
| `REST_WARMUP_REQUESTS`        | 40      | Total requests, warmup phase              |
| `REST_OVERLOAD_CONCURRENCY`   | 80      | Client concurrency, overload phase        |
| `REST_OVERLOAD_REQUESTS`      | 400     | Total requests, overload phase            |
| `REST_CLIENT_TIMEOUT_MS`      | 5000    | Per-request client-side deadline          |

## Layout

```
24-concurrent-rest/
├── src/rest_server.cpp   Beast async HTTP server, in-flight cap, 503 shed, SIGTERM drain
├── src/rest_client.cpp   Beast async concurrent load generator
├── src/cli.hpp           shared "--flag value" CLI parser
├── conanfile.txt         [requires] boost/1.84.0, trimmed to Asio+Beast+System
├── CMakeLists.txt        C++20, find_package(Boost COMPONENTS system), -O2, two targets
├── Containerfile         UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua            Lua 5.4 orchestrator: start server, two client phases, SIGTERM
├── demo.sh               the driver (docker build + docker run)
└── README.md             this file
```

## Convention this example follows

Same directory shape, `verify.lua` contract, `demo.sh` contract, and CI
wrapper contract as
[20-mechanical-sympathy](../20-mechanical-sympathy/README.md#convention-this-example-establishes)
— the one addition here is that `verify.lua` itself manages a background
process (the server) across the whole run, rather than just invoking one
batch binary per trial.
