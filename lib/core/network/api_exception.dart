import 'package:dio/dio.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  factory ApiException.from(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) {
      final body = error.response?.data;
      String? serverMessage;
      if (body is Map) {
        serverMessage =
            body['message']?.toString() ??
            body['detail']?.toString() ??
            body['title']?.toString();
      }
      const localized = <String, String>{
        'Email is already registered.': 'Email này đã được đăng ký.',
        'Display name must contain 1 to 80 characters.':
            'Tên hiển thị cần từ 1 đến 80 ký tự.',
        'A valid email address is required.': 'Vui lòng nhập email hợp lệ.',
        'Authentication is required.': 'Phiên đăng nhập đã hết hạn.',
        'Access is denied.': 'Bạn không có quyền thực hiện thao tác này.',
        'Too many requests. Try again later.':
            'Bạn thao tác quá nhanh. Vui lòng thử lại sau.',
        'Text must contain 1 to 4000 characters.':
            'Tin nhắn cần từ 1 đến 4.000 ký tự.',
      };
      return ApiException(
        localized[serverMessage] ??
            (error.response?.statusCode == 401
                ? 'Email hoặc mật khẩu không đúng, hoặc phiên đã hết hạn.'
                : null) ??
            serverMessage ??
            (error.response == null
                ? 'Không thể kết nối máy chủ. Kiểm tra mạng và thử lại.'
                : 'Yêu cầu không thành công. Vui lòng thử lại.'),
        statusCode: error.response?.statusCode,
      );
    }
    return const ApiException('Đã xảy ra lỗi. Vui lòng thử lại.');
  }

  @override
  String toString() => message;
}
