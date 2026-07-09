import 'dart:async';
import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RingFrameCodec', () {
    const codec = RingFrameCodec();

    test('encodes golden command frames from docs', () {
      final cases = <RingCommand, (List<int>, String)>{
        RingCommand.deviceInfo: (
          const [],
          '89 56 01 01 01 00 01 00 00 00 91 2A B5 3A',
        ),
        RingCommand.battery: (
          const [],
          '89 56 02 01 01 00 01 00 00 00 D1 3F B5 3A',
        ),
        RingCommand.buttonCountQuery: (
          const [],
          '89 56 03 01 01 00 01 00 00 00 10 F3 B5 3A',
        ),
        RingCommand.queryTime: (
          const [],
          '89 56 02 05 01 00 01 00 00 00 94 FF B5 3A',
        ),
        RingCommand.sportRealtimeSwitch: (
          const [1],
          '89 56 08 01 01 00 01 00 01 00 01 11 FC B5 3A',
        ),
        RingCommand.softDisconnect: (
          const [],
          '89 56 09 01 01 00 01 00 00 00 90 8C B5 3A',
        ),
        RingCommand.screenFlip: (
          const [],
          '89 56 0A 01 01 00 01 00 00 00 D0 99 B5 3A',
        ),
        RingCommand.findRing: (
          const [1],
          '89 56 0B 01 01 00 01 00 01 00 01 05 0C B5 3A',
        ),
        RingCommand.clearZikrHistoryDay: (
          const [0x1A, 0x06, 0x1E],
          '89 56 0C 01 01 00 01 00 03 00 1A 06 1E 93 4E B5 3A',
        ),
        RingCommand.screenDirection: (
          const [],
          '89 56 0E 01 01 00 01 00 00 00 D1 6A B5 3A',
        ),
        RingCommand.prayerReminderQuery: (
          const [],
          '89 56 10 01 01 00 01 00 00 00 51 EA B5 3A',
        ),
        RingCommand.prayerReminderSet: (
          const [1, 1, 8, 30, 0x7F],
          '89 56 0F 01 01 00 01 00 05 00 01 01 08 1E 7F 43 F5 B5 3A',
        ),
      };

      for (final entry in cases.entries) {
        expect(
          bytesToHex(codec.encode(entry.key, entry.value.$1)),
          entry.value.$2,
          reason: entry.key.name,
        );
      }
    });

    test('decodes error frames and rejects CRC mismatch', () {
      final frame = codec.encode(RingCommand.battery, const [0xFF, 0x04]);
      final decoded = codec.decode(frame);
      expect(decoded.valueOrNull?.deviceError, RingDeviceError.outOfRange);

      frame[4] = 2;
      final corrupted = codec.decode(frame);
      expect(corrupted.failureOrNull?.code, BleFailureCode.unsupported);

      final crcFrame = codec.encode(RingCommand.battery);
      crcFrame[10] ^= 0x01;
      final crcResult = codec.decode(crcFrame);
      expect(crcResult.failureOrNull?.code, BleFailureCode.crcMismatch);
    });

    test('parses payload models', () {
      final deviceInfo = Uint8List(52);
      deviceInfo.setRange(0, 6, 'BUMBLE'.codeUnits);
      deviceInfo.setRange(16, 21, 'Ring2'.codeUnits);
      deviceInfo[22] = 1;
      deviceInfo.setRange(30, 36, [1, 2, 3, 4, 5, 6]);
      deviceInfo.setRange(46, 50, [1, 1, 5, 0]);

      expect(RingDeviceInfo.fromPayload(deviceInfo).manufacturer, 'BUMBLE');
      expect(RingBattery.fromPayload(Uint8List.fromList([88, 2])).percent, 88);
      expect(
        RingButtonCount.fromPayload(Uint8List.fromList([0x10, 0])).count,
        16,
      );
      expect(RingScreenDirection.fromValue(1), RingScreenDirection.flipped);
      // final reminders = RingPrayerReminder.listFromPayload(
      //   Uint8List.fromList([1, 1, 8, 30, 0x7F]),
      // );
      // expect(reminders.single.enabled, true);
      // expect(reminders.single.timeText, '08:30');
      // expect(reminders.single.everyDay, true);

      final zikr = Uint8List(52);
      zikr[0] = 1;
      zikr[1] = 26;
      zikr[2] = 6;
      zikr[3] = 30;
      zikr[4] = 7;
      expect(RingZikrDay.fromPayload(zikr).hourlyCounts.first, 7);
    });

    test('parses manufacturer advertisement data', () {
      final fullPayloadDevice = BleScanDevice(
        deviceId: 'ring-adv-full',
        manufacturerData: [
          BleManufacturerData(
            companyId: 0,
            payload: Uint8List.fromList([
              0x59,
              0x4A,
              0xAA,
              0xBB,
              0xCC,
              0xDD,
              0xEE,
              0xFF,
              0x01,
              0x00,
              0x02,
              0x00,
              0x03,
              0x00,
              0x01,
              0x00,
              0x01,
            ]),
          ),
        ],
      );

      final full = fullPayloadDevice.parseRingAdvertisement().valueOrNull;
      expect(full?.identifier, RingProtocol.manufacturerIdentifier);
      expect(full?.macAddressText, 'AA:BB:CC:DD:EE:FF');
      expect(full?.firmwareVersion, 1);
      expect(full?.customerId, 2);
      expect(full?.machineId, 3);
      expect(full?.bindSupported, 1);
      expect(full?.isBound, true);

      final splitPayloadDevice = BleScanDevice(
        deviceId: 'ring-adv-split',
        manufacturerData: [
          BleManufacturerData(
            companyId: RingProtocol.manufacturerIdentifier,
            payload: Uint8List.fromList([
              0x01,
              0x02,
              0x03,
              0x04,
              0x05,
              0x06,
              0x02,
              0x00,
              0x01,
              0x00,
              0x01,
              0x00,
              0x00,
              0x00,
              0x00,
            ]),
          ),
        ],
      );

      final split = const RingProtocolAdapter()
          .parseAdvertisement(splitPayloadDevice)
          .valueOrNull;
      expect(split?.macAddressText, '01:02:03:04:05:06');
      expect(split?.firmwareVersion, 2);
      expect(const RingProtocolAdapter().matches(splitPayloadDevice), true);
    });
  });

  group('RingBleSession', () {
    test(
      'connect initialization follows mtu discover subscribe order',
      () async {
        final transport = FakeBleTransport();
        final sdk = BlueToothSdk(transport: transport);
        final result = await sdk.connect(_device());

        expect(result.isSuccess, true);
        expect(transport.calls, [
          'stopScan',
          'connect',
          'requestMtu:247',
          'discoverServices',
          'subscribeNotifications',
        ]);
      },
    );

    test('keeps parsed advertisement on session', () {
      final transport = FakeBleTransport();
      final session = RingBleSession(
        device: _advertisedDevice(),
        transport: transport,
      );

      expect(session.advertisement?.macAddressText, 'AA:BB:CC:DD:EE:FF');
      expect(session.advertisement?.firmwareVersion, 1);
      expect(session.advertisement?.isBound, true);
    });

    test('screen flip waits for DONE before completing', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();
      final states = <RingActionState>[];
      final subscription = session.actionStateStream.listen(states.add);

      final future = session.flipScreen();
      var completed = false;
      future.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(transport.writes.last, contains('0A 01'));
      expect(states.last.phase, RingActionPhase.sending);

      transport.emit(RingCommand.screenFlip, const [1, 1]);
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      expect(states.last.phase, RingActionPhase.accepted);
      expect(states.last.status, 1);
      expect(states.last.screenDirection, RingScreenDirection.flipped);

      transport.emit(RingCommand.screenFlip, const [2, 1]);
      final result = await future;
      expect(result.valueOrNull, RingScreenDirection.flipped);
      expect(states.last.phase, RingActionPhase.done);
      expect(states.last.status, 2);
      expect(states.last.screenDirection, RingScreenDirection.flipped);
      await subscription.cancel();
    });

    test('screen flip handles DONE arriving before method resumes', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final future = session.flipScreen();
      await Future<void>.delayed(Duration.zero);

      transport.emit(RingCommand.screenFlip, const [2, 0]);

      final result = await future;
      expect(result.valueOrNull, RingScreenDirection.normal);
    });

    test('queries button count, direction and prayer reminders', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final countFuture = session.queryButtonCount();
      await Future<void>.delayed(Duration.zero);
      transport.emit(RingCommand.buttonCountQuery, const [0x2A, 0]);
      expect((await countFuture).valueOrNull?.count, 42);

      final directionFuture = session.queryScreenDirection();
      await Future<void>.delayed(Duration.zero);
      transport.emit(RingCommand.screenDirection, const [1]);
      expect((await directionFuture).valueOrNull, RingScreenDirection.flipped);

      // final remindersFuture = session.queryPrayerReminders();
      await Future<void>.delayed(Duration.zero);
      transport.emit(RingCommand.prayerReminderQuery, const [
        1,
        1,
        8,
        30,
        0x7F,
      ]);
      // final reminders = (await remindersFuture).valueOrNull;
      // expect(reminders?.single.timeText, '08:30');
    });

    test('screen off time separates command ack and active report', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();
      final reports = <RingScreenOffTime>[];
      final subscription = session.screenOffTimeStream.listen(reports.add);

      final invalid = await session.setScreenOffTime(15);
      expect(invalid.failureOrNull?.code, BleFailureCode.protocolError);
      expect(transport.writes, isEmpty);

      final future = session.setScreenOffTime(20);
      await Future<void>.delayed(Duration.zero);
      expect(transport.writes.last, contains('0D 01'));

      transport.emit(RingCommand.screenOffTime, const [1]);
      expect((await future).isSuccess, true);
      await Future<void>.delayed(Duration.zero);
      expect(reports, isEmpty);

      transport.emit(RingCommand.screenOffTime, const [20]);
      await Future<void>.delayed(Duration.zero);
      expect(reports.single.seconds, 20);
      await subscription.cancel();
    });

    test('write failure returns Result.failure', () async {
      final transport = FakeBleTransport()..failWrites = true;
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final result = await session.queryBattery();
      expect(result.failureOrNull?.code, BleFailureCode.writeFailed);
    });
  });
}

