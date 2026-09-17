class LocalAppException implements Exception {
  final String message;
  final int? code;

  const LocalAppException(this.message, {this.code});

  @override
  String toString() => message;
}
