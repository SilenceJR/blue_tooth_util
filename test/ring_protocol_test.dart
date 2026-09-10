import 'dart:async';
import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:common/common.dart';
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
        RingCommand.otaEnter: (
          const [],
          '89 56 01 04 01 00 01 00 00 00 C4 2A B5 3A',
        ),
        RingCommand.otaInfo: (
          const [],
          '89 56 02 04 01 00 01 00 00 00 84 3F B5 3A',
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

  group('Ring OTA models and identity', () {
    test('parses exact OTA info fields and accepts all defined flags', () {
      final info = RingOtaInfo.fromPayload(_otaInfoPayload());

      expect(info.firmwareVersion, 0x5678);
      expect(info.product, 'RING');
      expect(info.productBytes, [0x52, 0x49, 0x4E, 0x47, 0, 0, 0, 0]);
      expect(info.bootFlags, 0x0F);
      expect(info.bootloaderPresent, isTrue);
      expect(info.requiresEncryption, isTrue);
      expect(info.validatesProduct, isTrue);
      expect(info.enforcesMinimumVersion, isTrue);
      expect(info.bootVersionBytes, [1, 2, 3]);
      expect(info.bootVersion, '1.2.3');
    });

    test('round trips the exact OTA info payload with defensive copies', () {
      final source = _otaInfoPayload();
      final info = RingOtaInfo.fromPayload(source);
      final encoded = info.toPayload();

      expect(encoded, source);
      expect(encoded, hasLength(16));
      expect(
        RingOtaInfo.fromPayload(encoded).toPayload(),
        source,
        reason: '0x0402 fields must keep their original little-endian bytes',
      );

      source[0] = 0;
      encoded[4] = 0;
      expect(info.firmwareVersion, 0x5678);
      expect(info.product, 'RING');
      expect(info.toPayload(), _otaInfoPayload());
    });

    test('requires exactly 16 OTA info bytes', () {
      expect(
        () => RingOtaInfo.fromPayload(Uint8List(15)),
        throwsFormatException,
      );
      expect(
        () => RingOtaInfo.fromPayload(Uint8List(17)),
        throwsFormatException,
      );
    });

    test('rejects nonzero OTA firmware version reserved bytes', () {
      for (final offset in [2, 3]) {
        final payload = _otaInfoPayload()..[offset] = 1;
        expect(() => RingOtaInfo.fromPayload(payload), throwsFormatException);
      }
    });

    test('validates OTA product padding, full text and printable ASCII', () {
      expect(
        RingOtaInfo.fromPayload(
          _otaInfoPayload(product: 'RING2026'.codeUnits),
        ).product,
        'RING2026',
      );
      expect(
        () => RingOtaInfo.fromPayload(
          _otaInfoPayload(product: [0x52, 0, 0x49, 0, 0, 0, 0, 0]),
        ),
        throwsFormatException,
      );
      expect(
        () => RingOtaInfo.fromPayload(
          _otaInfoPayload(product: [0x1F, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsFormatException,
      );
    });

    test('rejects OTA info reserved boot flags', () {
      expect(
        () => RingOtaInfo.fromPayload(_otaInfoPayload(bootFlags: 0x10)),
        throwsFormatException,
      );
    });

    test('normalizes strict MAC input, byte order and OTA wraparound', () {
      final textIdentity = RingDeviceIdentity.fromMac('AA:BB:CC:DD:EE:FF');
      final lsbIdentity = RingDeviceIdentity.fromBytes([
        6,
        5,
        4,
        3,
        2,
        1,
      ], byteOrder: RingMacByteOrder.lsbFirst);

      expect(textIdentity.applicationMacText, 'AA:BB:CC:DD:EE:FF');
      expect(textIdentity.otaMacText, 'AA:BB:CC:DD:EE:00');
      expect(lsbIdentity.applicationMacText, '01:02:03:04:05:06');
      expect(lsbIdentity.otaMacText, '01:02:03:04:05:07');
      expect(
        RingDeviceIdentity.fromMac('aabbccddeeff').applicationMacText,
        'AA:BB:CC:DD:EE:FF',
      );
      expect(
        () => RingDeviceIdentity.fromMac('AA:BB-CC:DD:EE:FF'),
        throwsFormatException,
      );
      expect(
        () => RingDeviceIdentity.fromBytes([1, 2, 3, 4, 5]),
        throwsFormatException,
      );
    });

    test(
      'confirms OTA candidates only with exact 0x0504 manufacturer data',
      () {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final matchingData = BleManufacturerData(
          companyId: RingProtocol.otaManufacturerCompanyId,
          payload: Uint8List.fromList([1, 2, 3, 4, 5, 7, 0xAA, 0xBB]),
        );
        final nameOnly = BleScanDevice(
          deviceId: 'name-only',
          name: RingProtocol.otaDeviceName,
        );
        final serviceOnly = BleScanDevice(
          deviceId: 'service-only',
          services: const [RingProtocol.otaServiceUuid],
        );
        final wrongCompany = BleManufacturerData(
          companyId: 0x0503,
          payload: matchingData.payload,
        );
        final wrongLength = BleManufacturerData(
          companyId: RingProtocol.otaManufacturerCompanyId,
          payload: Uint8List.fromList([1, 2, 3, 4, 5, 7, 0xAA]),
        );
        final wrongMac = BleManufacturerData(
          companyId: RingProtocol.otaManufacturerCompanyId,
          payload: Uint8List.fromList([1, 2, 3, 4, 5, 8, 0xAA, 0xBB]),
        );
        final candidates = [
          BleScanDevice(
            deviceId: 'wrong-company',
            name: RingProtocol.otaDeviceName,
            manufacturerData: [wrongCompany],
          ),
          BleScanDevice(
            deviceId: 'wrong-length',
            services: const [RingProtocol.otaServiceUuid],
            manufacturerData: [wrongLength],
          ),
          BleScanDevice(
            deviceId: 'wrong-mac',
            name: RingProtocol.otaDeviceName,
            manufacturerData: [wrongMac],
          ),
          BleScanDevice(
            deviceId: 'target',
            services: const [RingProtocol.otaServiceUuid],
            manufacturerData: [matchingData],
          ),
        ];

        expect(identity.isOtaCandidate(nameOnly), isTrue);
        expect(identity.isOtaCandidate(serviceOnly), isTrue);
        expect(identity.matchesOtaDevice(nameOnly), isFalse);
        expect(identity.matchesOtaDevice(serviceOnly), isFalse);
        expect(identity.matchesOtaManufacturerData(matchingData), isTrue);
        expect(identity.matchesOtaManufacturerData(wrongCompany), isFalse);
        expect(identity.matchesOtaManufacturerData(wrongLength), isFalse);
        expect(identity.matchesOtaManufacturerData(wrongMac), isFalse);
        expect(
          candidates
              .where(identity.matchesOtaDevice)
              .map((item) => item.deviceId),
          ['target'],
        );
      },
    );
  });

  group('Custom zikr and daily report models', () {
    test('accepts active, cleared and completed custom zikr states', () {
      final active = RingCustomZikrState.fromPayload(
        Uint8List.fromList([1, 5, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );
      final cleared = RingCustomZikrState.fromPayload(
        Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );
      final completed = RingCustomZikrState.fromPayload(
        Uint8List.fromList([0, 33, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );

      expect(active.active, isTrue);
      expect(active.count, 5);
      expect(active.target, 33);
      expect(active.isCompleted, isFalse);
      expect(cleared.isCompleted, isFalse);
      expect(completed.isCompleted, isTrue);
      expect(active.toPayload(), [
        1,
        5,
        0,
        33,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
    });

    test('rejects malformed custom state and event payloads', () {
      expect(
        () => RingCustomZikrState.fromPayload(Uint8List(4)),
        throwsFormatException,
      );
      expect(
        () => RingCustomZikrState.fromPayload(
          Uint8List.fromList([0, 5, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsFormatException,
      );
      expect(
        () => RingCustomZikrState.fromPayload(
          Uint8List.fromList([1, 33, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsFormatException,
      );
      expect(
        () => RingCustomZikrEvent.fromPayload(
          Uint8List.fromList([0, 1, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsFormatException,
      );
      expect(
        () => RingCustomZikrEvent.fromPayload(
          Uint8List.fromList([1, 33, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsFormatException,
      );
    });

    test('parses progress and completion events with exact fifteen bytes', () {
      final progress = RingCustomZikrEvent.fromPayload(
        Uint8List.fromList([1, 5, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );
      final completion = RingCustomZikrEvent.fromPayload(
        Uint8List.fromList([2, 33, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );

      expect(progress.isProgress, isTrue);
      expect(progress.count, 5);
      expect(completion.isCompleted, isTrue);
      expect(completion.count, completion.target);
    });

    test('separates strict 52-byte daily data from the 13-byte batch end', () {
      final dayPayload = Uint8List(52)
        ..[0] = 1
        ..[1] = 26
        ..[2] = 9
        ..[3] = 4
        ..[4] = 7;
      final day = RingZikrDay.fromPayload(dayPayload);
      final end = RingZikrBatchEnd.fromPayload(
        Uint8List.fromList([
          2,
          0,
          0,
          0,
          0x78,
          0x56,
          0x34,
          0x12,
          0xEF,
          0xCD,
          0xAB,
          0x90,
          1,
        ]),
      );

      expect(day.date, DateTime.utc(2026, 9, 4));
      expect(day.hourlyCounts.first, 7);
      expect(end.sentAt, 0x12345678);
      expect(end.previousSentAt, 0x90ABCDEF);
      expect(end.dayCount, 1);
      expect(
        () => RingZikrDay.fromPayload(Uint8List(53)),
        throwsFormatException,
      );
      expect(
        () => RingZikrBatchEnd.fromPayload(Uint8List(12)),
        throwsFormatException,
      );
      expect(
        () => RingZikrBatchEnd.fromPayload(
          Uint8List.fromList([0, 0, 0, 0, ...List<int>.filled(9, 0)]),
        ),
        throwsFormatException,
      );
    });
  });

  group('RingBleSession', () {
    test(
      'connect initialization follows mtu discover subscribe order',
      () async {
        final transport = FakeBleTransport();
        final sdk = BlueToothSdk(transport: transport);
        final result = await sdk.connect(_device());

        expect(result.isOk, true);
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

    test('queries OTA info and maps the 0x0402 payload', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final future = session.queryOtaInfo();
      await Future<void>.delayed(Duration.zero);
      transport.emit(RingCommand.otaInfo, _otaInfoPayload());

      final result = await future;
      expect(result.valueOrNull?.firmwareVersion, 0x5678);
      expect(result.valueOrNull?.product, 'RING');
      expect(result.valueOrNull?.bootVersion, '1.2.3');
    });

    test(
      'does not confuse OTA firmware low byte FF with device error',
      () async {
        final transport = FakeBleTransport();
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();

        final future = session.queryOtaInfo();
        await Future<void>.delayed(Duration.zero);
        final payload = _otaInfoPayload()..[0] = 0xFF;
        transport.emit(RingCommand.otaInfo, payload);

        final result = await future;
        expect(result.isOk, isTrue);
        expect(result.valueOrNull?.firmwareVersion, 0x56FF);
      },
    );

    test('maps malformed OTA info response to protocol error', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final future = session.queryOtaInfo();
      await Future<void>.delayed(Duration.zero);
      transport.emit(RingCommand.otaInfo, List<int>.filled(15, 0));

      expect((await future).failureOrNull?.code, BleFailureCode.protocolError);
    });

    test(
      'returns OTA device errors without waiting for command timeout',
      () async {
        final transport = FakeBleTransport();
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();

        final future = session.queryOtaInfo();
        await Future<void>.delayed(Duration.zero);
        transport.emit(RingCommand.otaInfo, const [0xFF, 0x05]);

        final result = await future.timeout(const Duration(seconds: 1));
        expect(result.failureOrNull?.code, BleFailureCode.deviceError);
        expect(result.failureOrNull?.cause, RingDeviceError.badState);
      },
    );

    test('enters OTA after acknowledgement then device disconnects', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final future = session.enterOtaMode();
      await Future<void>.delayed(Duration.zero);
      expect(transport.writes.last, contains('01 04'));
      transport.emit(RingCommand.otaEnter, const [1]);
      await Future<void>.delayed(Duration.zero);
      transport.emitConnection(false);

      expect((await future).valueOrNull, RingOtaEntryState.deviceDisconnected);
    });

    test(
      'accepts an OTA disconnect that arrives before acknowledgement',
      () async {
        final transport = FakeBleTransport();
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();

        final future = session.enterOtaMode();
        await Future<void>.delayed(Duration.zero);
        transport.emitConnection(false);
        await Future<void>.delayed(Duration.zero);
        transport.emit(RingCommand.otaEnter, const [1]);

        expect(
          (await future).valueOrNull,
          RingOtaEntryState.deviceDisconnected,
        );
      },
    );

    test(
      'accepts an OTA disconnect that interrupts the GATT write callback',
      () async {
        final transport = FakeBleTransport();
        final writeResult = Completer<Result<void, BleFailure>>();
        transport.pendingWriteResult = writeResult.future;
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();

        final future = session.enterOtaMode();
        await Future<void>.delayed(Duration.zero);
        transport.emitConnection(false);
        await Future<void>.delayed(Duration.zero);
        writeResult.complete(
          const Result.err(
            BleFailure(
              code: BleFailureCode.writeFailed,
              message: 'Device Disconnected',
            ),
          ),
        );

        expect(
          (await future).valueOrNull,
          RingOtaEntryState.deviceDisconnected,
        );
      },
    );

    test(
      'rejects duplicate OTA entry while the first request is pending',
      () async {
        final transport = FakeBleTransport();
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();

        final first = session.enterOtaMode();
        await Future<void>.delayed(Duration.zero);
        final duplicate = await session.enterOtaMode();
        transport.emit(RingCommand.otaEnter, const [0xFF, 0x05]);

        expect(duplicate.failureOrNull?.code, BleFailureCode.busy);
        expect((await first).failureOrNull?.code, BleFailureCode.deviceError);
      },
    );

    test('disposing after OTA acknowledgement fails without waiting', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final future = session.enterOtaMode();
      await Future<void>.delayed(Duration.zero);
      transport.emit(RingCommand.otaEnter, const [1]);
      await Future<void>.delayed(Duration.zero);
      await session.dispose();

      final result = await future.timeout(const Duration(seconds: 1));
      expect(result.failureOrNull?.code, BleFailureCode.connectionFailed);
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

    test('find ring DONE completes start and stop pending frames', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();

      final start = session.startFindRing();
      await Future<void>.delayed(Duration.zero);
      final stop = session.stopFindRing();
      await Future<void>.delayed(Duration.zero);
      expect(transport.writes, hasLength(2));
      expect(transport.writes.first, contains('0B 01'));
      expect(transport.writes.last, contains('01 00 01 00 02'));

      var startCompleted = false;
      var stopCompleted = false;
      final startResult = start.whenComplete(() => startCompleted = true);
      final stopResult = stop.whenComplete(() => stopCompleted = true);
      transport.emit(RingCommand.findRing, const [2]);
      await Future<void>.delayed(Duration.zero);

      expect(startCompleted, isTrue);
      expect(stopCompleted, isTrue);
      await Future.wait([startResult, stopResult]);
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

    test(
      'serializes custom zikr operations and requires exact query state',
      () async {
        final transport = FakeBleTransport();
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();

        final enter = session.enterCustomZikr(33, taskId: 5);
        final query = session.queryCustomZikr();
        await Future<void>.delayed(Duration.zero);
        expect(transport.writes, hasLength(1));
        expect(
          transport.writes.single,
          '89 56 11 01 01 00 01 00 05 00 01 21 00 05 00 AA F9 B5 3A',
        );

        // A late one-byte ACK from the previous operation cannot complete the
        // fifteen-byte query; the first operation is still the only pending one.
        transport.emit(RingCommand.customZikrMode, const [1]);
        expect((await enter).isOk, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(transport.writes, hasLength(2));

        var queryCompleted = false;
        query.then((_) => queryCompleted = true);
        transport.emit(RingCommand.customZikrMode, const [1]);
        await Future<void>.delayed(Duration.zero);
        expect(queryCompleted, isFalse);

        transport.emit(RingCommand.customZikrMode, const [
          1,
          5,
          0,
          33,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]);
        final state = await query;
        expect(state.valueOrNull?.active, isTrue);
        expect(state.valueOrNull?.count, 5);
        expect(state.valueOrNull?.target, 33);
      },
    );

    test(
      'validates custom target before writing and keeps device errors',
      () async {
        final transport = FakeBleTransport();
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();

        expect(
          (await session.enterCustomZikr(0, taskId: 5)).failureOrNull?.code,
          BleFailureCode.protocolError,
        );
        expect(
          (await session.enterCustomZikr(10000, taskId: 5)).failureOrNull?.code,
          BleFailureCode.protocolError,
        );
        for (final id in [-1, 65536]) {
          expect(
            (await session.enterCustomZikr(33, taskId: id)).failureOrNull?.code,
            BleFailureCode.protocolError,
          );
        }
        expect(transport.writes, isEmpty);

        final oldQuery = session.queryCustomZikr();
        await Future<void>.delayed(Duration.zero);
        transport.emit(RingCommand.customZikrMode, const [1, 5, 0, 33, 0]);
        expect(
          (await oldQuery).failureOrNull?.code,
          BleFailureCode.protocolError,
        );

        final query = session.queryCustomZikr();
        await Future<void>.delayed(Duration.zero);
        transport.emit(RingCommand.customZikrMode, const [0xFF, 0x02]);
        final result = await query;
        expect(result.failureOrNull?.code, BleFailureCode.deviceError);
        expect(result.failureOrNull?.cause, RingDeviceError.unknownCommand);
      },
    );

    test(
      'accepts both task ID and target boundaries without truncation',
      () async {
        final transport = FakeBleTransport();
        final session = RingBleSession(device: _device(), transport: transport);
        await session.initialize();
        for (final (target, taskId) in [(1, 0), (9999, 65535)]) {
          final operation = session.enterCustomZikr(target, taskId: taskId);
          await Future<void>.delayed(Duration.zero);
          expect(
            transport.writes.last,
            bytesToHex(
              const RingFrameCodec().encode(RingCommand.customZikrMode, [
                1,
                target & 255,
                target >> 8,
                taskId & 255,
                taskId >> 8,
              ]),
            ),
          );
          transport.emit(RingCommand.customZikrMode, const [1]);
          expect((await operation).isOk, isTrue);
        }
        await session.dispose();
      },
    );

    test('dispatches custom events and batch end independently', () async {
      final transport = FakeBleTransport();
      final session = RingBleSession(device: _device(), transport: transport);
      await session.initialize();
      final events = <RingCustomZikrEvent>[];
      final batches = <RingZikrBatchEnd>[];
      final eventSubscription = session.customZikrEventStream.listen(
        events.add,
      );
      final batchSubscription = session.zikrBatchEndStream.listen(batches.add);

      transport.emit(RingCommand.customZikrReport, const [
        1,
        5,
        0,
        33,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      transport.emit(RingCommand.zikrHourlyReport, const [
        2,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(events.single.count, 5);
      expect(batches.single.dayCount, 0);
      await eventSubscription.cancel();
      await batchSubscription.cancel();
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
      expect((await future).isOk, true);
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

Uint8List _otaInfoPayload({
  List<int> product = const [0x52, 0x49, 0x4E, 0x47, 0, 0, 0, 0],
  int bootFlags = 0x0F,
}) {
  return Uint8List.fromList([
    0x78,
    0x56,
    0x00,
    0x00,
    ...product,
    bootFlags,
    1,
    2,
    3,
  ]);
}

class FakeBleTransport implements BleTransport {
  final scanController = StreamController<BleScanDevice>.broadcast();
  final availabilityController = StreamController<BleAvailability>.broadcast();
  final connectionController = StreamController<bool>.broadcast();
  final valueController = StreamController<Uint8List>.broadcast();
  final calls = <String>[];
  final writes = <String>[];
  bool failWrites = false;
  Future<Result<void, BleFailure>>? pendingWriteResult;

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
  Future<Result<void, BleFailure>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    calls.add('connect');
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> disconnect(String deviceId) async {
    calls.add('disconnect');
    return const Result.ok(null);
  }

  @override
  Future<Result<List<BleDiscoveredService>, BleFailure>> discoverServices(
    String deviceId,
  ) async {
    calls.add('discoverServices');
    return const Result.ok([
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
  Future<Result<BleAvailability, BleFailure>> getAvailability() async {
    return const Result.ok(BleAvailability.poweredOn);
  }

  @override
  Future<Result<void, BleFailure>> requestPermissions() async {
    return const Result.ok(null);
  }

  @override
  Future<Result<int, BleFailure>> requestMtu(
    String deviceId,
    int expectedMtu,
  ) async {
    calls.add('requestMtu:$expectedMtu');
    return Result.ok(expectedMtu);
  }

  @override
  Future<Result<void, BleFailure>> startScan(BleScanOptions options) async {
    calls.add('startScan');
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> stopScan() async {
    calls.add('stopScan');
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> subscribeNotifications(
    String deviceId,
    String serviceId,
    String characteristicId,
  ) async {
    calls.add('subscribeNotifications');
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
    writes.add(bytesToHex(value));
    final pendingWriteResult = this.pendingWriteResult;
    if (pendingWriteResult != null) return pendingWriteResult;
    if (failWrites) {
      return const Result.err(
        BleFailure(code: BleFailureCode.writeFailed, message: 'boom'),
      );
    }
    return const Result.ok(null);
  }

  void emit(RingCommand command, List<int> payload) {
    valueController.add(_codec.encode(command, payload));
  }

  void emitConnection(bool connected) {
    connectionController.add(connected);
  }

  @override
  void dispose() {}
}
