import 'dart:convert';

/// Canonical exchange fields; these three root keys belong to the local store.
Map<String, dynamic> publicResult(Map<String, dynamic> value) {
  final public = Map<String, dynamic>.from(value)
    ..remove('_localManual')
    ..remove('_snapshotPath')
    ..remove('_exportedDigest');
  return _canonical(public) as Map<String, dynamic>;
}

bool samePublicResult(Map<String, dynamic> a, Map<String, dynamic> b) =>
    jsonEncode(publicResult(a)) == jsonEncode(publicResult(b));

dynamic _canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) return [for (final item in value) _canonical(item)];
  return value;
}
