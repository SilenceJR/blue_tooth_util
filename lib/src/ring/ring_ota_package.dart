import 'dart:collection';
import 'dart:typed_data';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import '../common/crc16.dart';
import 'ring_models.dart';
import 'ring_protocol.dart';

/// `.rota` 目标版本的使用意图。
enum RingOtaVersionPolicy {
  /// 普通升级，只接受严格高于设备当前版本的升级包。
  normalUpgrade,

  /// 用户明确进入恢复入口时，只接受与设备当前版本相同的安全重刷包。
  sameVersionRecovery,
}

/// `.rota` 中的一条分区记录及其数据。
class RingOtaPartition {
  RingOtaPartition._({
    required this.index,
    required this.flashAddress,
    required this.runAddress,
    required this.size,
    required this.checksum,
    required Uint8List data,
  }) : _data = Uint8List.fromList(data);

  /// 分区在包内的原始顺序，从 0 开始。
  final int index;

  /// Bootloader 使用的 Flash 地址或应用 bank 相对偏移。
  final int flashAddress;

  /// 固件运行地址。
  final int runAddress;

  /// 分区数据字节数。
  final int size;

  /// 分区数据 CRC16，来自表项低 16 位。
  final int checksum;

  final Uint8List _data;

  /// 分区数据的防御性副本。
  Uint8List get data => Uint8List.fromList(_data);
}

/// 已通过设备能力、结构、CRC、地址、产品和版本门禁的 `.rota v1` 包。
class RingOtaPackage {
  RingOtaPackage._({
    required this.firmwareVersion,
    required this.totalSize,
    required Uint8List productBytes,
    required this.product,
    required this.headerChecksum,
    required List<RingOtaPartition> partitions,
  }) : _productBytes = Uint8List.fromList(productBytes),
       partitions = UnmodifiableListView(partitions);

  /// 包内目标固件版本，编码与 `0x0402.fw_version` 相同。
  final int firmwareVersion;

  /// 全部分区数据总字节数。
  final int totalSize;

  final Uint8List _productBytes;

  /// 产品展示文本，仅移除尾部补零。
  final String product;

  /// 包头与分区表 CRC16。
  final int headerChecksum;

  /// 分区原始顺序，不允许调用方重排此列表。
  final UnmodifiableListView<RingOtaPartition> partitions;

  /// 固定 8 字节产品标识的防御性副本。
  Uint8List get productBytes => Uint8List.fromList(_productBytes);
}

/// `.rota v1` 解析器。
///
/// 解析必须同时提供 [deviceInfo] 和显式 [versionPolicy]，避免调用方在发送
/// `0x0401` 前遗漏安全能力、产品或版本门禁。
class RingOtaPackageParser {
  const RingOtaPackageParser();

  static const _headerSize = 32;
  static const _partitionEntrySize = 16;
  static const _maxPartitionCount = 32;
  static const _maxPartitionSize = 16384;
  static const _sramRunStart = 0x1FFF0000;
  static const _sramRunEnd = 0x1FFFF400;
  static const _sramFlashSize = 0xF000;
  static const _sramPhysicalBase = 0x11011000;
  static const _xipStart = 0x11020000;
  static const _xipEnd = 0x1103D000;

