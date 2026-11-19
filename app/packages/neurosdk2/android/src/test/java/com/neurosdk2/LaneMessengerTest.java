package com.neurosdk2;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.junit.Test;

import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import io.flutter.plugin.common.BinaryMessenger;

/**
 * eeg_tracker test (VENDORED.md): the plugin's Pigeon API set up through {@link LaneMessenger}. The test thread plays
 * Android's main thread, the way Flutter's dispatcher calls a handler: it hands the bytes over and frees them as soon
 * as the handler returns.
 */
public class LaneMessengerTest {
    private static final String API = "dev.flutter.pigeon.pigeon_neuro_api_package.NeuroApi.";

    /** The engine side: keeps the handlers, as Flutter's messenger does. */
    private static final class Engine implements BinaryMessenger {
        final Map<String, BinaryMessageHandler> handlers = new HashMap<>();

        @Override
        public void send(@NonNull String channel, @Nullable ByteBuffer message) {}

        @Override
        public void send(@NonNull String channel, @Nullable ByteBuffer message, @Nullable BinaryReply callback) {}

        @Override
        public void setMessageHandler(@NonNull String channel, @Nullable BinaryMessageHandler handler) {
            if (handler == null) handlers.remove(channel);
            else handlers.put(channel, handler);
        }

        /** One message from Dart; afterwards its bytes are gone (DartMessenger frees them). */
        void deliver(String method, List<Object> args, BinaryReply reply) {
            ByteBuffer bytes = PigeonMessages.NeuroApi.getCodec().encodeMessage(args);
            assertNotNull(bytes);
            bytes.rewind();
            handlers.get(API + method).onMessage(bytes, reply);
            bytes.clear();
            while (bytes.hasRemaining()) bytes.put((byte) 0x7f);
            bytes.limit(0);
        }
    }

    /** A NeuroApi whose getSensors blocks until released, like the native call that hung. */
    private static PigeonMessages.NeuroApi blockingApi(CountDownLatch release, List<String> calls,
            List<Thread> threads) {
        return (PigeonMessages.NeuroApi) Proxy.newProxyInstance(
                PigeonMessages.NeuroApi.class.getClassLoader(),
                new Class<?>[] {PigeonMessages.NeuroApi.class},
                (proxy, method, args) -> {
                    calls.add(method.getName() + "(" + args[0] + ")");
                    threads.add(Thread.currentThread());
                    switch (method.getName()) {
                        case "getSensors":
                            release.await();
                            return new ArrayList<PigeonMessages.FSensorInfo>();
                        case "getName":
                            return "BrainBit";
                        case "getBattPower":
                            return 77L;
                        default:
                            throw new UnsupportedOperationException(method.getName());
                    }
                });
    }

    private static Object decoded(ByteBuffer reply) {
        reply.rewind();
        return PigeonMessages.NeuroApi.getCodec().decodeMessage(reply);
    }

    @Test
    public void aBlockedSdkCallReturnsTheMainThreadAtOnceAndAnswersLaterInOrder() throws Exception {
        Engine engine = new Engine();
        CountDownLatch release = new CountDownLatch(1);
        List<String> calls = Collections.synchronizedList(new ArrayList<>());
        List<Thread> threads = Collections.synchronizedList(new ArrayList<>());
        PigeonMessages.NeuroApi.setUp(new LaneMessenger(engine, new SdkLane("test-lane", 10)),
                blockingApi(release, calls, threads));
        assertTrue(engine.handlers.containsKey(API + "getSensors"));

        BlockingQueue<String> answers = new ArrayBlockingQueue<>(10);
        long t0 = System.nanoTime();
        engine.deliver("getSensors", Collections.singletonList("scanner-1"),
                r -> answers.add("getSensors " + decoded(r)));
        engine.deliver("getName", Collections.singletonList("sensor-1"),
                r -> answers.add("getName " + decoded(r)));
        engine.deliver("getBattPower", Collections.singletonList("sensor-1"),
                r -> answers.add("getBattPower " + decoded(r)));
        long took = System.nanoTime() - t0;
        assertTrue("the main thread is back within 1 s, not stuck in the SDK", took < TimeUnit.SECONDS.toNanos(1));
        assertNull("nothing answered while the SDK blocks", answers.poll(300, TimeUnit.MILLISECONDS));

        release.countDown();
        // Pigeon's answer list: [value]. The bytes were copied, so each call saw its own arguments.
        assertEquals("getSensors [[]]", answers.poll(5, TimeUnit.SECONDS));
        assertEquals("getName [BrainBit]", answers.poll(5, TimeUnit.SECONDS));
        assertEquals("getBattPower [77]", answers.poll(5, TimeUnit.SECONDS));
        assertEquals(Arrays.asList("getSensors(scanner-1)", "getName(sensor-1)", "getBattPower(sensor-1)"),
                calls);
        assertEquals(1, threads.stream().distinct().count());
        assertNotSame(Thread.currentThread(), threads.get(0));
    }

