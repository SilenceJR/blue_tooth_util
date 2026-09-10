import 'dart:async';
import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RingOtaProtocolAdapter', () {
    test('requires both OTA candidate evidence and 0x0504 derived MAC', () {
      final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:FF');
      final dynamicAdapter = RingOtaProtocolAdapter(identity: identity);
      final matchingData = BleManufacturerData(
        companyId: RingProtocol.otaManufacturerCompanyId,
        payload: Uint8List.fromList([...identity.otaMac, 0xAA, 0x55]),
      );

      expect(identity.otaMacText, '01:02:03:04:05:00');
      expect(
        dynamicAdapter.matches(
          BleScanDevice(
            deviceId: 'target',
            name: RingProtocol.otaDeviceName,
            manufacturerData: [matchingData],
          ),
        ),
        isTrue,
      );
      expect(
        dynamicAdapter.matches(
          BleScanDevice(
            deviceId: 'target-by-service',
            services: [RingProtocol.otaServiceUuid.toUpperCase()],
            manufacturerData: [matchingData],
          ),
        ),
        isTrue,
      );
      expect(
        dynamicAdapter.matches(
          BleScanDevice(
            deviceId: 'name-only',
            name: RingProtocol.otaDeviceName,
          ),
        ),
        isFalse,
      );
      expect(
        dynamicAdapter.matches(
          BleScanDevice(
            deviceId: 'service-only',
            services: [RingProtocol.otaServiceUuid],
          ),
        ),
        isFalse,
      );
      expect(
        dynamicAdapter.matches(
          BleScanDevice(deviceId: 'mac-only', manufacturerData: [matchingData]),
        ),
        isFalse,
      );
      expect(
        dynamicAdapter.matches(
          BleScanDevice(
            deviceId: 'wrong-company',
            name: RingProtocol.otaDeviceName,
            manufacturerData: [
              BleManufacturerData(
                companyId: 0x0503,
                payload: Uint8List.fromList([...identity.otaMac, 0, 0]),
              ),
            ],
          ),
        ),
        isFalse,
      );
      expect(
        dynamicAdapter.matches(
          BleScanDevice(
            deviceId: 'wrong-length',
            name: RingProtocol.otaDeviceName,
            manufacturerData: [
              BleManufacturerData(
                companyId: RingProtocol.otaManufacturerCompanyId,
                payload: identity.otaMac,
              ),
            ],
          ),
        ),
        isFalse,
      );
      expect(dynamicAdapter.id, 'ring-ota-v1');
    });

    test(
      'requires exact application Manufacturer Data MAC after candidate filtering',
      () {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        BleManufacturerData advertisement(List<int> mac) => BleManufacturerData(
          companyId: RingProtocol.manufacturerIdentifier,
          payload: Uint8List.fromList([
            ...mac,
            0x03,
            0x02,
            0x01,
            0,
            0x02,
            0,
            0x03,
            0,
            0x01,
            0,
            0x01,
          ]),
        );

        expect(
          identity.matchesApplicationDevice(
            BleScanDevice(
              deviceId: 'application-target',
              name: RingProtocol.deviceName,
              manufacturerData: [advertisement(identity.applicationMac)],
            ),
          ),
          isTrue,
        );
        expect(
          identity.matchesApplicationDevice(
            BleScanDevice(
              deviceId: 'same-name-wrong-mac',
              name: RingProtocol.deviceName,
              manufacturerData: [
                advertisement([1, 2, 3, 4, 5, 7]),
              ],
            ),
          ),
          isFalse,
        );
        expect(
          identity.matchesApplicationDevice(
            BleScanDevice(deviceId: 'name-only', name: RingProtocol.deviceName),
          ),
          isFalse,
        );
      },
    );
  });

  group('RingOtaProtocol', () {
    test('encodes START, PARTITION_INFO and delayed REBOOT exactly', () {
      final package = _package(const [
        _PartitionSpec(0, 0x1FFF0000, [1, 2, 3, 4]),
        _PartitionSpec(0x11020000, 0x11020000, [5, 6, 7, 8]),
      ]);

      expect(RingOtaProtocol.startCommand(2, 8), [0x01, 0x02, 0x08]);
      expect(RingOtaProtocol.partitionInfoCommand(package.partitions.first), [
        0x02,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xFF,
        0x1F,
        0x04,
        0x00,
        0x00,
        0x00,
        0xA1,
        0x0F,
        0x00,
        0x00,
      ]);
      expect(RingOtaProtocol.partitionInfoCommand(package.partitions.last), [
        0x02,
        0x01,
        0x00,
        0x00,
        0x02,
        0x11,
        0x00,
        0x00,
        0x02,
        0x11,
        0x04,
        0x00,
        0x00,
        0x00,
        0xE3,
        0x3B,
        0x00,
        0x00,
      ]);
      expect(RingOtaProtocol.delayedRebootCommand(), [0x04, 0x01]);
    });

    test(
      'distinguishes one-byte device errors and valid/invalid response shapes',
      () {
        final success = RingOtaProtocol.parseResponse(
          Uint8List.fromList([0, 0x81]),
        );
        final deviceError = RingOtaProtocol.parseResponse(
          Uint8List.fromList([0x68]),
        );
        final unknown = RingOtaProtocol.parseResponse(
          Uint8List.fromList([0, 0x99]),
        );
        final encryptedLength = RingOtaProtocol.parseResponse(Uint8List(16));

        expect(success.valueOrNull?.code, 0x81);
        expect(deviceError.failureOrNull?.code, BleFailureCode.deviceError);
        expect(
          (deviceError.failureOrNull?.cause as RingOtaDeviceFailure?)?.error,
          RingOtaDeviceError.badData,
        );
        expect(unknown.failureOrNull?.code, BleFailureCode.protocolError);
        expect(encryptedLength.failureOrNull?.code, BleFailureCode.unsupported);
        expect(
          RingOtaProtocol.parseResponse(
            Uint8List.fromList([0]),
          ).failureOrNull?.code,
          BleFailureCode.protocolError,
        );
      },
    );
  });

  group('RingOtaSession initialization', () {
    test(
      'SDK disposes and disconnects when OTA initialization fails',
      () async {
        final identity = RingDeviceIdentity.fromMac('01:02:03:04:05:06');
        final fake = _FakeTransport(services: const []);
        final sdk = BlueToothSdk(
          transport: fake,
          adapters: [RingOtaProtocolAdapter(identity: identity)],
        );
        addTearDown(fake.close);
        final device = BleScanDevice(
          deviceId: 'target',
          name: RingProtocol.otaDeviceName,
          manufacturerData: [
            BleManufacturerData(
              companyId: RingProtocol.otaManufacturerCompanyId,
              payload: Uint8List.fromList([...identity.otaMac, 0, 0]),
            ),
          ],
        );

        final result = await sdk.connect(device);

        expect(result.failureOrNull?.code, BleFailureCode.serviceNotFound);
        expect(fake.calls.last, 'disconnect');

        final cleanupFailure = _FakeTransport(
          services: const [],
          disconnectResult: const Result.err(
            BleFailure(
              code: BleFailureCode.connectionFailed,
              message: 'disconnect failed',
            ),
          ),
        );
        final failingSdk = BlueToothSdk(
          transport: cleanupFailure,
          adapters: [RingOtaProtocolAdapter(identity: identity)],
        );
        addTearDown(cleanupFailure.close);
        final failingResult = await failingSdk.connect(device);
        final cause =
            failingResult.failureOrNull?.cause
                as ({BleFailure disconnect, BleFailure initialization});
        expect(
          failingResult.failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );
        expect(cause.initialization.code, BleFailureCode.serviceNotFound);
        expect(cause.disconnect.code, BleFailureCode.connectionFailed);
      },
    );

    test(
      'listens before negotiating MTU, checks GATT then subscribes',
      () async {
        final fake = _FakeTransport();
        final session = _session(fake);
        addTearDown(() async {
          await session.dispose();
          await fake.close();
        });

        final result = await session.initialize();

        expect(result.isOk, isTrue);
        expect(session.actualMtu, 240);
        expect(session.packetSize, 237);
        expect(fake.calls, [
          'connectionStream',
          'valueStream',
          'requestMtu:247',
          'discoverServices',
          'subscribeNotifications',
        ]);
      },
    );

    test(
      'uses negotiated minimum and caps oversized MTU for packet length',
      () async {
        for (final item in <(int, int)>[(23, 20), (240, 237), (300, 237)]) {
          final fake = _FakeTransport(mtu: item.$1);
          final session = _session(fake);
          addTearDown(() async {
            await session.dispose();
            await fake.close();
          });

          expect((await session.initialize()).isOk, isTrue);
          expect(session.packetSize, item.$2, reason: 'MTU ${item.$1}');
        }
      },
    );

    test(
      'shares concurrent initialization and rejects dispose or disconnect races',
      () async {
        final sharedGate = Completer<Result<int, BleFailure>>();
        final sharedFake = _FakeTransport(mtuFuture: sharedGate.future);
        final sharedSession = _session(sharedFake);
        addTearDown(() async {
          await sharedSession.dispose();
          await sharedFake.close();
        });
        final first = sharedSession.initialize();
        final second = sharedSession.initialize();
        await _until(() => sharedFake.calls.contains('requestMtu:247'));
        expect(
          sharedFake.calls.where((call) => call == 'connectionStream'),
          hasLength(1),
        );
        sharedGate.complete(const Result.ok(240));
        expect((await first).isOk, isTrue);
        expect((await second).isOk, isTrue);

        for (final disposeDuringInit in [false, true]) {
          final gate = Completer<Result<int, BleFailure>>();
          final fake = _FakeTransport(mtuFuture: gate.future);
          final session = _session(fake);
          addTearDown(() async {
            await session.dispose();
            await fake.close();
          });
          final initialization = session.initialize();
          await _until(() => fake.calls.contains('requestMtu:247'));
          if (disposeDuringInit) {
            final disposal = session.dispose();
            gate.complete(const Result.ok(240));
            await disposal;
          } else {
            fake.emitConnection(false);
            gate.complete(const Result.ok(240));
          }
          expect(
            (await initialization).failureOrNull?.code,
            BleFailureCode.connectionFailed,
          );
        }
      },
    );

    test(
      'fails MTU negotiation, missing required capability, and subscribe failure',
      () async {
        final mtuFailure = _FakeTransport(
          mtuResult: const Result.err(
            BleFailure(code: BleFailureCode.writeFailed, message: 'MTU failed'),
          ),
        );
        final subscribeFailure = _FakeTransport(
          subscribeResult: const Result.err(
            BleFailure(
              code: BleFailureCode.connectionFailed,
              message: 'subscribe',
            ),
          ),
        );
        final fixtures = [
          (mtuFailure, BleFailureCode.writeFailed),
          (subscribeFailure, BleFailureCode.connectionFailed),
          ...[
            const [
              BleDiscoveredCharacteristic(
                uuid: RingOtaProtocol.responseCharacteristicUuid,
                canNotify: true,
              ),
              BleDiscoveredCharacteristic(
                uuid: RingOtaProtocol.dataCharacteristicUuid,
                canWriteWithoutResponse: true,
              ),
            ],
            const [
              BleDiscoveredCharacteristic(
                uuid: RingOtaProtocol.commandCharacteristicUuid,
                canWrite: true,
              ),
              BleDiscoveredCharacteristic(
                uuid: RingOtaProtocol.dataCharacteristicUuid,
                canWriteWithoutResponse: true,
              ),
            ],
            const [
              BleDiscoveredCharacteristic(
                uuid: RingOtaProtocol.commandCharacteristicUuid,
                canWrite: true,
              ),
              BleDiscoveredCharacteristic(
                uuid: RingOtaProtocol.responseCharacteristicUuid,
                canNotify: true,
              ),
            ],
          ].map(
            (characteristics) => (
              _FakeTransport(
                services: [
                  BleDiscoveredService(
                    uuid: RingOtaProtocol.serviceUuid,
                    characteristics: characteristics,
                  ),
                ],
              ),
              BleFailureCode.serviceNotFound,
            ),
          ),
        ];
        for (final item in fixtures) {
          final session = _session(item.$1);
          addTearDown(() async {
            await session.dispose();
            await item.$1.close();
          });
          final result = await session.initialize();
          expect(result.failureOrNull?.code, item.$2);
        }
      },
    );
  });

  group('RingOtaSession transfer', () {
    test(
      'sends mixed bursts, uses cached terminal response, then reboots and disconnects',
      () async {
        final fake = _FakeTransport(mtu: 23);
        final session = _session(fake);
        final package = _package([
          _PartitionSpec(0, 0x1FFF0000, List<int>.generate(164, (i) => i)),
          _PartitionSpec(
            0x11020000,
            0x11020000,
            List<int>.generate(160, (i) => i),
          ),
        ]);
        final snapshots = <RingOtaTransferSnapshot>[];
        final subscription = session.snapshotStream.listen(snapshots.add);
        addTearDown(() async {
          await subscription.cancel();
          await session.dispose();
          await fake.close();
        });
        var partition = -1;
        var dataInPartition = 0;
        fake.onWrite = (write) {
          if (write.characteristicId ==
              RingOtaProtocol.commandCharacteristicUuid) {
            switch (write.value.first) {
              case 0x01:
                fake.respond(RingOtaProtocol.responseStart);
              case 0x02:
                partition++;
                dataInPartition = 0;
                fake.respond(RingOtaProtocol.responsePartitionInfo);
              case 0x04:
                fake.respond(RingOtaProtocol.responseReboot);
            }
            return;
          }
          dataInPartition++;
          if (partition == 0 && dataInPartition == 8) {
            fake.respond(RingOtaProtocol.responseBlockBurst);
          } else if (partition == 0 && dataInPartition == 9) {
            fake.respond(RingOtaProtocol.responsePartitionComplete);
          } else if (partition == 1 && dataInPartition == 8) {
            // The terminal response follows 0x87 before the next wait is registered.
            fake.respond(RingOtaProtocol.responseBlockBurst);
            fake.respond(RingOtaProtocol.responseOtaComplete);
          }
        };

        expect((await session.initialize()).isOk, isTrue);
        final result = await session.transfer(package);
        await _flushEvents();

        expect(result.isOk, isTrue);
        expect(result.valueOrNull?.acknowledgedBytes, 324);
        expect(result.valueOrNull?.partitionCount, 2);
        expect(result.valueOrNull?.rebootAcknowledged, isTrue);
        expect(result.valueOrNull?.requiresVersionConfirmation, isTrue);
        expect(fake.calls.last, 'disconnect');
        final controls = fake.writes
            .where(
              (item) =>
                  item.characteristicId ==
                  RingOtaProtocol.commandCharacteristicUuid,
            )
            .toList();
        expect(controls.map((item) => item.value.first), [
          0x01,
          0x02,
          0x02,
          0x04,
        ]);
        expect(controls.first.value, [0x01, 0x02, 0x08]);
        expect(controls[1].value.sublist(0, 14), [
          0x02,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0xFF,
          0x1F,
          0xA4,
          0,
          0,
          0,
        ]);
        expect(controls[2].value.sublist(0, 14), [
          0x02,
          1,
          0,
          0,
          2,
          0x11,
          0,
          0,
          2,
          0x11,
          0xA0,
          0,
          0,
          0,
        ]);
        expect(controls.last.value, [0x04, 0x01]);
        final dataWrites = fake.writes
            .where(
              (item) =>
                  item.characteristicId ==
                  RingOtaProtocol.dataCharacteristicUuid,
            )
            .toList();
        expect(dataWrites, hasLength(17));
        expect(dataWrites.map((item) => item.value.length), [
          ...List.filled(8, 20),
          4,
          ...List.filled(8, 20),
        ]);
        expect(dataWrites.every((item) => item.withoutResponse), isTrue);
        expect(
          fake.writes
              .where(
                (item) =>
                    item.characteristicId ==
                    RingOtaProtocol.commandCharacteristicUuid,
              )
              .every((item) => !item.withoutResponse),
          isTrue,
        );
        expect(snapshots.map((item) => (item.phase, item.acknowledgedBytes)), [
          (RingOtaTransferPhase.starting, 0),
          (RingOtaTransferPhase.declaringPartition, 0),
          (RingOtaTransferPhase.transferringPartition, 0),
          (RingOtaTransferPhase.transferringPartition, 160),
          (RingOtaTransferPhase.awaitingPartitionComplete, 164),
          (RingOtaTransferPhase.declaringPartition, 164),
          (RingOtaTransferPhase.transferringPartition, 164),
          (RingOtaTransferPhase.transferringPartition, 324),
          (RingOtaTransferPhase.awaitingPartitionComplete, 324),
          (RingOtaTransferPhase.bootloaderComplete, 324),
          (RingOtaTransferPhase.rebooting, 324),
        ]);
      },
    );

    test(
      'retransmits one [0x68, 0x87] burst at most three times without duplicate acknowledgement',
      () async {
        final fake = _FakeTransport(mtu: 23);
        final session = _session(fake);
        final snapshots = <RingOtaTransferSnapshot>[];
        final subscription = session.snapshotStream.listen(snapshots.add);
        addTearDown(() async {
          await subscription.cancel();
          await session.dispose();
          await fake.close();
        });
        var dataWrites = 0;
        fake.onWrite = (write) {
          if (write.characteristicId ==
              RingOtaProtocol.commandCharacteristicUuid) {
            fake.respond(
              write.value.first == 0x01
                  ? RingOtaProtocol.responseStart
                  : RingOtaProtocol.responsePartitionInfo,
            );
          } else {
            dataWrites++;
            fake.respondRaw(
              dataWrites == 1
                  ? [0, RingOtaProtocol.responseBlockBurst]
                  : [0x68, RingOtaProtocol.responseBlockBurst],
            );
          }
        };
        expect((await session.initialize()).isOk, isTrue);

        final result = await session.transfer(
          _package([
            _PartitionSpec(
              0,
              0x1FFF0000,
              List<int>.generate(44, (index) => index),
            ),
          ]),
          burstSize: 1,
        );
        await _flushEvents();

        expect(result.failureOrNull?.code, BleFailureCode.deviceError);
        expect(
          dataWrites,
          5,
          reason: 'initial write, then exactly three resends',
        );
        expect(
          snapshots.map((snapshot) => snapshot.acknowledgedBytes).toSet(),
          {0, 20},
          reason:
              'the accepted first burst must not be counted again while retrying the second',
        );
        expect(snapshots.last.acknowledgedBytes, 20);
      },
    );

    test(
      'retransmits partial tails after [0x68, 0x87] and waits for their 0x85 or 0x83 terminal ACK',
      () async {
        final fake = _FakeTransport(mtu: 23);
        final session = _session(fake);
        final snapshots = <RingOtaTransferSnapshot>[];
        final subscription = session.snapshotStream.listen(snapshots.add);
        addTearDown(() async {
          await subscription.cancel();
          await session.dispose();
          await fake.close();
        });
        var partition = -1;
        var writesInPartition = 0;
        fake.onWrite = (write) {
          if (write.characteristicId ==
              RingOtaProtocol.commandCharacteristicUuid) {
            switch (write.value.first) {
              case 0x01:
                fake.respond(RingOtaProtocol.responseStart);
              case 0x02:
                partition++;
                writesInPartition = 0;
                fake.respond(RingOtaProtocol.responsePartitionInfo);
              case 0x04:
                fake.respond(RingOtaProtocol.responseReboot);
            }
            return;
          }
          writesInPartition++;
          fake.respondRaw(
            writesInPartition == 1
                ? [0x68, RingOtaProtocol.responseBlockBurst]
                : [
                    0,
                    partition == 0
                        ? RingOtaProtocol.responsePartitionComplete
                        : RingOtaProtocol.responseOtaComplete,
                  ],
          );
        };
        expect((await session.initialize()).isOk, isTrue);

        final result = await session.transfer(_goldenPackage());
        await _flushEvents();

        expect(result.isOk, isTrue);
        final dataWrites = fake.writes
            .where(
              (write) =>
                  write.characteristicId ==
                  RingOtaProtocol.dataCharacteristicUuid,
            )
            .toList();
        expect(dataWrites, hasLength(4));
        expect(dataWrites[0].value, dataWrites[1].value);
        expect(dataWrites[2].value, dataWrites[3].value);
        expect(
          snapshots
              .where(
                (snapshot) =>
                    snapshot.phase ==
                    RingOtaTransferPhase.awaitingPartitionComplete,
              )
              .map((snapshot) => snapshot.acknowledgedBytes),
          [4, 8],
          reason: 'only terminal ACKs advance each partial tail',
        );
      },
    );

    test(
      'retries a timed out control once and isolates its late duplicate ACK',
      () async {
        final fake = _FakeTransport();
        final session = _session(fake);
        addTearDown(() async {
          await session.dispose();
          await fake.close();
        });
        var startWrites = 0;
        var partition = -1;
        fake.onWrite = (write) {
          if (write.characteristicId ==
              RingOtaProtocol.commandCharacteristicUuid) {
            switch (write.value.first) {
              case 0x01:
                startWrites++;
              case 0x02:
                partition++;
              case 0x04:
                fake.respond(RingOtaProtocol.responseReboot);
            }
          } else {
            fake.respond(
              partition == 0
                  ? RingOtaProtocol.responsePartitionComplete
                  : RingOtaProtocol.responseOtaComplete,
            );
          }
        };
        expect((await session.initialize()).isOk, isTrue);

        final transfer = session.transfer(_goldenPackage());
        await _until(() => startWrites == 1);
        await Future<void>.delayed(const Duration(seconds: 3));
        await _until(() => startWrites == 2);
        expect(
          startWrites,
          2,
          reason: 'first control timeout permits one retry',
        );

        fake.respond(RingOtaProtocol.responseStart);
        await _until(
          () =>
              fake.writes
                      .where(
                        (write) =>
                            write.characteristicId ==
                            RingOtaProtocol.commandCharacteristicUuid,
                      )
                      .map((write) => write.value.first)
                      .where((command) => command == 0x01)
                      .length ==
                  2 &&
              fake.writes
                      .where(
                        (write) =>
                            write.characteristicId ==
                            RingOtaProtocol.commandCharacteristicUuid,
                      )
                      .where((write) => write.value.first == 0x02)
                      .length ==
                  1,
        );
        fake.respond(RingOtaProtocol.responseStart);
        fake.respond(RingOtaProtocol.responsePartitionInfo);
        await _until(
          () =>
              fake.writes
                  .where(
                    (write) =>
                        write.characteristicId ==
                        RingOtaProtocol.commandCharacteristicUuid,
                  )
                  .where((write) => write.value.first == 0x02)
                  .length ==
              2,
        );
        fake.respond(RingOtaProtocol.responsePartitionInfo);

        expect((await transfer).isOk, isTrue);
        expect(startWrites, 2);
      },
    );

    test(
      'requires reconnect before a second PARTITION_INFO when its retried 0x84 remains ambiguous',
      () async {
        final fake = _FakeTransport();
        final session = _session(fake);
        addTearDown(() async {
          await session.dispose();
          await fake.close();
        });
        var partitionInfoWrites = 0;
        var dataWrites = 0;
        fake.onWrite = (write) {
          if (write.characteristicId ==
              RingOtaProtocol.commandCharacteristicUuid) {
            switch (write.value.first) {
              case 0x01:
                fake.respond(RingOtaProtocol.responseStart);
              case 0x02:
                partitionInfoWrites++;
                if (partitionInfoWrites == 2) {
                  fake.respond(RingOtaProtocol.responsePartitionInfo);
                }
            }
          } else {
            dataWrites++;
            fake.respond(RingOtaProtocol.responsePartitionComplete);
          }
        };
        expect((await session.initialize()).isOk, isTrue);

        final transfer = session.transfer(_goldenPackage());
        await _until(() => partitionInfoWrites == 1);
        await Future<void>.delayed(const Duration(seconds: 3));
        final result = await transfer;

        expect(result.failureOrNull?.code, BleFailureCode.connectionFailed);
        expect(
          partitionInfoWrites,
          2,
          reason: 'the second partition must not write PARTITION_INFO',
        );
        expect(
          dataWrites,
          1,
          reason: 'only the first partition may write data',
        );
      },
    );

    test(
      'consumes a retried PARTITION_INFO duplicate during data wait before continuing to the next partition',
      () async {
        final fake = _FakeTransport();
        final session = _session(fake);
        addTearDown(() async {
          await session.dispose();
          await fake.close();
        });
        var partitionInfoWrites = 0;
        var dataWrites = 0;
        fake.onWrite = (write) {
          if (write.characteristicId ==
              RingOtaProtocol.commandCharacteristicUuid) {
            switch (write.value.first) {
              case 0x01:
                fake.respond(RingOtaProtocol.responseStart);
              case 0x02:
                partitionInfoWrites++;
                if (partitionInfoWrites > 1) {
                  fake.respond(RingOtaProtocol.responsePartitionInfo);
                }
              case 0x04:
                fake.respond(RingOtaProtocol.responseReboot);
            }
          } else {
            dataWrites++;
            if (dataWrites == 1) {
              fake.respond(RingOtaProtocol.responsePartitionInfo);
              fake.respond(RingOtaProtocol.responsePartitionComplete);
            } else {
              fake.respond(RingOtaProtocol.responseOtaComplete);
            }
          }
        };
        expect((await session.initialize()).isOk, isTrue);

        final transfer = session.transfer(_goldenPackage());
        await _until(() => partitionInfoWrites == 1);
        await Future<void>.delayed(const Duration(seconds: 3));
        final result = await transfer;

        expect(result.isOk, isTrue);
        expect(partitionInfoWrites, 3);
        expect(dataWrites, 2);
      },
    );

    test(
      'fails immediately for early terminal, wrong final terminal, out-of-order and device errors',
      () async {
        final cases = <(String, List<int>, BleFailureCode)>[
          (
            'early terminal',
            [0, RingOtaProtocol.responseOtaComplete],
            BleFailureCode.protocolError,
          ),
          (
            'out of order',
            [0, RingOtaProtocol.responsePartitionInfo],
            BleFailureCode.protocolError,
          ),
          (
            'device error 0x68',
            [0x68, RingOtaProtocol.responseStart],
            BleFailureCode.deviceError,
          ),
        ];
        for (final item in cases) {
          final fake = _FakeTransport();
          final session = _session(fake);
          addTearDown(() async {
            await session.dispose();
            await fake.close();
          });
          fake.onWrite = (_) => fake.respondRaw(item.$2);
          expect((await session.initialize()).isOk, isTrue);
          final result = await session.transfer(_goldenPackage());
          expect(result.failureOrNull?.code, item.$3, reason: item.$1);
          expect(
            fake.writes,
            hasLength(1),
            reason: '${item.$1} must not retry',
          );
        }

        final fake = _FakeTransport();
        final session = _session(fake);
        addTearDown(() async {
          await session.dispose();
          await fake.close();
        });
        var command = 0;
        fake.onWrite = (write) {
          if (write.characteristicId ==
              RingOtaProtocol.commandCharacteristicUuid) {
            command++;
            fake.respond(command == 1 ? 0x81 : 0x84);
          } else {
            fake.respond(RingOtaProtocol.responsePartitionComplete);
          }
        };
        expect((await session.initialize()).isOk, isTrue);
        final result = await session.transfer(_goldenPackage());
        expect(result.failureOrNull?.code, BleFailureCode.protocolError);
        expect(
          fake.writes,
          hasLength(5),
          reason: 'last partition 0x85 must not retry',
        );
      },
    );

    test('rejects a buffered terminal before writing the next burst', () async {
      final fake = _FakeTransport(mtu: 23);
      final session = _session(fake);
      addTearDown(() async {
        await session.dispose();
        await fake.close();
      });
      var dataWrites = 0;
      fake.onWrite = (write) {
        if (write.characteristicId ==
            RingOtaProtocol.commandCharacteristicUuid) {
          fake.respond(
            write.value.first == 0x01
                ? RingOtaProtocol.responseStart
                : RingOtaProtocol.responsePartitionInfo,
          );
        } else if (++dataWrites == 8) {
          fake.respond(RingOtaProtocol.responseBlockBurst);
          fake.respond(RingOtaProtocol.responsePartitionComplete);
        }
      };
      expect((await session.initialize()).isOk, isTrue);

      final result = await session.transfer(
        _package([
          _PartitionSpec(0, 0x1FFF0000, List<int>.generate(164, (i) => i)),
        ]),
      );

      expect(result.failureOrNull?.code, BleFailureCode.protocolError);
      expect(
        dataWrites,
        8,
        reason: 'must fail before writing the ninth packet',
      );
    });

    test(
      'segments data writes for negotiated MTU 23, 240 and an oversized result',
      () async {
        for (final item in <(int, int, List<int>)>[
          (23, 24, [20, 4]),
          (240, 240, [237, 3]),
          (300, 240, [237, 3]),
        ]) {
          final fake = _FakeTransport(mtu: item.$1);
          final session = _session(fake);
          addTearDown(() async {
            await session.dispose();
            await fake.close();
          });
          var dataWrites = 0;
          fake.onWrite = (write) {
            if (write.characteristicId ==
                RingOtaProtocol.commandCharacteristicUuid) {
              switch (write.value.first) {
                case 0x01:
                  fake.respond(RingOtaProtocol.responseStart);
                case 0x02:
                  fake.respond(RingOtaProtocol.responsePartitionInfo);
                case 0x04:
                  fake.respond(RingOtaProtocol.responseReboot);
              }
            } else {
              dataWrites++;
              fake.respond(
                dataWrites == 1
                    ? RingOtaProtocol.responseBlockBurst
                    : RingOtaProtocol.responseOtaComplete,
              );
            }
          };

          expect((await session.initialize()).isOk, isTrue);
          final result = await session.transfer(
            _package([
              _PartitionSpec(
                0,
                0x1FFF0000,
                List<int>.generate(item.$2, (index) => index),
              ),
            ]),
            burstSize: 1,
          );

          expect(result.isOk, isTrue, reason: 'MTU ${item.$1}');
          expect(session.packetSize, item.$3.first == 20 ? 20 : 237);
          expect(
            fake.writes
                .where(
                  (write) =>
                      write.characteristicId ==
                      RingOtaProtocol.dataCharacteristicUuid,
                )
                .map((write) => write.value.length),
            item.$3,
            reason: 'MTU ${item.$1}',
          );
        }
      },
    );

    test(
      'cancels a pending transfer and requires reconnect before reuse',
      () async {
        final fake = _FakeTransport();
        final session = _session(fake);
        addTearDown(() async {
          await session.dispose();
          await fake.close();
        });
        expect((await session.initialize()).isOk, isTrue);
        final pending = session.transfer(_goldenPackage());
        await _until(() => fake.writes.isNotEmpty);
        expect(
          (await session.transfer(_goldenPackage())).failureOrNull?.code,
          BleFailureCode.busy,
        );
        session.cancelTransfer();
        expect((await pending).failureOrNull?.code, BleFailureCode.cancelled);
        final writesAfterCancel = fake.writes.length;
        fake.respond(RingOtaProtocol.responseStart);
        await _flushEvents();
        expect(
          (await session.transfer(_goldenPackage())).failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );
        expect(fake.writes, hasLength(writesAfterCancel));
      },
    );

    test(
      'disconnect or dispose releases a pending response and prevents later calls',
      () async {
        final disconnectFake = _FakeTransport();
        final disconnectSession = _session(disconnectFake);
        addTearDown(() async {
          await disconnectSession.dispose();
          await disconnectFake.close();
        });
        expect((await disconnectSession.initialize()).isOk, isTrue);
        final disconnected = disconnectSession.transfer(_goldenPackage());
        await _until(() => disconnectFake.writes.isNotEmpty);
        disconnectFake.emitConnection(false);
        expect(
          (await disconnected).failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );

        final explicitFake = _FakeTransport();
        final explicitSession = _session(explicitFake);
        addTearDown(() async {
          await explicitSession.dispose();
          await explicitFake.close();
        });
        expect((await explicitSession.initialize()).isOk, isTrue);
        final explicitlyDisconnected = explicitSession.transfer(
          _goldenPackage(),
        );
        await _until(() => explicitFake.writes.isNotEmpty);
        expect((await explicitSession.disconnect()).isOk, isTrue);
        expect(
          (await explicitlyDisconnected).failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );

        final disposeFake = _FakeTransport();
        final disposeSession = _session(disposeFake);
        addTearDown(() async {
          await disposeSession.dispose();
          await disposeFake.close();
        });
        expect((await disposeSession.initialize()).isOk, isTrue);
        final pending = disposeSession.transfer(_goldenPackage());
        await _until(() => disposeFake.writes.isNotEmpty);
        await disposeSession.dispose();
        expect(
          (await pending).failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );
        expect(
          (await disposeSession.transfer(_goldenPackage())).failureOrNull?.code,
          BleFailureCode.connectionFailed,
        );
      },
    );
  });
}

