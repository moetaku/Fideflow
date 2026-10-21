import 'package:fideflow_domain/domain.dart';
import 'package:intl/intl.dart';

String compactCount(int count, {required String locale}) {
  if (locale.startsWith('en')) {
    return NumberFormat.compact(locale: locale).format(count);
  }
  for (final (threshold, format) in <(int, String Function(String))>[
    (100000000, UiMessages.hundredMillion),
    (10000, UiMessages.tenThousand),
  ]) {
    if (count >= threshold) {
      final value = count / threshold;
      return format(
        value.toStringAsFixed(value == value.truncateToDouble() ? 0 : 1),
      );
    }
  }
  return count.toString();
}
