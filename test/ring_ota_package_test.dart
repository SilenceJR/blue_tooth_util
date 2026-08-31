import 'dart:typed_data';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RingOtaPackageParser golden package', () {
    test('parses the 72-byte two-partition little-endian golden package', () {
      final bytes = Uint8List.fromList(_goldenPackageBytes);
      final result = _parse(bytes);
      final package = result.valueOrNull;

      expect(bytes, hasLength(72));
      expect(
        _otaCrc16(bytes.take(28).followedBy(bytes.sublist(32, 64))),
        0x3852,
      );
      expect(result.isOk, isTrue);
      expect(package?.firmwareVersion, 0x00010203);
      expect(package?.totalSize, 8);
      expect(package?.product, 'Ring2');
      expect(package?.headerChecksum, 0x3852);
      expect(package?.partitions.map((item) => item.index), [0, 1]);
      expect(package?.partitions.map((item) => item.flashAddress), [
        0,
        0x11020000,
      ]);
      expect(package?.partitions.map((item) => item.runAddress), [
        0x1FFF0000,
        0x11020000,
      ]);
      expect(package?.partitions.map((item) => item.checksum), [
        0x0FA1,
        0x3BE3,
      ]);
      expect(package?.partitions[0].data, [1, 2, 3, 4]);
      expect(package?.partitions[1].data, [5, 6, 7, 8]);
    });

    test('keeps parser input and public byte getters defensive', () {
      final bytes = _package();
      final package = _parse(bytes).valueOrNull!;

      bytes[16] = 0;
      bytes[64] = 0;
      final productBytes = package.productBytes;
      final data = package.partitions.first.data;
      productBytes[0] = 0;
      data[0] = 0;

      expect(package.productBytes, _ringProduct);
      expect(package.partitions.first.data, [1, 2, 3, 4]);
    });

    test('keeps business-frame and OTA CRC seeds distinct', () {
      final data = '123456789'.codeUnits;

      expect(RingFrameCodec.crc16Modbus(data), 0x4B37);
      expect(_otaCrc16(data), 0xBB3D);
    });
  });

  group('RingOtaPackageParser structure and CRC rejection', () {
    test('rejects short header, magic, format, count and reserved bytes', () {
      _expectRejected(Uint8List(31));

      final magic = _package()..[0] = 0;
      _expectRejected(magic);

      final format = _package();
      _writeUint16(format, 4, 2);
      _expectRejected(format, code: BleFailureCode.unsupported);

      final noPartitions = _package()..[6] = 0;
      _expectRejected(noPartitions);

      final tooManyPartitions = _package()..[6] = 33;
      _expectRejected(tooManyPartitions);

      final reserved = _package()..[24] = 1;
      _expectRejected(reserved);
    });

    test(
      'rejects truncated table/data, total length mismatches and unused data',
      () {
        _expectRejected(Uint8List.fromList(_package().sublist(0, 63)));
        _expectRejected(Uint8List.fromList(_package().sublist(0, 71)));

        final extra = Uint8List.fromList([..._package(), 0]);
        _expectRejected(extra);

        final unclaimedData = _package(trailingData: const [0, 0, 0, 0]);
        _expectRejected(unclaimedData);
      },
    );

    test('rejects high checksum bits and header or data CRC corruption', () {
      final headerHighBits = _package();
      _writeUint32(headerHighBits, 28, 0x00013852);
      _expectRejected(headerHighBits);

      final headerCrc = _package()..[28] ^= 1;
      _expectRejected(headerCrc, code: BleFailureCode.crcMismatch);

      final checksumHighBits = _package();
      _writeUint32(checksumHighBits, 44, 0x00010FA1);
      _refreshHeaderChecksum(checksumHighBits);
      _expectRejected(checksumHighBits);

      final partitionCrc = _package();
      _writeUint32(partitionCrc, 44, 0x0FA0);
      _refreshHeaderChecksum(partitionCrc);
      _expectRejected(partitionCrc, code: BleFailureCode.crcMismatch);
    });

    test('rejects zero, oversized and non-word-aligned partition sizes', () {
      for (final size in [0, 16385, 6]) {
        final bytes = _package();
        _writeUint32(bytes, 40, size);
        _refreshHeaderChecksum(bytes);
        _expectRejected(bytes);
      }
    });
  });

  group('RingOtaPackageParser address validation', () {
    test(
      'accepts SRAM and XIP edges but rejects boundary and near-u32 escapes',
      () {
        final sramEdge = _package(
          partitions: const [
            _PartitionSpec(
              flashAddress: 0xEFFC,
              runAddress: 0x1FFFF3FC,
              data: [1, 2, 3, 4],
            ),
          ],
        );
        final xipEdge = _package(
          partitions: const [
            _PartitionSpec(
              flashAddress: 0x1103CFFC,
              runAddress: 0x1103CFFC,
              data: [1, 2, 3, 4],
            ),
          ],
        );
        expect(_parse(sramEdge).isOk, isTrue);
        expect(_parse(xipEdge).isOk, isTrue);

        _expectRejected(
          _package(
            partitions: const [
              _PartitionSpec(
                flashAddress: 0xF000,
                runAddress: 0x1FFF0000,
                data: [1, 2, 3, 4],
              ),
            ],
          ),
        );
        _expectRejected(
          _package(
            partitions: const [
              _PartitionSpec(
                flashAddress: 0x1103D000,
                runAddress: 0x1103D000,
                data: [1, 2, 3, 4],
              ),
            ],
          ),
        );
        _expectRejected(
          _package(
            partitions: const [
              _PartitionSpec(
                flashAddress: 0,
                runAddress: 0x1FFFF400,
                data: [1, 2, 3, 4],
              ),
            ],
          ),
        );
        _expectRejected(
          _package(
            partitions: const [
              _PartitionSpec(
                flashAddress: 0xFFFFFFFC,
                runAddress: 0xFFFFFFFC,
                data: [1, 2, 3, 4],
              ),
            ],
          ),
        );
        _expectRejected(
          _package(
            partitions: const [
              _PartitionSpec(
                flashAddress: 0x11020000,
                runAddress: 0x11020004,
                data: [1, 2, 3, 4],
              ),
            ],
          ),
        );
      },
    );

    test('accepts physically adjacent partitions and rejects overlap', () {
      final adjacent = _package(
        partitions: const [
          _PartitionSpec(
            flashAddress: 0,
            runAddress: 0x1FFF0000,
            data: [1, 2, 3, 4],
          ),
          _PartitionSpec(
            flashAddress: 4,
            runAddress: 0x1FFF0004,
            data: [5, 6, 7, 8],
          ),
        ],
      );
      final overlapping = _package(
        partitions: const [
          _PartitionSpec(
            flashAddress: 0,
            runAddress: 0x1FFF0000,
            data: [1, 2, 3, 4],
          ),
          _PartitionSpec(
            flashAddress: 0,
            runAddress: 0x1FFF0004,
            data: [5, 6, 7, 8],
          ),
        ],
      );

      expect(_parse(adjacent).isOk, isTrue);
      _expectRejected(overlapping);
    });
  });

  group('RingOtaPackageParser device gates', () {
    test('requires exact padded printable product bytes', () {
      expect(_parse(_package()).isOk, isTrue);

      _expectRejected(
        _package(
          product: 'ring'.codeUnits.followedBy(List.filled(4, 0)).toList(),
        ),
      );
      _expectRejected(
        _package(product: [0x52, 0x49, 0x4E, 0x47, 0x20, 0, 0, 0]),
      );
      _expectRejected(
        _package(product: [0x52, 0x49, 0x4E, 0x47, 0, 0x20, 0, 0]),
      );
      _expectRejected(_package(product: [0x52, 0, 0x49, 0, 0, 0, 0, 0]));
      _expectRejected(_package(product: [0x80, 0, 0, 0, 0, 0, 0, 0]));
      _expectRejected(_package(product: List.filled(8, 0)));
    });

    test(
      'enforces normal upgrades, same-version recovery and lower-version rejection',
      () {
        final current = _deviceInfo(firmwareVersion: 0x00010202);

        expect(
          _parse(
            _package(firmwareVersion: 0x00010203),
            deviceInfo: current,
          ).isOk,
          isTrue,
        );
        _expectRejected(
          _package(firmwareVersion: 0x00010202),
          deviceInfo: current,
        );
        expect(
          _parse(
            _package(firmwareVersion: 0x00010202),
            deviceInfo: current,
            policy: RingOtaVersionPolicy.sameVersionRecovery,
          ).isOk,
          isTrue,
        );
        for (final policy in RingOtaVersionPolicy.values) {
          _expectRejected(
            _package(firmwareVersion: 0x00010201),
            deviceInfo: current,
            policy: policy,
          );
        }
      },
    );

    test(
      'rejects absent or encryption-required bootloaders before parsing',
      () {
        _expectRejected(
          _package(),
          deviceInfo: _deviceInfo(bootFlags: 0),
          code: BleFailureCode.unsupported,
        );
        _expectRejected(
          _package(),
          deviceInfo: _deviceInfo(bootFlags: 0x02),
          code: BleFailureCode.unsupported,
        );
      },
    );

    test(
      'product and version checks still apply with boot flags 0x04 or 0x08',
      () {
        _expectRejected(
          _package(
            product: 'ring'.codeUnits.followedBy(List.filled(4, 0)).toList(),
          ),
          deviceInfo: _deviceInfo(bootFlags: 0x05),
        );
        _expectRejected(
          _package(firmwareVersion: 0x00010201),
          deviceInfo: _deviceInfo(bootFlags: 0x09),
        );
      },
    );
  });
}

