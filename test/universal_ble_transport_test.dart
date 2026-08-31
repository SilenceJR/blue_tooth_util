import 'dart:async';
import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:blue_tooth_util/src/core/universal_ble_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart' as universal;

void main() {
  late _FakeUniversalBlePlatform platform;
  late UniversalBleTransport transport;

  setUp(() {
    universal.UniversalBle.queueType = universal.QueueType.global;
    platform = _FakeUniversalBlePlatform();
    universal.UniversalBle.setInstance(platform);
    transport = UniversalBleTransport();
  });

  group('UniversalBleTransport scan', () {
    test('passes filtered parameters and maps advertisement data', () async {
      final result = await transport.startScan(
        const BleScanOptions(serviceIds: ['180d'], namePrefixes: ['Ring']),
      );

      expect(result.isOk, isTrue);
      expect(platform.lastScanFilter?.withServices, ['180d']);
      expect(platform.lastScanFilter?.withNamePrefix, ['Ring']);
      expect(
        platform.lastPlatformConfig?.android?.scanMode,
        universal.AndroidScanMode.lowLatency,
      );
      expect(platform.lastPlatformConfig?.android?.callbackType, [
        universal.AndroidScanCallbackType.allMatches,
      ]);
      expect(
        platform.lastPlatformConfig?.android?.requestLocationPermission,
        isFalse,
      );
      expect(platform.lastPlatformConfig?.web?.optionalServices, ['180d']);

      final deviceFuture = transport.scanStream.first;
      platform.updateScanResult(
        universal.BleDevice(
          deviceId: 'ring-1',
          name: ' Ring\u0000',
          rssi: -47,
          paired: true,
          isSystemDevice: false,
          timestamp: 1710000000123,
          services: const ['180d'],
          manufacturerDataList: [
            universal.ManufacturerData(0x1234, Uint8List.fromList([1, 2, 3])),
          ],
          serviceData: {
            '180f': Uint8List.fromList([4, 5]),
          },
        ),
      );

      final device = await deviceFuture;
      expect(device.deviceId, 'ring-1');
      expect(device.name, 'Ring');
      expect(device.rawName, ' Ring\u0000');
      expect(device.rssi, -47);
      expect(device.paired, isTrue);
      expect(device.isSystemDevice, isFalse);
      expect(device.timestamp, 1710000000123);
      expect(device.services, ['180d']);
      expect(device.manufacturerData, hasLength(1));
      expect(device.manufacturerData.single.companyId, 0x1234);
      expect(device.manufacturerData.single.payload, [1, 2, 3]);
      expect(device.serviceData[universal.BleUuidParser.string('180f')], [
        4,
        5,
      ]);
    });

    test('omits the scan filter for unfiltered scanning', () async {
      final result = await transport.startScan(
        const BleScanOptions(
          unfiltered: true,
          serviceIds: ['180d'],
          namePrefixes: ['Ring'],
        ),
      );

      expect(result.isOk, isTrue);
      expect(platform.lastScanFilter, isNull);
      expect(platform.lastPlatformConfig?.web?.optionalServices, ['180d']);
    });
  });

  group('UniversalBleTransport platform state', () {
    test(
      'requests permission without Android fine location and maps availability',
      () async {
        platform.availability = universal.AvailabilityState.poweredOn;

        final permissionResult = await transport.requestPermissions();
        final availabilityResult = await transport.getAvailability();
        final poweredOff = transport.availabilityStream.firstWhere(
          (state) => state == BleAvailability.poweredOff,
        );
        platform.updateAvailability(universal.AvailabilityState.poweredOff);

        expect(permissionResult.isOk, isTrue);
        expect(platform.lastPermissionWithAndroidFineLocation, isFalse);
        expect(availabilityResult.valueOrNull, BleAvailability.poweredOn);
        expect(await poweredOff, BleAvailability.poweredOff);
      },
    );

    test('requests 247 MTU and returns the negotiated value', () async {
      platform.mtuResult = 240;

      final result = await transport.requestMtu('ring-1', 247);

      expect(result.valueOrNull, 240);
      expect(platform.mtuRequests, [('ring-1', 247)]);
    });
  });

  group('UniversalBleTransport GATT', () {
    test('maps service and characteristic capabilities', () async {
      platform.discoveredServices = [
        universal.BleService('180d', [
          universal.BleCharacteristic('2a37', const [
            universal.CharacteristicProperty.read,
            universal.CharacteristicProperty.write,
            universal.CharacteristicProperty.writeWithoutResponse,
            universal.CharacteristicProperty.notify,
            universal.CharacteristicProperty.indicate,
          ], const []),
        ]),
      ];

      final result = await transport.discoverServices('ring-1');

      final service = result.valueOrNull?.single;
      final characteristic = service?.characteristics.single;
      expect(service?.uuid, universal.BleUuidParser.string('180d'));
      expect(characteristic?.uuid, universal.BleUuidParser.string('2a37'));
      expect(characteristic?.canRead, isTrue);
      expect(characteristic?.canWrite, isTrue);
      expect(characteristic?.canWriteWithoutResponse, isTrue);
      expect(characteristic?.canNotify, isTrue);
      expect(characteristic?.canIndicate, isTrue);
    });

    test(
      'forwards notification values and subscribes through the platform',
      () async {
        final valueFuture = transport.valueStream('ring-1', '2a37').first;

        final result = await transport.subscribeNotifications(
          'ring-1',
          '180d',
          '2a37',
        );
        platform.updateCharacteristicValue(
          'ring-1',
          '2a37',
          Uint8List.fromList([6, 7, 8]),
          null,
        );

        expect(result.isOk, isTrue);
        expect(platform.notifiableRequests, [
          (
            'ring-1',
            universal.BleUuidParser.string('180d'),
            universal.BleUuidParser.string('2a37'),
            universal.BleInputProperty.notification,
          ),
        ]);
        expect(await valueFuture, [6, 7, 8]);
      },
    );

    test(
      'uses requested write type and waits before starting the next write',
      () async {
        final withResponse = await transport.write(
          'ring-1',
          '180d',
          '2a37',
          Uint8List.fromList([1]),
        );
        final withoutResponse = await transport.write(
          'ring-1',
          '180d',
          '2a37',
          Uint8List.fromList([2]),
          withoutResponse: true,
        );

        expect(withResponse.isOk, isTrue);
        expect(withoutResponse.isOk, isTrue);
        expect(
          platform.writeRequests.map((request) => request.outputProperty),
          [
            universal.BleOutputProperty.withResponse,
            universal.BleOutputProperty.withoutResponse,
          ],
        );

        platform.blockFirstWrite();
        final first = transport.write(
          'ring-1',
          '180d',
          '2a37',
          Uint8List.fromList([3]),
        );
        await platform.firstWriteStarted.future;
        final second = transport.write(
          'ring-1',
          '180d',
          '2a37',
          Uint8List.fromList([4]),
        );

        await Future<void>.delayed(Duration.zero);
        expect(platform.writeRequests.map((request) => request.value), [
          [1],
          [2],
          [3],
        ]);

        platform.releaseFirstWrite();
        expect((await first).isOk, isTrue);
        expect((await second).isOk, isTrue);
        expect(platform.writeRequests.last.value, [4]);
      },
    );
  });

  test('disconnects through the injected platform', () async {
    final result = await transport.disconnect('ring-1');

    expect(result.isOk, isTrue);
    expect(platform.disconnectRequests, ['ring-1']);
  });
}

