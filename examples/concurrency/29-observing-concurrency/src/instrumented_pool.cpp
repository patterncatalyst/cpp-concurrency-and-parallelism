// concurrency/29-observing-concurrency — an instrumented thread pool that
// exports traces and metrics over OTLP/HTTP to an OpenTelemetry Collector.
//
// The pool itself is the ch15-style single-queue design (one mutex +
// condition_variable-guarded deque every worker pops from) -- this chapter
// is not about pool architecture, it is about what it takes to observe one
// correctly. Two things ride on top of that familiar pool:
//
//   1. A trace per request, with a child span per pool task that actually
//      nests under the request that submitted it. The pool's worker
//      threads run a task's body on a call stack that has nothing to do
//      with the thread that submitted the task, so nothing connects a
//      child span started there to the request -- UNLESS the submitting
//      thread captures its own Context explicitly and hands it across the
//      hop. This example captures the request's opentelemetry::context::
//      Context at submit() time and passes it as an explicit
//      StartSpanOptions::parent on the worker thread. That is one of the
//      two propagation techniques the chapter describes (the other is
//      RuntimeContext::Attach + a thread-local Scope); an explicit parent
//      field is the more direct choice for a one-shot, fire-into-a-pool
//      hand-off, because it needs no Attach/Detach bookkeeping on the
//      worker thread at all.
//
//   2. A queue-depth UpDownCounter: +1 every time a task is pushed onto the
//      queue, -1 the moment a worker pops it back off. That is pool
//      saturation made visible instead of inferred from latency.
//
// The whole program is a single short-lived batch run, not a server: it
// drives OBS_REQUESTS concurrent "requests" (each a root span fanning out
// to OBS_TASKS_PER_REQUEST pool tasks), waits for every task to finish, and
// exits. Because it is short-lived, the default batch/export intervals
// (seconds) would let the whole run finish before the first scheduled
// export -- so both the span batch processor and the periodic metric
// reader use short intervals, AND the program explicitly ForceFlush()es
// both providers before exit. Skipping that step is exactly the mistake
// the chapter's "Running in a container" section calls out: a short-lived
// process's last batch never leaving before the process exits.
//
// Configuration is environment-only (the compose file controls the
// workload shape, not a human typing flags):
//   OTEL_SERVICE_NAME            resource service.name   (default "observing-concurrency-service")
//   OTEL_EXPORTER_OTLP_ENDPOINT  collector base URL      (default "http://lgtm:4318")
//   OBS_WORKERS                  pool worker threads      (default 2)
//   OBS_REQUESTS                 concurrent requests      (default 24)
//   OBS_TASKS_PER_REQUEST        child tasks per request  (default 3)
//   OBS_TASK_WORK_MS             simulated work per task  (default 60)
//
// With the defaults, 24 requests x 3 tasks = 72 tasks land on 2 workers
// almost immediately, so the queue backs up to roughly 70 before draining
// over ~2 seconds -- comfortably inside the metric reader's export window,
// and long enough for Tempo/Mimir's own ingestion lag not to matter to the
// workload itself (verify.lua is what waits out ingestion lag).

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <functional>
#include <latch>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

#include <opentelemetry/common/attribute_value.h>
#include <opentelemetry/context/context.h>
#include <opentelemetry/context/runtime_context.h>
#include <opentelemetry/exporters/otlp/otlp_http_exporter_factory.h>
#include <opentelemetry/exporters/otlp/otlp_http_exporter_options.h>
#include <opentelemetry/exporters/otlp/otlp_http_metric_exporter_factory.h>
#include <opentelemetry/exporters/otlp/otlp_http_metric_exporter_options.h>
#include <opentelemetry/metrics/meter.h>
#include <opentelemetry/metrics/provider.h>
#include <opentelemetry/metrics/sync_instruments.h>
#include <opentelemetry/nostd/shared_ptr.h>
#include <opentelemetry/nostd/unique_ptr.h>
#include <opentelemetry/sdk/metrics/export/periodic_exporting_metric_reader_factory.h>
#include <opentelemetry/sdk/metrics/export/periodic_exporting_metric_reader_options.h>
#include <opentelemetry/sdk/metrics/meter_context_factory.h>
#include <opentelemetry/sdk/metrics/meter_provider.h>
#include <opentelemetry/sdk/metrics/view/view_registry.h>
#include <opentelemetry/sdk/resource/resource.h>
#include <opentelemetry/sdk/trace/batch_span_processor_factory.h>
#include <opentelemetry/sdk/trace/batch_span_processor_options.h>
#include <opentelemetry/sdk/trace/tracer_provider.h>
#include <opentelemetry/sdk/trace/tracer_provider_factory.h>
#include <opentelemetry/trace/provider.h>
#include <opentelemetry/trace/scope.h>
#include <opentelemetry/trace/span_startoptions.h>
#include <opentelemetry/trace/tracer.h>

