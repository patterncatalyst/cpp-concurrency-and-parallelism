---
title: "Observing Concurrency"
order: 29
layout: tutorial
sectionid: docs
part: correctness-errors-and-debugging
description: "Instrumenting a concurrent C++ service with OpenTelemetry, propagating trace context across thread-pool, future, and coroutine boundaries, and the saturation and contention metrics that reveal a struggling pool before it becomes an incident."
duration: "17 min"
---

<!-- PROVENANCE: NEW (draws on linux-systems-programming/_docs/38-opentelemetry-to-lgtm.md) | anchor books: Lim -->

## Learning objectives

By the end of this chapter you can:

- Instrument a concurrent C++ service with OpenTelemetry's trace, metric, and log signal providers.
- Propagate a trace's context across a thread-pool hop, a future continuation, and a coroutine suspension without losing the parent span.
- Define and export the four metrics that reveal pool saturation and lock contention before they become an incident: queue depth, lock wait time, task latency percentiles, and a contention counter.
- Keep metric cardinality bounded by labeling on pool or stage name rather than per-request identifiers.
- Ship traces, metrics, and logs to a local LGTM stack and navigate between them through a shared trace ID.

## Why this matters

A concurrent service in production cannot be stopped, rerun, or attached to with a debugger. The pool clogging under a traffic burst and the lock half the fleet is queued behind each happen once, on a host nobody is watching, and the only way to see either after the fact is a signal the service was already emitting when it happened.

The failure mode is specific and easy to miss: a span created on a thread-pool worker silently starts a disconnected trace root unless the parent context is captured and reinstalled explicitly, leaving a dashboard full of single-span traces where a deep request tree was expected. The propagation discipline in this chapter is what keeps a trace meaningful once work crosses a thread boundary, which concurrent code does constantly.

## What we'll cover

- Cover instrumenting a concurrent C++ service with OpenTelemetry's trace, metric, and log signals.
- Cover propagating a trace context across an async boundary (a thread-pool hop, a future, a coroutine suspension) without losing the parent span.
- Define the metrics that matter for concurrency health: pool saturation, lock contention, and queueing latency.
- Wire the signals into the LGTM stack (Loki, Grafana, Tempo, Mimir) for a working observability loop.

[Debugging Real Races and Deadlocks]({{ '/docs/27-debugging-real-races-and-deadlocks/' | relative_url }}) and [Sanitizers and Dynamic Analysis]({{ '/docs/28-sanitizers-and-dynamic-analysis/' | relative_url }}) both work on a program you can stop, rerun, or instrument offline. A concurrent service in production affords none of that: the pool clogging under a traffic burst, the lock half the fleet is queued behind, the one task that took four hundred times longer than its neighbors: each happens once, on a host nobody has a debugger attached to, and is gone by the time the symptom reaches a person. Observability fills that gap with signals a running service emits continuously, cheap enough to leave on, specific enough to say which pool, which lock, and which percentile actually misbehaved. This chapter instruments a service with OpenTelemetry, works through the one part that's hard for concurrent code (carrying a trace's context across a boundary where the thread finishing the work isn't the thread that started it) and ships the result to a local LGTM stack so the numbers are something to query, not something the program merely asserts about itself.

## OpenTelemetry for Concurrent Services

The OpenTelemetry C++ SDK (`opentelemetry-cpp`) exposes three independent signal providers against a shared `Resource`, a set of attributes identifying the process emitting them, with `service.name` the one that matters most once more than one service shares a backend. A `TracerProvider` hands out `Tracer`s that start spans; a `MeterProvider` hands out `Meter`s that create counters and histograms; a `LoggerProvider` does the equivalent for structured log records. All three batch internally (a batch span processor buffering spans until a flush interval fires, a periodic metric reader doing the same for aggregated counters and histograms), and all three are safe to call from any thread without external locking, which matters immediately in a concurrent service, because the normal case is dozens of worker threads creating spans and recording metrics at once with no coordination between them.

That thread-safety guarantee answers "is it safe to call this concurrently," not "does calling it from many threads produce the trace I expect." Those are different questions, and the gap between them is this chapter's real subject: a pool's worker threads creating spans concurrently is fine on its own, but nothing about the SDK knows that a span created on worker thread 7 belongs to the same logical request as a span created a moment earlier on the thread that submitted the work. Getting that relationship right is a propagation problem, not a thread-safety problem, and the next section is where it gets solved.

