
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:example/main.dart';

void main() {
  setUp(() {
    Get.testMode = true;
  });

  tearDown(() {
    Get.reset();
  });

  testWidgets('BLE debug page renders', (WidgetTester tester) async {
    Get.put(
      BleDebugController(
        // sdk: BlueToothSdk(transport: _FakeBleTransport()),
        cache: _FakeBleDebugCache(),
      ),
    );
    await tester.pumpWidget(const BleDebugApp());

    await tester.pump();

    expect(find.text('Ring BLE Debug'), findsWidgets);
    expect(find.byIcon(Icons.bluetooth), findsOneWidget);
  });
}

class _FakeBleDebugCache implements BleDebugCache {
  CachedBleDevice? lastDevice;
  final devices = <CachedBleDevice>[];

  @override
  Future<void> close() async {}

  @override
  Future<void> init() async {}

  @override
  Future<CachedBleDevice?> loadLastDevice() async => lastDevice;

  @override
  Future<List<CachedBleDevice>> loadDevices() async => List.of(devices);

  @override
  Future<void> removeDevice(String deviceId) async {
    devices.removeWhere((device) => device.deviceId == deviceId);
    if (lastDevice?.deviceId == deviceId) lastDevice = null;
  }

  @override
  Future<void> saveDevice(CachedBleDevice device) async {
    devices.removeWhere((item) => item.deviceId == device.deviceId);
    devices.add(device);
  }

  @override
  Future<void> saveLastDevice(CachedBleDevice device) async {
    lastDevice = device;
    await saveDevice(device);
  }
}

// class _FakeBleTransport implements BleTransport {
//   final _scan = StreamController<BleScanDevice>.broadcast();
//   final _availability = StreamController<BleAvailability>.broadcast();
//   final _connection = StreamController<bool>.broadcast();
//   final _values = StreamController<Uint8List>.broadcast();
//
//   @override
//   Stream<BleAvailability> get availabilityStream => _availability.stream;
//
//   @override
//   Stream<BleScanDevice> get scanStream => _scan.stream;
//
//   @override
//   Stream<bool> connectionStream(String deviceId) => _connection.stream;
//
//   @override
//   Stream<Uint8List> valueStream(String deviceId, String characteristicId) {
//     return _values.stream;
//   }
//
//   // @override
//   // Future<Result<void>> connect(
//   //   String deviceId, {
//   //   Duration timeout = const Duration(seconds: 20),
//   //   bool autoConnect = false,
//   // }) async {
//   //   return const Result.success(null);
//   // }
//   //
//   // @override
//   // Future<Result<void>> disconnect(String deviceId) async {
//   //   return const Result.success(null);
//   // }
//   //
//   // @override
//   // void dispose() {}
//   //
//   // @override
//   // Future<Result<List<BleDiscoveredService>>> discoverServices(
//   //   String deviceId,
//   // ) async {
//   //   return const Result.success([]);
//   // }
//   //
//   // @override
//   // Future<Result<BleAvailability>> getAvailability() async {
//   //   return const Result.success(BleAvailability.poweredOn);
//   // }
//   //
//   // @override
//   // Future<Result<void>> requestPermissions() async {
//   //   return const Result.success(null);
//   // }
//   //
//   // @override
//   // Future<Result<int>> requestMtu(String deviceId, int expectedMtu) async {
//   //   return Result.success(expectedMtu);
//   // }
//   //
//   // @override
//   // Future<Result<void>> startScan(BleScanOptions options) async {
//   //   return const Result.success(null);
//   // }
//   //
//   // @override
//   // Future<Result<void>> stopScan() async {
//   //   return const Result.success(null);
//   // }
//   //
//   // @override
//   // Future<Result<void>> subscribeNotifications(
//   //   String deviceId,
//   //   String serviceId,
//   //   String characteristicId,
//   // ) async {
//   //   return const Result.success(null);
//   // }
//   //
//   // @override
//   // Future<Result<void>> write(
//   //   String deviceId,
//   //   String serviceId,
//   //   String characteristicId,
//   //   Uint8List value, {
//   //   bool withoutResponse = false,
//   // }) async {
//   //   return const Result.success(null);
//   // }
// }
