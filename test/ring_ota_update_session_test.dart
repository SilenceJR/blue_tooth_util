import 'dart:async';
import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RingOtaUpdateSession', () {
    test(
      'connects the exact OTA target before creating any business session',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final transport = _UpdateTransport(
          scanBatches: [
            [_otaDevice(identity, 'ota-target')],
          ],
        );
        final update = _updateSession(transport, identity);
        final startWritten = Completer<void>();
        transport.onWrite = (write) {
          if (write.characteristicId ==
                  RingOtaProtocol.commandCharacteristicUuid &&
              write.value.first == 0x01 &&
              !startWritten.isCompleted) {
            startWritten.complete();
          }
        };
        addTearDown(() async {
          await update.dispose();
          await transport.close();
        });

        final pending = update.update(_testPackage());
        await startWritten.future;

        expect(transport.connects, ['ota-target']);
        expect(transport.applicationCommands, isEmpty);
        update.cancel();
        expect((await pending).failureOrNull?.code, BleFailureCode.cancelled);
      },
    );

    test(
      'ignores candidate lookalikes and completes only after exact application 0x0402 confirmation',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final other = RingDeviceIdentity.fromMac('10:20:30:40:50:60');
        final transport = _UpdateTransport(
          scanBatches: [
            [
              _otaDevice(other, 'wrong-ota'),
              _otaDevice(identity, 'ota-target'),
            ],
            [
              _applicationDevice(other, 'wrong-app'),
              _applicationDevice(identity, 'app-target'),
            ],
          ],
        );
        final update = _updateSession(transport, identity);
        final snapshots = <RingOtaUpdateSnapshot>[];
        final subscription = update.snapshotStream.listen(snapshots.add);
        final queryWritten = Completer<void>();
        _wireOtaTransfer(
          transport,
          onApplicationOtaInfo: () {
            if (!queryWritten.isCompleted) queryWritten.complete();
          },
        );
        addTearDown(() async {
          await subscription.cancel();
          await update.dispose();
          await transport.close();
        });

        final future = update.update(_testPackage());
        await queryWritten.future;
        var finished = false;
        unawaited(future.then((_) => finished = true));
        await _flushEvents();
        expect(finished, isFalse, reason: '0x83 and 0x8A are not success');
        transport.respondApplicationOtaInfo(_otaInfoPayload());
        final result = await future;

        expect(result.isOk, isTrue);
        expect(result.valueOrNull?.roundCount, 1);
        expect(result.valueOrNull?.confirmedOtaInfo.firmwareVersion, 0x0103);
        expect(transport.connects, [
          'ota-target',
          'app-target',
        ], reason: 'name/service candidates without matching MAC are ignored');
        expect(transport.startScanCount, 2);
        expect(transport.applicationCommands, [
          RingCommand.otaInfo,
        ], reason: 'final success requires an application-mode query');
        expect(
          snapshots
              .where(
                (snapshot) => snapshot.phase == RingOtaUpdatePhase.transferring,
              )
              .map((snapshot) => snapshot.transferPhase),
          containsAll(<RingOtaTransferPhase>[
            RingOtaTransferPhase.starting,
            RingOtaTransferPhase.declaringPartition,
            RingOtaTransferPhase.transferringPartition,
            RingOtaTransferPhase.awaitingPartitionComplete,
            RingOtaTransferPhase.bootloaderComplete,
            RingOtaTransferPhase.rebooting,
          ]),
          reason: 'progress forwarding must retain protocol phase boundaries',
        );
      },
    );

    test(
      'dispose waits for a pending application query and leaves the update cancelled',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final transport = _UpdateTransport(
          scanBatches: [
            [_otaDevice(identity, 'ota-target')],
            [_applicationDevice(identity, 'app-target')],
          ],
        );
        final update = _updateSession(transport, identity);
        final snapshots = <RingOtaUpdateSnapshot>[];
        final subscription = update.snapshotStream.listen(snapshots.add);
        final queryWritten = Completer<void>();
        _wireOtaTransfer(
          transport,
          onApplicationOtaInfo: () {
            if (!queryWritten.isCompleted) queryWritten.complete();
          },
        );
        addTearDown(() async {
          await subscription.cancel();
          await update.dispose();
          await transport.close();
        });

        final future = update.update(_testPackage());
        await queryWritten.future;
        final disposing = update.dispose();
        final result = await future;
        await disposing;
        final snapshotCount = snapshots.length;
        final writeCount = transport.writes.length;
        final connectCount = transport.connects.length;
        transport.respondApplicationOtaInfo(_otaInfoPayload());
        await _flushEvents();

        expect(result.failureOrNull?.code, BleFailureCode.cancelled);
        expect(
          snapshots.map((snapshot) => snapshot.phase),
          isNot(contains(RingOtaUpdatePhase.completed)),
        );
        expect(snapshots.last.phase, RingOtaUpdatePhase.cancelled);
        expect(snapshots, hasLength(snapshotCount));
        expect(transport.writes, hasLength(writeCount));
        expect(transport.connects, hasLength(connectCount));
        expect(
          (await update.update(_testPackage())).failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );
      },
    );

    test(
      'fails final verification when the exact target reports a different firmware version',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final transport = _UpdateTransport(
          scanBatches: [
            [_otaDevice(identity, 'ota-target')],
            [_applicationDevice(identity, 'app-target')],
          ],
        );
        final update = _updateSession(transport, identity);
        _wireOtaTransfer(
          transport,
          onApplicationOtaInfo: () => transport.respondApplicationOtaInfo(
            _otaInfoPayload(firmwareVersion: 0x0102),
          ),
        );
        addTearDown(() async {
          await update.dispose();
          await transport.close();
        });

        final result = await update.update(_testPackage());

        expect(result.failureOrNull?.code, BleFailureCode.protocolError);
        expect(
          transport.startScanCount,
          2,
          reason: 'version mismatch is not recoverable',
        );
        expect(transport.otaStartWrites, 1);
        expect(transport.applicationCommands, [RingCommand.otaInfo]);
      },
    );

    test(
      'restarts from START at most three rounds for recoverable OTA device errors',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final transport = _UpdateTransport(
          scanBatches: [
            [_otaDevice(identity, 'ota-target')],
            [_otaDevice(identity, 'ota-target')],
            [_otaDevice(identity, 'ota-target')],
          ],
        );
        final update = _updateSession(transport, identity);
        transport.onWrite = (write) {
          if (write.characteristicId ==
                  RingOtaProtocol.commandCharacteristicUuid &&
              write.value.first == 0x01) {
            transport.respondOtaRaw([0x68, RingOtaProtocol.responseStart]);
          }
        };
        addTearDown(() async {
          await update.dispose();
          await transport.close();
        });

        final result = await update.update(_testPackage());

        expect(result.failureOrNull?.code, BleFailureCode.deviceError);
        expect(transport.otaStartWrites, 3);
        expect(transport.startScanCount, 3);
        expect(transport.connects, ['ota-target', 'ota-target', 'ota-target']);
        expect(transport.applicationCommands, isEmpty);
      },
    );

    test(
      'replays complete START rounds when OTA reappears after OTA_COMPLETE',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final transport = _UpdateTransport(
          scanBatches: List<List<BleScanDevice>>.generate(
            6,
            (_) => [_otaDevice(identity, 'ota-target')],
          ),
        );
        final update = _updateSession(transport, identity);
        _wireOtaTransfer(
          transport,
          onApplicationOtaInfo: () => fail(
            'an OTA-mode rediscovery must recover instead of querying business 0x0402',
          ),
        );
        addTearDown(() async {
          await update.dispose();
          await transport.close();
        });

        final result = await update.update(_testPackage());

        expect(result.failureOrNull?.code, BleFailureCode.connectionFailed);
        expect(
          transport.otaStartWrites,
          RingOtaUpdateSession.maxTransferRounds,
        );
        expect(
          transport.startScanCount,
          RingOtaUpdateSession.maxTransferRounds * 2,
        );
        expect(
          transport.connects,
          List<String>.filled(
            RingOtaUpdateSession.maxTransferRounds,
            'ota-target',
          ),
        );
        expect(transport.applicationCommands, isEmpty);
      },
    );

    test('does not retry nonrecoverable OTA device errors', () async {
      final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
      final transport = _UpdateTransport(
        scanBatches: [
          [_otaDevice(identity, 'ota-target')],
          [_otaDevice(identity, 'ota-target')],
        ],
      );
      final update = _updateSession(transport, identity);
      transport.onWrite = (write) {
        if (write.characteristicId ==
                RingOtaProtocol.commandCharacteristicUuid &&
            write.value.first == 0x01) {
          transport.respondOtaRaw([0x06, RingOtaProtocol.responseStart]);
        }
      };
      addTearDown(() async {
        await update.dispose();
        await transport.close();
      });

      final result = await update.update(_testPackage());

      expect(result.failureOrNull?.code, BleFailureCode.deviceError);
      expect(transport.otaStartWrites, 1);
      expect(transport.startScanCount, 1);
    });

    test(
      'cancels a pending scan, rejects concurrent update, and releases resources on dispose',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final transport = _UpdateTransport();
        final update = _updateSession(transport, identity);
        addTearDown(transport.close);

        final pending = update.update(_testPackage());
        await _until(() => transport.startScanCount == 1);
        expect(
          (await update.update(_testPackage())).failureOrNull?.code,
          BleFailureCode.busy,
        );
        update.cancel();
        expect((await pending).failureOrNull?.code, BleFailureCode.cancelled);
        transport.emitScan(_otaDevice(identity, 'late-target'));
        await _flushEvents();
        expect(transport.connects, isEmpty);

        await update.dispose();
        expect(
          (await update.update(_testPackage())).failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );
        expect(transport.stopScanCount, greaterThanOrEqualTo(2));
      },
    );
  });
}

