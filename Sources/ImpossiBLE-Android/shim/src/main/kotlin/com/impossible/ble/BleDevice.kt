package com.impossible.ble

class BleDevice(val address: String, val name: String?) {
    override fun equals(other: Any?) = other is BleDevice && other.address == address

    override fun hashCode() = address.hashCode()

    override fun toString() = "BleDevice($address, $name)"
}
