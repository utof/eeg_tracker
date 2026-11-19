package com.neurosdk2;

import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * eeg_tracker change (VENDORED.md): one thread that does, in order, the SDK work Android's main thread did in
 * neurosdk2 1.0.21: the plugin's synchronous calls from Dart (getSensors, getState, getBattPower ...) and the
 * Bluetooth scan results handed to the native library. A native call that blocks for good then stops this thread
 * only: the main thread, where Flutter 3.29+ also runs every Dart isolate of the process, stays free, so the app
 * keeps answering and the night recorder's own deadline can fire. One lane per process, as there was one main
 * thread: the order and one-at-a-time behaviour the native library saw before are kept.
 */
public final class SdkLane {
    private static final SdkLane SHARED = new SdkLane("neurosdk2-calls", 1000);

    /** The process's lane. */
    public static SdkLane shared() {
        return SHARED;
    }

    private final ThreadPoolExecutor executor;
    private final int maxDroppable;
    private final AtomicInteger droppablePending = new AtomicInteger();
    private final AtomicLong dropped = new AtomicLong();

    /**
     * @param maxDroppable at most this many droppable tasks wait at once; more are dropped (a wedged lane must not
     *                     collect scan results without end)
     */
    public SdkLane(String threadName, int maxDroppable) {
        this.maxDroppable = maxDroppable;
        ThreadFactory factory = r -> {
            Thread t = new Thread(r, threadName);
            t.setDaemon(true);
            return t;
        };
        // One thread that never times out; an unbounded queue: a call from Dart is never dropped.
        executor = new ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, new LinkedBlockingQueue<>(), factory);
    }

    /** Runs {@code task} after every task given before it. Never dropped. */
    public void run(Runnable task) {
        executor.execute(() -> guarded(task));
    }

    /**
     * Like {@link #run}, but dropped when {@code maxDroppable} droppable tasks are already waiting (scan results: the next scan
     * reports the headband again).
     *
     * @return false when dropped
     */
    public boolean offer(Runnable task) {
        if (droppablePending.incrementAndGet() > maxDroppable) {
            droppablePending.decrementAndGet();
            dropped.incrementAndGet();
            return false;
        }
        executor.execute(() -> {
            droppablePending.decrementAndGet();
            guarded(task);
        });
        return true;
    }

    /**
     * An exception from a task is printed and the lane goes on: on the main thread Flutter's dispatcher caught it the
     * same way, while one escaping a thread of our own would end the app. An Error still ends it, as before.
     */
    private static void guarded(Runnable task) {
        try {
            task.run();
        } catch (RuntimeException e) {
            System.err.println("neurosdk2-calls: a task failed: " + e);
            e.printStackTrace();
        }
    }

    /** Droppable tasks dropped so far. */
    public long dropped() {
        return dropped.get();
    }

    /** Tasks waiting (not counting one that runs). */
    public int waiting() {
        return executor.getQueue().size();
    }
}
