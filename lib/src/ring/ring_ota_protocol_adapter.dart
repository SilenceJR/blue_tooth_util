import '../core/ble_protocol_adapter.dart';
import '../core/ble_scan_device.dart';
import '../core/ble_transport.dart';
import 'ring_models.dart';
import 'ring_ota_session.dart';

/// 绑定单个目标身份的戒指 OTA 模式协议适配器。
class RingOtaProtocolAdapter implements BleProtocolAdapter<RingOtaSession> {
  const RingOtaProtocolAdapter({required this.identity});

  /// 本次升级目标的业务/OTA MAC 关系。
  final RingDeviceIdentity identity;

  @override
  String get id => 'ring-ota-v1';

  @override
  bool matches(BleScanDevice device) => identity.matchesOtaDevice(device);

  @override
  RingOtaSession createSession({
    required BleScanDevice device,
    required BleTransport transport,
  }) {
    return RingOtaSession(device: device, transport: transport);
  }
}
