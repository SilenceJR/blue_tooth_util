import 'dart:async';
import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const morning = RingPrayerReminder(
    enabled: true,
    startHour: 8,
    startMinute: 30,
    endHour: 22,
    endMinute: 0,
    intervalMinutes: 120,
  );

  group('RingPrayerReminder', () {
    test('encodes the documented 0x0112 golden frames', () {
      const codec = RingFrameCodec();

      expect(
        bytesToHex(codec.encode(RingCommand.prayerReminder)),
        '89 56 12 01 01 00 01 00 00 00 D0 33 B5 3A',
      );
      expect(
        bytesToHex(
          codec.encode(RingCommand.prayerReminder, morning.toPayload()),
        ),
        '89 56 12 01 01 00 01 00 07 00 01 08 1E 16 00 78 00 6D FC B5 3A',
      );
      expect(
        bytesToHex(codec.encode(RingCommand.prayerReminder, const [0])),
        '89 56 12 01 01 00 01 00 01 00 00 63 5C B5 3A',
      );
      for (final (payload, expected) in [
        (
          [1, 9, 0, 21, 0, 60, 0],
          '89 56 12 01 01 00 01 00 07 00 01 09 00 15 00 3C 00 F7 6B B5 3A',
        ),
        (
          [0, 9, 0, 21, 0, 60, 0],
          '89 56 12 01 01 00 01 00 07 00 00 09 00 15 00 3C 00 E7 AB B5 3A',
        ),
        ([1], '89 56 12 01 01 00 01 00 01 00 01 A2 9C B5 3A'),
      ]) {
        expect(
          bytesToHex(codec.encode(RingCommand.prayerReminder, payload)),
          expected,
        );
      }
    });

    test('preserves minute precision and little-endian interval', () {
      final decoded = RingPrayerReminder.fromPayload(
        Uint8List.fromList([0, 8, 30, 22, 0, 0x78, 0]),
      );

      expect(decoded.enabled, isFalse);
      expect(decoded.startMinute, 30);
      expect(decoded.intervalMinutes, 120);
      expect(decoded.toPayload(), [0, 8, 30, 22, 0, 0x78, 0]);
    });

    test('allows protocol-valid short ranges ending at 23:00', () {
      final reminder = morning.copyWith(
        startHour: 22,
        startMinute: 59,
        endHour: 23,
        intervalMinutes: 180,
      );
      expect(reminder.validate().isOk, isTrue);
      expect(
        RingPrayerReminder.fromPayload(reminder.toPayload()).durationMinutes,
        1,
      );
    });

    test('rejects malformed payload and invalid protocol values', () {
      final invalidPayloads = <List<int>>[
        [1, 9, 0, 21, 0, 60],
        [2, 9, 0, 21, 0, 60, 0],
        [1, 9, 0, 9, 0, 60, 0],
        [1, 9, 0, 23, 30, 60, 0],
        [1, 9, 60, 21, 0, 60, 0],
        [1, 9, 0, 21, 0, 90, 0],
      ];

      for (final payload in invalidPayloads) {
        expect(
          () => RingPrayerReminder.fromPayload(Uint8List.fromList(payload)),
          throwsFormatException,
          reason: payload.toString(),
        );
      }
    });
  });

  group('RingBleSession reminder', () {
    late _ReminderTransport transport;
    late RingBleSession session;

    setUp(() async {
      transport = _ReminderTransport();
      session = RingBleSession(device: _device(), transport: transport);
      expect((await session.initialize()).isOk, isTrue);
    });

    tearDown(() async {
      await session.dispose();
      transport.dispose();
    });

    test('queries the strict seven-byte configuration', () async {
      final query = session.queryPrayerReminder();
      await _flush();
      expect(transport.reminderPayloads, [isEmpty]);

      transport.emit([1, 8, 30, 22, 0, 0x78, 0]);
      final result = await query;

      expect(result.valueOrNull?.startMinute, 30);
      expect(result.valueOrNull?.intervalMinutes, 120);
    });

    test('maps malformed query payload and device error', () async {
      var query = session.queryPrayerReminder();
      await _flush();
      transport.emit([1, 8, 0, 22, 0, 60]);
      expect((await query).failureOrNull?.code, BleFailureCode.protocolError);

      query = session.queryPrayerReminder();
      await _flush();
      transport.emit([0xFF, 0x02]);
      final failure = (await query).failureOrNull;
      expect(failure?.code, BleFailureCode.deviceError);
      expect(failure?.cause, RingDeviceError.unknownCommand);
    });

    test('writes full settings and requires an exact success ack', () async {
      var setting = session.setPrayerReminder(morning);
      await _flush();
      expect(transport.reminderPayloads.single, morning.toPayload());
      transport.emit([1, 0]);
      expect((await setting).failureOrNull?.code, BleFailureCode.protocolError);

      setting = session.setPrayerReminder(morning);
      await _flush();
      transport.emit([1]);
      expect((await setting).isOk, isTrue);
    });

    test('disable sends only zero and accepts an exact success ack', () async {
      final disabling = session.disablePrayerReminder();
      await _flush();

      expect(transport.reminderPayloads, [
        const [0],
      ]);
      transport.emit([1]);
      expect((await disabling).isOk, isTrue);
    });

    test('rejects invalid settings before writing', () async {
      final result = await session.setPrayerReminder(
        morning.copyWith(intervalMinutes: 90),
      );

      expect(result.failureOrNull?.code, BleFailureCode.protocolError);
      expect(transport.reminderPayloads, isEmpty);
    });

    test(
      'serializes the shared command and releases the tail after failure',
      () async {
        final query = session.queryPrayerReminder();
        final setting = session.setPrayerReminder(morning);
        await _flush();
        expect(transport.reminderPayloads, [isEmpty]);

        transport.emit([1, 8, 0, 22, 0, 60]);
        expect((await query).failureOrNull?.code, BleFailureCode.protocolError);
        await _flush();
        expect(transport.reminderPayloads, [isEmpty, morning.toPayload()]);

        transport.emit([1]);
        expect((await setting).isOk, isTrue);
      },
    );

    test('times out without a response', () async {
      final result = await session.queryPrayerReminder();

      expect(result.failureOrNull?.code, BleFailureCode.timeout);
    }, timeout: const Timeout(Duration(seconds: 7)));

    test('dispose releases pending and queued operations', () async {
      final first = session.queryPrayerReminder();
      final second = session.queryPrayerReminder();
      await _flush();

      await session.dispose();
      expect(
        (await first).failureOrNull?.code,
        BleFailureCode.connectionFailed,
      );
      expect(
        (await second).failureOrNull?.code,
        BleFailureCode.connectionFailed,
      );
      session = RingBleSession(device: _device(), transport: transport);
    });
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

BleScanDevice _device() => const BleScanDevice(
  deviceId: 'ring',
  name: RingProtocol.deviceName,
  services: [RingProtocol.serviceUuid],
);

final class _ReminderTransport implements BleTransport {
  final _availability = StreamController<BleAvailability>.broadcast();
  final _scan = StreamController<BleScanDevice>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  final _values = StreamController<Uint8List>.broadcast();
  final _codec = const RingFrameCodec();
  final reminderPayloads = <Uint8List>[];

  @override
  Stream<BleAvailability> get availabilityStream => _availability.stream;

  @override
  Stream<BleScanDevice> get scanStream => _scan.stream;

  @override
  Stream<bool> connectionStream(String deviceId) => _connection.stream;

  @override
  Stream<Uint8List> valueStream(String deviceId, String characteristicId) =>
      _values.stream;

  @override
  Future<Result<void, BleFailure>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async => const Result.ok(null);

  @override
  Future<Result<void, BleFailure>> disconnect(String deviceId) async =>
      const Result.ok(null);

  @override
  Future<Result<List<BleDiscoveredService>, BleFailure>> discoverServices(
    String deviceId,
  ) async => const Result.ok([
    BleDiscoveredService(
      uuid: RingProtocol.serviceUuid,
      characteristics: [
        BleDiscoveredCharacteristic(uuid: RingProtocol.writeCharacteristicUuid),
        BleDiscoveredCharacteristic(
          uuid: RingProtocol.notifyCharacteristicUuid,
        ),
      ],
    ),
  ]);

  @override
  Future<Result<BleAvailability, BleFailure>> getAvailability() async =>
      const Result.ok(BleAvailability.poweredOn);

  @override
  Future<Result<void, BleFailure>> requestPermissions() async =>
      const Result.ok(null);

  @override
  Future<Result<int, BleFailure>> requestMtu(
    String deviceId,
    int expectedMtu,
  ) async => Result.ok(expectedMtu);

  @override
  Future<Result<void, BleFailure>> startScan(BleScanOptions options) async =>
      const Result.ok(null);

  @override
  Future<Result<void, BleFailure>> stopScan() async => const Result.ok(null);

  @override
  Future<Result<void, BleFailure>> subscribeNotifications(
    String deviceId,
    String serviceId,
    String characteristicId,
  ) async => const Result.ok(null);

  @override
  Future<Result<void, BleFailure>> write(
    String deviceId,
    String serviceId,
    String characteristicId,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    final frame = _codec.decode(value).valueOrNull!;
    if (frame.command == RingCommand.prayerReminder) {
      reminderPayloads.add(frame.payload);
    }
    return const Result.ok(null);
  }

  void emit(List<int> payload) {
    _values.add(_codec.encode(RingCommand.prayerReminder, payload));
  }

  @override
  void dispose() {
    _availability.close();
    _scan.close();
    _connection.close();
    _values.close();
  }
}
