import 'dart:async';
import 'dart:typed_data';

import 'package:common/common.dart';
import 'package:universal_ble/universal_ble.dart' as universal;

import '../common/ble_failure.dart';
import '../common/result.dart';
import 'ble_scan_device.dart';
import 'ble_transport.dart';

class UniversalBleTransport implements BleTransport {
  UniversalBleTransport();

  @override
  Stream<BleScanDevice> get scanStream =>
      universal.UniversalBle.scanStream.map(_mapDevice);

  @override
  Stream<BleAvailability> get availabilityStream =>
      universal.UniversalBle.availabilityStream.map(_mapAvailability);

  @override
  Stream<bool> connectionStream(String deviceId) {
    return universal.UniversalBle.connectionStream(deviceId);
  }

  @override
  Stream<Uint8List> valueStream(String deviceId, String characteristicId) {
    return universal.UniversalBle.characteristicValueStream(
      deviceId,
      characteristicId,
    );
  }

  @override
  Future<Result<void,BleFailure>> requestPermissions() async {
    try {
      await universal.UniversalBle.requestPermissions(
        withAndroidFineLocation: false,
      );
      return const Result.ok(null);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.permissionDenied,
          message: 'Bluetooth permission denied',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<BleAvailability,BleFailure>> getAvailability() async {
    try {
      final state =
          await universal.UniversalBle.getBluetoothAvailabilityState();
      return Result.ok(_mapAvailability(state));
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.bluetoothUnavailable,
          message: 'Unable to read Bluetooth availability',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void,BleFailure>> startScan(BleScanOptions options) async {
    try {
      await universal.UniversalBle.startScan(
        scanFilter: options.unfiltered
            ? null
            : universal.ScanFilter(
                withServices: options.serviceIds,
                withNamePrefix: options.namePrefixes,

              ),
        platformConfig: universal.PlatformConfig(
          android: universal.AndroidOptions(
            scanMode: universal.AndroidScanMode.lowLatency,
            callbackType: [universal.AndroidScanCallbackType.allMatches],
            requestLocationPermission: false,
          ),
          web: universal.WebOptions(optionalServices: options.serviceIds),
        ),
      );
      return const Result.ok(null);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.scanFailed,
          message: 'Unable to start BLE scan',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void,BleFailure>> stopScan() async {
    try {
      await universal.UniversalBle.stopScan();
      return const Result.ok(null);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.scanFailed,
          message: 'Unable to stop BLE scan',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void,BleFailure>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    try {
      await universal.UniversalBle.connect(
        deviceId,
        timeout: timeout,
        autoConnect: autoConnect,
      );
      return const Result.ok(null);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.connectionFailed,
          message: 'Unable to connect device',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void,BleFailure>> disconnect(String deviceId) async {
    try {
      await universal.UniversalBle.disconnect(deviceId);
      return const Result.ok(null);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.connectionFailed,
          message: 'Unable to disconnect device',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<int,BleFailure>> requestMtu(String deviceId, int expectedMtu) async {
    try {
      final mtu = await universal.UniversalBle.requestMtu(
        deviceId,
        expectedMtu,
      );
      return Result.ok(mtu);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.unsupported,
          message: 'Unable to request MTU',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<BleDiscoveredService>,BleFailure>> discoverServices(
    String deviceId,
  ) async {
    try {
      final services = await universal.UniversalBle.discoverServices(deviceId);
      return Result.ok(services.map(_mapService).toList());
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.serviceNotFound,
          message: 'Unable to discover services',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void,BleFailure>> subscribeNotifications(
    String deviceId,
    String serviceId,
    String characteristicId,
  ) async {
    try {
      await universal.UniversalBle.subscribeNotifications(
        deviceId,
        serviceId,
        characteristicId,
      );
      return const Result.ok(null);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.characteristicNotFound,
          message: 'Unable to subscribe notifications',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void,BleFailure>> write(
    String deviceId,
    String serviceId,
    String characteristicId,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    try {
      await universal.UniversalBle.write(
        deviceId,
        serviceId,
        characteristicId,
        value,
        withoutResponse: withoutResponse,
      );
      return const Result.ok(null);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.writeFailed,
          message: 'Unable to write BLE characteristic',
          cause: error,
        ),
      );
    }
  }

  @override
  void dispose() {}

  static BleScanDevice _mapDevice(universal.BleDevice device) {
    return BleScanDevice(
      deviceId: device.deviceId,
      name: device.name,
      rawName: device.rawName,
      rssi: device.rssi,
      paired: device.paired,
      isSystemDevice: device.isSystemDevice,
      timestamp: device.timestamp,
      services: device.services,
      manufacturerData: device.manufacturerDataList
          .map(
            (data) => BleManufacturerData(
              companyId: data.companyId,
              payload: data.payload,
            ),
          )
          .toList(),
      serviceData: device.serviceData,
    );
  }

  static BleDiscoveredService _mapService(universal.BleService service) {
    return BleDiscoveredService(
      uuid: service.uuid,
      characteristics: service.characteristics.map(_mapCharacteristic).toList(),
    );
  }

  static BleDiscoveredCharacteristic _mapCharacteristic(
    universal.BleCharacteristic characteristic,
  ) {
    return BleDiscoveredCharacteristic(
      uuid: characteristic.uuid,
      canRead: characteristic.properties.contains(
        universal.CharacteristicProperty.read,
      ),
      canWrite: characteristic.properties.contains(
        universal.CharacteristicProperty.write,
      ),
      canWriteWithoutResponse: characteristic.properties.contains(
        universal.CharacteristicProperty.writeWithoutResponse,
      ),
      canNotify: characteristic.properties.contains(
        universal.CharacteristicProperty.notify,
      ),
      canIndicate: characteristic.properties.contains(
        universal.CharacteristicProperty.indicate,
      ),
    );
  }

  static BleAvailability _mapAvailability(universal.AvailabilityState state) {
    return switch (state) {
      universal.AvailabilityState.poweredOn => BleAvailability.poweredOn,
      universal.AvailabilityState.poweredOff => BleAvailability.poweredOff,
      universal.AvailabilityState.unauthorized => BleAvailability.unauthorized,
      universal.AvailabilityState.unsupported => BleAvailability.unsupported,
      universal.AvailabilityState.unknown => BleAvailability.unknown,
      universal.AvailabilityState.resetting => BleAvailability.unknown,
    };
  }
}