One more constraint matters before diagrams and code: starting a span is not free. It allocates, reads a clock, and copies attribute key-value pairs; a `Histogram::Record` or a counter `Add` is a few atomic operations. On the sustained hot path [The Low-Latency Fast Path]({{ '/docs/19-the-low-latency-fast-path/' | relative_url }}) described, where single-digit microseconds matter end to end, paying that cost per sub-microsecond unit of work would make the instrumentation dominate the thing it measures. The practical rule is to instrument at the grain of a request or a batch (one span per unit of work a human cares about) and reserve the truly hot inner loop for the cheap, lock-free counters [Atomics and the Memory Model]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }}) already covers, aggregating those into a coarser metric at the export boundary rather than recording one telemetry call per iteration.

## Tracing Across Async Boundaries

OpenTelemetry tracks the "current" span through a `Context` object and a `Scope` that installs it for the lifetime of a call. That installation rides the call stack of whichever thread is executing: it is not magically attached to a logical request, it is attached to the thread currently running that request's code. As long as a request's work stays on one thread, a child span started anywhere inside that call stack picks up the active parent automatically, exactly as [The Actor Model and Channels]({{ '/docs/23-the-actor-model-and-channels/' | relative_url }})'s confined worker loop would expect.

[Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) breaks that assumption by design: a task submitted to a pool runs its body on a worker thread with its own, unrelated call stack, where no `Scope` is installed. A child span started inside that lambda does not fail: it silently starts a brand-new trace root, disconnected from the request that submitted the task, and the first sign of the mistake is usually a dashboard full of single-span traces where a deep request tree was expected. The fix is to make the hand-off explicit: capture the parent `Context` (a cheap handle, not the span itself) in the task's closure at submission time, and install a `Scope` from that captured context as the first thing the worker's handler does, before creating any child span. This is the same discipline [Lock-Free Messaging and the Disruptor]({{ '/docs/21-lock-free-messaging-and-the-disruptor/' | relative_url }})'s single-writer principle and Chapter 23's confinement both rest on: nothing crosses a thread boundary implicitly, it has to be handed off as an explicit, owned value.

A future-based continuation has the identical problem in different clothing. A continuation attached to a `std::future` or a task graph, scheduled to run on whatever executor thread the future completes on, inherits no context from the thread that attached it; the attaching code has to capture the context the same way the thread-pool task does, and the continuation has to reinstall it before doing anything that should nest under the original request's span.

Coroutines add a wrinkle beyond "capture it once." [Coroutines in Depth]({{ '/docs/11-coroutines-in-depth/' | relative_url }}) covered a coroutine that suspends on one thread and resumes on another, awaiting a result an I/O completion handler posts back from a different pool entirely. The coroutine's local variables survive a suspension because they live in the heap-allocated frame, but a `Scope` on the call stack does not: it was installed on the suspending thread's stack and is gone the moment that stack unwinds past the suspension point. The frame has to carry its own copy of the `Context` (stored in the promise type alongside the state a `stop_token`-aware coroutine already tracks), and the awaiter's resumption path has to reinstall a `Scope` from that stored context before the coroutine body runs any more user code: capture at suspend, restore at resume, the same shape as the thread-pool case, triggered by a suspend/resume pair instead of a submit/run pair.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, two stacked panels. Top panel "Thread-pool hop": a blue #4a73b8 box "Thread A: submitting request" containing a small "parent span (open)" tag and a "Context" chip; an arrow labeled "capture Context, bundle with task" goes from that chip into a cream task-queue box; a second arrow goes from the queue into a green #5a8870 box "Thread B: worker" labeled "install Scope(ctx) -> start child span"; a red #c0392b box floats beside Thread B labeled "no Scope installed -> orphan root span" with an X, showing the failure mode being avoided. Bottom panel "Coroutine suspend/resume": an orange #a06030 box "coroutine frame (promise_type)" holding a "stored Context" chip persists across a dashed vertical line separating "Thread A (suspend)" from "Thread C (resume)"; an arrow from the stored Context chip into Thread C's box is labeled "reinstall Scope on resume, before user code runs". -->
{% include excalidraw.html name="29-context-propagation" caption="Figure 29.1: a trace's context does not cross a thread boundary on its own: a thread-pool task and a coroutine resumption both have to capture the parent Context explicitly and reinstall a Scope before any child span is created on the new thread" %}

## Metrics for Pool Saturation and Contention

