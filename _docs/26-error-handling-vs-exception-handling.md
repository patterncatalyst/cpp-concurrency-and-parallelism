---
title: "Error Handling vs Exception Handling"
order: 26
layout: tutorial
sectionid: docs
part: correctness-errors-and-debugging
description: "Error codes versus exceptions, std::expected as a middle ground, propagating errors across thread, future, and coroutine boundaries, and exception safety under concurrency."
duration: "16 min"
---

<!-- PROVENANCE: NEW | anchor books: Williams, Lim -->

## What we'll cover

- Contrast error codes and exceptions as the two traditional C++ error-reporting mechanisms, with their respective costs.
- Introduce std::expected<T, E> as a value-based alternative that avoids exception-handling overhead on the hot path.
- Cover how an error or exception propagates across a thread boundary, a future, and a coroutine, and where each one can get lost.
- Cover noexcept and exception safety specifically under concurrency, where a thrown destructor or an unhandled exception in a worker thread has outsized consequences.

Every mechanism covered so far in this book — futures, coroutines, lock-free structures, thread pools — moves a unit of work off the calling thread, and none of it answers what happens when that unit of work fails. A thread has no caller to return to. A future's producer and consumer run on different stacks. A coroutine can suspend between starting and the moment anything observes whether it succeeded. Error handling that works fine single-threaded routinely breaks across these boundaries, usually by going silent rather than crashing loudly — the worse failure mode of the two.

## Error Codes vs Exceptions

C++ has offered two first-class error-reporting mechanisms since before the committee ever discussed concurrency primitives, and the choice between them is a choice about who pays, and when. An error code — a return value, an out-parameter, or the standard library's `std::error_code`/`std::error_condition` pair — costs the same on every call, whether or not anything goes wrong: a branch on the return value, maybe a comparison against a platform-specific category. That cost is paid unconditionally, which makes it fully predictable, and predictable is what a latency-sensitive call site wants. `std::error_code` exists to make these codes portable across subsystems — it pairs a numeric value with a `std::error_category` so a POSIX `ENOENT` and a Windows `ERROR_FILE_NOT_FOUND` both compare equal to the portable `std::errc::no_such_file_or_directory` condition without platform-specific branches at the call site.

