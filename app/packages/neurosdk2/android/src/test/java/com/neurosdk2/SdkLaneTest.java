package com.neurosdk2;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** eeg_tracker test (VENDORED.md): the SDK lane that stands in for Android's main thread. */
public class SdkLaneTest {
    @Test
    public void runsTasksInOrderOnItsOwnThread() throws Exception {
        SdkLane lane = new SdkLane("test-lane", 10);
        List<Integer> order = Collections.synchronizedList(new ArrayList<>());
        List<Thread> threads = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch done = new CountDownLatch(20);
        for (int i = 0; i < 20; i++) {
            int n = i;
            Runnable task = () -> {
                order.add(n);
                threads.add(Thread.currentThread());
                done.countDown();
            };
            if (i % 2 == 0) lane.run(task);
            else assertTrue(lane.offer(task));
        }
        assertTrue(done.await(5, TimeUnit.SECONDS));
        for (int i = 0; i < 20; i++) assertEquals(i, (int) order.get(i));
        assertEquals(1, threads.stream().distinct().count());
        assertNotSame(Thread.currentThread(), threads.get(0));
        assertEquals("test-lane", threads.get(0).getName());
        assertTrue(threads.get(0).isDaemon());
    }

    @Test
    public void aTaskThatNeverReturnsHoldsTheLaneButNotTheCaller() throws Exception {
        SdkLane lane = new SdkLane("test-lane", 10);
        CountDownLatch stuck = new CountDownLatch(1);
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch after = new CountDownLatch(1);
        long t0 = System.nanoTime();
        lane.run(() -> {
            entered.countDown();
            awaitQuietly(stuck); // a native call that blocks for good
        });
        lane.run(after::countDown);
        assertTrue("the caller came back at once", System.nanoTime() - t0 < TimeUnit.SECONDS.toNanos(1));
        assertTrue(entered.await(5, TimeUnit.SECONDS));
        assertFalse("later calls wait behind it, in order", after.await(200, TimeUnit.MILLISECONDS));
        stuck.countDown();
        assertTrue(after.await(5, TimeUnit.SECONDS));
    }

    @Test
    public void scanResultsAreDroppedPastTheLimitWhileTheLaneIsStuckButCallsAreNot() throws Exception {
        SdkLane lane = new SdkLane("test-lane", 3);
        CountDownLatch stuck = new CountDownLatch(1);
        CountDownLatch entered = new CountDownLatch(1);
        lane.run(() -> {
            entered.countDown();
            awaitQuietly(stuck);
        });
        assertTrue(entered.await(5, TimeUnit.SECONDS));
        CountDownLatch ran = new CountDownLatch(3 + 5);
        int accepted = 0;
        for (int i = 0; i < 10; i++) if (lane.offer(ran::countDown)) accepted++;
        for (int i = 0; i < 5; i++) lane.run(ran::countDown);
        assertEquals(3, accepted);
        assertEquals(7, lane.dropped());
        assertEquals(8, lane.waiting());
        stuck.countDown();
        assertTrue(ran.await(5, TimeUnit.SECONDS));
        // room again once the lane moves
        assertTrue(lane.offer(() -> {}));
    }

    @Test
    public void aTaskThatThrowsDoesNotEndTheLane() throws Exception {
        SdkLane lane = new SdkLane("test-lane", 10);
        List<Thread> threads = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch after = new CountDownLatch(2);
        lane.run(() -> {
            threads.add(Thread.currentThread());
            throw new IllegalStateException("from a task");
        });
        lane.offer(() -> {
            throw new IllegalStateException("from a scan result");
        });
        lane.run(() -> {
            threads.add(Thread.currentThread());
            after.countDown();
        });
        lane.offer(after::countDown);
        assertTrue(after.await(5, TimeUnit.SECONDS));
        assertEquals("the same thread goes on", 1, threads.stream().distinct().count());
    }

    private static void awaitQuietly(CountDownLatch latch) {
        try {
            latch.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
