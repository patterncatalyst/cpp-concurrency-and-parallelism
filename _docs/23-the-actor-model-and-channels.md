---
title: "The Actor Model and Channels"
order: 23
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "Actors and mailboxes, CSP-style channels, confinement as a design discipline, and how to write no-shared-state message passing in C++."
duration: "13 min"
---

<!-- PROVENANCE: NEW | anchor books: Grokking Concurrency, Grimm -->

## What we'll cover

- Introduce the actor model: independent actors with private state, communicating only through mailboxes.
- Introduce CSP-style channels as the alternative formalism underlying languages like Go, and the differences from actor mailboxes.
- Cover confinement as a discipline for guaranteeing no shared mutable state crosses a concurrency boundary.
- Show a concrete C++ pattern for no-shared-state message passing built on queues and move semantics.

## Actors and Mailboxes

<!-- TODO: cover the actor model's private-state-plus-mailbox structure with a small C++ example -->

## CSP-Style Channels

<!-- TODO: cover channel-based communication and how it differs from actor mailboxes -->

## Confinement

<!-- TODO: cover confinement as a design discipline that structurally prevents shared mutable state -->

## No-Shared-State Message Passing in C++

<!-- TODO: cover implementing move-only message passing over a queue to enforce confinement -->

## Running in a container

<!-- TODO: container callout — running the actor-style message-passing example across a small pool of worker containers -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
