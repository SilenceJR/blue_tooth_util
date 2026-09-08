import 'dart:typed_data';
import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = RingFrameCodec();
  group('v1.2 golden frames', () {
    test('进入，目标 33，序号 5 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [
        0x01,
        0x21,
        0x00,
        0x05,
        0x00,
      ]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 05 00 01 21 00 05 00 AA F9 B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('进入，老格式无序号 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [
        0x01,
        0x21,
        0x00,
      ]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 03 00 01 21 00 17 DD B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('退出 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [0x00]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 01 00 00 77 AC B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('查询 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [0x02]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 01 00 02 F6 6D B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('进入/退出的成功应答 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [0x01]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 01 00 01 B6 6C B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('查询应答：模式中 5/33 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [
        0x01,
        0x05,
        0x00,
        0x21,
        0x00,
        0x05,
        0x00,
        0x7C,
        0xB2,
        0x9F,
        0x6A,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 0F 00 01 05 00 21 00 05 00 7C B2 9F 6A 00 00 00 00 BA CC B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('查询应答：已完成 33/33 未清 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [
        0x00,
        0x21,
        0x00,
        0x21,
        0x00,
        0x05,
        0x00,
        0x7C,
        0xB2,
        0x9F,
        0x6A,
        0xDB,
        0xB2,
        0x9F,
        0x6A,
      ]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 0F 00 00 21 00 21 00 05 00 7C B2 9F 6A DB B2 9F 6A 2C F4 B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('查询应答：op=0 后 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrMode, [
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      expect(
        bytesToHex(encoded),
        '89 56 11 01 01 00 01 00 0F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 82 79 B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('上报：进度 5/33 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrReport, [
        0x01,
        0x05,
        0x00,
        0x21,
        0x00,
        0x05,
        0x00,
        0x7C,
        0xB2,
        0x9F,
        0x6A,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      expect(
        bytesToHex(encoded),
        '89 56 07 03 01 00 01 00 0F 00 01 05 00 21 00 05 00 7C B2 9F 6A 00 00 00 00 7F 93 B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
    test('上报：达标 33/33 (codec only)', () {
      final encoded = codec.encode(RingCommand.customZikrReport, [
        0x02,
        0x21,
        0x00,
        0x21,
        0x00,
        0x05,
        0x00,
        0x7C,
        0xB2,
        0x9F,
        0x6A,
        0xDB,
        0xB2,
        0x9F,
        0x6A,
      ]);
      expect(
        bytesToHex(encoded),
        '89 56 07 03 01 00 01 00 0F 00 02 21 00 21 00 05 00 7C B2 9F 6A DB B2 9F 6A 6B AA B5 3A',
      );
      expect(codec.decode(encoded).isOk, isTrue);
    });
  });
  test('timestamps and task ID preserve unsigned bounds and JSON', () {
    for (final taskId in [0, 65535]) {
      for (final timestamp in [0, 0xffffffff]) {
        final state = RingCustomZikrState(
          active: false,
          count: 9999,
          target: 9999,
          taskId: taskId,
          firstPressUnix: timestamp,
          doneUnix: timestamp,
        );
        final decoded = RingCustomZikrState.fromPayload(state.toPayload());
        expect(decoded.sameTaskResult(state), isTrue);
        expect(decoded.toJson()['taskId'], taskId);
        final event = RingCustomZikrEvent.fromPayload(
          state.toPayload()..[0] = 2,
        );
        expect(event.toState().sameTaskResult(state), isTrue);
        expect(event.toJson()['firstPressUnix'], timestamp);
        expect(event.toJson()['doneUnix'], timestamp);
      }
    }
  });
  test('rejects old and malformed payload lengths', () {
    for (final length in [0, 5, 14, 16]) {
      expect(
        () => RingCustomZikrState.fromPayload(Uint8List(length)),
        throwsFormatException,
      );
      expect(
        () => RingCustomZikrEvent.fromPayload(Uint8List(length)),
        throwsFormatException,
      );
    }
  });
  test('rejects nonzero cleared metadata and completion time while active', () {
    for (final offset in [0, 5, 7, 11]) {
      final payload = Uint8List(15)..[offset] = 3;
      expect(
        () => RingCustomZikrState.fromPayload(payload),
        throwsFormatException,
      );
    }
    final active = Uint8List(15)
      ..[0] = 1
      ..[3] = 33
      ..[11] = 1;
    expect(
      () => RingCustomZikrState.fromPayload(active),
      throwsFormatException,
    );
  });
}
