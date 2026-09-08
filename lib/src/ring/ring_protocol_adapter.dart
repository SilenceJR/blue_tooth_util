import 'package:blue_tooth_util/src/common/ble_failure.dart';
import 'package:common/common.dart';

import '../core/ble_protocol_adapter.dart';
import '../core/ble_scan_device.dart';
import '../core/ble_transport.dart';
import 'ring_ble_session.dart';
import 'ring_models.dart';
import 'ring_protocol.dart';

/// 智能戒指协议适配器。
///
/// 通过设备名 `BS Ring 2` 或 Service UUID `0x56FF` 判断扫描结果，
/// 匹配后创建 [RingBleSession]。
class RingProtocolAdapter implements BleProtocolAdapter<RingBleSession> {
  const RingProtocolAdapter();

  @override
  /// 适配器标识，包含当前支持的协议版本。
  String get id => 'ring-v1.1.7';

  @override
  /// 判断扫描设备是否为智能戒指。
  ///
  /// [device] 为扫描结果，优先匹配名称，其次匹配广播 Service UUID。
  bool matches(BleScanDevice device) {
    final name = device.name ?? device.rawName ?? '';
    final advertisesService = device.services
        .map((service) => service.toLowerCase())
        .contains(RingProtocol.serviceUuid);
    final hasRingManufacturerData = RingAdvertisement.fromScanDevice(
      device,
    ).isOk;
    return name.startsWith(RingProtocol.deviceName) ||
        advertisesService ||
        hasRingManufacturerData;
  }

  /// 解析扫描结果中的智能戒指厂商数据。
  ///
  /// [device] 为扫描结果；成功时返回 MAC、固件版本、客户 id、机器 id、
  /// 绑定能力和绑定状态等结构化字段。
  Result<RingAdvertisement, BleFailure> parseAdvertisement(
    BleScanDevice device,
  ) {
    return RingAdvertisement.fromScanDevice(device);
  }

  @override
  /// 创建智能戒指会话。
  ///
  /// [device] 为匹配到的戒指设备；[transport] 为 BLE 传输层。
  RingBleSession createSession({
    required BleScanDevice device,
    required BleTransport transport,
  }) {
    return RingBleSession(device: device, transport: transport);
  }
}