Exceptions invert the trade. The *zero-cost* exception model GCC and Clang use on Linux (the Itanium C++ ABI's table-based unwinding) means a function that never throws pays nothing extra for the possibility — no implicit branch, no flag check, no reserved register at the call site. The compiler instead emits a side table, keyed by instruction-pointer ranges, that a runtime *unwinder* consults only when a `throw` executes: it walks the call stack frame by frame, looking up each return address to find which destructors must run and which `catch` blocks are candidates, until something catches it or the stack runs out and `std::terminate` fires. The table adds to binary size but nothing to steady-state execution time — the sense in which the model is "zero-cost until thrown": the cost error codes pay on every call, exceptions defer to the one call in however many that actually throws.

That deferred cost, once paid, is large relative to a branch. `__cxa_throw` allocates the exception object (normally on the heap, falling back to a small emergency pool only if ordinary allocation fails), consults the personality routine at every frame the unwind touches, and, in a multithreaded binary, synchronizes against the runtime's bookkeeping of in-flight exceptions per thread. None of this is proportional to the small, two-or-three-frame case most tutorials show; it is proportional to the worst-case depth your actual call graph permits, paying for every frame between `throw` and the matching `catch`. On a hot path where a failure is routine rather than exceptional — a lock-free queue reporting itself full, a parser rejecting malformed input, a retry loop's expected-to-sometimes-miss cache lookup — that cost model is backwards: the common case is the one you want cheapest, and an exception makes it free only by making the differentiating case disproportionately expensive. `std::system_error`, thrown by a failed `std::thread` construction or a `std::mutex::lock()` that fails at the operating-system level, is the standard library's own acknowledgment that some failures are rare and severe enough that the exception model's cost structure fits.

## std::expected

`std::expected<T, E>` (C++23) sits between those two mechanisms: a value type, returned like any other, holding either a `T` on success or an `E` on failure, queried with `has_value()`/`operator bool()` and unwrapped with `value()` (which throws `std::bad_expected_access<E>` if empty — opt back into the exception model only at the one point you choose) or the unchecked `operator*()`. It closes a real gap `std::optional<T>` (C++17) leaves open: `optional` tells a caller something is missing, but not *why* — a `std::optional<Connection>` from a connect attempt says nothing about whether the peer refused, DNS failed, or the handshake timed out, forcing callers onto a side channel exactly where `expected`'s second type parameter was built to go instead.

What makes `expected` more than a renamed two-member struct is its monadic interface, carried over from `optional`'s own C++23 additions: `and_then(f)` calls `f` with the contained value and returns its `expected`-returning result, short-circuiting to the final error if any step failed; `transform(f)` applies `f` to a contained value and rewraps the result for a step that cannot itself fail; `or_else(f)` runs only on the error path, letting a chain recover from or re-map a failure; `transform_error(f)` rewrites the error while leaving a success untouched. Chained together, these let a multi-step fallible pipeline — parse a header, validate a field, open a resource — read as a flat sequence of transformations with no nested `if (!result) return error;` guards and no exception in flight at any point: every step is a branch on a tag bit, not a stack walk. The Standards section below puts the three generations' approaches to this same connect-and-validate pipeline side by side.

## Propagating Errors Across Thread, Future, and Coroutine Boundaries

An exception's unwinding mechanism is defined in terms of one call stack. The moment a failure needs to cross from one stack to another — the thing every concurrency primitive in this book exists to let you do — that mechanism has nothing to attach to on its own, and each boundary in the standard library makes its own explicit decision about what happens instead.

A `std::thread`'s entry function has no caller frame to unwind into: if the callable passed to `std::thread` exits via an exception it does not catch internally, the library has no stack to propagate it onto, and the process calls `std::terminate()` — the same outcome [Threads in Modern C++]({{ '/docs/04-threads-in-modern-cpp/' | relative_url }}) describes for a `std::thread` object destroyed while still joinable, for the identical reason: no destination exists. This holds whether the thread is later joined or detached; by the time anyone could join it, the exception has already escaped and the process is gone. The only correct pattern wraps the entire callable body in a `try`/`catch` that never lets an exception reach the thread's top frame, converting it into something that *can* cross the boundary — a logged diagnostic, an atomic error flag a supervisor polls, or an exception stored explicitly in a shared result.

A `std::future` is exactly that deliberate channel. [Futures, Promises, and Packaged Tasks]({{ '/docs/10-futures-promises-packaged-tasks/' | relative_url }}) covers the mechanism in full: `std::async` and `std::packaged_task` wrap the producer's callable in a `try`/`catch` you never write, and a thrown exception is caught and stored in the shared state via `promise::set_exception(std::current_exception())` in place of a value. The consumer's `future::get()` rethrows that exact exception object — not a copy — the first time it is called, on the consumer's own thread: the one boundary in the standard library with first-class, built-in exception propagation, because a future's shared state is the explicit hand-off point both sides already synchronize through, unlike a bare detached thread with nothing waiting on it.

A coroutine's promise type makes the same default decision a thread's entry function does, easy to miss because the syntax looks nothing like `std::thread`. [Coroutines in Depth]({{ '/docs/11-coroutines-in-depth/' | relative_url }}) shows the compiler-generated `catch` block around a coroutine body calling the promise type's `unhandled_exception()` member whenever the body throws and does not catch internally. A minimal promise type's `unhandled_exception()` is one line, `std::terminate();`, reproducing the detached-thread outcome exactly: a coroutine that suspends, resumes, and then throws with nobody watching takes the whole process down. A production `Task`-style coroutine type avoids that default: its `unhandled_exception()` instead calls `exception_ = std::current_exception();`, and the coroutine's own `get()` (or the awaiter's `await_resume()`, if the `Task` is awaited) rethrows it when something asks for the result — hand-rolled, because the standard library ships the coroutine *machinery* without this convenience type.

