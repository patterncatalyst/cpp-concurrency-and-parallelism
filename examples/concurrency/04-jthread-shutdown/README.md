# concurrency/04-jthread-shutdown — SIGTERM -> request_stop() -> clean exit

Compendium reference:
[Doc 4 — Threads in Modern C++](../../../_docs/04-threads-in-modern-cpp.md)

The runnable companion to compendium Doc 4's closing "Running in a
container" section. The one-line takeaway: **a process whose SIGTERM path
calls `request_stop()` on every outstanding `jthread` and then joins them
all exits cleanly, well inside an orchestrator's grace period** — no forced
`SIGKILL`, no resources abandoned mid-write.

## What it demonstrates

[`src/jthread_shutdown.cpp`](src/jthread_shutdown.cpp) starts N `jthread`
workers (default 4), each polling a `stop_token` in a 5ms loop. A real
`SIGTERM` handler is installed before any worker starts.

**One deliberate deviation from the chapter's literal phrasing:** the
handler does **not** call `request_stop()` itself.
`std::stop_source::request_stop()` is not guaranteed async-signal-safe — it
may touch an internal mutex and invoke any registered `stop_callback`s,
neither of which is safe inside a signal handler. The handler instead does
the one thing that *is* safe there: a relaxed store to a lock-free
`std::atomic<bool>`. The main thread polls that flag and performs every
`request_stop()`/`join()` call itself, which preserves the chapter's actual
claim — a real termination signal drives a clean, destructor/join-backed
shutdown — without smuggling undefined behavior into the one code path a
crash-safety chapter can least afford it in.

```
main: started 4 worker(s)
main: SIGTERM received, calling request_stop() on 4 worker(s)
worker 0: stop observed, exiting
worker 2: stop observed, exiting
worker 1: stop observed, exiting
worker 3: stop observed, exiting
main: shutdown complete, all workers joined
```

## Verification: verify.lua

Doc 4's EXAMPLE SPEC calls for a Lua harness asserting "the container's
exit code is 0 and the shutdown log line appears within the grace period,
not after a forced kill." [`verify.lua`](verify.lua) delivers that by
driving `jthread_shutdown` as its **own child process** rather than relying
on an external `docker stop`/`docker kill` against the container's PID 1:

1. Launches `jthread_shutdown` in the background, stdout redirected to a log
   file.
2. After a one-second startup delay, sends it a **real `SIGTERM`**
   (`kill -TERM`) — the same signal Kubernetes and `docker stop` both send.
3. Polls, once per second, for the process to exit on its own, bounded by a
   configurable grace period (default 8s). If it's still alive once the
   grace period elapses, the harness itself sends `SIGKILL` and records that
   as a **hard failure** — the exact "forced kill" case the chapter warns
   against.
4. Checks, per trial (default 2 trials):
   - exit code is `0`
   - no forced kill was needed
   - elapsed time from `SIGTERM` to exit stayed under the grace period
   - the log contains `main: SIGTERM received`, one
     `worker <id>: stop observed, exiting` line **per worker**, and the
     final `main: shutdown complete, all workers joined` line

Because this script's own exit code becomes the **container's** exit code
(`CMD` is `lua verify.lua`), a PASS here really does mean "the container
exited 0" — the spec's literal assertion — while also proving the thing
that assertion stands in for.

All of the above are **hard** assertions: this program either exits cleanly
inside the grace period with every worker accounted for, or it doesn't —
there's no timing-dependent "slower but still correct" case to treat as
soft, unlike the mechanical-sympathy or deadline-propagation demos.

## Running it

```bash
./demo.sh            # build + run jthread_shutdown + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-04-jthread-shutdown.sh`](../../../scripts/test-concurrency-demo-04-jthread-shutdown.sh).

To see the real orchestrator-level signal path instead (SIGTERM delivered
to the container's own PID 1 by the container runtime):

```bash
docker run --rm --name jthread-shutdown-demo --entrypoint jthread_shutdown \
    cpp-tut/concurrency-04-jthread-shutdown:latest &
sleep 1
docker stop -t 10 jthread-shutdown-demo   # sends SIGTERM, waits up to 10s, then SIGKILL
docker logs jthread-shutdown-demo
```

## Layout

```
04-jthread-shutdown/
├── src/jthread_shutdown.cpp   N jthread workers, SIGTERM -> flag -> request_stop()+join() on main thread
├── conanfile.txt              no external deps — pure standard library + POSIX signals
├── CMakeLists.txt             C++20, -O2, target jthread_shutdown
├── Containerfile               UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua                  Lua 5.4 assertion harness (drives jthread_shutdown as its own child, sends a real SIGTERM, enforces a grace period)
├── demo.sh                     the driver (docker build + docker run)
└── README.md                   this file
```