RingOtaUpdateSession _updateSession(
  _UpdateTransport transport,
  RingDeviceIdentity identity,
) => RingOtaUpdateSession(
  transport: transport,
  identity: identity,
  scanTimeout: const Duration(milliseconds: 100),
  versionConfirmationTimeout: const Duration(milliseconds: 100),
);

void _wireOtaTransfer(
  _UpdateTransport transport, {
  required void Function() onApplicationOtaInfo,
}) {
  final codec = const RingFrameCodec();
  transport.onWrite = (write) {
    if (write.characteristicId == RingOtaProtocol.commandCharacteristicUuid) {
      switch (write.value.first) {
        case 0x01:
          transport.respondOta(RingOtaProtocol.responseStart);
        case 0x02:
          transport.respondOta(RingOtaProtocol.responsePartitionInfo);
        case 0x04:
          transport.respondOta(RingOtaProtocol.responseReboot);
      }
      return;
    }
    if (write.characteristicId == RingOtaProtocol.dataCharacteristicUuid) {
      transport.respondOta(RingOtaProtocol.responseOtaComplete);
      return;
    }
    if (write.characteristicId == RingProtocol.writeCharacteristicUuid) {
      final frame = codec.decode(write.value).valueOrNull;
      if (frame?.command == RingCommand.otaInfo) onApplicationOtaInfo();
    }
  };
}