class _FakeUniversalBlePlatform extends universal.UniversalBlePlatform {
  universal.AvailabilityState availability =
      universal.AvailabilityState.unknown;
  universal.ScanFilter? lastScanFilter;
  universal.PlatformConfig? lastPlatformConfig;
  bool? lastPermissionWithAndroidFineLocation;
  int mtuResult = 23;
  List<universal.BleService> discoveredServices = const [];
  final mtuRequests = <(String deviceId, int expectedMtu)>[];
  final notifiableRequests =
      <
        (
          String deviceId,
          String serviceId,
          String characteristicId,
          universal.BleInputProperty inputProperty,
        )
      >[];
  final writeRequests = <_WriteRequest>[];
  final disconnectRequests = <String>[];
  final firstWriteStarted = Completer<void>();
  Completer<void>? _firstWriteRelease;

  @override
  Future<universal.AvailabilityState> getBluetoothAvailabilityState() async {
    return availability;
  }

  @override
  Future<void> requestPermissions({
    bool withAndroidFineLocation = false,
  }) async {
    lastPermissionWithAndroidFineLocation = withAndroidFineLocation;
  }

  @override
  Future<void> startScan({
    universal.ScanFilter? scanFilter,
    universal.PlatformConfig? platformConfig,
  }) async {
    lastScanFilter = scanFilter;
    lastPlatformConfig = platformConfig;
  }

  @override
  Future<List<universal.BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async {
    return discoveredServices;
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    universal.BleInputProperty bleInputProperty,
  ) async {
    notifiableRequests.add((
      deviceId,
      service,
      characteristic,
      bleInputProperty,
    ));
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    universal.BleOutputProperty bleOutputProperty,
  ) async {
    writeRequests.add(
      _WriteRequest(
        deviceId: deviceId,
        serviceId: service,
        characteristicId: characteristic,
        value: Uint8List.fromList(value),
        outputProperty: bleOutputProperty,
      ),
    );
    if (_firstWriteRelease != null && writeRequests.length == 3) {
      firstWriteStarted.complete();
      await _firstWriteRelease!.future;
    }
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    mtuRequests.add((deviceId, expectedMtu));
    return mtuResult;
  }

  @override
  Future<universal.BleConnectionState> getConnectionState(
    String deviceId,
  ) async {
    return universal.BleConnectionState.disconnected;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectRequests.add(deviceId);
  }

  void blockFirstWrite() {
    _firstWriteRelease = Completer<void>();
  }

  void releaseFirstWrite() {
    _firstWriteRelease!.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WriteRequest {
  const _WriteRequest({
    required this.deviceId,
    required this.serviceId,
    required this.characteristicId,
    required this.value,
    required this.outputProperty,
  });

  final String deviceId;
  final String serviceId;
  final String characteristicId;
  final Uint8List value;
  final universal.BleOutputProperty outputProperty;
}
