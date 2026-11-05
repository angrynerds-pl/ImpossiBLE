package no.nordicsemi.android.ble.exception

import no.nordicsemi.android.ble.Request

open class ConnectionException : Exception()

class DeviceDisconnectedException : ConnectionException()

class BluetoothDisabledException : ConnectionException()

class RequestFailedException(val request: Request, val status: Int) : Exception("Request failed with status $status")

class InvalidRequestException(val request: Request) : Exception("Invalid request")
