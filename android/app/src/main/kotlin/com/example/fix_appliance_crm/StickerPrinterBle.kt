package com.example.fix_appliance_crm

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

/**
 * Принтер наклеек Phomemo (M250 и вся M-серия) по Bluetooth LE.
 *
 * Канал `fix_appliance/sticker_printer`:
 *  - `scan {timeoutMs}` → список `{id, name, rssi}` найденных устройств с именем;
 *  - `print {id, steps:[{data, delayMs}], chunkSize, chunkDelayMs}` → подключиться,
 *    включить уведомления `ff03`, записать шаги в характеристику `ff02` сервиса
 *    `ff00` и отключиться. Так же делает phomymo, с которым M250 печатает.
 *
 * Байты команд собирает Dart (`PhomemoCommands`); здесь только транспорт.
 * Каждая запись ждёт `onCharacteristicWrite`: Android не принимает следующую,
 * пока не подтвердил предыдущую, даже для записи без ответа. Ответы принтера
 * (`01 01` на запись, `1A 06 88` — нет бумаги) идут в лог `StickerPrinterBle`.
 */
class StickerPrinterBle(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)

    private class Step(val data: ByteArray, val delayMs: Int)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scan" -> scan(call.argument<Int>("timeoutMs") ?: 6000, result)
            "print" -> print(call, result)
            "isEnabled" -> result.success(adapter()?.isEnabled == true)
            else -> result.notImplemented()
        }
    }

    private fun adapter(): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun granted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun canScan(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            granted(Manifest.permission.BLUETOOTH_SCAN)
        } else {
            granted(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun canConnect(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            granted(Manifest.permission.BLUETOOTH_CONNECT)

    @SuppressLint("MissingPermission")
    private fun scan(timeoutMs: Int, result: MethodChannel.Result) {
        val adapter = adapter()
        if (adapter == null) {
            result.error("unavailable", "Bluetooth unavailable", null)
            return
        }
        if (!adapter.isEnabled) {
            result.error("off", "Bluetooth is off", null)
            return
        }
        if (!canScan()) {
            result.error("permission", "Bluetooth scan permission missing", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.error("unavailable", "BLE scanner unavailable", null)
            return
        }
        val found = LinkedHashMap<String, Map<String, Any>>()
        val replied = AtomicBoolean(false)
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scan: ScanResult) = record(scan)

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { record(it) }
            }

            override fun onScanFailed(errorCode: Int) {
                if (replied.compareAndSet(false, true)) {
                    main.post { result.error("scan", "BLE scan failed: $errorCode", null) }
                }
            }

            private fun record(scan: ScanResult) {
                val name = scan.scanRecord?.deviceName
                    ?: (if (canConnect()) scan.device.name else null)
                    ?: return
                if (name.isBlank()) return
                synchronized(found) {
                    found[scan.device.address] = mapOf(
                        "id" to scan.device.address,
                        "name" to name.trim(),
                        "rssi" to scan.rssi,
                    )
                }
            }
        }
        try {
            scanner.startScan(
                null,
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),
                callback,
            )
        } catch (e: Exception) {
            result.error("scan", e.message ?: "BLE scan failed", null)
            return
        }
        main.postDelayed({
            try {
                scanner.stopScan(callback)
            } catch (_: Exception) {
            }
            if (replied.compareAndSet(false, true)) {
                result.success(synchronized(found) { found.values.toList() })
            }
        }, timeoutMs.coerceIn(1500, 20000).toLong())
    }

    private fun print(call: MethodCall, result: MethodChannel.Result) {
        val address = call.argument<String>("id")
        val rawSteps = call.argument<List<Map<String, Any?>>>("steps")
        if (address.isNullOrBlank() || rawSteps.isNullOrEmpty()) {
            result.error("args", "Printer id or data missing", null)
            return
        }
        val adapter = adapter()
        if (adapter == null) {
            result.error("unavailable", "Bluetooth unavailable", null)
            return
        }
        if (!adapter.isEnabled) {
            result.error("off", "Bluetooth is off", null)
            return
        }
        if (!canConnect()) {
            result.error("permission", "Bluetooth connect permission missing", null)
            return
        }
        val steps = rawSteps.mapNotNull { raw ->
            val data = raw["data"] as? ByteArray ?: return@mapNotNull null
            Step(data, (raw["delayMs"] as? Number)?.toInt() ?: 0)
        }
        val chunkSize = call.argument<Int>("chunkSize") ?: 128
        val chunkDelay = call.argument<Int>("chunkDelayMs") ?: 20
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "Printer is busy", null)
            return
        }
        worker.execute {
            val error = try {
                try {
                    runPrint(adapter, address, steps, chunkSize, chunkDelay, notify = true)
                } catch (_: NotifyDropped) {
                    Log.w(TAG, "notifications broke the link, printing without them")
                    Thread.sleep(500)
                    runPrint(adapter, address, steps, chunkSize, chunkDelay, notify = false)
                }
                null
            } catch (e: Exception) {
                Log.w(TAG, "print failed: ${e.message}")
                e.message ?: e.toString()
            } finally {
                busy.set(false)
            }
            main.post {
                if (error == null) result.success(true) else result.error("print", error, null)
            }
        }
    }

    /** Связь оборвалась на включении уведомлений — печатаем без них. */
    private class NotifyDropped : Exception("notifications dropped the link")

    private class Session : BluetoothGattCallback() {
        val connected = CountDownLatch(1)
        @Volatile var discovered = CountDownLatch(1)
        @Volatile var mtuLatch = CountDownLatch(1)
        @Volatile var writeLatch = CountDownLatch(1)
        @Volatile var descriptorLatch = CountDownLatch(1)
        @Volatile var isConnected = false
        @Volatile var disconnectStatus = BluetoothGatt.GATT_SUCCESS
        @Volatile var discoverStatus = -1
        @Volatile var mtu = 23
        @Volatile var writeStatus = BluetoothGatt.GATT_SUCCESS
        @Volatile var descriptorStatus = -1
        val replies = CopyOnWriteArrayList<ByteArray>()

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            isConnected = newState == BluetoothProfile.STATE_CONNECTED &&
                status == BluetoothGatt.GATT_SUCCESS
            if (newState == BluetoothProfile.STATE_CONNECTED) connected.countDown()
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.i(TAG, "disconnected status=$status")
                isConnected = false
                disconnectStatus = status
                connected.countDown()
                discovered.countDown()
                mtuLatch.countDown()
                writeLatch.countDown()
                descriptorLatch.countDown()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            discoverStatus = status
            discovered.countDown()
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            descriptorStatus = status
            descriptorLatch.countDown()
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) = reply(value)

        @Deprecated("Android 12 и ниже присылают ответы принтера сюда")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            characteristic.value?.let { reply(it) }
        }

        private fun reply(value: ByteArray) {
            replies.add(value.copyOf())
            Log.i(TAG, "printer <<< ${hex(value)}")
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) this.mtu = mtu
            mtuLatch.countDown()
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            writeStatus = status
            writeLatch.countDown()
        }
    }

    @SuppressLint("MissingPermission")
    private fun runPrint(
        adapter: BluetoothAdapter,
        address: String,
        steps: List<Step>,
        chunkSize: Int,
        chunkDelay: Int,
        notify: Boolean,
    ) {
        val device = adapter.getRemoteDevice(address)
        val started = SystemClock.elapsedRealtime()
        val log: (String) -> Unit = { message ->
            Log.i(TAG, "+${SystemClock.elapsedRealtime() - started}ms $message")
        }
        log("connect bond=${device.bondState} type=${device.type} notify=$notify")
        val session = Session()
        val gatt = device.connectGatt(context, false, session, BluetoothDevice.TRANSPORT_LE)
            ?: throw IllegalStateException("Не удалось подключиться к принтеру")
        try {
            if (!session.connected.await(12, TimeUnit.SECONDS) || !session.isConnected) {
                val reason = if (session.disconnectStatus == 0) "" else " (${session.disconnectStatus})"
                throw IllegalStateException("Принтер не отвечает$reason — включён ли он и рядом ли?")
            }
            // Сразу после соединения M250 просит шифрование — даём ему закончиться.
            Thread.sleep(600)
            discover(gatt, session, log)
            session.mtuLatch = CountDownLatch(1)
            if (gatt.requestMtu(247)) session.mtuLatch.await(5, TimeUnit.SECONDS)
            val mtu = session.mtu
            val characteristic = findWriteCharacteristic(gatt)
                ?: throw IllegalStateException("Это не принтер Phomemo: нет канала печати ff02")
            log("mtu=$mtu write=${characteristic.uuid} services=${describe(gatt)}")
            if (notify) enableNotifications(gatt, session, characteristic.service, log)
            val noResponse =
                (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
            val writeType = if (noResponse) {
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            } else {
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            }
            // Как phomymo сразу после соединения: батарея, бумага, прошивка.
            for (query in STATUS_QUERIES) {
                write(gatt, session, characteristic, query, writeType)
                Thread.sleep(100)
            }
            Thread.sleep(300)
            if (session.replies.any { it.isStatus(0x06, 0x88) }) {
                throw IllegalStateException("В принтере нет наклеек — вставьте рулон и закройте крышку.")
            }
            val size = max(20, min(chunkSize, mtu - 3))
            var sent = 0
            for (step in steps) {
                var offset = 0
                while (offset < step.data.size) {
                    val end = min(offset + size, step.data.size)
                    write(gatt, session, characteristic, step.data.copyOfRange(offset, end), writeType)
                    sent += end - offset
                    offset = end
                    if (offset < step.data.size && chunkDelay > 0) Thread.sleep(chunkDelay.toLong())
                }
                if (step.delayMs > 0) Thread.sleep(step.delayMs.toLong())
            }
            log("sent $sent bytes by $size, printer said: ${session.replies.joinToString(" | ") { hex(it) }}")
            if (session.replies.any { it.isStatus(0x0B, 0xB8) }) {
                throw IllegalStateException(
                    "Принтер не принял наклейку. Проверьте в настройках модель M250 и размер наклейки.",
                )
            }
        } finally {
            try {
                gatt.disconnect()
            } catch (_: Exception) {
            }
            try {
                Thread.sleep(150)
                gatt.close()
            } catch (_: Exception) {
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun discover(gatt: BluetoothGatt, session: Session, log: (String) -> Unit) {
        repeat(2) {
            session.discovered = CountDownLatch(1)
            if (!gatt.discoverServices() || !session.discovered.await(15, TimeUnit.SECONDS)) {
                throw IllegalStateException("Принтер не отдал список сервисов")
            }
            if (!session.isConnected) throw IllegalStateException("Принтер отключился")
            log("discovered status=${session.discoverStatus} services=${gatt.services.size}")
            if (session.discoverStatus == BluetoothGatt.GATT_SUCCESS && gatt.services.isNotEmpty()) return
            Thread.sleep(500)
        }
        throw IllegalStateException("Принтер не отдал список сервисов (${session.discoverStatus})")
    }

    /**
     * Подписка на ответы принтера (`ff03`), как у phomymo: M250 отвечает
     * на каждую запись и сообщает о бумаге. Если подписка рвёт связь —
     * [NotifyDropped], и печать идёт заново без неё.
     */
    @SuppressLint("MissingPermission")
    private fun enableNotifications(
        gatt: BluetoothGatt,
        session: Session,
        service: BluetoothGattService,
        log: (String) -> Unit,
    ) {
        val notifyMask = BluetoothGattCharacteristic.PROPERTY_NOTIFY or
            BluetoothGattCharacteristic.PROPERTY_INDICATE
        val notify = service.getCharacteristic(NOTIFY_FF03)
            ?: service.characteristics.firstOrNull { (it.properties and notifyMask) != 0 }
        val cccd = notify?.getDescriptor(CCCD)
        if (notify == null || cccd == null || !gatt.setCharacteristicNotification(notify, true)) {
            log("notify unavailable")
            return
        }
        val value = if ((notify.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        }
        session.descriptorLatch = CountDownLatch(1)
        val accepted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(cccd, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = value
                gatt.writeDescriptor(cccd)
            }
        }
        val done = accepted && session.descriptorLatch.await(3, TimeUnit.SECONDS)
        log("notify ${notify.uuid} accepted=$accepted done=$done status=${session.descriptorStatus}")
        if (!session.isConnected || (accepted && !done)) throw NotifyDropped()
        val until = SystemClock.elapsedRealtime() + 1000
        while (session.replies.isEmpty() && SystemClock.elapsedRealtime() < until) Thread.sleep(50)
    }

    @SuppressLint("MissingPermission")
    private fun write(
        gatt: BluetoothGatt,
        session: Session,
        characteristic: BluetoothGattCharacteristic,
        bytes: ByteArray,
        writeType: Int,
    ) {
        val deadline = SystemClock.elapsedRealtime() + 3000
        while (true) {
            if (!session.isConnected) throw IllegalStateException("Принтер отключился во время печати")
            session.writeLatch = CountDownLatch(1)
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, bytes, writeType)
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType = writeType
                    characteristic.value = bytes
                    if (gatt.writeCharacteristic(characteristic)) BluetoothStatusCodes.SUCCESS else -1
                }
            }
            if (code == BluetoothStatusCodes.SUCCESS) break
            if (SystemClock.elapsedRealtime() > deadline) {
                throw IllegalStateException("Принтер занят и не принимает данные ($code)")
            }
            Thread.sleep(20)
        }
        if (!session.writeLatch.await(5, TimeUnit.SECONDS)) {
            throw IllegalStateException("Принтер не подтвердил приём данных")
        }
        if (session.writeStatus != BluetoothGatt.GATT_SUCCESS) {
            throw IllegalStateException("Ошибка записи в принтер: ${session.writeStatus}")
        }
    }

    private fun findWriteCharacteristic(gatt: BluetoothGatt): BluetoothGattCharacteristic? {
        gatt.getService(SERVICE_FF00)?.getCharacteristic(WRITE_FF02)?.let { return it }
        for (uuid in FALLBACK_SERVICES) {
            val service = gatt.getService(uuid) ?: continue
            service.characteristics.firstOrNull { isWritable(it) }?.let { return it }
        }
        return gatt.services
            .flatMap { it.characteristics }
            .firstOrNull { it.uuid == WRITE_FF02 && isWritable(it) }
    }

    private fun describe(gatt: BluetoothGatt): String =
        gatt.services.joinToString("; ") { service ->
            service.uuid.toString().take(8) + ":" + service.characteristics.joinToString(",") {
                it.uuid.toString().take(8) + "/" + Integer.toHexString(it.properties)
            }
        }

    private fun isWritable(c: BluetoothGattCharacteristic): Boolean =
        (
            c.properties and (
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
                )
            ) != 0

    companion object {
        private const val TAG = "StickerPrinterBle"
        private val SERVICE_FF00: UUID = UUID.fromString("0000ff00-0000-1000-8000-00805f9b34fb")
        private val WRITE_FF02: UUID = UUID.fromString("0000ff02-0000-1000-8000-00805f9b34fb")
        private val NOTIFY_FF03: UUID = UUID.fromString("0000ff03-0000-1000-8000-00805f9b34fb")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val FALLBACK_SERVICES = listOf(
            SERVICE_FF00,
            UUID.fromString("0000ffe0-0000-1000-8000-00805f9b34fb"),
            UUID.fromString("0000ae30-0000-1000-8000-00805f9b34fb"),
            UUID.fromString("49535343-fe7d-4ae5-8fa9-9fafd205e455"),
        )

        /** Батарея, бумага, прошивка — ответ `1A <тип> <значение>` приходит в `ff03`. */
        private val STATUS_QUERIES = listOf(
            byteArrayOf(0x1F, 0x11, 0x08),
            byteArrayOf(0x1F, 0x11, 0x11),
            byteArrayOf(0x1F, 0x11, 0x07),
        )

        private fun hex(bytes: ByteArray): String = bytes.joinToString(" ") { "%02x".format(it) }

        private fun ByteArray.isStatus(type: Int, value: Int): Boolean =
            size >= 3 && this[0] == 0x1A.toByte() && this[1] == type.toByte() && this[2] == value.toByte()
    }
}