BleScanDevice _otaDevice(RingDeviceIdentity identity, String deviceId) =>
    BleScanDevice(
      deviceId: deviceId,
      name: RingProtocol.otaDeviceName,
      manufacturerData: [
        BleManufacturerData(
          companyId: RingProtocol.otaManufacturerCompanyId,
          payload: Uint8List.fromList([...identity.otaMac, 0, 0]),
        ),
      ],
    );

BleScanDevice _applicationDevice(
  RingDeviceIdentity identity,
  String deviceId,
) => BleScanDevice(
  deviceId: deviceId,
  name: RingProtocol.deviceName,
  manufacturerData: [
    BleManufacturerData(
      companyId: RingProtocol.manufacturerIdentifier,
      payload: Uint8List.fromList([
        ...identity.applicationMac,
        0x03,
        0x02,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]),
    ),
  ],
);

Uint8List _otaInfoPayload({int firmwareVersion = 0x0103}) =>
    Uint8List.fromList([
      firmwareVersion & 0xFF,
      (firmwareVersion >> 8) & 0xFF,
      (firmwareVersion >> 16) & 0xFF,
      (firmwareVersion >> 24) & 0xFF,
      ...'Ring2'.codeUnits,
      0,
      0,
      0,
      0x01,
      1,
      0,
      0,
    ]);

RingOtaPackage _testPackage() {
  const product = [0x52, 0x69, 0x6E, 0x67, 0x32, 0, 0, 0];
  final bytes = Uint8List(52);
  bytes.setRange(0, 4, 'ROTA'.codeUnits);
  bytes[4] = 1;
  bytes[6] = 1;
  _writeUint32(bytes, 8, 0x0103);
  _writeUint32(bytes, 12, 4);
  bytes.setRange(16, 24, product);
  _writeUint32(bytes, 32, 0);
  _writeUint32(bytes, 36, 0x1FFF0000);
  _writeUint32(bytes, 40, 4);
  _writeUint32(bytes, 44, _otaCrc16([1, 2, 3, 4]));
  bytes.setRange(48, 52, [1, 2, 3, 4]);
  _writeUint32(
    bytes,
    28,
    _otaCrc16(bytes.take(28).followedBy(bytes.sublist(32, 48))),
  );
  final result = const RingOtaPackageParser().parse(
    bytes,
    deviceInfo: RingOtaInfo.fromPayload(
      Uint8List.fromList([0x02, 0x01, 0, 0, ...product, 1, 1, 0, 0]),
    ),
    versionPolicy: RingOtaVersionPolicy.normalUpgrade,
  );
  expect(result.isOk, isTrue);
  return result.valueOrNull!;
}

void _writeUint32(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xFF;
  bytes[offset + 1] = (value >> 8) & 0xFF;
  bytes[offset + 2] = (value >> 16) & 0xFF;
  bytes[offset + 3] = (value >> 24) & 0xFF;
}