    @Test
    public void withoutTheLaneTheCallingThreadIsHeldByTheBlockedCall() throws Exception {
        // neurosdk2 1.0.21 as published: the handler runs on the thread that delivers the message (Android's main
        // thread, which since Flutter 3.29 also runs Dart), so a native call that never returns holds that thread.
        Engine engine = new Engine();
        CountDownLatch release = new CountDownLatch(1);
        List<String> calls = Collections.synchronizedList(new ArrayList<>());
        PigeonMessages.NeuroApi.setUp(engine, blockingApi(release, calls, Collections.synchronizedList(new ArrayList<>())));
        CountDownLatch delivered = new CountDownLatch(1);
        Thread main = new Thread(() -> {
            engine.deliver("getSensors", Collections.singletonList("scanner-1"), r -> {});
            delivered.countDown();
        }, "main-standin");
        main.start();
        assertFalse("the delivering thread is still inside the SDK", delivered.await(300, TimeUnit.MILLISECONDS));
        release.countDown();
        assertTrue(delivered.await(5, TimeUnit.SECONDS));
    }

    @Test
    public void aHandlerThatThrowsIsAnsweredEmptyAndTheLaneGoesOn() throws Exception {
        Engine engine = new Engine();
        SdkLane lane = new SdkLane("test-lane", 10);
        BinaryMessenger messenger = new LaneMessenger(engine, lane);
        messenger.setMessageHandler("throws", (message, reply) -> {
            throw new IllegalStateException("boom");
        });
        BlockingQueue<Object> answers = new ArrayBlockingQueue<>(10);
        engine.handlers.get("throws").onMessage(ByteBuffer.allocate(0), r -> answers.add(r == null ? "empty" : r));
        assertEquals("empty", answers.poll(5, TimeUnit.SECONDS));
        CountDownLatch next = new CountDownLatch(1);
        lane.run(next::countDown);
        assertTrue(next.await(5, TimeUnit.SECONDS));
    }

    @Test
    public void copiesFromThePositionOnAndKeepsAnEmptyMessageEmpty() {
        ByteBuffer original = ByteBuffer.wrap(new byte[] {1, 2, 3, 4});
        original.position(1);
        ByteBuffer copy = LaneMessenger.copyOf(original);
        assertNotNull(copy);
        assertEquals(3, copy.remaining());
        assertEquals(2, copy.get(0));
        assertEquals(1, original.position()); // the original is left as it was
        assertNull(LaneMessenger.copyOf(null));
    }

    @Test
    public void unregisteringAChannelPassesTheNullThrough() {
        Engine engine = new Engine();
        BinaryMessenger messenger = new LaneMessenger(engine, new SdkLane("test-lane", 10));
        messenger.setMessageHandler("c", (message, reply) -> {});
        assertTrue(engine.handlers.containsKey("c"));
        messenger.setMessageHandler("c", null);
        assertTrue(engine.handlers.isEmpty());
    }
}