{% include excalidraw.html name="26-error-propagation-boundaries" caption="Figure 26.1 — the same thrown exception at three boundaries: terminated outright from a detached thread, stored and rethrown from a future, stored and rethrown from a coroutine's own Task wrapper" %}
<!-- DIAGRAM SPEC: cream #fdfbf7 background, three side-by-side lanes. Lane 1 "detached std::thread", orange #a06030 header: a box "worker lambda" with a jagged red #c0392b lightning-bolt arrow labeled "throw, uncaught" straight down into a red box "std::terminate() -- no destination to unwind into". Lane 2 "std::future", blue #4a73b8 header: a box "producer (async/packaged_task)" with an arrow labeled "set_exception(current_exception())" into a shared-state box, then a green #5a8870 arrow labeled "get() rethrows, same object" into a "consumer thread" box. Lane 3 "coroutine Task", green #5a8870 header: a box "coroutine body" with an arrow labeled "unhandled_exception() stores it" into a "promise state" box, then an arrow labeled "awaiter's get() / await_resume() rethrows" into a "resuming caller" box. A footer note reads: all three start from the identical throw statement -- only the destination differs, and only two of the three are safe by default. -->

The pattern across all three boundaries: a synchronous `throw`/`catch` pair only works within one stack, so every mechanism that moves work onto another stack needs its own explicit store-and-rethrow convention, and the one case with none — a bare detached thread, or a coroutine's minimal default promise — terminates the process rather than losing the error silently, which is loud but rarely the behavior anyone intended.

## noexcept and Exception Safety Under Concurrency

`noexcept` is a promise to the compiler and a contract with the runtime, and the two sides matter differently under concurrency. To the compiler, `noexcept` permits optimizations unavailable to a function that might throw — no landing pads to reserve, and for a move constructor specifically, the difference between `std::vector` moving elements during a reallocation and falling back to copying them, since the strong exception-safety guarantee a reallocation needs only holds if a mid-move throw can't leave the container in a state between the old and new storage. To the runtime, the contract is blunter: if a function marked `noexcept` throws anyway, `std::terminate()` is called immediately, with no obligation to unwind the stack first — there is no partial credit for promising not to throw and almost getting away with it.

Destructors are the sharpest edge of this rule because they are implicitly `noexcept` since C++11 unless declared otherwise, for a reason that becomes obvious during stack unwinding: if an exception is already propagating and a destructor running as part of that unwind throws a second one, there are now two exceptions in flight with no well-defined way to resolve which the program is handling, and the standard resolves the ambiguity by calling `std::terminate()` outright. This is why [Mutual Exclusion and Locking]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }})'s RAII lock types stay safe even when code inside their scope throws: `std::mutex::unlock()` is specified never to throw, so `lock_guard`'s destructor — which calls exactly that — cannot become the second exception in a two-exception pileup. A custom RAII wrapper that does something non-trivial in its destructor (closing a socket, releasing a handle that can itself fail) has to preserve that guarantee explicitly; a destructor that can throw is a loaded clause nobody checks until a different exception is already unwinding through it.

Exception safety under concurrency needs the ordinary single-threaded guarantees — basic, strong, nothrow — plus one concern those don't by themselves address: the mutex. A function that holds a lock across a mutation and throws partway through leaves shared state exactly as broken for the *next* thread to acquire the lock as for the same thread continuing — a lock serializes access, it does not validate coherence of what it hands the next acquirer. The strong guarantee rescues this: a mutation written to either fully succeed or leave protected state untouched (build new state off to the side, commit it with one `noexcept` operation, such as a pointer swap or an atomic compare) guarantees any exception thrown mid-operation happens before the commit point, so the lock's eventual release hands off state that is either fully old or fully new, never half-updated. Code that mutates shared state in place, field by field, under a lock has no such guarantee: an exception thrown between field three and field seven of an eight-field update is visible, in full, to the next thread the mutex admits.

## Running in a container

The table-based unwinder depends on the `.eh_frame` section the compiler emits alongside the code it describes, shipped inside the binary rather than a separate debug-info file, so a minimal or distroless image built with `strip --strip-all` does not disable exception handling by removing debug symbols — `.eh_frame` is not `.debug_info`. What *can* go missing is the symbolic quality of the default terminate handler's diagnostic: `__gnu_cxx::__verbose_terminate_handler` prints the uncaught exception's `typeid` and `what()` to stderr before calling `abort()`, as readable as the binary's remaining symbol table allows — a fully stripped production image still terminates correctly, it just explains itself less legibly in the container's log, the only evidence a failure left behind.