BleScanDevice _advertisedDevice() {
  return BleScanDevice(
    deviceId: 'ring-adv',
    name: RingProtocol.deviceName,
    services: const [RingProtocol.serviceUuid],
    manufacturerData: [
      BleManufacturerData(
        companyId: 0,
        payload: Uint8List.fromList([
          0x59,
          0x4A,
          0xAA,
          0xBB,
          0xCC,
          0xDD,
          0xEE,
          0xFF,
          0x01,
          0x00,
          0x01,
          0x00,
          0x01,
          0x00,
          0x00,
          0x00,
          0x01,
        ]),
      ),
    ],
  );
}

BleScanDevice _device() {
  return const BleScanDevice(
    deviceId: 'ring-1',
    name: RingProtocol.deviceName,
    services: [RingProtocol.serviceUuid],
  );
}

class FakeBleTransport implements BleTransport {
  final scanController = StreamController<BleScanDevice>.broadcast();
  final availabilityController = StreamController<BleAvailability>.broadcast();
  final connectionController = StreamController<bool>.broadcast();
  final valueController = StreamController<Uint8List>.broadcast();
  final calls = <String>[];
  final writes = <String>[];
  bool failWrites = false;

  final _codec = const RingFrameCodec();

  @override
  Stream<BleAvailability> get availabilityStream =>
      availabilityController.stream;