RingOtaSession _session(_FakeTransport transport) => RingOtaSession(
  device: const BleScanDevice(deviceId: 'ota-ring'),
  transport: transport,
);

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (predicate()) return;
    await _flushEvents();
  }
  fail('Expected fake transport activity did not occur');
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

RingOtaPackage _goldenPackage() => _package(const [
  _PartitionSpec(0, 0x1FFF0000, [1, 2, 3, 4]),
  _PartitionSpec(0x11020000, 0x11020000, [5, 6, 7, 8]),
]);

RingOtaPackage _package(List<_PartitionSpec> partitions) {
  const product = [0x52, 0x69, 0x6E, 0x67, 0x32, 0, 0, 0];
  final tableEnd = 32 + partitions.length * 16;
  final totalSize = partitions.fold<int>(
    0,
    (sum, item) => sum + item.data.length,
  );
  final bytes = Uint8List(tableEnd + totalSize);
  bytes.setRange(0, 4, 'ROTA'.codeUnits);
  bytes[4] = 1;
  bytes[6] = partitions.length;
  _writeUint32(bytes, 8, 0x0103);
  _writeUint32(bytes, 12, totalSize);
  bytes.setRange(16, 24, product);
  var dataOffset = tableEnd;
  for (var index = 0; index < partitions.length; index++) {
    final part = partitions[index];
    final tableOffset = 32 + index * 16;
    _writeUint32(bytes, tableOffset, part.flashAddress);
    _writeUint32(bytes, tableOffset + 4, part.runAddress);
    _writeUint32(bytes, tableOffset + 8, part.data.length);
    _writeUint32(bytes, tableOffset + 12, _otaCrc16(part.data));
    bytes.setRange(dataOffset, dataOffset + part.data.length, part.data);
    dataOffset += part.data.length;
  }
  _writeUint32(
    bytes,
    28,
    _otaCrc16(bytes.take(28).followedBy(bytes.sublist(32, tableEnd))),
  );
  final result = const RingOtaPackageParser().parse(
    bytes,
    deviceInfo: RingOtaInfo.fromPayload(
      Uint8List.fromList([0x02, 0x01, 0, 0, ...product, 0x01, 1, 0, 0]),
    ),
    versionPolicy: RingOtaVersionPolicy.normalUpgrade,
  );
  expect(
    result.isOk,
    isTrue,
    reason: 'synthetic package must satisfy B3 parser gates',
  );
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

class _PartitionSpec {
  const _PartitionSpec(this.flashAddress, this.runAddress, this.data);

  final int flashAddress;
  final int runAddress;
  final List<int> data;
}

class _Write {
  _Write({
    required this.characteristicId,
    required Uint8List value,
    required this.withoutResponse,
  }) : value = Uint8List.fromList(value);

  final String characteristicId;
  final Uint8List value;
  final bool withoutResponse;
}

class _FakeTransport implements BleTransport {
  _FakeTransport({
    this.mtu = 240,
    this.mtuResult,
    this.mtuFuture,
    List<BleDiscoveredService>? services,
    this.subscribeResult,
    this.disconnectResult,
  }) : _services = services ?? _requiredGatt();

  final int mtu;
  final Result<int, BleFailure>? mtuResult;
  final Future<Result<int, BleFailure>>? mtuFuture;
  final List<BleDiscoveredService> _services;
  final Result<void, BleFailure>? subscribeResult;
  final Result<void, BleFailure>? disconnectResult;
  final connectionController = StreamController<bool>.broadcast();
  final valueController = StreamController<Uint8List>.broadcast();
  final calls = <String>[];
  final writes = <_Write>[];
  void Function(_Write write)? onWrite;

  @override
  Stream<BleScanDevice> get scanStream => const Stream.empty();

  @override
  Stream<BleAvailability> get availabilityStream => const Stream.empty();

  @override
  Stream<bool> connectionStream(String deviceId) {
    calls.add('connectionStream');
    return connectionController.stream;
  }

  @override
  Stream<Uint8List> valueStream(String deviceId, String characteristicId) {
    calls.add('valueStream');
    return valueController.stream;
  }

  @override
  Future<Result<void, BleFailure>> requestPermissions() async =>
      const Result.ok(null);

  @override
  Future<Result<BleAvailability, BleFailure>> getAvailability() async =>
      const Result.ok(BleAvailability.poweredOn);

  @override
  Future<Result<void, BleFailure>> startScan(BleScanOptions options) async =>
      const Result.ok(null);

  @override
  Future<Result<void, BleFailure>> stopScan() async => const Result.ok(null);

  @override
  Future<Result<void, BleFailure>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async => const Result.ok(null);

  @override
  Future<Result<void, BleFailure>> disconnect(String deviceId) async {
    calls.add('disconnect');
    return disconnectResult ?? const Result.ok(null);
  }

  @override
  Future<Result<int, BleFailure>> requestMtu(
    String deviceId,
    int expectedMtu,
  ) async {
    calls.add('requestMtu:$expectedMtu');
    if (mtuFuture case final future?) return future;
    return mtuResult ?? Result.ok(mtu);
  }

  @override
  Future<Result<List<BleDiscoveredService>, BleFailure>> discoverServices(
    String deviceId,
  ) async {
    calls.add('discoverServices');
    return Result.ok(_services);
  }

  @override
  Future<Result<void, BleFailure>> subscribeNotifications(
    String deviceId,
    String serviceId,
    String characteristicId,
  ) async {
    calls.add('subscribeNotifications');
    return subscribeResult ?? const Result.ok(null);
  }

  @override
  Future<Result<void, BleFailure>> write(
    String deviceId,
    String serviceId,
    String characteristicId,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    final write = _Write(
      characteristicId: characteristicId,
      value: value,
      withoutResponse: withoutResponse,
    );
    writes.add(write);
    onWrite?.call(write);
    return const Result.ok(null);
  }

  void respond(int responseCode) => respondRaw([0, responseCode]);

  void respondRaw(List<int> value) =>
      scheduleMicrotask(() => valueController.add(Uint8List.fromList(value)));

  void emitConnection(bool connected) => connectionController.add(connected);

  Future<void> close() async {
    await connectionController.close();
    await valueController.close();
  }

  @override
  void dispose() {}
}

List<BleDiscoveredService> _requiredGatt() => [
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