namespace trace_api   = opentelemetry::trace;
namespace trace_sdk   = opentelemetry::sdk::trace;
namespace metrics_api = opentelemetry::metrics;
namespace metrics_sdk = opentelemetry::sdk::metrics;
namespace otlp        = opentelemetry::exporter::otlp;
namespace resource_sdk = opentelemetry::sdk::resource;
namespace otel_ctx    = opentelemetry::context;

namespace {

using Clock = std::chrono::steady_clock;

std::string env_or(const char* key, std::string fallback) {
    const char* v = std::getenv(key);
    return (v && *v) ? std::string(v) : fallback;
}

std::uint64_t env_or_u64(const char* key, std::uint64_t fallback) {
    const char* v = std::getenv(key);
    if (!v || !*v) {
        return fallback;
    }
    return std::strtoull(v, nullptr, 10);
}

// ───────────────────────────── telemetry bring-up ───────────────────────

struct Telemetry {
    std::shared_ptr<trace_api::TracerProvider> tracer_provider;
    opentelemetry::nostd::shared_ptr<trace_api::Tracer> tracer;
    std::shared_ptr<metrics_api::MeterProvider> meter_provider;
    opentelemetry::nostd::shared_ptr<metrics_api::Meter> meter;
};

Telemetry init_telemetry(const std::string& service_name, const std::string& otlp_base) {
    auto resource = resource_sdk::Resource::Create({
        {"service.name", service_name},
        {"service.version", "1.0.0"},
        {"deployment.environment", "local"},
    });

    // Traces: OTLP/HTTP to the collector, service-name DNS, never localhost
    // -- see Containerfile/compose.yaml for why. schedule_delay_millis is
    // short (500ms, not the 5s default) because this is a short-lived
    // batch process: a 5s batch window would mean most runs exit before
    // the first scheduled export, and ForceFlush() at the end (see
    // shutdown_telemetry) is what guarantees the LAST batch leaves too.
    otlp::OtlpHttpExporterOptions trace_opts;
    trace_opts.url = otlp_base + "/v1/traces";
    auto trace_exporter = otlp::OtlpHttpExporterFactory::Create(trace_opts);

    trace_sdk::BatchSpanProcessorOptions batch_opts;
    batch_opts.schedule_delay_millis = std::chrono::milliseconds(500);
    auto processor =
        trace_sdk::BatchSpanProcessorFactory::Create(std::move(trace_exporter), batch_opts);

    std::shared_ptr<trace_api::TracerProvider> tracer_provider =
        trace_sdk::TracerProviderFactory::Create(std::move(processor), resource);
    trace_api::Provider::SetTracerProvider(tracer_provider);
    auto tracer = tracer_provider->GetTracer(service_name);

    // Metrics: same collector, same short-lived-process reasoning applied
    // to the periodic export interval.
    otlp::OtlpHttpMetricExporterOptions metric_opts;
    metric_opts.url = otlp_base + "/v1/metrics";
    auto metric_exporter = otlp::OtlpHttpMetricExporterFactory::Create(metric_opts);

    metrics_sdk::PeriodicExportingMetricReaderOptions reader_opts;
    reader_opts.export_interval_millis = std::chrono::milliseconds(500);
    reader_opts.export_timeout_millis  = std::chrono::milliseconds(400);
    auto reader = metrics_sdk::PeriodicExportingMetricReaderFactory::Create(
        std::move(metric_exporter), reader_opts);

    auto views = std::make_unique<metrics_sdk::ViewRegistry>();
    auto meter_context = metrics_sdk::MeterContextFactory::Create(std::move(views), resource);
    meter_context->AddMetricReader(std::move(reader));

    auto u_meter_provider = metrics_sdk::MeterProviderFactory::Create(std::move(meter_context));
    std::shared_ptr<metrics_api::MeterProvider> meter_provider(std::move(u_meter_provider));
    metrics_api::Provider::SetMeterProvider(meter_provider);
    auto meter = meter_provider->GetMeter(service_name);

    return Telemetry{tracer_provider, tracer, meter_provider, meter};
}

void shutdown_telemetry(Telemetry& t) {
    // Explicit flush before shutdown: the fix for the "last batch never
    // leaves a short-lived process" failure mode. Downcasting to the SDK
    // type to reach ForceFlush/Shutdown mirrors opentelemetry-cpp's own
    // OTLP/HTTP examples (examples/otlp/http_main.cc), which do the same
    // thing for the trace provider.
    static_cast<trace_sdk::TracerProvider*>(t.tracer_provider.get())
        ->ForceFlush(std::chrono::seconds(5));
    static_cast<metrics_sdk::MeterProvider*>(t.meter_provider.get())
        ->ForceFlush(std::chrono::seconds(5));
    static_cast<trace_sdk::TracerProvider*>(t.tracer_provider.get())->Shutdown();
    static_cast<metrics_sdk::MeterProvider*>(t.meter_provider.get())->Shutdown();
}

// ───────────────────────────── instrumented pool ────────────────────────

struct Task {
    otel_ctx::Context parent_ctx;
    std::uint64_t request_id = 0;
    std::uint64_t task_index = 0;
    std::function<void()> on_done;
};

class InstrumentedPool {
public:
    InstrumentedPool(unsigned n,
                     opentelemetry::nostd::shared_ptr<trace_api::Tracer> tracer,
                     metrics_api::UpDownCounter<int64_t>* queue_depth,
                     std::chrono::milliseconds task_work)
        : tracer_(std::move(tracer)), queue_depth_(queue_depth), task_work_(task_work) {
        workers_.reserve(n);
        for (unsigned i = 0; i < n; ++i) {
            workers_.emplace_back([this] { run(); });
        }
    }

