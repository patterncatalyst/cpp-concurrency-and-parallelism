# concurrency/10-futures-promises-packaged-tasks — launch policies and a packaged_task worker pool

Compendium reference:
[Doc 10 — Futures, Promises, and Packaged Tasks](../../../_docs/10-futures-promises-packaged-tasks.md)

The runnable companion to compendium Doc 10. The one-line takeaway:
**`std::async`'s default launch policy is a silent correctness gap, not a
guarantee of concurrency** — the only way to know whether a task actually
ran concurrently is to ask it which thread it ran on, which is exactly
what this example does instead of trusting the API's own vocabulary.

## What it demonstrates

Two binaries, each addressing one half of the chapter.

[`src/launch_policy.cpp`](src/launch_policy.cpp) submits the same N trivial
callables under three launch policies, each callable reporting the thread
id it actually executed on:

- `std::launch::async` — every task must run on a thread **distinct** from
  the submitter, every time: the policy guarantees a new thread.
- `std::launch::deferred` — every task must run on the **submitter's own
  thread**, every time, and only inside the corresponding `future::get()`
  call: no new thread is ever created.
- the default policy (`async | deferred`) — reported, never asserted in a
  direction, because an implementation choosing either per call is
  standard-conforming.

```
policy=async    task=0 submitter_tid=140234881193024 exec_tid=140234872788544 same_thread=false start_ns=11 end_ns=48213
policy=deferred task=0 submitter_tid=140234881193024 exec_tid=140234881193024 same_thread=true  start_ns=0  end_ns=52109
RESULT: policy=async    n=5 all_distinct_from_submitter=true
RESULT: policy=deferred n=5 all_same_as_submitter=true
RESULT: policy=default  n=5 distinct_count=5 same_count=0
```

[`src/worker_pool.cpp`](src/worker_pool.cpp) is a small fixed-size thread
pool built around `std::packaged_task`: `submit()` wraps any callable in a
`packaged_task<R()>`, queues a type-erased thunk, and returns the task's
own future immediately. `--fail-at I` makes task `I` throw a
`std::runtime_error` instead of returning — the chapter's exception model
made observable: that exception is rethrown, intact, at task `I`'s own
`future::get()`, and every other task's result is completely unaffected.

```
task=6 status=ok result=36
task=7 status=exception caught_at=get what="task 7 failed on purpose"
task=8 status=ok result=64
RESULT: submitted=12 ok=11 exceptions=1 workers=4
```

Neither binary needs anything beyond the standard library for its
substance — `fmt` is pulled in for output formatting only, the same role
it plays in `20-mechanical-sympathy`.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container and checks, all as
**hard** assertions (both halves of this chapter are standard-mandated
guarantees, not performance claims a noisy host could mute):

1. **`launch_policy`.** Every `std::launch::async` task's `exec_tid` must
   differ from `submitter_tid`. Every `std::launch::deferred` task's
   `exec_tid` must equal `submitter_tid`. The default-policy round's
   results are printed for inspection only.
2. **`worker_pool`.** The task named by `--fail-at` must report
   `status=exception caught_at=get`; every other task must report
   `status=ok` with the arithmetically correct `result` (task `i` computes
   `i*i`); the summary line's `submitted`/`ok`/`exceptions` counts must be
   internally consistent.

`verify.lua` exits 0 on pass and non-zero on any hard failure, printing a
readable per-task log either way.

## Running it

```bash
./demo.sh            # build + run launch_policy/worker_pool + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-10-futures-promises-packaged-tasks.sh`](../../../scripts/test-concurrency-demo-10-futures-promises-packaged-tasks.sh).

Per the chapter's "Running in a container" section, run the image under a
CPU quota to compare the default policy's behavior at different core
counts:

```bash
docker run --rm --cpus=4 cpp-tut/concurrency-10-futures-promises-packaged-tasks:latest
docker run --rm --cpus=1 cpp-tut/concurrency-10-futures-promises-packaged-tasks:latest
```

`launch_policy`'s explicit `std::launch::async` round should still show
every task on a distinct thread id in both cases; whether the default
policy leans further toward deferred-like behavior under `--cpus=1` is
exactly the implementation-defined gap the chapter calls out, and this
program's `same_count`/`distinct_count` fields make it visible.

## Layout

```
10-futures-promises-packaged-tasks/
├── src/launch_policy.cpp   async/deferred/default comparison, per-task thread-id + timing report
├── src/worker_pool.cpp     fixed-size packaged_task pool, --fail-at exercises exception propagation
├── conanfile.txt           [requires] fmt/10.2.1 — output formatting only
├── CMakeLists.txt          C++20, find_package(fmt), -O2, targets launch_policy + worker_pool
├── Containerfile           UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua              Lua 5.4 assertion harness (both halves hard — no noise-prone timing claim)
├── demo.sh                 the driver (docker build + docker run)
└── README.md               this file
```