  /// 解析并验证明文 `.rota v1`。
  Result<RingOtaPackage, BleFailure> parse(
    Uint8List bytes, {
    required RingOtaInfo deviceInfo,
    required RingOtaVersionPolicy versionPolicy,
  }) {
    try {
      _validateDeviceCapabilities(deviceInfo);
      return Result.ok(_parse(bytes, deviceInfo, versionPolicy));
    } on _RingOtaValidationFailure catch (failure) {
      return Result.err(failure.failure);
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Unable to parse .rota package',
          cause: error,
        ),
      );
    }
  }

  RingOtaPackage _parse(
    Uint8List bytes,
    RingOtaInfo deviceInfo,
    RingOtaVersionPolicy versionPolicy,
  ) {
    if (bytes.length < _headerSize) {
      _reject('ROTA package is shorter than the 32-byte header');
    }
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'ROTA') {
      _reject('Invalid ROTA package magic');
    }
    if (ringReadUint16(bytes, 4) != 1) {
      _reject('Unsupported ROTA format version', unsupported: true);
    }
    final partitionCount = bytes[6];
    if (partitionCount == 0 || partitionCount > _maxPartitionCount) {
      _reject('ROTA partition count must be between 1 and 32');
    }
    if (bytes[7] != 0 || bytes.sublist(24, 28).any((value) => value != 0)) {
      _reject('ROTA reserved header bytes must be zero');
    }

    final firmwareVersion = ringReadUint32(bytes, 8);
    final totalSize = ringReadUint32(bytes, 12);
    final productBytes = Uint8List.fromList(bytes.sublist(16, 24));
    final tableEnd = _headerSize + partitionCount * _partitionEntrySize;
    if (bytes.length < tableEnd) {
      _reject('ROTA partition table is truncated');
    }
    if (bytes.length - tableEnd != totalSize) {
      _reject('ROTA file length does not match total_size');
    }

    final headerChecksumField = ringReadUint32(bytes, 28);
    if (headerChecksumField >> 16 != 0) {
      _reject('ROTA header checksum high 16 bits must be zero');
    }
    final headerChecksum = bleCrc16Modbus(
      bytes.take(28).followedBy(bytes.sublist(32, tableEnd)),
      seed: 0,
    );
    if (headerChecksum != headerChecksumField) {
      _reject('ROTA header or partition table CRC mismatch', crc: true);
    }

    final partitions = <RingOtaPartition>[];
    final physicalFlashRanges = <(int, int)>[];
    var dataOffset = tableEnd;
    var partitionSizeSum = 0;
    for (var index = 0; index < partitionCount; index++) {
      final entryOffset = _headerSize + index * _partitionEntrySize;
      final flashAddress = ringReadUint32(bytes, entryOffset);
      final runAddress = ringReadUint32(bytes, entryOffset + 4);
      final size = ringReadUint32(bytes, entryOffset + 8);
      final checksumField = ringReadUint32(bytes, entryOffset + 12);
      if (checksumField >> 16 != 0) {
        _reject('ROTA partition checksum high 16 bits must be zero');
      }
      if (size == 0 || size > _maxPartitionSize || size % 4 != 0) {
        _reject('ROTA partition size is invalid');
      }

      final physicalStart = _validateAddresses(
        flashAddress: flashAddress,
        runAddress: runAddress,
        size: size,
      );
      final physicalEnd = physicalStart + size;
      if (physicalFlashRanges.any(
        (range) => physicalStart < range.$2 && range.$1 < physicalEnd,
      )) {
        _reject('ROTA physical flash partitions overlap');
      }
      physicalFlashRanges.add((physicalStart, physicalEnd));

      if (size > bytes.length - dataOffset) {
        _reject('ROTA partition data is truncated');
      }
      final data = Uint8List.fromList(
        bytes.sublist(dataOffset, dataOffset + size),
      );
      final checksum = checksumField & 0xFFFF;
      if (bleCrc16Modbus(data, seed: 0) != checksum) {
        _reject('ROTA partition data CRC mismatch', crc: true);
      }
      partitions.add(
        RingOtaPartition._(
          index: index,
          flashAddress: flashAddress,
          runAddress: runAddress,
          size: size,
          checksum: checksum,
          data: data,
        ),
      );
      dataOffset += size;
      partitionSizeSum += size;
    }
    if (partitionSizeSum != totalSize || dataOffset != bytes.length) {
      _reject('ROTA partition sizes do not match total_size');
    }

    final product = _parseProduct(productBytes);
    if (!_bytesEqual(productBytes, deviceInfo.productBytes)) {
      _reject('ROTA product does not match the connected ring');
    }
    _validateVersion(
      target: firmwareVersion,
      current: deviceInfo.firmwareVersion,
      policy: versionPolicy,
    );

    return RingOtaPackage._(
      firmwareVersion: firmwareVersion,
      totalSize: totalSize,
      productBytes: productBytes,
      product: product,
      headerChecksum: headerChecksum,
      partitions: partitions,
    );
  }

  void _validateDeviceCapabilities(RingOtaInfo deviceInfo) {
    if (!deviceInfo.bootloaderPresent) {
      _reject(
        'The connected ring does not have an OTA Bootloader',
        unsupported: true,
      );
    }
    if (deviceInfo.requiresEncryption) {
      _reject(
        'The connected ring requires an encrypted OTA package',
        unsupported: true,
      );
    }
  }

  int _validateAddresses({
    required int flashAddress,
    required int runAddress,
    required int size,
  }) {
    if (flashAddress < 0x11000000) {
      if (flashAddress > _sramFlashSize - size ||
          runAddress < _sramRunStart ||
          runAddress > _sramRunEnd - size) {
        _reject('ROTA SRAM partition address is out of range');
      }
      return _sramPhysicalBase + flashAddress;
    }
    if (flashAddress != runAddress ||
        flashAddress < _xipStart ||
        flashAddress > _xipEnd - size) {
      _reject('ROTA XIP partition address is out of range');
    }
    return flashAddress;
  }

  String _parseProduct(Uint8List bytes) {
    final firstPadding = bytes.indexOf(0);
    final textLength = firstPadding < 0 ? bytes.length : firstPadding;
    if (textLength == 0) _reject('ROTA product must not be empty');
    if (firstPadding >= 0 &&
        bytes.skip(firstPadding).any((value) => value != 0)) {
      _reject('ROTA product contains data after zero padding');
    }
    if (bytes.take(textLength).any((value) => value < 0x20 || value > 0x7E)) {
      _reject('ROTA product must contain printable ASCII');
    }
    return String.fromCharCodes(bytes.take(textLength));
  }

  void _validateVersion({
    required int target,
    required int current,
    required RingOtaVersionPolicy policy,
  }) {
    final accepted = switch (policy) {
      RingOtaVersionPolicy.normalUpgrade => target > current,
      RingOtaVersionPolicy.sameVersionRecovery => target == current,
    };
    if (!accepted) {
      _reject('ROTA firmware version is not allowed by the selected policy');
    }
  }

  bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  Never _reject(String message, {bool crc = false, bool unsupported = false}) {
    throw _RingOtaValidationFailure(
      BleFailure(
        code: crc
            ? BleFailureCode.crcMismatch
            : unsupported
            ? BleFailureCode.unsupported
            : BleFailureCode.protocolError,
        message: message,
      ),
    );
  }
}

class _RingOtaValidationFailure implements Exception {
  const _RingOtaValidationFailure(this.failure);

  final BleFailure failure;
}