const _ringProduct = [0x52, 0x69, 0x6E, 0x67, 0x32, 0, 0, 0];

const _goldenPackageBytes = [
  0x52,
  0x4F,
  0x54,
  0x41,
  0x01,
  0x00,
  0x02,
  0x00,
  0x03,
  0x02,
  0x01,
  0x00,
  0x08,
  0x00,
  0x00,
  0x00,
  0x52,
  0x69,
  0x6E,
  0x67,
  0x32,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x52,
  0x38,
  0x00,
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
  0x01,
  0x02,
  0x03,
  0x04,
  0x05,
  0x06,
  0x07,
  0x08,
];

Result<RingOtaPackage, BleFailure> _parse(
  Uint8List bytes, {
  RingOtaInfo? deviceInfo,
  RingOtaVersionPolicy policy = RingOtaVersionPolicy.normalUpgrade,
}) {
  return const RingOtaPackageParser().parse(
    bytes,
    deviceInfo: deviceInfo ?? _deviceInfo(),
    versionPolicy: policy,
  );
}

void _expectRejected(
  Uint8List bytes, {
  RingOtaInfo? deviceInfo,
  RingOtaVersionPolicy policy = RingOtaVersionPolicy.normalUpgrade,
  BleFailureCode code = BleFailureCode.protocolError,
}) {
  final result = _parse(bytes, deviceInfo: deviceInfo, policy: policy);
  expect(result.isErr, isTrue);
  expect(result.failureOrNull?.code, code);
}