Four metrics cover most of what a concurrency-aware dashboard needs, and each maps to a specific failure mode earlier chapters already described in words. **Queue depth**, exported as an `UpDownCounter` that rises on submit and falls on dequeue, is the exact number [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) said an operator should be able to read rather than infer from a backlog nobody can see. A pool's queue depth climbing steadily, rather than oscillating around a baseline, is saturation in progress, visible before latency complaints arrive. **Lock wait time**, a histogram recording the interval between requesting a lock and acquiring it, separates two failure modes that look identical from outside: a climbing wait time with a flat hold-time distribution means threads are queued behind a lock that's fine once acquired, while a climbing hold time means the critical section itself has gotten slower. [Shared State and the Futex]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }})'s point that a default `std::mutex` does one compare-and-swap and then a futex wait, with no adaptive spin, is exactly why this histogram needs to exist separately from a generic latency number: a contended mutex's cost is almost entirely the futex round trip, and that cost is invisible unless something measures the wait specifically. **Task latency percentiles** (queue wait plus run time, reported as p50, p99, and p99.9 rather than a mean) matter because an average hides precisely the tail a latency budget cares about; the benchmarking discipline [Benchmarking Without Deception]({{ '/docs/18-benchmarking-without-deception/' | relative_url }}) applied to offline measurement applies the same way to production percentiles, where coordinated omission (not counting the latency of work still queued when you sample) silently flatters the number. **Contention counters** (a count of failed `try_lock` attempts, or futex wake-ups, tagged by lock or pool name) turn "is this lock contended" from a guess into a trend line a release can be measured against.

All four need the same cardinality discipline: label by pool name or stage name, a small, bounded set known at compile time, never by anything unbounded like a request ID or a connection handle. A metric's label set is a long-lived storage dimension: every unique combination of label values becomes its own time series, while a request's identifying detail belongs on a span attribute, cheap and scoped to that one trace. Recording the metrics on the hot path is safe at line rate, since an `Add` or a `Record` call is a few atomic operations, not a lock; what isn't safe is recording one per sub-microsecond unit of work, the same hot-path-cost concern the first section raised. The practical pattern, following [Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }})'s cache-line discipline, is a per-thread, padded counter aggregated locally and flushed into the OTel metric at the periodic export boundary.

## The LGTM Stack

The OTel Collector is the single point every signal converges on: the instrumented service exports OTLP (gRPC or HTTP/protobuf) to the collector, which routes traces to Tempo, metrics to Mimir (or any Prometheus remote-write-compatible store), and logs to Loki. Grafana queries all three through one interface, and the payoff of putting them behind a single pane is direct navigation between them: a trace ID attached to a log line jumps straight to that request's span tree in Tempo, and a histogram bucket carrying an exemplar (a sampled trace ID for an observation that landed in that bucket) turns a p99 latency spike on a Grafana panel into one click through to an actual slow trace, rather than a number with no path back to its cause.

Export timing follows the same trade-off the anchor OpenTelemetry chapter in this series worked through: the SDK's default batch intervals (several seconds for spans, up to a minute for metrics) suit a long-running service that's always about to flush again, but a short-lived process, or a burst that needs to show up quickly on a dashboard, needs a shorter interval and an explicit flush triggered on shutdown; otherwise the last batch, and on a short enough run every batch, never leaves the process.

## Running in a container

A minimal observability stack for this chapter's example is three pieces in one docker compose file: the instrumented service, an OTel Collector, and the LGTM services (Tempo, Mimir, Loki, Grafana) that a tool like `lgtm-docker-stack` provisions in one shot. Inside that compose network, the instrumented process has to reach the collector by its service name (`otel-collector:4318`, not `localhost:4318`), because `localhost` inside a container refers to that container alone; pointing the exporter at `localhost` is the containerized version of the wrong-endpoint mistake that made an export fail with a silent 404 in the anchor chapter, just one layer up the stack, at the hostname instead of the path.

Batching introduces real, bounded memory pressure: a batch span processor buffers every span created since the last flush, so a container's memory limit needs headroom above steady per-request allocation to cover that buffer during a burst, or the buffer itself triggers an OOM kill in exactly the spike the telemetry exists to explain. The cgroup-aware pool sizing from Chapter 15 applies unchanged here: the exporter's own flush thread is one more thread against the container's CPU quota, and it should be counted, not treated as free.

<!-- EXAMPLE SPEC: examples/concurrency/29-observing-concurrency/: an instrumented thread-pool service (the Chapter 15 pool, extended) that accepts simple work items over a local socket, submits them to the pool, and on each task start/finish creates a span correctly parented to the submitting request's context per the propagation pattern above, while exporting a queue-depth UpDownCounter, a lock-wait-time histogram around the pool's internal mutex, and a task-latency histogram. Run via docker compose (lgtm-docker-stack) alongside an OTel Collector and the LGTM services; a driver script submits a burst of tasks sized to push the pool into visible queueing. verify.lua queries Tempo through the collector/Grafana proxy to assert spans for pool tasks arrived with the expected parent/child nesting (request -> task), and queries Mimir/Prometheus to assert the queue-depth metric rose above zero during the burst and returned to zero after drain: proving saturation was both produced and observed, not merely claimed by the service's own logs. -->