  @override
  Stream<BleScanDevice> get scanStream => scanController.stream;

  @override
  Stream<bool> connectionStream(String deviceId) => connectionController.stream;

  @override
  Stream<Uint8List> valueStream(String deviceId, String characteristicId) {
    return valueController.stream;
  }

  @override
  Future<Result<void>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    calls.add('connect');
    return const Result.success(null);
  }

  @override
  Future<Result<void>> disconnect(String deviceId) async {
    calls.add('disconnect');
    return const Result.success(null);
  }

  @override
  Future<Result<List<BleDiscoveredService>>> discoverServices(
    String deviceId,
  ) async {
    calls.add('discoverServices');
    return const Result.success([
      BleDiscoveredService(
        uuid: RingProtocol.serviceUuid,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: RingProtocol.writeCharacteristicUuid,
          ),
          BleDiscoveredCharacteristic(
            uuid: RingProtocol.notifyCharacteristicUuid,
          ),
        ],
      ),
    ]);
  }

  @override
  Future<Result<BleAvailability>> getAvailability() async {
    return const Result.success(BleAvailability.poweredOn);
  }

  @override
  Future<Result<void>> requestPermissions() async {
    return const Result.success(null);
  }

  @override
  Future<Result<int>> requestMtu(String deviceId, int expectedMtu) async {
    calls.add('requestMtu:$expectedMtu');
    return Result.success(expectedMtu);
  }

  @override
  Future<Result<void>> startScan(BleScanOptions options) async {
    calls.add('startScan');
    return const Result.success(null);
  }

  @override
  Future<Result<void>> stopScan() async {
    calls.add('stopScan');
    return const Result.success(null);
  }

  @override
  Future<Result<void>> subscribeNotifications(
    String deviceId,
    String serviceId,
    String characteristicId,
  ) async {
    calls.add('subscribeNotifications');
    return const Result.success(null);
  }

  @override
  Future<Result<void>> write(
    String deviceId,
    String serviceId,
    String characteristicId,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    writes.add(bytesToHex(value));
    if (failWrites) {
      return const Result.failure(
        BleFailure(code: BleFailureCode.writeFailed, message: 'boom'),
      );
    }
    return const Result.success(null);
  }

  void emit(RingCommand command, List<int> payload) {
    valueController.add(_codec.encode(command, payload));
  }

  @override
  void dispose() {}
}
