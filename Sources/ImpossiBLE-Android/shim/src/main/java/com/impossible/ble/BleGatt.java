package com.impossible.ble;

import android.bluetooth.BluetoothGattService;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

public class BleGatt {
    private final List<BluetoothGattService> services;

    public BleGatt(List<BluetoothGattService> services) {
        this.services = new ArrayList<>(services);
    }

    public List<BluetoothGattService> getServices() {
        return new ArrayList<>(services);
    }

    public BluetoothGattService getService(UUID uuid) {
        for (BluetoothGattService service : services) {
            if (service.getUuid().equals(uuid)) return service;
        }
        return null;
    }
}