    InstrumentedPool(const InstrumentedPool&) = delete;
    InstrumentedPool& operator=(const InstrumentedPool&) = delete;

    ~InstrumentedPool() {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto& t : workers_) {
            t.join();
        }
    }

    // Submits one task, parented to whatever Context is current on the
    // CALLER's thread at the moment of the call -- the caller is
    // responsible for calling this while its own request span's Scope is
    // still active (see handle_request below).
    void submit(std::uint64_t request_id, std::uint64_t task_index,
               otel_ctx::Context parent_ctx, std::function<void()> on_done) {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            queue_.push_back(
                Task{std::move(parent_ctx), request_id, task_index, std::move(on_done)});
        }
        // +1 the instant the task is queued, regardless of when a worker
        // actually picks it up -- this is the saturation signal, not a
        // per-worker busy/idle gauge.
        queue_depth_->Add(1, {{"pool.name", "default"}});
        cv_.notify_one();
    }

    std::uint64_t completed() const { return completed_.load(std::memory_order_relaxed); }

private:
    void run() {
        while (true) {
            Task task;
            {
                std::unique_lock<std::mutex> lk(mtx_);
                cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
                if (stop_ && queue_.empty()) {
                    return;
                }
                task = std::move(queue_.front());
                queue_.pop_front();
            }
            // -1 the moment the task leaves the queue, whether or not its
            // span/work has started yet -- matches the +1 in submit().
            queue_depth_->Add(-1, {{"pool.name", "default"}});

            // The hard part: this span is created on a worker thread with
            // no relation to the thread that called submit(). Setting
            // StartSpanOptions::parent explicitly to the Context captured
            // at submit() time is what makes this nest under the request
            // instead of starting a disconnected root span.
            trace_api::StartSpanOptions span_opts;
            span_opts.parent = task.parent_ctx;
            auto span = tracer_->StartSpan(
                "pool.task",
                {{"task.request_id", static_cast<int64_t>(task.request_id)},
                 {"task.index", static_cast<int64_t>(task.task_index)}},
                span_opts);
            auto scope = tracer_->WithActiveSpan(span);

            std::this_thread::sleep_for(task_work_);

            span->End();
            completed_.fetch_add(1, std::memory_order_relaxed);

            if (task.on_done) {
                task.on_done();
            }
        }
    }

    opentelemetry::nostd::shared_ptr<trace_api::Tracer> tracer_;
    metrics_api::UpDownCounter<int64_t>* queue_depth_;
    std::chrono::milliseconds task_work_;

    std::mutex mtx_;
    std::condition_variable cv_;
    std::deque<Task> queue_;
    bool stop_ = false;
    std::vector<std::thread> workers_;
    std::atomic<std::uint64_t> completed_{0};
};

