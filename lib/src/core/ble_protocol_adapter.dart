import 'ble_scan_device.dart';
import 'ble_session.dart';
import 'ble_transport.dart';

/// BLE 协议适配器接口。
///
/// 每种设备或协议实现一个 adapter，用于判断扫描结果是否匹配并创建会话。
abstract class BleProtocolAdapter<T extends BleSession> {
  /// 协议适配器标识，例如 `ring-v1.1.5`。
  String get id;

  /// 判断扫描结果是否属于当前协议。
  ///
  /// [device] 为扫描结果，通常根据名称、Service UUID 或厂商数据判断。
  bool matches(BleScanDevice device);

  /// 创建协议会话。
  ///
  /// [device] 为已选设备；[transport] 为连接后继续使用的传输层。
  T createSession({
    required BleScanDevice device,
    required BleTransport transport,
  });
}
