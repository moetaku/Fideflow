import 'package:fideflow_domain/domain.dart';
import 'package:flutter/foundation.dart';

final class DetailLoader<T> extends ChangeNotifier {
  DetailLoader({required this.failureCode});
  final String failureCode;
  T? data;
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;

  Future<void> load(Future<T> Function() read, {bool reset = false}) async {
    if (_disposed) return;
    final generation = ++_generation;
    if (reset) data = null;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final value = await read();
      if (_disposed || generation != _generation) return;
      data = value;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e is AppError ? e.code : failureCode;
    }
    if (_disposed || generation != _generation) return;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
