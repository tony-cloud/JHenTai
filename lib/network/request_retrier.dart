import 'package:dio/dio.dart';
import 'package:jhentai/setting/network_setting.dart';

enum RetryCategory { timeout, serverError, forbidden, none }

typedef RetryLogHook = void Function(
  DioException error,
  RetryCategory category,
  int attempt,
  int maxRetries,
);

Future<Response<T>> runWithNetworkRetry<T>({
  required Future<Response<T>> Function() send,
  RetryLogHook? onRetry,
}) async {
  final Map<RetryCategory, int> retryCounts = {
    RetryCategory.timeout: 0,
    RetryCategory.serverError: 0,
  };

  while (true) {
    try {
      return await send();
    } on DioException catch (error) {
      final RetryCategory category = _classifyRetry(error);
      final int maxRetries = _maxRetries(category);
      if (category == RetryCategory.forbidden || maxRetries == 0) {
        rethrow;
      }

      final int nextAttempt = (retryCounts[category] ?? 0) + 1;
      if (nextAttempt > maxRetries) {
        rethrow;
      }
      retryCounts[category] = nextAttempt;
      onRetry?.call(error, category, nextAttempt, maxRetries);
    }
  }
}

RetryCategory _classifyRetry(DioException error) {
  final int? status = error.response?.statusCode;

  if (status == 403) {
    return RetryCategory.forbidden;
  }
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      status == 408) {
    return RetryCategory.timeout;
  }
  if ((error.type == DioExceptionType.badResponse && status != null && status >= 500) ||
      error.type == DioExceptionType.connectionError) {
    return RetryCategory.serverError;
  }
  return RetryCategory.none;
}

int _maxRetries(RetryCategory category) {
  switch (category) {
    case RetryCategory.timeout:
      return networkSetting.timeoutRetryTimes.value;
    case RetryCategory.serverError:
      return networkSetting.serverErrorRetryTimes.value;
    case RetryCategory.forbidden:
    case RetryCategory.none:
      return 0;
  }
}

String retryCategoryLabel(RetryCategory category) {
  switch (category) {
    case RetryCategory.timeout:
      return 'timeout';
    case RetryCategory.serverError:
      return 'serverError';
    case RetryCategory.forbidden:
      return 'forbidden';
    case RetryCategory.none:
      return 'none';
  }
}
