import 'dart:typed_data';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import 'ring_ota_package.dart';

/// 戒指 OTA Bootloader GATT 与协议常量。
class RingOtaProtocol {
  const RingOtaProtocol._();

  static const serviceUuid = '5833ff01-9b8b-5191-6142-22a4536ef123';
  static const commandCharacteristicUuid =
      '5833ff02-9b8b-5191-6142-22a4536ef123';
  static const responseCharacteristicUuid =
      '5833ff03-9b8b-5191-6142-22a4536ef123';
  static const dataCharacteristicUuid = '5833ff04-9b8b-5191-6142-22a4536ef123';

  static const requestedMtu = 247;
  static const maximumMtu = 240;
  static const defaultBurstSize = 8;

  static const responseStart = 0x81;
  static const responseOtaComplete = 0x83;
  static const responsePartitionInfo = 0x84;
  static const responsePartitionComplete = 0x85;
  static const responseBlockBurst = 0x87;
  static const responseReboot = 0x8A;

  /// 编码 START_OTA 控制命令。
  static Uint8List startCommand(int partitionCount, int burstSize) =>
      Uint8List.fromList([0x01, partitionCount, burstSize]);

  /// 编码 PARTITION_INFO 控制命令，字段保持包内原始值与小端顺序。
  static Uint8List partitionInfoCommand(RingOtaPartition partition) {
    final bytes = Uint8List(18);
    bytes[0] = 0x02;
    bytes[1] = partition.index;
    _writeUint32(bytes, 2, partition.flashAddress);
    _writeUint32(bytes, 6, partition.runAddress);
    _writeUint32(bytes, 10, partition.size);
    _writeUint32(bytes, 14, partition.checksum);
    return bytes;
  }

  /// 编码延迟重启命令；设备确认后由 App 主动断开链路。
  static Uint8List delayedRebootCommand() => Uint8List.fromList([0x04, 0x01]);

  /// 解析明文 OTA 常规应答。
  static Result<RingOtaResponse, BleFailure> parseResponse(Uint8List value) {
    if (value.length == 1) {
      if (value[0] == 0) {
        return _protocolFailure('OTA single-byte success response is invalid');
      }
      return _deviceFailure(value[0]);
    }
    if (value.length != 2) {
      return Result.err(
        BleFailure(
          code: value.length > 2
              ? BleFailureCode.unsupported
              : BleFailureCode.protocolError,
          message: 'Unsupported OTA response length: ${value.length}',
        ),
      );
    }
    final errorCode = value[0];
    final responseCode = value[1];
    if (errorCode != 0) return _deviceFailure(errorCode, responseCode);
    if (!const {
      responseStart,
      responseOtaComplete,
      responsePartitionInfo,
      responsePartitionComplete,
      responseBlockBurst,
      responseReboot,
    }.contains(responseCode)) {
      return _protocolFailure(
        'Unknown OTA response code: 0x${responseCode.toRadixString(16)}',
      );
    }
    return Result.ok(RingOtaResponse(responseCode));
  }

  static Result<RingOtaResponse, BleFailure> _deviceFailure(
    int errorCode, [
    int? responseCode,
  ]) {
    final error = RingOtaDeviceError.fromCode(errorCode);
    return Result.err(
      BleFailure(
        code: BleFailureCode.deviceError,
        message:
            error?.message ??
            'OTA device error 0x${errorCode.toRadixString(16)}',
        cause: RingOtaDeviceFailure(
          errorCode: errorCode,
          responseCode: responseCode,
          error: error,
        ),
      ),
    );
  }

  static Result<RingOtaResponse, BleFailure> _protocolFailure(String message) {
    return Result.err(
      BleFailure(code: BleFailureCode.protocolError, message: message),
    );
  }

  static void _writeUint32(Uint8List bytes, int offset, int value) {
    bytes[offset] = value & 0xFF;
    bytes[offset + 1] = (value >> 8) & 0xFF;
    bytes[offset + 2] = (value >> 16) & 0xFF;
    bytes[offset + 3] = (value >> 24) & 0xFF;
  }
}

/// OTA Bootloader 常规成功应答。
class RingOtaResponse {
  const RingOtaResponse(this.code);

  /// 应答码，例如 `0x81` START_OTA 或 `0x83` OTA_COMPLETE。
  final int code;
}

/// OTA Bootloader 设备错误。
enum RingOtaDeviceError {
  notSupported(0x05, 'OTA command is not supported'),
  invalidParameter(0x06, 'OTA partition parameter is invalid'),
  dataAlignment(0x0C, 'OTA erase alignment is invalid'),
  invalidAddress(0x10, 'OTA address is invalid'),
  spiFlash(0x17, 'OTA flash write failed'),
  invalidState(0x64, 'OTA state is invalid'),
  dataSize(0x65, 'OTA partition data exceeds its declared size'),
  crc(0x66, 'OTA partition CRC mismatch'),
  badData(0x68, 'OTA data burst timed out'),
  crypto(0x6A, 'OTA encryption verification failed');

  const RingOtaDeviceError(this.code, this.message);

  final int code;
  final String message;

  static RingOtaDeviceError? fromCode(int code) {
    for (final error in values) {
      if (error.code == code) return error;
    }
    return null;
  }
}

/// 设备错误应答中的原始错误码和可选应答码。
class RingOtaDeviceFailure {
  const RingOtaDeviceFailure({
    required this.errorCode,
    required this.responseCode,
    required this.error,
  });

  final int errorCode;
  final int? responseCode;
  final RingOtaDeviceError? error;
}
