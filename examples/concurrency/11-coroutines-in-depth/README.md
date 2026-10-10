# concurrency/11-coroutines-in-depth — generator, Task<T>, and HALO

Compendium reference:
[Doc 11 — Coroutines in Depth](../../../_docs/11-coroutines-in-depth.md)

The runnable companion to compendium Doc 11. C++20 coroutines are a
language feature with no standard-library coroutine *type* at all —
`std::generator` doesn't exist until C++23, and this project targets
C++20 throughout — so both coroutine types below are hand-rolled, the way
the chapter builds them.

## What it demonstrates

[`src/coroutines_in_depth.cpp`](src/coroutines_in_depth.cpp) is one
translation unit, three things:

1. **`Generator<T>`** — a `co_yield`-based lazy sequence. `fibonacci()` is
   an intentionally infinite generator; `main()` consumes the first 10
   terms via an ordinary range-for loop plus an explicit `break`, which
   destroys the generator's coroutine while it's suspended mid-`co_yield`
   — well-defined per the chapter, not a leak.
2. **`Task<T>`** — a `co_await`-able coroutine type whose `final_suspend`
   performs **symmetric transfer**: instead of calling `.resume()` on the
   awaiting coroutine's handle directly (which would nest one stack frame
   per link in a chain), it *returns* that handle, which the compiler
   turns into a tail call. `compute()` chains two `co_await`'d calls to
   `add_one()` to exercise this path twice.
3. **HALO observation** — `ProbeTask<Tag>`'s `promise_type` overloads
   `operator new`/`operator delete` to count allocations and record the
   requested frame size. `tiny_probe()` has no state live across a
   suspension point; `fat_probe()` carries a 4 KiB buffer across a real
   internal `co_await`. The standard only *permits* eliding the frame
   allocation when the compiler can prove it doesn't outlive the caller
   ([dcl.fct.def.coroutine]: "may", not "shall") — this example measures
   what the build's actual toolchain does rather than assuming either
   answer.

The program prints `key=value` lines:

```
generator_sequence=0,1,1,2,3,5,8,13,21,34
task_result=23
tiny_frame_allocs=1 tiny_frame_bytes=48
fat_frame_allocs=1 fat_frame_bytes=4136 fat_buffer_bytes=4096
```

(Exact allocation counts/byte counts vary by toolchain and optimization
level — that variability is the point; see the HALO section of
`verify.lua` below.)

## Verification: verify.lua

Lua 5.4, run inside the container, same contract as every sibling demo:

1. **Generator correctness (hard).** The sequence must match the first 10
   Fibonacci terms exactly: `0,1,1,2,3,5,8,13,21,34`.
2. **Task<T> correctness (hard).** `compute()`'s `co_await`-chained result
   must be exactly `23` (`add_one(10)=11`, `add_one(11)=12`, `11+12=23`).
3. **HALO observation (soft).** Frame-allocation counts and sizes for the
   tiny and fat probes are reported, never asserted against a fixed
   expectation — whichever way a given toolchain resolves the elision
   opportunity, the demo says so and still passes.

## Running it

```bash
./demo.sh            # build + run coroutines_in_depth + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-11-coroutines-in-depth.sh`](../../../scripts/test-concurrency-demo-11-coroutines-in-depth.sh).

## Layout

```
11-coroutines-in-depth/
├── src/coroutines_in_depth.cpp   Generator<T>, Task<T>, HALO probes, prints key=value lines
├── conanfile.txt                 [requires] fmt/10.2.1 — output formatting only
├── CMakeLists.txt                C++20, -fcoroutines on GCC, find_package(fmt), -O2
├── Containerfile                 UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua                    Lua 5.4 assertion harness (generator+Task hard, HALO soft)
├── demo.sh                       the driver (docker build + docker run)
└── README.md                     this file
```

## Notes on scope

Compendium Doc 11's `<!-- EXAMPLE SPEC -->` additionally sketches a
`-O0`-through-`-O3` HALO optimization-level matrix (a multi-stage
Containerfile compiling the same probes at each level) and a
`coroutine_handle` ownership/lifetime-trap demonstration (an owned handle
freed by a destructor-based wrapper vs. an abandoned one that leaks). This
example keeps to a single `-O2` build — consistent with every other
example in this project — and the generator/`Task<T>`/HALO coverage above;
the `coroutine_handle` ownership discipline is still visible in the code
(`Task`, `Generator`, and `ProbeTask` all follow the destructor-calls-
`.destroy()` pattern the chapter names as the fix), just not exercised as
a separate failure-mode demonstration.