// ───────────────────────────── request driver ───────────────────────────

// One "request": a root span fanning out to tasks_per_request pool tasks,
// blocking until every one of ITS OWN tasks has finished before ending the
// span. The Scope stays alive for the whole function (including the
// latch.wait() below it), so every submit() call inside the loop captures
// a Context whose current span is this request's root -- that captured
// Context, not the Scope itself, is what survives the thread hop.
void handle_request(InstrumentedPool& pool,
                    const opentelemetry::nostd::shared_ptr<trace_api::Tracer>& tracer,
                    std::uint64_t request_id, unsigned tasks_per_request,
                    std::latch& total_latch) {
    auto span =
        tracer->StartSpan("request.handle", {{"request.id", static_cast<int64_t>(request_id)}});
    auto scope = tracer->WithActiveSpan(span);

    std::latch request_latch(tasks_per_request);
    for (unsigned i = 0; i < tasks_per_request; ++i) {
        otel_ctx::Context parent_ctx = otel_ctx::RuntimeContext::GetCurrent();
        pool.submit(request_id, i, parent_ctx, [&request_latch] { request_latch.count_down(); });
    }
    request_latch.wait();

    span->End();
    total_latch.count_down();
}

}  // namespace

int main() {
    const std::string service_name =
        env_or("OTEL_SERVICE_NAME", "observing-concurrency-service");
    const std::string otlp_base = env_or("OTEL_EXPORTER_OTLP_ENDPOINT", "http://lgtm:4318");
    const unsigned workers = static_cast<unsigned>(env_or_u64("OBS_WORKERS", 2));
    const std::uint64_t n_requests = env_or_u64("OBS_REQUESTS", 24);
    const unsigned tasks_per_request =
        static_cast<unsigned>(env_or_u64("OBS_TASKS_PER_REQUEST", 3));
    const std::uint64_t task_work_ms = env_or_u64("OBS_TASK_WORK_MS", 60);

    fmt::print(
        "observing-concurrency-service: service_name={} otlp_endpoint={} workers={} "
        "requests={} tasks_per_request={} task_work_ms={}\n",
        service_name, otlp_base, workers, n_requests, tasks_per_request, task_work_ms);

    Telemetry telemetry = init_telemetry(service_name, otlp_base);

    auto queue_depth = telemetry.meter->CreateInt64UpDownCounter(
        "pool_queue_depth", "Number of tasks waiting in the pool's queue (saturation signal)",
        "");

    InstrumentedPool pool(workers, telemetry.tracer, queue_depth.get(),
                          std::chrono::milliseconds(task_work_ms));

    auto t0 = Clock::now();
    std::latch total_latch(static_cast<std::ptrdiff_t>(n_requests));
    std::vector<std::thread> request_threads;
    request_threads.reserve(n_requests);
    for (std::uint64_t r = 0; r < n_requests; ++r) {
        request_threads.emplace_back([&, r] {
            handle_request(pool, telemetry.tracer, r, tasks_per_request, total_latch);
        });
    }
    total_latch.wait();
    for (auto& t : request_threads) {
        t.join();
    }
    auto t1 = Clock::now();

    const std::uint64_t total_tasks = n_requests * tasks_per_request;
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    fmt::print("requests={} tasks={} completed={} elapsed_ms={:.3f}\n", n_requests, total_tasks,
              pool.completed(), elapsed_ms);

    // Flush before the pool and telemetry providers are torn down --
    // skipping this is the chapter's "last batch never leaves" mistake.
    shutdown_telemetry(telemetry);

    return pool.completed() == total_tasks ? 0 : 1;
}
