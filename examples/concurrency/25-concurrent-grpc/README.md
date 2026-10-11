# concurrency/25-concurrent-grpc — async gRPC server, bounded admission

Compendium reference:
[Doc 25 — Concurrent gRPC Services](../../../_docs/25-concurrent-grpc-services.md)

The runnable companion to compendium Doc 25. The one-line takeaway: **a
`grpc::CompletionQueue` is the one concurrency model underneath all of
gRPC C++'s APIs**, and a server built directly on it needs its own
explicit admission control — nothing bounds how many `CallData` objects
pile up unless the handler code enforces a cap itself.

## What it demonstrates

[`src/async_server.cpp`](src/async_server.cpp) implements the chapter's
`CallData` pattern directly against `grpc::ServerCompletionQueue` (the raw
async API, not callback): every call is a tiny state machine —
`CREATE -> PROCESS -> (WRITE <-> DELAY)* -> FINISH` — tagged with `this`,
re-arming itself at each phase and immediately spawning its own
replacement the instant it leaves `CREATE` so the server never stops
accepting new calls while an existing one is still being served.

Two things on top of the chapter's minimal unary sketch:

- **Bounded admission.** A single process-wide `std::atomic<int>` tracks
  calls admitted past `CREATE`. `--cap` enforces an upper bound via a
  `fetch_add`-then-rollback reservation: a call that would push the count
  over `cap` finishes immediately with `RESOURCE_EXHAUSTED` — streaming
  nothing — the gRPC equivalent of a REST endpoint's 503.
- **Deliberate per-message pacing**, via a non-blocking `grpc::Alarm` tag
  between successive `Write()` calls, instead of writing (and finishing)
  as fast as the CPU allows. This is what makes the bounded-admission test
  meaningful: without it, a small fast stream could finish and free its
  slot before the concurrent client's threads have all even started,
  masking the cap entirely.

Multiple completion queues, one dedicated servicing thread per queue (the
chapter's sizing guidance), with the queue count derived from the
container's `cpu.max` quota rather than `hardware_concurrency()` — the
same cgroup-aware sizing concern `15-thread-pool`'s `cgroup_probe` and
`32-concurrency-in-containers` demonstrate, reimplemented locally here
since every example in this project is self-contained.

[`src/concurrent_client.cpp`](src/concurrent_client.cpp) opens `--calls`
concurrent `ServerStreamEcho` RPCs: one `std::thread` per call (OS-level
concurrency), all released from the same starting line via a
`std::latch` so they actually overlap instead of trickling in one at a
time. Each call reads its stream to completion (or its immediate terminal
status, if rejected) and prints one `key=value` line:

```
call=3 status=OK code=0 messages=10 elapsed_ms=512.345
call=7 status=RESOURCE_EXHAUSTED code=8 messages=0 elapsed_ms=1.204
```

[`proto/echo.proto`](proto/echo.proto) declares a single RPC,
`ServerStreamEcho` — a unary call completes in one round trip, too fast to
reliably hold many concurrent callers open against a small cap; a
stream's longer, multi-event lifecycle (one `CallData` owns several live
`Write` tags in turn) is what makes the admission test possible at all.

## Graceful shutdown

On `SIGTERM`/`SIGINT`, a signal handler only sets a `volatile
sig_atomic_t` flag (signal-safe); `main()`'s loop reacts off-handler by
calling `Server::Shutdown(deadline)` and then `Shutdown()` on every
completion queue, continuing to pump `cq->Next()` (via each servicing
thread's loop) until it returns `false` on every queue before the process
exits — the chapter's explicit warning that skipping this per-queue drain
abandons outstanding tags instead of completing them.

## Verification: verify.lua

Both `async_server` and `concurrent_client` run **inside this one
container** — no compose, no second container. [`verify.lua`](verify.lua)
starts the server in the background (PID and exit code captured to files
via a plain shell idiom, no Lua process library needed), drives the
client through two phases against it over `127.0.0.1:50051`, then signals
shutdown and checks the server drained cleanly:

1. **Phase A — hard.** Exactly `cap` concurrent calls. Every call must
   succeed with exactly `repeat_count` messages; `RESOURCE_EXHAUSTED` must
   not appear at or under the cap.
2. **Phase B — hard.** `cap + overflow` concurrent calls. Every attempted
   RPC must terminate with `OK` or `RESOURCE_EXHAUSTED` — no hang, no
   missing output line, no third status. The number of `OK` calls must
   never exceed `cap` (the hard ceiling the server enforces);
   `RESOURCE_EXHAUSTED` must appear at least once (the cap was actually
   exercised); `ok + resource_exhausted` must equal the calls attempted
   exactly; every `OK` call has exactly `repeat_count` messages and every
   `RESOURCE_EXHAUSTED` call has zero (no partially-streamed-then-dropped
   calls).
3. **Shutdown — hard.** The server must exit with code 0 within 10s of
   `SIGTERM` — proof the per-queue drain loop actually terminates.
4. **Latency — soft.** Phase B's average admitted-call latency shouldn't
   be dramatically higher than Phase A's. Pacing is timer-driven, not
   contention-driven, so this should stay roughly flat under load; a WARN
   (not a failure) covers scheduling noise on a busy shared host.

`verify.lua` exits 0 on pass (with or without the latency WARN) and
non-zero on any hard failure, printing both phases' per-call summary and
the server's own log on failure.

## Running it

```bash
./demo.sh            # build + run server+client inside the container + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-25-concurrent-grpc.sh`](../../../scripts/test-concurrency-demo-25-concurrent-grpc.sh).

### A note on the build

This is **the heaviest Conan graph in this project**: gRPC + protobuf +
abseil, built fully static (`*/*:shared=False`, matching the sibling
`cpp-statelessness` tutorial's verified `10-grpc-microservices` reference
for the identical trio+version pins), plus everything gRPC's own Conan
recipe pulls in transitively — abseil, c-ares, re2, zlib,
OpenSSL/boringssl. Static linking means the runtime stage needs nothing
beyond `libstdc++` (no `/deps` shared-lib staging, unlike
`01-execution-models`'s oneTBB). The first build can take a long
time, especially if no prebuilt Conan binary matches this exact
UBI10/gcc/Conan profile and `--build=missing` falls back to compiling the
whole trio from source; a warm Conan layer in the image cache makes every
rebuild after that fast.

## Layout

```
25-concurrent-grpc/
├── proto/echo.proto           ServerStreamEcho(EchoRequest) returns (stream EchoResponse)
├── src/async_server.cpp       raw CompletionQueue server: CallData state machine, bounded admission, Alarm pacing, multi-queue, graceful shutdown
├── src/concurrent_client.cpp  N concurrent ServerStreamEcho calls released via std::latch
├── conanfile.py                grpc/1.54.3 + protobuf/3.21.12 + abseil/20230125.3, static
├── CMakeLists.txt             C++20, protoc + grpc_cpp_plugin codegen, -O2, two targets
├── Containerfile               UBI 10 (gcc + cmake + conan, static gRPC build) → ubi-minimal + lua runtime
├── verify.lua                  Lua 5.4 assertion harness (admission hard, shutdown hard, latency soft)
├── demo.sh                     the driver (docker build + docker run)
└── README.md                   this file
```
