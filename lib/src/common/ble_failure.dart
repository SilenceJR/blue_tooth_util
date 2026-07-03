/// BLE SDK 统一错误码。
enum BleFailureCode {
  /// 未分类错误。
  unknown,

  /// 蓝牙权限被拒绝或缺失。
  permissionDenied,

  /// 蓝牙不可用，例如系统关闭、设备不支持或状态未知。
  bluetoothUnavailable,

  /// 扫描启动或停止失败。
  scanFailed,

  /// 连接、断开或连接状态异常。
  connectionFailed,

  /// 未发现目标 GATT 服务。
  serviceNotFound,

  /// 未发现目标 GATT 特征值。
  characteristicNotFound,

  /// 写入特征值失败。
  writeFailed,

  /// 读取特征值失败。
  readFailed,

  /// 等待连接、响应或 DONE 超时。
  timeout,

  /// 协议解析、参数校验或状态流转错误。
  protocolError,

  /// 帧 CRC 校验失败。
  crcMismatch,

  /// 帧头、帧尾、长度或包序号非法。
  invalidFrame,

  /// 设备按协议返回错误帧。
  deviceError,

  /// 当前平台、设备或协议能力不支持。
  unsupported,

  /// 命令正在执行中，需要等待前一次完成。
  busy,
}

/// BLE SDK 失败详情。
class BleFailure {
  /// 创建失败详情。
  ///
  /// [code] 是稳定错误码；[message] 是可展示/可记录的说明；
  /// [cause] 保存底层异常或平台错误，便于调试。
  const BleFailure({required this.code, required this.message, this.cause});

  /// 稳定错误码，调用方可用于分支处理。
  final BleFailureCode code;

  /// 错误说明。
  final String message;

  /// 底层异常或平台错误，可为空。
  final Object? cause;

  @override
  String toString() => 'BleFailure($code, $message)';
}
