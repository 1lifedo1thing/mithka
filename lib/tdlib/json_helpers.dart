//
//  json_helpers.dart
//
//  Typed accessors over the `Map<String, dynamic>` dictionaries TDLib produces.
//  `jsonDecode` yields num/String for numbers, so we normalize here. TDLib
//  serializes int64 fields (chat order, file sizes, …) as JSON **strings**; the
//  helpers parse those transparently — mirroring the Swift `JSON+Helpers`.
//

/// Convenience for an untyped TDLib JSON object.
typedef TdObject = Map<String, dynamic>;

extension TdJson on Map<String, dynamic> {
  /// The TDLib object type, e.g. "updateAuthorizationState".
  String? get type => this['@type'] as String?;

  String? str(String key) => this[key] as String?;

  int? integer(String key) => jsonInt(this[key]);

  /// TDLib serializes int64 as strings; parse those transparently.
  int? int64(String key) => jsonInt(this[key]);

  bool? boolean(String key) {
    final v = this[key];
    if (v is bool) return v;
    if (v is num) return v != 0;
    return null;
  }

  double? dbl(String key) => jsonDouble(this[key]);

  Map<String, dynamic>? obj(String key) {
    final v = this[key];
    return v is Map<String, dynamic> ? v : null;
  }

  List<Map<String, dynamic>>? objects(String key) {
    final v = this[key];
    if (v is! List) return null;
    return v.whereType<Map<String, dynamic>>().toList();
  }

  List<int>? int64Array(String key) {
    final v = this[key];
    if (v is! List) return null;
    return v.map(jsonInt).whereType<int>().toList();
  }
}

/// A JSON number, or a numeric string such as a TDLib int64, as an [int].
int? jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// A JSON number, or a numeric string, as a [double].
double? jsonDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
