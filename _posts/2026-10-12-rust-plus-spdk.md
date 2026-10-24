---
layout: post
title: "Rust + SPDK"
date: 2026-10-12 12:00:00 +0000
categories: [Rust, SPDK]
tags: [rust, spdk]
---

At one point, I thought, “It would be nice to port SPDK to Rust.”

SPDK is an innovative framework built around a share-nothing execution model: *share memory by communicating*, rather than the classical approach of locks and atomics, *communicate by sharing memory*. Surprisingly, Rust shares a lot of ideas with SPDK, and goes further: the compiler refuses to let data cross thread boundaries unless that is provably safe. SPDK follows the same discipline too, but only by convention, because C gives it no way to enforce anything.

But while reading through the SPDK codebase, I realized that SPDK and Rust complement each other rather than duplicate each other. It is better to *extend* SPDK with Rust than to rewrite it in Rust from scratch. A similar concept is Rust in the Linux kernel: it is a framework for writing Linux drivers in Rust, not a replacement for the C-based kernel.

That realization became [ironspdk](https://github.com/ironspdk/ironspdk), a Rust runtime for SPDK. This post is about the design choices behind it, including the trade-offs I accepted and the alternatives I rejected. If you've ever wondered “can't I just run Tokio on top of SPDK?”, this is the long answer.

## A one-minute refresher on SPDK's execution model

If you know SPDK well, feel free to skip ahead.

SPDK (the Storage Performance Development Kit) is a userspace storage framework built around polled-mode drivers: instead of waiting for interrupts, the CPU actively polls device queues. Its execution model has a handful of key pieces:

- **Reactors.** One event loop per CPU core, pinned to that core. A reactor never blocks; it just keeps spinning through its work.
- **Lightweight threads (`spdk_thread`).** The unit of scheduling on top of a reactor. A lightweight thread owns pollers and state, and all code touching a given piece of state runs on one of them.
- **Pollers.** Functions the reactor calls over and over: “is there a completion in this queue?”, “has this timeout expired?”.
- **Message passing.** If thread A needs something done with thread B's data, it sends B a message. Nobody reaches into somebody else's state.
- **I/O channels.** Per-thread contexts for talking to a device (for NVMe, essentially a queue pair). Every thread has its own channel, so submitting I/O needs no locks.

The result is lock-free by construction. State has exactly one owner, so you don't need atomics or mutexes (although you still can use them) to protect it, and cache lines stay where they are.

The price is the programming model. Everything is asynchronous, and in C asynchronous means callbacks.

## Where C hurts, and where Rust helps

Consider a common storage task: mirror a write to N backend devices and complete the parent request when all of them are done. In C with SPDK it looks roughly like this:

```c
struct mirror_io {
    struct spdk_bdev_io *parent;
    int remaining;
    bool failed;
};

static void child_io_done(struct spdk_bdev_io *child_io, bool success, void *cb_arg)
{
    struct mirror_io *m = cb_arg;

    if (!success)
        m->failed = true;

    spdk_bdev_free_io(child_io);

    if (--m->remaining == 0) {
        spdk_bdev_io_complete(m->parent, m->failed ?
            SPDK_BDEV_IO_STATUS_FAILED : SPDK_BDEV_IO_STATUS_SUCCESS);
        free(m);
    }
}

/* ...and in the submit path: allocate mirror_io, set remaining = n_children,
   submit one write per child with child_io_done as the callback, and handle every
   submission failure (-ENOMEM, io_wait retries, partial submits) by hand. */
```

Notice the `--m->remaining`. It is a plain, non-atomic decrement, and that is *correct*, because every callback for this request runs on the same SPDK thread. That's the SPDK model working beautifully. What's less beautiful is everything around it: the logic is smeared across callbacks, the state machine is something you write and debug by hand, and ownership (who frees what, and when) lives in your head.

The same idea in async Rust reads like straight-line code:

```rust
// Pseudocode in the spirit of examples/raid1 in the ironspdk repo, not the literal API
async fn mirror_write(&self, io: BdevIo) {
    let writes = self.children.iter().map(|child| child.write(&io));
    let results = join_all(writes).await;

    let ok = results.iter().all(|r| r.is_ok());
    io.complete(if ok { IoStatus::Success } else { IoStatus::Failed });
}
```

The compiler generates the state machine. Buffers, I/O channels and DMA memory are owned Rust values that get released by `Drop`, not by whoever remembers to call the right free function on the right path. And the “this object belongs to this thread” rule, which in C lives in comments and reviewers' heads, can become a type-level fact: a type that isn't `Send` simply cannot leave its thread.

That is the pitch in one paragraph: **keep SPDK's execution model, replace the programming model.**

## Extend, don't rewrite

The obvious alternative is the title of every “rewrite it in Rust” post: port SPDK itself. I decided against it, for the same reasons the Linux kernel did not become a Rust project overnight:

- **SPDK is a lot more than an event loop.** It contains drivers, a block device layer, NVMe-oF, vhost, ublk support, and years of hardware quirks and performance tuning. A from-scratch port would spend years reaching parity and then keep chasing upstream.
- **The bugs live in the logic layer.** The device drivers are mature and heavily exercised. The fragile code is what people write on top: RAID, replication, tiering, translation layers, anything with a complex asynchronous state machine. That is exactly where Rust's ownership model and `async`/`await` pay off.
- **SPDK's core is already the right design.** Thread-per-core, message passing, polling and per-thread I/O channels are what Rust's concurrency model naturally fits. Rewriting a design I agree with would be work with no upside.

So ironspdk exposes SPDK's primitives (lightweight threads, I/O channels, block device descriptors, DMA buffers) to Rust, and lets you write block devices and storage logic as Rust code. When the high-level abstractions aren't enough, you can drop down to the SPDK C API directly. SPDK stays C; your logic doesn't have to.

## The big question: where do the futures run?

Once you decide to bring `async`/`await` to SPDK, you immediately face the real design decision. Rust gives you the futures; *something* has to poll them. There are three realistic options.

### Option 1: a work-stealing scheduler (the Tokio way)

The default multi-threaded runtime in the Rust world is work-stealing: N worker threads, each with a local queue, plus a global injection queue. An idle worker steals tasks from a busy one. For a general-purpose server, with an unpredictable mix of short and long tasks and no idea which connection will be busy next, this is a fantastic default. You get automatic load balancing for free.

![Work-stealing scheduler: each core has a queue and a worker, and an idle worker steals a task from another core's queue]({{"/assets/img/work-stealing-scheduler.png" | relative_url}})

*An idle worker takes a task from another core's queue. The global injection queue is omitted for clarity.*

But look at what it demands:

- Tasks must be `Send + 'static`, because any task may resume on any worker.
- More synchronization and shared state, resulting in more `Arc` reference counting, mutexes and atomics.
- Wakeups can come from any thread, and every steal is a cross-core transaction on shared queue memory.

Now put that on top of SPDK. SPDK objects are *thread-affine by design*. An I/O channel belongs to the thread that obtained it. NVMe queue pairs aren't thread-safe. Per-thread caches and pollers assume nobody else touches them. A task that gets stolen mid-flight is suddenly holding an I/O channel on the wrong core. You'd have to wrap everything in `Send` shims with `unsafe`, or re-acquire channels on every migration. In other words, you would be rebuilding thread-affinity guarantees on top of a scheduler whose whole purpose is to violate them.

There's a performance angle too, which I'll come back to below: migrating tasks means cold caches and shared cache lines on the hot path.

### Option 2: a pluggable, general-purpose async runtime

The second approach is to bring an existing runtime and teach it about SPDK, either by writing an SPDK-aware I/O driver for it, or by running the runtime alongside SPDK and bridging the two with queues.

This approach is less unreasonable than it might seem, and it looks attractive on paper because you get a mature ecosystem. In practice I encountered several sources of friction:

- **Two schedulers.** SPDK's reactors and the runtime's workers both want to decide what runs where, and they both want the cores. You either oversubscribe the machine or carefully split it.
- **Two event loops.** General-purpose runtimes park a thread when idle and wake it through epoll or futexes. SPDK reactors busy-poll. Tokio's current-thread runtime wasn't designed to be stepped one tick at a time from somebody else's poller.
- **Hops across the boundary.** Every time work crosses from the SPDK world to the runtime and back you pay for a queue, a wakeup and usually a core switch, which is the kind of overhead SPDK exists to eliminate.
- **Less ecosystem than it appears.** Rust has no single, universally adopted runtime-agnostic abstraction for spawning, timers and I/O, so “pluggable” tends to mean “adapted to one runtime's internals”. And general-purpose crates built around byte-stream I/O traits don't know about SPDK's zero-copy, DMA-aligned buffers anyway.

It's more code, more moving parts, and the headline benefit mostly evaporates.

### Option 3: the executor extends the reactor

The third option is the one ironspdk takes. SPDK already has a scheduler: the reactor. It already decides which core runs what, and when pollers fire. So instead of adding a second scheduler, **the Rust executor becomes just another poller on the SPDK thread.**

- Every SPDK thread gets a run queue of ready tasks.
- A poller registered with SPDK drains that queue and polls the futures in it.
- A custom waker puts a task back on its own thread's run queue when it's ready to make progress.
- A task is born on one SPDK thread and stays there. No stealing, no migration.

![ironspdk executor extends the reactor: each task stays on the reactor and executor of the core that spawned it, and only explicit messages cross cores]({{"/assets/img/ironspdk-executor-extends-reactor.png" | relative_url}})

As you can see in the image, tasks stay on their SPDK thread, and only an explicit message ever crosses cores.

This choice buys several things at once:

- **There is still exactly one scheduler.** The reactor remains in charge, so Rust code and C code interleave naturally on the same event loop, and SPDK's pollers, messages and timeouts keep working as documented.
- **Futures don't have to be `Send`.** State that belongs to a thread can use `Rc` and `RefCell` instead of `Arc` and `Mutex`. The I/O channel handles in ironspdk are plain thread-local, reference-counted values, and that is only possible because tasks never leave their thread.
- **Thread affinity becomes a feature of the type system.** The thing SPDK relies on by convention is checked by the compiler.
- **Crossing cores is explicit.** If work needs to move to another thread, you say so, using SPDK's message passing. Nothing migrates behind your back.

One nuance I want to be fair about: SPDK is not opposed to moving work between cores. Its scheduler framework can migrate whole lightweight threads between reactors. But that is a coarse-grained, deliberate operation that moves an *owner* together with its pollers and channels, not individual tasks. That's the right granularity, and it fits an executor that keeps each task on its own thread.

## Cross-core accesses: the hidden tax

“Performance is doubtful because of cross-core data accesses” sounds like hand-waving until you do the arithmetic. These numbers are rough orders of magnitude, and they vary by CPU:

- An L1 cache hit costs on the order of a nanosecond.
- Pulling in a cache line that another core just modified costs tens of nanoseconds.
- Across sockets it can cost well over a hundred.

A single SPDK core can push on the order of a million I/Os per second, which leaves roughly a microsecond for *everything* that happens to one request. A work-stealing scheduler touches shared memory constantly: queue heads and tails, wakeup flags, reference counts on shared tasks, the mutex-protected state those tasks share. Each of those touches is a potential cache miss in the middle of a budget that is measured in hundreds of nanoseconds. Add the cold cache a stolen task finds on its new core, and you've spent a noticeable fraction of the I/O's budget on bookkeeping, before doing any storage work.

SPDK's design avoids all of this on purpose: one owner per piece of state, communication via messages, and nothing on the hot path that bounces cache lines between cores. An executor that extends the reactor keeps that property. The scheduler itself introduces no cross-core traffic, because there are no cross-core queues to touch. The only source of cache-line bouncing and cross-core traffic is message passing between SPDK threads.

(I'm not the first to notice that thread-per-core suits Rust: [Glommio](https://github.com/DataDog/glommio) and [Monoio](https://github.com/monoio-rs/monoio) make the same bet for io\_uring-based I/O. SPDK has simply been living there for a decade.)

## What the executor looks like from the inside

The whole thing is deliberately small:

- **Run queue:** the per-SPDK-thread queue of tasks that are ready to be polled.
- **Poller:** registered with SPDK; on each turn of the reactor it polls the futures in the run queue.
- **TLS:** lightweight per-SPDK-thread storage for contexts such as I/O channels.
- **Waker:** a custom implementation that re-queues a task on its thread's run queue.

From the user's side, writing a block device means implementing a small trait and spawning a future per request:

```rust
fn submit_io(&self, ch: BdevIoChannelRef, io: BdevIo) {
    SpdkThread::current().spawn(async move {
        // process the I/O, awaiting backend devices as needed...
        io.complete(IoStatus::Success);
    });
}
```

That's it. No callbacks to thread through, and no `Arc<Mutex<...>>` to protect request state.

## What you give up

No design is free, and I'd rather list the costs than pretend they don't exist:

- **No automatic load balancing.** If one core is hot, it stays hot. You design the partitioning yourself, for example by giving each core ownership of a slice of the address space or by serializing requests per stripe, as the RAID5 example does. This is the same discipline SPDK has always required.
- **You must not block.** A task that blocks stalls its whole reactor. That's inherent to polling-mode design, but Rust's familiar blocking escape hatches don't exist here.
- **Less ecosystem reuse.** Crates that assume a Tokio-style runtime won't just work, and timers and I/O need SPDK-aware implementations.
- **You inherit SPDK's constraints.** It's Linux-only for now, tied to specific SPDK versions, and the FFI boundary is still `unsafe` code that needs careful auditing.

For storage datapaths I think these are the right trade-offs. For a general-purpose web service they would be the wrong ones, and that's exactly why Tokio makes different choices.

There is one more cost, and it's the one people ask about first: **the abstractions themselves aren't free.** `async`/`await`, futures and Rust's wrapper types add a thin layer of native code between SPDK and your logic. C callbacks get wrapped into futures, and every task passes through a run queue and a waker. To put a number on it, I benchmarked the ironspdk RAID5 example against SPDK's own C `raid5f` module, using memory-backed (malloc) child block devices:

```bash
$ ./bench/bench-raid5.py --affinity 0x1,0x3,0xf --jobs 1,2,4 \
    --rw randrw,randwrite --isa sse --time 120 --format table 2>/dev/null
┌────────────────┬─────┬──────────┬──────┬───────────┬──────┬─────────┬──────────┐
│ implementation │ isa │ affinity │ jobs │ rw        │ time │ bw READ │ bw WRITE │
├────────────────┼─────┼──────────┼──────┼───────────┼──────┼─────────┼──────────┤
│ ironspdk       │ sse │ 0x1      │ 1    │ randrw    │ 120  │ 1022.0  │ 1021.7   │
│ spdk           │ sse │ 0x1      │ 1    │ randrw    │ 120  │ 1114.7  │ 1114.2   │
│ ironspdk       │ sse │ 0x1      │ 2    │ randrw    │ 120  │ 802.8   │ 802.4    │
│ spdk           │ sse │ 0x1      │ 2    │ randrw    │ 120  │ 818.3   │ 818.0    │
│ ironspdk       │ sse │ 0x1      │ 4    │ randrw    │ 120  │ 795.0   │ 794.7    │
│ spdk           │ sse │ 0x1      │ 4    │ randrw    │ 120  │ 759.6   │ 759.5    │
│ ironspdk       │ sse │ 0x1      │ 1    │ randwrite │ 120  │ 0.0     │ 1695.6   │
│ spdk           │ sse │ 0x1      │ 1    │ randwrite │ 120  │ 0.0     │ 1739.0   │
│ ironspdk       │ sse │ 0x1      │ 2    │ randwrite │ 120  │ 0.0     │ 1319.5   │
│ spdk           │ sse │ 0x1      │ 2    │ randwrite │ 120  │ 0.0     │ 1354.9   │
│ ironspdk       │ sse │ 0x1      │ 4    │ randwrite │ 120  │ 0.0     │ 1352.7   │
│ spdk           │ sse │ 0x1      │ 4    │ randwrite │ 120  │ 0.0     │ 1341.8   │
│ ironspdk       │ sse │ 0x3      │ 1    │ randrw    │ 120  │ 1215.7  │ 1215.3   │
│ spdk           │ sse │ 0x3      │ 1    │ randrw    │ 120  │ 1128.1  │ 1127.9   │
│ ironspdk       │ sse │ 0x3      │ 2    │ randrw    │ 120  │ 919.7   │ 919.3    │
│ spdk           │ sse │ 0x3      │ 2    │ randrw    │ 120  │ 824.5   │ 824.2    │
│ ironspdk       │ sse │ 0x3      │ 4    │ randrw    │ 120  │ 830.1   │ 829.6    │
│ spdk           │ sse │ 0x3      │ 4    │ randrw    │ 120  │ 765.4   │ 765.2    │
│ ironspdk       │ sse │ 0x3      │ 1    │ randwrite │ 120  │ 0.0     │ 1992.6   │
│ spdk           │ sse │ 0x3      │ 1    │ randwrite │ 120  │ 0.0     │ 1757.9   │
│ ironspdk       │ sse │ 0x3      │ 2    │ randwrite │ 120  │ 0.0     │ 1568.8   │
│ spdk           │ sse │ 0x3      │ 2    │ randwrite │ 120  │ 0.0     │ 1366.0   │
│ ironspdk       │ sse │ 0x3      │ 4    │ randwrite │ 120  │ 0.0     │ 1492.5   │
│ spdk           │ sse │ 0x3      │ 4    │ randwrite │ 120  │ 0.0     │ 1348.4   │
│ ironspdk       │ sse │ 0xf      │ 1    │ randrw    │ 120  │ 981.7   │ 981.4    │
│ spdk           │ sse │ 0xf      │ 1    │ randrw    │ 120  │ 877.3   │ 876.7    │
│ ironspdk       │ sse │ 0xf      │ 2    │ randrw    │ 120  │ 1351.4  │ 1350.8   │
│ spdk           │ sse │ 0xf      │ 2    │ randrw    │ 120  │ 1211.9  │ 1211.3   │
│ ironspdk       │ sse │ 0xf      │ 4    │ randrw    │ 120  │ 1422.6  │ 1421.9   │
│ spdk           │ sse │ 0xf      │ 4    │ randrw    │ 120  │ 1299.6  │ 1298.7   │
│ ironspdk       │ sse │ 0xf      │ 1    │ randwrite │ 120  │ 0.0     │ 1700.1   │
│ spdk           │ sse │ 0xf      │ 1    │ randwrite │ 120  │ 0.0     │ 1464.2   │
│ ironspdk       │ sse │ 0xf      │ 2    │ randwrite │ 120  │ 0.0     │ 2355.5   │
│ spdk           │ sse │ 0xf      │ 2    │ randwrite │ 120  │ 0.0     │ 1991.0   │
│ ironspdk       │ sse │ 0xf      │ 4    │ randwrite │ 120  │ 0.0     │ 2538.4   │
│ spdk           │ sse │ 0xf      │ 4    │ randwrite │ 120  │ 0.0     │ 2168.2   │
└────────────────┴─────┴──────────┴──────┴───────────┴──────┴─────────┴──────────┘
```

This benchmark was run on an AMD Ryzen 3 3200G with Radeon Vega Graphics (4 CPU cores), which supports AVX2 but not AVX-512. The tests use memory-backed SPDK bdevs (malloc bdevs). Both RAID5 implementations (ironspdk raid5 and SPDK raid5f) use the same RAID geometry and parity settings (2 data disks and 1 parity disk, strip size is 16 KiB), all I/Os are full-stripe (--bs=32kb). Right two columns of the table are `fio` bandwidth results in MiB/s. In the table, `isa` is the SIMD instruction set used for the parity calculation in ironspdk raid5 example (always SSE in this run), `affinity` is the CPU core mask used for the run, `jobs` is the number of `fio` jobs and `rw` is the I/O pattern. The right two columns are `fio` bandwidth results in MiB/s. The script is [bench/bench-raid5.py](https://github.com/ironspdk/ironspdk/blob/master/bench/bench-raid5.py) in the ironspdk repository.

The results depend a lot on the number of cores. On a single core (`0x1`) the two implementations are close: ironspdk is slower in four of six configurations (by 1.9% to 8.3%) and faster in two (by 0.8% and 4.7%), with a median of -2.2%. That is the closest thing to a pure measure of what the Rust layer costs, and it is consistent with a thin layer costing a few percent. With two or more cores, the situation changes: ironspdk is faster in all twelve configurations, by 7.8% to 18.3%: +11.1% on average with two cores (`0x3`) and +14.1% with four cores (`0xf`). The advantage is larger for writes (up to +18.3% for `randwrite`) than for mixed read/write. Overall ironspdk is ahead in 14 of 18 configurations (mean +7.8%, median +10.1%).

I wouldn't read the multi-core numbers as "Rust is faster than C". The gap is consistent enough across all twelve configurations that is is unlikely to be noise, but the two RAID5 implementations are different designs, and this benchmark does not isolate what causes the difference. Anyway, additional research (i.e. profiling with perf) is needed to explain *why* ironspdk is faster at this particular hardware when the number of cores increases.

That is a deliberately harsh test. A memory-backed device completes an I/O almost instantly, so the RAID layer's own CPU work is nearly the entire cost of a request, and every extra instruction shows up in full.

## Does it pay off?

The repository includes two reference block devices: a RAID1 and a RAID5 implementation. The RAID1 example is considerably shorter and easier to read than SPDK's own C `raid1.c`. The RAID5 example, with full-stripe writes, read-modify-write for partial stripes, parity reconstruction for a failed read and per-stripe request serialization, is the kind of intricate asynchronous state machine that I really wouldn't enjoy writing as a tangle of callbacks.

That's the real payoff: the execution model is unchanged, so the performance characteristics you already know from SPDK largely carry over, while the code that implements storage logic becomes smaller, linear and checkable by the compiler.

## SPDK + Rust = ?

So what does SPDK + Rust add up to?

**SPDK's execution model, with a better programming model.** Polling, thread-per-core, message passing and zero-copy I/O stay exactly as they are. What changes is how you express the logic on top: `async`/`await` instead of callback chains, ownership instead of manual lifetimes, and the compiler enforcing the thread-affinity rules that SPDK has always relied on.

The project is young, and there's plenty left to do: T10 PI (DIF/DIX) support, SIMD optimizations, bdev resizing, more block device examples, performance profiling tools and higher-level storage abstractions are all on the roadmap.

If you develop storage software and want to explore Rust without giving up SPDK's execution model, I'd love for you to try [ironspdk on GitHub](https://github.com/ironspdk/ironspdk).

Run the RAID1 or RAID5 examples. Inspect the design. Challenge the performance results. Tell me what is missing, what is wrong, and what you would do differently.

Issues, discussions, and pull requests are very welcome.
