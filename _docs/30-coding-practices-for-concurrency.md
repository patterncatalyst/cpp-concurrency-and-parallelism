---
title: "Coding Practices for Concurrency"
order: 30
layout: tutorial
sectionid: docs
part: practice
description: "Immutability, RAII locking, const-correctness as a concurrency tool, minimizing and confining shared state, and the naming and documentation conventions that make a threading contract legible without reading the implementation."
duration: "15 min"
---

<!-- PROVENANCE: NEW | anchor books: Williams, Grimm -->

## What we'll cover

- Make immutability the default for any data shared across threads, reducing the surface that needs synchronization at all.
- Reaffirm RAII locking and const-correctness as baseline discipline, not optional polish.
- Cover minimizing shared state through thread confinement, so most data never needs a lock in the first place.
- Establish naming and ownership conventions that make it obvious, from the type alone, which thread or scope owns a piece of state.

Every chapter so far has been about a mechanism: a primitive, a pattern, a way of structuring work across threads. This one is about the coding habits that decide whether those mechanisms stay correct once a second engineer touches the code, six months after the first one got it right under deadline. None of what follows is novel in isolation — RAII locking and const-correctness are old advice — but concurrent code is where skipping them stops being a style complaint and starts being a race that reproduces once a quarter, under load, on a host nobody is watching.

## Immutability by Default

The cheapest way to avoid synchronizing access to data is to make the data impossible to write to after it's constructed. An immutable value shared across threads needs no lock for reads, because there is no write for a read to race with — every thread sees the same bytes for the object's entire lifetime, and [Atomics and the Memory Model]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }})'s acquire/release reasoning only has to cover the single act of publishing the object, not every subsequent access to it. Publication itself still needs care: a pointer to a newly constructed immutable object has to become visible to other threads through a mechanism with the right ordering — `std::call_once` for a lazily constructed singleton, a `std::latch` gating readers until a value is ready, or a release store paired with an acquire load on the pointer that exposes it — but that's a one-time cost paid at construction, not a per-access cost paid on every read.

The common structural pattern this enables is a snapshot: rather than mutating a shared object in place under a lock, construct a new immutable version and publish it by swapping a pointer. Readers holding the old pointer keep reading a consistent, if slightly stale, value, and a `std::shared_ptr<const T>` (or a plain atomic pointer swap) makes the old version's deallocation automatic once the last reader releases it. This trades a lock held for every read for an atomic swap held for none of them — readers never block each other or the writer, at the cost of occasionally reading a version a step behind the latest write. For configuration, routing tables, and reference data, read far more often than changed, that trade is almost always right, and it's the same shape [Lock-Free Data Structures]({{ '/docs/09-lock-free-data-structures/' | relative_url }}) used for a single value, generalized to an entire object.

Value semantics reinforce the habit at a smaller scale: passing a small object by value into a function running on another thread, rather than a pointer to a shared mutable one, means that function operates on its own copy and can never race with the original. The cost is a copy; the benefit is that an entire category of aliasing bug — two threads holding different names for the same mutable memory — cannot occur, because there is no shared memory for it to occur in.

## RAII Locks and const-Correctness

A bare `mutex.lock()` paired with a bare `mutex.unlock()` is a bug waiting for an exception or an early return between the two calls. Every lock acquisition in this book's examples, and every lock acquisition in production code that wants to survive a code review, goes through an RAII guard: `std::lock_guard` for the single-mutex, no-early-unlock case, `std::unique_lock` when the lock needs to be released early, waited on with a condition variable, or transferred, and `std::scoped_lock` when more than one mutex needs to be held at once, because it takes all of them through `std::lock`'s deadlock-avoiding algorithm rather than acquiring them one at a time in an order that might differ between two call sites. The guarantee all three provide is the same: the lock releases on every exit path — normal return, early return, or an exception unwinding through the scope — without a single line of cleanup code at each exit point. A codebase with a bare `lock()`/`unlock()` pair anywhere in it has, by construction, at least one path where an exception leaves that mutex held forever, and the bug is invisible until the exact exception that triggers it fires in production.