A cgroup memory limit interacts with the exception path at allocation time: `__cxa_allocate_exception` normally allocates from the ordinary heap, but falls back to a small fixed emergency pool if that allocation fails, so a process unable to even allocate a `std::bad_alloc` object does not vanish without a trace. A container running close to its `memory.max` ceiling is where this fallback path gets exercised. None of this changes with CPU quota the way earlier chapters' mutex-contention stories do — unwinding cost is proportional to call-stack depth, not CPU share — but a throttled container stretches out how long that unwind takes in wall-clock terms, the same constant-factor tax every other code path in this book pays under `cpu.max`.

## Standards: C++20 / C++23 / C++26

C++20 has no value-based error channel beyond `std::optional<T>`, so the idiomatic choice for a function that can fail without throwing is a plain error code (often `std::error_code`, for cases mapping onto an existing OS or library domain) or `optional<T>`, when the only interesting fact is that failure happened, with no accompanying reason. C++23's `std::expected<T, E>` closes that gap by attaching a real error payload, with the monadic combinators above letting a chain of fallible steps compose without nested branches or an exception anywhere in it. C++26's senders/receivers model (`std::execution`, accepted via P2300, no shipping standard-library implementation as of this writing — the example below targets the `stdexec` reference implementation's shape, not a production compiler) generalizes the same outcome further: every sender completes along exactly one of three channels, `set_value`, `set_error`, or `set_stopped`, so error propagation is part of a pipeline's structure rather than a value a caller remembers to check, and `let_error` routes around a `set_error` completion the way `expected`'s `or_else` routes around a contained error today.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20 -- optional signals failure with no reason attached; a real
// cause has to travel through a side channel if the caller needs one.
std::optional<Connection> connect(const Endpoint& ep) {
    if (auto raw = try_connect(ep)) {
        return Connection{*raw};
    }
    return std::nullopt;  // caller learns only that it failed
}
```

```cpp
// C++23 -- std::expected carries the reason as a first-class value,
// and the monadic chain below never throws or branches explicitly.
std::expected<Connection, ConnectError> connect(const Endpoint& ep) {
    return resolve_dns(ep)
        .and_then([](const Address& addr) { return tcp_connect(addr); })
        .and_then([](RawSocket sock)      { return tls_handshake(sock); })
        .transform([](TlsSession s)       { return Connection{std::move(s)}; });
}
```

```cpp
// C++26 (proposed; targets the accepted P2300 std::execution model, not
// yet shipping in a mainstream standard library) -- the same pipeline as
// a sender chain, where a failure at any stage completes on set_error
// instead of set_value, and let_error supplies the recovery step.
ex::sender auto connect(ex::scheduler auto sch, Endpoint ep) {
    return ex::schedule(sch)
         | ex::let_value([ep] { return resolve_dns_async(ep); })
         | ex::let_value([](Address a) { return tcp_connect_async(a); })
         | ex::let_value([](RawSocket s) { return tls_handshake_async(s); })
         | ex::let_error([](auto err) { return ex::just(Connection::failed(err)); });
}
```

## What we learned

- Error codes pay a fixed, predictable cost on every call; exceptions pay nothing until thrown, then pay for table-based unwinding proportional to call-stack depth — why a hot path favors the former and a rare, severe failure tolerates the latter.
- `std::expected<T, E>` (C++23) gives a value-based error channel a real payload `std::optional<T>` never carried, and its monadic combinators chain fallible steps without an exception or a nested `if`.
- None of `std::thread`, a coroutine's default promise, or a bare detached task has anywhere to unwind an uncaught exception to, and all three call `std::terminate()` by default; `std::future` is the one boundary with built-in store-and-rethrow, and a production coroutine `Task` type hand-rolls the same pattern.
- `noexcept` destructors keep RAII locking safe during unwinding because `std::mutex::unlock()` cannot throw; the strong exception-safety guarantee, applied to a lock-protected mutation, prevents a thrown exception mid-update from handing the next thread a half-updated, inconsistent object.

Next, **debugging real races and deadlocks**: what a type system and an error channel cannot prevent at compile time still has to be caught and read off a live process — this chapter's `terminate()` is often the first visible symptom.