RingOtaInfo _deviceInfo({
  int firmwareVersion = 0x00010202,
  int bootFlags = 0x01,
}) {
  return RingOtaInfo.fromPayload(
    Uint8List.fromList([
      firmwareVersion & 0xFF,
      (firmwareVersion >> 8) & 0xFF,
      (firmwareVersion >> 16) & 0xFF,
      (firmwareVersion >> 24) & 0xFF,
      ..._ringProduct,
      bootFlags,
      1,
      0,
      0,
    ]),
  );
}

Uint8List _package({
  int firmwareVersion = 0x00010203,
  List<int> product = _ringProduct,
  List<_PartitionSpec> partitions = const [
    _PartitionSpec(flashAddress: 0, runAddress: 0x1FFF0000, data: [1, 2, 3, 4]),
    _PartitionSpec(
      flashAddress: 0x11020000,
      runAddress: 0x11020000,
      data: [5, 6, 7, 8],
    ),
  ],
  List<int> trailingData = const [],
}) {
  if (product.length != 8) throw ArgumentError.value(product, 'product');
  final tableEnd = 32 + partitions.length * 16;
  final dataSize = partitions.fold<int>(
    0,
    (sum, item) => sum + item.data.length,
  );
  final bytes = Uint8List(tableEnd + dataSize + trailingData.length);
  bytes.setRange(0, 4, 'ROTA'.codeUnits);
  _writeUint16(bytes, 4, 1);
  bytes[6] = partitions.length;
  _writeUint32(bytes, 8, firmwareVersion);
  _writeUint32(bytes, 12, dataSize + trailingData.length);
  bytes.setRange(16, 24, product);

  var dataOffset = tableEnd;
  for (var index = 0; index < partitions.length; index++) {
    final partition = partitions[index];
    final entryOffset = 32 + index * 16;
    _writeUint32(bytes, entryOffset, partition.flashAddress);
    _writeUint32(bytes, entryOffset + 4, partition.runAddress);
    _writeUint32(bytes, entryOffset + 8, partition.data.length);
    _writeUint32(bytes, entryOffset + 12, _otaCrc16(partition.data));
    bytes.setRange(
      dataOffset,
      dataOffset + partition.data.length,
      partition.data,
    );
    dataOffset += partition.data.length;
  }
  bytes.setRange(dataOffset, bytes.length, trailingData);
  _refreshHeaderChecksum(bytes);
  return bytes;
}

void _refreshHeaderChecksum(Uint8List bytes) {
  final tableEnd = 32 + bytes[6] * 16;
  final checksum = _otaCrc16(
    bytes.take(28).followedBy(bytes.sublist(32, tableEnd)),
  );
  _writeUint32(bytes, 28, checksum);
}

void _writeUint16(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xFF;
  bytes[offset + 1] = (value >> 8) & 0xFF;
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
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}

class _PartitionSpec {
  const _PartitionSpec({
    required this.flashAddress,
    required this.runAddress,
    required this.data,
  });

  final int flashAddress;
  final int runAddress;
  final List<int> data;
}