## Standards: C++20 / C++23 / C++26

Three standards touch different layers of this chapter's instrumentation: how a worker's shutdown guarantees a final flush, how a queued task carries both its closure and its captured trace context without forcing an extra allocation, and, on the furthest horizon, how an entire instrumented pipeline might be expressed as a composed chain of senders rather than hand-wired threads and queues.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: jthread + stop_token give an instrumented worker a shutdown path
// that is guaranteed to run — the destructor requests stop and joins, and
// the stop-aware loop flushes telemetry before it returns, rather than
// relying on every caller to remember an explicit shutdown() call.
class InstrumentedWorker {
public:
    explicit InstrumentedWorker(telemetry::Handle t)
        : t_(std::move(t)), thread_([this](std::stop_token st) { run(st); }) {}
    // ~InstrumentedWorker() is implicit: jthread requests_stop() and joins.

private:
    void run(std::stop_token st) {
        while (!st.stop_requested()) {
            process_next();
        }
        t_.flush_and_shutdown(std::chrono::milliseconds(5000));
    }
    telemetry::Handle t_;
    void process_next();
    std::jthread thread_;
};
```

```cpp
// C++23: move_only_function (header <functional>) lets a queued task carry
// its captured otel Context alongside move-only state (a unique_ptr-owned
// buffer, a promise) without std::function's copyability requirement
// forcing an extra shared_ptr wrapper just to satisfy the queue's element type.
#include <functional>

struct Task {
    opentelemetry::context::Context parent_ctx;
    std::move_only_function<void()> work;
};

void submit(Queue<Task>& q, opentelemetry::context::Context ctx,
            std::unique_ptr<Buffer> buf) {
    q.push(Task{ctx, [b = std::move(buf)]() mutable { handle(*b); }});
}
```

```cpp
// C++26 (proposed; targets the accepted P2300 std::execution model, not
// yet shipping in a mainstream standard library — shown against the
// stdexec reference implementation's API shape). An "instrumented" adaptor
// wraps a scheduler so every sender scheduled on it installs the captured
// Scope automatically, making propagation a pipeline stage instead of
// something each task author has to remember.
namespace ex = std::execution;

auto traced = instrumented_schedule(pool.get_scheduler(), parent_ctx)
            | ex::then([] { return do_work(); });
ex::sync_wait(std::move(traced));
```

The `jthread`/`stop_token` pairing is what makes "flush before shutdown" a property of the type rather than a discipline every caller has to remember, the same guarantee [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) relied on for clean worker teardown applies directly to telemetry, where a skipped flush means the last batch of spans and metrics describing exactly the shutdown path never arrives. `std::move_only_function` removes a real tax on instrumented task queues specifically, since a task closure that owns non-copyable state is already common and pairing it with a captured `Context` only makes `std::function`'s copyability requirement more expensive to work around. `std::execution` is worth tracking and nothing more today: no shipping compiler implements it, and the "instrumented scheduler" shown above is a sketch of where the ecosystem is heading, not a pattern to build a production exporter on.

## What we learned

- A concurrent service exposes three signal types (traces, metrics, and logs) through independent OpenTelemetry providers that are safe to call from any thread, but thread-safety says nothing about whether spans created on different threads end up correctly related.
- Trace context does not cross a thread boundary on its own: a thread-pool task, a future continuation, and a resuming coroutine all have to capture the parent `Context` explicitly and reinstall a `Scope` before creating a child span, or the result is a disconnected root span instead of a nested request.
- Four metrics cover most concurrency failure modes: queue depth for saturation, lock wait time for contention, task latency percentiles for tail behavior, and a contention counter for trend. All four need bounded, small label sets; per-request identifying detail belongs on a span, not a metric label.
- An OTel Collector fans traces, metrics, and logs out to Tempo, Mimir, and Loki, with Grafana querying all three; exemplars and shared trace IDs are what let a metric spike resolve into the actual trace that caused it.
- Export is batched, and in a container both the export interval and the batch buffer's memory footprint need explicit sizing: a default interval can mean a short-lived burst's telemetry never leaves the process, and an unsized buffer can turn the exact traffic spike telemetry exists to explain into an OOM kill.

[Coding Practices for Concurrency]({{ '/docs/30-coding-practices-for-concurrency/' | relative_url }}) turns from watching a concurrent system run to writing one that's easier to get right in the first place.