int _otaCrc16(Iterable<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xA001;
    }
  }
  return crc & 0xFFFF;
}

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (predicate()) return;
    await _flushEvents();
  }
  fail('Expected fake transport activity did not occur');
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

class _UpdateWrite {
  _UpdateWrite({required this.characteristicId, required Uint8List value})
    : value = Uint8List.fromList(value);

  final String characteristicId;
  final Uint8List value;
}

class _UpdateTransport implements BleTransport {
  _UpdateTransport({this.scanBatches = const []});

  final List<List<BleScanDevice>> scanBatches;
  final scanController = StreamController<BleScanDevice>.broadcast();
  final connectionController = StreamController<bool>.broadcast();
  final valueController = StreamController<Uint8List>.broadcast();
  final writes = <_UpdateWrite>[];
  final connects = <String>[];
  var startScanCount = 0;
  var stopScanCount = 0;
  void Function(_UpdateWrite write)? onWrite;

  int get otaStartWrites => writes
      .where(
        (write) =>
            write.characteristicId ==
                RingOtaProtocol.commandCharacteristicUuid &&
            write.value.first == 0x01,
      )
      .length;

  List<RingCommand> get applicationCommands {
    const codec = RingFrameCodec();
    return writes
        .where(
          (write) =>
              write.characteristicId == RingProtocol.writeCharacteristicUuid,
        )
        .map((write) => codec.decode(write.value).valueOrNull?.command)
        .whereType<RingCommand>()
        .toList();
  }

  @override
  Stream<BleScanDevice> get scanStream => scanController.stream;

  @override
  Stream<BleAvailability> get availabilityStream => const Stream.empty();

  @override
  Stream<bool> connectionStream(String deviceId) => connectionController.stream;

  @override
  Stream<Uint8List> valueStream(String deviceId, String characteristicId) =>
      valueController.stream;

  @override
  Future<Result<void, BleFailure>> requestPermissions() async =>
      const Result.ok(null);

  @override
  Future<Result<BleAvailability, BleFailure>> getAvailability() async =>
      const Result.ok(BleAvailability.poweredOn);

  @override
  Future<Result<void, BleFailure>> startScan(BleScanOptions options) async {
    final index = startScanCount++;
    if (index < scanBatches.length) {
      scheduleMicrotask(() {
        for (final device in scanBatches[index]) {
          scanController.add(device);
        }
      });
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> stopScan() async {
    stopScanCount++;
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    connects.add(deviceId);
    return const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> disconnect(String deviceId) async =>
      const Result.ok(null);

  @override
  Future<Result<int, BleFailure>> requestMtu(
    String deviceId,
    int expectedMtu,
  ) async => Result.ok(240);

  @override
  Future<Result<List<BleDiscoveredService>, BleFailure>> discoverServices(
    String deviceId,
  ) async =>
      Result.ok(deviceId.startsWith('ota-') ? _otaGatt : _applicationGatt);

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
    final write = _UpdateWrite(
      characteristicId: characteristicId,
      value: value,
    );
    writes.add(write);
    onWrite?.call(write);
    return const Result.ok(null);
  }

  void emitScan(BleScanDevice device) => scanController.add(device);

  void respondOta(int code) => respondOtaRaw([0, code]);

  void respondOtaRaw(List<int> value) =>
      scheduleMicrotask(() => valueController.add(Uint8List.fromList(value)));

  void respondApplicationOtaInfo(Uint8List payload) => scheduleMicrotask(
    () => valueController.add(
      const RingFrameCodec().encode(RingCommand.otaInfo, payload),
    ),
  );

  Future<void> close() async {
    await scanController.close();
    await connectionController.close();
    await valueController.close();
  }

  @override
  void dispose() {}
}

final _otaGatt = <BleDiscoveredService>[
  BleDiscoveredService(
    uuid: RingOtaProtocol.serviceUuid,
    characteristics: const [
      BleDiscoveredCharacteristic(
        uuid: RingOtaProtocol.commandCharacteristicUuid,
        canWrite: true,
      ),
      BleDiscoveredCharacteristic(
        uuid: RingOtaProtocol.responseCharacteristicUuid,
        canNotify: true,
      ),
      BleDiscoveredCharacteristic(
        uuid: RingOtaProtocol.dataCharacteristicUuid,
        canWriteWithoutResponse: true,
      ),
    ],
  ),
];

final _applicationGatt = <BleDiscoveredService>[
  BleDiscoveredService(
    uuid: RingProtocol.serviceUuid,
    characteristics: const [
      BleDiscoveredCharacteristic(uuid: RingProtocol.writeCharacteristicUuid),
      BleDiscoveredCharacteristic(uuid: RingProtocol.notifyCharacteristicUuid),
    ],
  ),
];
