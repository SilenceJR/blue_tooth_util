import 'dart:async';
import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
// ignore: depend_on_referenced_packages
import 'package:common/common.dart';
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
        sdk: BlueToothSdk(transport: _FakeBleTransport()),
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

class _FakeBleTransport implements BleTransport {
  final _scanController = StreamController<BleScanDevice>.broadcast();
  final _availabilityController = StreamController<BleAvailability>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _valueController = StreamController<Uint8List>.broadcast();

  @override
  Stream<BleScanDevice> get scanStream => _scanController.stream;

  @override
  Stream<BleAvailability> get availabilityStream =>
      _availabilityController.stream;

  @override
  Stream<bool> connectionStream(String deviceId) =>
      _connectionController.stream;

  @override
  Stream<Uint8List> valueStream(String deviceId, String characteristicId) {
    return _valueController.stream;
  }

  @override
  Future<Result<void, BleFailure>> requestPermissions() async {
    return const Result.ok(null);
  }

  @override
  Future<Result<BleAvailability, BleFailure>> getAvailability() async {
    return const Result.ok(BleAvailability.poweredOn);
  }

  @override
  Future<Result<void, BleFailure>> startScan(BleScanOptions options) async {
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> stopScan() async {
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> disconnect(String deviceId) async {
    return const Result.ok(null);
  }

  @override
  Future<Result<int, BleFailure>> requestMtu(
    String deviceId,
    int expectedMtu,
  ) async {
    return Result.ok(expectedMtu);
  }

  @override
  Future<Result<List<BleDiscoveredService>, BleFailure>> discoverServices(
    String deviceId,
  ) async {
    return const Result.ok([]);
  }

  @override
  Future<Result<void, BleFailure>> subscribeNotifications(
    String deviceId,
    String serviceId,
    String characteristicId,
  ) async {
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> write(
    String deviceId,
    String serviceId,
    String characteristicId,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    return const Result.ok(null);
  }

  @override
  void dispose() {
    unawaited(_scanController.close());
    unawaited(_availabilityController.close());
    unawaited(_connectionController.close());
    unawaited(_valueController.close());
  }
}
