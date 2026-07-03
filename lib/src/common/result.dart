import 'ble_failure.dart';

/// SDK 公开接口的统一返回类型。
///
/// 成功时返回 [Success]，失败时返回 [Failure]，调用方不需要通过异常判断业务结果。
sealed class Result<T> {
  const Result();

  /// 构造成功结果。
  ///
  /// [value] 为接口实际返回的数据；无返回值的接口使用 `null`。
  const factory Result.success(T value) = Success<T>;

  /// 构造失败结果。
  ///
  /// [failure] 包含错误码、错误说明和可选底层异常。
  const factory Result.failure(BleFailure failure) = Failure<T>;

  /// 当前结果是否为成功。
  bool get isSuccess => this is Success<T>;

  /// 当前结果是否为失败。
  bool get isFailure => this is Failure<T>;

  /// 成功时返回数据；失败时返回 `null`。
  T? get valueOrNull => switch (this) {
    Success<T>(:final value) => value,
    Failure<T>() => null,
  };

  /// 失败时返回错误信息；成功时返回 `null`。
  BleFailure? get failureOrNull => switch (this) {
    Success<T>() => null,
    Failure<T>(:final failure) => failure,
  };
}

/// 成功结果。
class Success<T> extends Result<T> {
  /// [value] 为成功返回的数据。
  const Success(this.value);

  /// 成功返回的数据。
  final T value;
}

/// 失败结果。
class Failure<T> extends Result<T> {
  /// [failure] 为失败详情。
  const Failure(this.failure);

  /// 失败详情。
  final BleFailure failure;
}
