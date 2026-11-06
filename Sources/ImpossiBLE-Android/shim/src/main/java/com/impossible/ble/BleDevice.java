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

    /** A relayed device is never bonded; mirrors BluetoothDevice.BOND_NONE. */
    public int getBondState() {
        return 10;
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
