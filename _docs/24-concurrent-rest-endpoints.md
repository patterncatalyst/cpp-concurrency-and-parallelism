---
title: "Concurrent REST Endpoints"
order: 24
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "Thread-per-request versus async handlers, a minimal Boost.Beast server, and the back-pressure and overload-shedding strategies that keep it alive under load."
duration: "14 min"
---

<!-- PROVENANCE: NEW | anchor books: Son -->

## What we'll cover

- Compare thread-per-request and async-handler models for serving REST traffic.
- Build a minimal Boost.Asio/Beast HTTP server as the concrete example for the rest of the chapter.
- Cover back-pressure: how the server signals it can't accept more work without collapsing.
- Cover overload shedding as the last line of defense when back-pressure isn't enough.

## Thread-per-Request vs Async Handlers

<!-- TODO: cover the concurrency model trade-off and its effect on maximum concurrent connections -->

## A Minimal Boost.Beast Server

<!-- TODO: cover the shape of a minimal async HTTP server built on Boost.Beast -->

## Back-Pressure

<!-- TODO: cover bounding in-flight requests and signaling the client to slow down -->

## Overload Shedding

<!-- TODO: cover rejecting new work early once the server is past its sustainable capacity -->

## Running in a container

<!-- TODO: container callout — running the Beast server under a load generator against a fixed container CPU and memory limit -->

## Standards: C++20 / C++23 / C++26

<!-- TODO: standards-delta — what changed across standards; use codetabs -->

## What we learned

<!-- TODO: recap -->