const-correctness earns a second job in concurrent code beyond its usual role of catching accidental mutation at compile time: a `const` member function is a signal to a caller that the call is read-only and, by implication, safe to call from multiple threads at once — provided the type's invariants hold under concurrent reads, which is exactly the caveat that makes `const` a hint rather than a guarantee. A `const` accessor that quietly maintains a mutable cache (a memoized result stored in a `mutable` member, recomputed lazily on first access) is not thread-safe just because its signature promises not to mutate observable state; two threads calling it concurrently can race on the cache write even though neither call looks, from its signature, like a write at all. The fix is not to avoid `mutable` caches — they're a legitimate pattern — but to pair every `mutable` member with its own synchronization (commonly a `mutable std::mutex` alongside the cache, locked inside the `const` method) so the method's `const` qualifier and its actual thread-safety agree. The practice this chapter asks for is narrower than "use `const` more": it's that a `const` method's thread-safety claim should be verifiable by reading its body, not assumed from its signature, and that any `mutable` state inside one is a flag for exactly that check.

## Minimizing Shared State and Thread Confinement

The data that needs no lock at all is the data no other thread can see, and the single highest-leverage habit in concurrent code is reducing how much data falls into that category versus how much genuinely has to be shared. [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }})'s work-stealing deque is itself an instance of this principle applied to a queue: each worker's own end of its deque is effectively confined, touched by that worker alone in the common case, and only the rare steal crosses the boundary — which is exactly why the common case needs no lock while the rare one does. The same idea scales down to ordinary counters and accumulators: a per-thread, cache-line-padded counter that each thread increments locally and that gets summed only at a well-defined reduction point (end of a batch, export interval, shutdown) avoids every one of the cache-coherence round trips a single shared atomic counter pays on every increment under contention, the false-sharing cost [Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }}) covered in detail.

`thread_local` storage is the language's direct tool for this: a `thread_local` accumulator, buffer, or random-number generator state needs no synchronization whatsoever, because the language guarantees each thread its own instance, and the only discipline required is remembering that a `thread_local`'s lifetime is tied to the thread, not to any particular call, which matters for thread-pool workers that outlive any single task. [The Actor Model and Channels]({{ '/docs/23-the-actor-model-and-channels/' | relative_url }}) generalized confinement into a full design discipline — an actor's private state is confined to its own thread for its entire lifetime, and the only way anything crosses that boundary is a moved message through a mailbox — and that generalization is worth defaulting toward whenever a component's correctness is easier to state as "one thread owns this, always" than as "multiple threads touch this, carefully." Message passing, not shared mutable memory, is the mechanism that moves data between confined regions without ever letting two threads hold a mutable handle to the same object at once.

## Naming and Ownership Discipline

