# concurrency/29-observing-concurrency — instrumented thread pool + LGTM stack

Compendium reference:
[Doc 29 — Observing Concurrency](../../../_docs/29-observing-concurrency.md)

The runnable companion to compendium Doc 29, and this tutorial's first
**multi-container** demo. Every earlier example built one Containerfile and
ran one `docker run`; this one is a `docker compose` stack — the
instrumented service, the `grafana/otel-lgtm` all-in-one observability
backend, and a verifier — modeled on the `lgtm-docker-stack` skill's
compose/collector/Grafana-datasource approach.

The one-line takeaway: **thread-safety and correct propagation are
different guarantees.** The OpenTelemetry SDK is safe to call from any
thread without external locking; nothing about that safety connects a span
created on a pool's worker thread to the request that submitted the task,
unless the submitting thread explicitly hands its `Context` across the
hop. Get that wrong and the symptom is a dashboard full of disconnected
single-span traces where a nested request tree was expected — and nothing
in the SDK will tell you it happened.

## What it demonstrates

[`src/instrumented_pool.cpp`](src/instrumented_pool.cpp) is a ch15-style
single-queue thread pool (one mutex + `condition_variable`-guarded deque)
extended with:

- **A trace per request, nested correctly across the pool's thread hop.**
  `handle_request` starts a `request.handle` root span, then for each of
  its `tasks_per_request` pool tasks captures the *current*
  `opentelemetry::context::Context` (which includes that root span, because
  the request's `Scope` is still active) and hands it to `pool.submit()`.
  On the worker thread — a different call stack entirely — that captured
  `Context` is set as `StartSpanOptions::parent` before the `pool.task`
  child span is created. No `RuntimeContext::Attach`/thread-local `Scope`
  juggling is needed on the worker side; an explicit parent field does the
  same job more directly for this one-shot, fire-into-a-pool hand-off.
- **A queue-depth `UpDownCounter`** (`pool_queue_depth`): +1 the instant a
  task is pushed onto the queue, -1 the instant a worker pops it back off.
  That is saturation made visible, not inferred from latency.
- **Explicit flush before exit.** This is a short-lived batch process, not
  a long-running service — the SDK's default multi-second batch/export
  intervals would let the whole run finish before the first scheduled
  export. Both the span batch processor and the periodic metric reader use
  short intervals (500ms), and `shutdown_telemetry()` still calls
  `ForceFlush()` on both providers before the process exits, exactly the
  fix the compendium chapter's "Running in a container" section describes.

With the compose defaults (24 requests × 3 tasks on a 2-worker pool), 72
tasks land on 2 workers almost immediately; the queue backs up to roughly
70 before draining over a couple of seconds — comfortably inside both the
metric reader's export window and a window the verifier's own retries can
tolerate.

## Topology

```
service ──OTLP/HTTP──▶ lgtm (grafana/otel-lgtm, all-in-one)
                         ├─ embedded OTel Collector (:4317 grpc, :4318 http)
                         ├─ Tempo   (traces,  :3200)
                         ├─ Mimir   (metrics, :9090, Prometheus-compatible API)
                         ├─ Loki    (logs,    :3100 — unused by this demo)
                         └─ Grafana (:3000)

verifier ──curl──▶ lgtm:3200 (Tempo search + trace fetch)
verifier ──curl──▶ lgtm:9090 (Prometheus-compatible query API)
```

Two containers (`service`, `verifier` — both built from the same
multi-stage `Containerfile`, different `--target`) plus one upstream image
(`lgtm`). The service reaches the collector embedded in that one image at
`http://lgtm:4318` — **service-name DNS, never `localhost`** — the
single most common first-run mistake this whole stack class has, per the
`lgtm-docker-stack` skill's own known-issues notes.

This is the simpler of the two topologies the compendium chapter
describes (service → standalone Collector → separate Tempo/Mimir/Loki
containers is the other). Given this is the series' most complex demo, the
fewer moving parts that still prove propagation and saturation, the
better: one upstream image instead of a standalone Collector plus three
backend containers.

**No ports are published to the host.** The verifier runs inside the
compose network and reaches `lgtm` by service name, so there's nothing for
a host port mapping to do by default. To look around in Grafana while the
stack is up, add `ports: ["3000:3000"]` under the `lgtm` service yourself.

## Verification: verify.lua

Same **Lua 5.4** convention as every other demo in this series, with one
difference: `verify.lua` queries the stack's own HTTP query APIs via
`io.popen("curl ...")` instead of parsing a binary's stdout, because what's
under test here is whether Tempo and Mimir actually received and correctly
related the telemetry the service sent — not whether the service's own
process thinks it succeeded. A small, dependency-free JSON decoder
(object/array/string/number/bool/null, nothing else) is defined directly
in `verify.lua`; this project's `verify.lua` convention is plain Lua 5.4
with no external modules, and no Lua JSON library ships in the verifier
image.

What it checks, with retries (both the trace search and the metric-name
lookup poll on a fixed interval until a timeout, since the stack takes
real time to ingest and index what the service already sent):

1. **HARD** — at least one trace for `observing-concurrency-service` is
   discoverable via a TraceQL search against Tempo
   (`{resource.service.name="..."}`).
2. **SOFT** — the discovered trace count is close to `OBS_REQUESTS`. A
   shortfall is reported, not failed on: it's as likely to be Tempo's own
   search-index lag as a real problem, and check 3 is the one that
   actually proves propagation correctness.
3. **HARD** — for a sample of up to 5 discovered traces, the full trace
   (fetched by ID, which returns an OTLP-JSON `batches[].scopeSpans[].spans[]`
   shape) contains exactly one root `request.handle` span (no
   `parentSpanId`) and `OBS_TASKS_PER_REQUEST` `pool.task` spans whose
   `parentSpanId` equals the root's `spanId`. This is the chapter's actual
   subject — a thread-pool hop that preserved the parent/child
   relationship instead of producing orphan root spans.
4. **HARD** — a metric whose name contains `queue_depth` exists in the
   Prometheus-compatible query API (`/api/v1/label/__name__/values`).
   Discovered by substring rather than asserted by exact name, because the
   OTel→Prometheus naming conversion a collector/backend applies to a
   non-monotonic Sum instrument is not something this demo should assume
   byte-for-byte across stack versions — what matters is that *some*
   queue-depth series made it through the metrics half of the pipeline.
5. **SOFT** — `max_over_time(<queue_depth metric>[10m])` is greater than
   zero. Soft because a fast host or unlucky export-interval timing could
   in principle drain the queue inside the one periodic export window that
   would have captured the saturation; check 4 (the metric pipeline works
   at all) is the hard requirement.

## Running it

```bash
./demo.sh            # build + bring up the stack + run the workload + verify
./demo.sh --clean    # tear down and remove the images this demo built
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pauses (CI / scripted)
```

`demo.sh` tears the stack down (`docker compose down -v`) on an EXIT trap,
so a failed run still leaves a clean `docker compose ps`. Its own exit code
is the verifier's exit code (or the service's, if the service's workload
itself failed before there was anything to verify).

