package com.neurosdk2;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.nio.ByteBuffer;

import io.flutter.plugin.common.BinaryMessenger;

/**
 * eeg_tracker change (VENDORED.md): the plugin's Pigeon API (PigeonMessages.NeuroApi) is set up through this
 * messenger, so each message from Dart runs on {@link SdkLane} instead of Android's main thread. Flutter hands the
 * message over on the main thread and frees its bytes as soon as the handler returns, so the bytes are copied
 * first. Everything else (sending, the event channels) goes to the engine's own messenger unchanged.
 */
public final class LaneMessenger implements BinaryMessenger {
    private static final String TAG = "NeuroSDK2";

    private final BinaryMessenger engine;
    private final SdkLane lane;

    public LaneMessenger(@NonNull BinaryMessenger engine, @NonNull SdkLane lane) {
        this.engine = engine;
        this.lane = lane;
    }

    @Override
    public void setMessageHandler(@NonNull String channel, @Nullable BinaryMessageHandler handler) {
        engine.setMessageHandler(channel, handler == null ? null : onLane(channel, handler));
    }

    @Override
    public void setMessageHandler(@NonNull String channel, @Nullable BinaryMessageHandler handler,
            @Nullable TaskQueue taskQueue) {
        // The lane is the queue: a Flutter task queue would run calls beside the scan results.
        setMessageHandler(channel, handler);
    }

    private BinaryMessageHandler onLane(String channel, BinaryMessageHandler handler) {
        return (message, reply) -> {
            ByteBuffer copy = copyOf(message);
            lane.run(() -> {
                try {
                    handler.onMessage(copy, reply);
                } catch (RuntimeException e) {
                    // What Flutter's own dispatcher does with a handler that throws: log it and answer empty.
                    Log.e(TAG, "Uncaught exception in " + channel, e);
                    try {
                        reply.reply(null);
                    } catch (RuntimeException alreadyAnswered) {
                        // the handler answered before it threw
                    }
                }
            });
        };
    }

    /** The bytes from the current position on, in a buffer of our own. */
    @Nullable
    static ByteBuffer copyOf(@Nullable ByteBuffer message) {
        if (message == null) return null;
        ByteBuffer copy = ByteBuffer.allocate(message.remaining());
        copy.put(message.duplicate());
        copy.flip();
        return copy;
    }

    @Override
    public void send(@NonNull String channel, @Nullable ByteBuffer message) {
        engine.send(channel, message);
    }

    @Override
    public void send(@NonNull String channel, @Nullable ByteBuffer message, @Nullable BinaryReply callback) {
        engine.send(channel, message, callback);
    }

    @Override
    public TaskQueue makeBackgroundTaskQueue(TaskQueueOptions options) {
        return engine.makeBackgroundTaskQueue(options);
    }

    @Override
    public void enableBufferingIncomingMessages() {
        engine.enableBufferingIncomingMessages();
    }

    @Override
    public void disableBufferingIncomingMessages() {
        engine.disableBufferingIncomingMessages();
    }
}