A reviewer looking at a function signature or a type name, without reading the implementation, should be able to tell whether a call is safe to make concurrently, and naming is the cheapest tool for making that true. A `Monitor<T>` wrapper — a small template holding a `T` and a `std::mutex` together, exposing access only through an accessor that returns a lock-holding handle — encodes the lock requirement in the type system rather than a comment: there is no way to touch the wrapped `T` without going through the accessor, because the raw member is private and nothing else exposes it. This is strictly better than a data member named `data_` next to a comment reading "protected by `mutex_`," because the compiler enforces the wrapper's rule and cannot enforce the comment's.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, two side-by-side panels contrasting enforcement. Left panel header "Comment-guarded (not enforced)" (red #c0392b): a class box containing a public data member "data_ : T" and a mutex "mutex_", with a faded grey sticky-note "// protected by mutex_" beside data_; three caller arrows reach data_ directly — one through "lock(mutex_)" (green #5a8870) and two red #c0392b arrows bypassing the lock entirely, each tagged "compiles fine". Right panel header "Monitor<T> (structurally enforced)" (green #5a8870): a Monitor box with PRIVATE "value_ : T" + "mutex_" sealed inside (a lock glyph on the box), exposing only one accessor "lock() -> Handle". A single caller arrow goes through the accessor, which returns an orange #a06030 "Handle { holds lock + T& }" box; label "no path to value_ except through the lock — the raw member is unreachable". Caption beneath both: "the compiler enforces the wrapper's rule; it cannot enforce the comment." -->
{% include excalidraw.html name="30-monitor-encapsulation" caption="Figure 30.1 — a comment-guarded member leaves unlocked access compiling fine; a Monitor<T> makes the lock the only path to the data" %}

```cpp
template <typename T>
class Monitor {
public:
    explicit Monitor(T value) : value_(std::move(value)) {}

    // The only way to touch value_: a lock-holding handle whose lifetime
    // is the critical section. There is no path that reaches value_
    // without going through here.
    template <typename F>
    auto with_lock(F&& f) {
        std::lock_guard lk(mutex_);
        return std::forward<F>(f)(value_);
    }

private:
    std::mutex mutex_;
    T value_;
};
```

Beyond individual types, naming conventions that mark ownership and affinity at the call site pay off across a whole codebase: a suffix or wrapper that distinguishes a type meant to be shared across threads (`Shared<T>`, `Atomic<T>`) from one meant to stay confined to its creating thread (`ThreadConfined<T>`, or simply a type with no thread-safety claim at all, treated as confined by default) turns "can I call this from another thread" from a question that requires reading the implementation into one answerable from the declaration. The convention only works if it's applied consistently and the default — a type with no annotation — means confined, not shared, since defaulting to "assume it's safe to share" is exactly the assumption that produces a race the first time it's wrong.

Documentation closes the gap naming can't: a function's threading contract — thread-safe without qualification, safe for concurrent calls from different objects but not the same one, safe for concurrent reads but not a concurrent read and write, or usable only from one specific thread (the owning thread of a confined design) — belongs in a comment at the declaration, in the same place a precondition or a complexity guarantee would go, because a caller deciding whether a given call site is safe needs that answer before writing the call, not after debugging a race that assumed otherwise. The standard library's own containers document exactly this kind of guarantee (concurrent `const` reads are safe, a concurrent read and a write are not, a single container has one implicit "owner" for any mutating call) precisely because the alternative — a caller guessing — is where races that pass code review come from.

## Running in a container

Clang's Thread Safety Analysis turns part of this chapter's naming discipline into a compile-time check rather than a convention a reviewer has to remember to apply. Annotating a guarded member with `GUARDED_BY(mutex_)` and a locking function with `REQUIRES(mutex_)` lets `-Wthread-safety` reject, at compile time, any access to the guarded member that isn't provably protected by the right lock — the `Monitor<T>` pattern above gets the same guarantee structurally, through encapsulation; the annotations get it for code that can't be restructured that way, by making the "protected by" comment a machine-checked fact instead of an assertion.

Running that check reproducibly belongs in a container rather than depending on whichever Clang version happens to be on a given machine: a pinned-version Clang image (built from a UBI base, matching this book's container convention) with `clang-tidy`'s concurrency checks enabled — `-Wthread-safety` plus `cppcoreguidelines-*` and `concurrency-mt-unsafe` from the Core Guidelines checker set — run over the example code as a CI gate catches a missing annotation or a lock taken in the wrong order before it reaches a reviewer, let alone production. The container pins the exact Clang version the annotations were validated against, which matters because `-Wthread-safety`'s diagnostics have changed in both directions (new checks added, edge cases in attribute inheritance fixed) across Clang releases, and a check that passes locally on one version and fails in CI on another is a worse outcome than not running the check at all.

## Standards: C++20 / C++23 / C++26

Three standards narrow different gaps between a coding practice and the language enforcing it: guaranteed initialization order without a runtime race, a single function body serving both the `const` and non-`const` cases a `Monitor`-style accessor needs, and a pipeline model where an ownership transfer is a visible stage rather than an implicit hand-off.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: constinit guarantees compile-time, constant initialization for a
// shared immutable value — no runtime initialization order to race on,
// and no risk of the "static local with a runtime-computed value" path
// that relies on magic-statics locking the first time every caller reaches it.
// The initializer must be a constant expression, so the helper is constexpr
// and RoutingTable is a literal type; a runtime-computed value would not compile.
constexpr RoutingTable make_default_routes();
constinit const RoutingTable kDefaultRoutes = make_default_routes();
```

```cpp
// C++23: "deducing this" (an explicit object parameter) lets one function
// body serve both a const and non-const accessor on a Monitor-style type,
// instead of hand-duplicating the body for each overload and risking the
// two copies drifting out of sync — a real risk once one of them grows a
// second lock or an extra check the other quietly doesn't get.
template <typename T>
class Monitor23 {
public:
    template <typename Self, typename F>
    auto with_lock(this Self&& self, F&& f) {
        std::lock_guard lk(self.mutex_);
        return std::forward<F>(f)(self.value_);
    }

private:
    mutable std::mutex mutex_;
    T value_;
};
```

```cpp
// C++26 (proposed; targets the accepted P2300 std::execution model, not
// yet shipping in a mainstream standard library — shown against the
// stdexec reference implementation's API shape). Ownership of a value
// moves explicitly from one pipeline stage to the next as a sender chain,
// making the hand-off a visible part of the code's structure rather than
// an implicit assumption about which thread currently holds the data.
namespace ex = std::execution;

ex::sender auto pipeline =
    ex::schedule(owning_stage.get_scheduler())
    | ex::then([v = std::move(owned_value)]() mutable { return validate(std::move(v)); })
    | ex::then([](auto v) { return publish(std::move(v)); });
```

`constinit` closes a narrow but real gap: a `const` global or static initialized from a runtime computation already gets thread-safe initialization from the "magic statics" guarantee C++11 added, but that guarantee is enforced with a runtime check on every subsequent access past the first, where `constinit` instead requires the initializer to be a constant expression, removing the runtime check entirely because there is no race window to guard against in the first place. "Deducing this" solves a smaller but recurring annoyance in lock-wrapper types like `Monitor`: before C++23, a type wanting both a `const` and non-`const` locking accessor either duplicated the body (with the attendant risk of the two copies diverging) or reached for a `const_cast` to share one implementation, which is exactly the kind of workaround that erodes the const-correctness guarantee this chapter argued for. `std::execution`'s relevance here is the same caveat as other chapters: no shipping compiler implements it, and the sender chain above illustrates a direction — ownership transfer as a pipeline stage — worth knowing about, not a pattern to build on today.

## What we learned

- Immutable, shared data needs no lock for reads because there is no write to race with; the recurring pattern is a snapshot published by an atomic pointer swap, trading a per-read lock for a one-time publication cost.
- RAII locking (`lock_guard`, `unique_lock`, `scoped_lock`) is non-negotiable baseline discipline, not polish — a bare `lock()`/`unlock()` pair is a bug the first time an exception or an early return skips the matching unlock.
- `const` signals read-only intent and, by implication, concurrent-call safety, but a `mutable` cache inside a `const` method breaks that implication unless the cache has its own synchronization; verify a `const` method's thread-safety claim by reading its body, not its signature.
- Minimizing shared state through thread confinement — `thread_local` storage, per-thread accumulators reduced at well-defined points, actor-style private state reached only through a mailbox — removes the need for synchronization entirely over the data that's confined, which is cheaper than synchronizing it correctly.
- Naming and documentation (a `Monitor<T>` wrapper that makes a lock structurally unavoidable, a `Shared<T>`/confined-by-default convention, a threading contract written at the declaration) turn "is this call safe to make concurrently" into a question answerable from the type and the comment, not from reading the implementation — and Clang's Thread Safety Analysis, pinned in a container, makes part of that convention a compiler-enforced fact instead of a reviewer's assumption.

[Design and Architecture Patterns]({{ '/docs/31-design-and-architecture-patterns/' | relative_url }}) takes these per-type habits up a level, to the architectures — pipelines, sharding, half-sync/half-async — that decide how whole systems of these well-behaved pieces fit together.