CI verification:
[`../../../scripts/test-concurrency-demo-29-observing-concurrency.sh`](../../../scripts/test-concurrency-demo-29-observing-concurrency.sh).

## Layout

```
29-observing-concurrency/
├── src/instrumented_pool.cpp   instrumented pool: traces + queue-depth metric
├── conanfile.txt               opentelemetry-cpp/1.14.2 (OTLP/HTTP only) + fmt
├── CMakeLists.txt               C++20, find_package(opentelemetry-cpp), target instrumented_pool
├── Containerfile                3 targets: builder, runtime (service), verify (verifier)
├── compose.yaml                 service + lgtm (grafana/otel-lgtm) + profile-gated verifier
├── verify.lua                   Lua 5.4 + a small inline JSON decoder, queries Tempo + Mimir
├── demo.sh                      compose up -d --build -> wait for service exit -> compose run verifier -> compose down (trap)
└── README.md                    this file
```

## Dependency and exporter choices

**OTLP/HTTP, not gRPC.** `conanfile.txt` pins
`opentelemetry-cpp/*:with_otlp_grpc=False` (the recipe's own default) and
`with_otlp_http=True`. OTLP's wire format is protobuf either way, so HTTP
doesn't avoid protobuf/`opentelemetry-proto` — but it does avoid pulling in
`grpc` and grpc's own sizeable transitive closure. For opentelemetry-cpp
1.14.2 specifically, the OTLP/HTTP dependency set is `protobuf`, `abseil`,
`libcurl`, `openssl`, and `nlohmann_json` — no `grpc`, and (checked against
the actual Conan recipe for this version) no `thrift`/`boost` either, since
1.14.2 has already dropped its optional Jaeger exporter option entirely.
`with_zipkin`/`with_prometheus`/`with_elasticsearch` are turned off
explicitly, mainly so a future opentelemetry-cpp release changing its own
defaults (Zipkin defaults to **on** upstream) doesn't silently add an
unused exporter to this example.

**Fully static linking** (`*:shared=False` in `conanfile.txt`) means the
`runtime` stage needs nothing beyond `libstdc++` — no matching
`libcurl.so`/`libssl.so` versions between the Conan-built binary and the
ubi-minimal runtime image to worry about.

## Build risk (read this before a first run)

This is the most dependency-heavy example in the tutorial so far, and the
most likely to need iteration on a first real build:

- **opentelemetry-cpp on Conan Center.** The recipe and its options are
  confirmed against the actual `conanfile.py` Conan Center serves for
  `opentelemetry-cpp/1.14.2` (not just the package index) — option names,
  defaults, and the exact transitive dependency set this configuration
  pulls (protobuf 5.27.0, abseil, libcurl, openssl, nlohmann_json; no
  grpc/thrift/boost) were all verified by reading that recipe directly, not
  assumed. What a dry run doesn't prove is that a prebuilt binary exists
  for this exact UBI10/gcc/gnu17 profile — expect `--build=missing` to
  compile most of that dependency closure (openssl and protobuf
  particularly) from source on a first build. That is a real time cost
  (plausibly 15–30+ minutes on a cold Conan cache), not a sign of a broken
  recipe.
- **The `grafana/otel-lgtm` image is heavy.** One container running
  Grafana + Tempo + Mimir + Loki + a Collector takes longer to become
  healthy than any single-purpose image this tutorial has used so far;
  `start_period: 60s` in `compose.yaml`'s healthcheck is a deliberate
  overestimate, not a guess.
- **Ingestion delay is real and is what `verify.lua`'s retries exist for.**
  A trace landing in the service's own successful exit does not mean
  Tempo's search index has it yet. `VERIFY_TIMEOUT_S` (default 90s) is
  generous on purpose.
- **The C++ source was written against the actual opentelemetry-cpp
  v1.14.2 headers and official examples** (`examples/otlp/http_main.cc`,
  `examples/otlp/http_metric_main.cc` from the upstream repo at that tag),
  not from memory or a newer/older version's API — every factory
  signature, `StartSpanOptions::parent` field, and `ForceFlush`/`Shutdown`
  downcast pattern used here was cross-checked against that tag's headers.
  That said, this file has not been compiled in this environment (author-only
  task; the orchestrator builds it) — treat the first real build as the
  actual test of this code, not this README's confidence in it.
- **`verify.lua`'s JSON decoder and span-nesting/metric-discovery logic
  were unit-tested** against synthetic Tempo/Prometheus-shaped JSON (via a
  throwaway Lua interpreter, not part of this demo) for both the pass path
  and two failure paths (no traces found; a span with the wrong
  `parentSpanId`) before being committed here. What that testing could not
  cover is the real stack's actual response shapes end-to-end.

Honest assessment: the compose topology, the verifier's query logic, and
the service's propagation pattern are all sound and were checked as
thoroughly as this environment allows without an actual build. The
opentelemetry-cpp compile step is the one piece with real first-run risk —
if it fails, it is far more likely to be a Conan profile/toolchain mismatch
than a wrong dependency graph.
