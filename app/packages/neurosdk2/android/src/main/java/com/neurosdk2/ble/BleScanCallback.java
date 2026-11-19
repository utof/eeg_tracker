package com.neurosdk2.ble;

import android.annotation.SuppressLint;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;

import com.neurosdk2.SdkLane;

import java.util.List;

public class BleScanCallback extends ScanCallback {
    private final String TAG = "BleScanCallback";
    private long nativePointer = 0;

    public BleScanCallback(long pointer) {
        this.nativePointer = pointer;
    }


    @SuppressLint("MissingPermission")
    @Override
    public void onScanResult(int callbackType, ScanResult result) {
        super.onScanResult(callbackType, result);
        // eeg_tracker change (VENDORED.md): Android calls this on the main thread; the native library gets the
        // result on the SDK lane instead. The task holds this object, so finalize() cannot run before it.
        SdkLane.shared().offer(() -> {
            try {
                if(nativePointer == 0) return;
                OnScanResult(nativePointer,callbackType,result);
            } catch (Exception e) {
                //Log.d(TAG, "Error +" + e.getMessage());
            }
        });
    }

    @Override
    public void onBatchScanResults(List<ScanResult> results) {
        super.onBatchScanResults(results);
        // eeg_tracker change (VENDORED.md): on the SDK lane, as onScanResult.
        SdkLane.shared().offer(() -> {
            try {
                if(nativePointer == 0) return;
                if(!results.isEmpty())
                {
                    OnBatchScanResult(nativePointer,results);
                }
            } catch (Exception e) {
                //Log.d(TAG, "Error +" + e.getMessage());
            }
        });
    }

    @Override
    public void onScanFailed(int errorCode) {
        super.onScanFailed(errorCode);
        // eeg_tracker change (VENDORED.md): on the SDK lane, as onScanResult; never dropped.
        SdkLane.shared().run(() -> {
            try {
                if(nativePointer == 0) return;
                OnScanFailed(nativePointer,errorCode);
            } catch (Exception e) {
                //Log.d(TAG, "Error +" + e.getMessage());
            }
        });
    }
    @Override
    protected void finalize() throws Throwable {
        OnDestroy(nativePointer);
        nativePointer = 0;
        super.finalize();
    }

    private native void OnScanResult(long pointer,int callbackType,ScanResult result);

    private native void OnBatchScanResult(long pointer,List<ScanResult> result);

    private native void OnScanFailed(long pointer,int errorCode);
    private native void OnDestroy(long pointer);
}
