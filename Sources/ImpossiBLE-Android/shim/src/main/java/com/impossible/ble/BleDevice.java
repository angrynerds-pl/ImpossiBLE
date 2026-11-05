package com.impossible.ble;

public final class BleDevice {
    private final String address;
    private final String name;

    public BleDevice(String address, String name) {
        this.address = address;
        this.name = name;
    }

    public String getAddress() {
        return address;
    }

    public String getName() {
        return name;
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof BleDevice && ((BleDevice) other).address.equals(address);
    }

    @Override
    public int hashCode() {
        return address.hashCode();
    }

    @Override
    public String toString() {
        return "BleDevice(" + address + ", " + name + ")";
    }
}
