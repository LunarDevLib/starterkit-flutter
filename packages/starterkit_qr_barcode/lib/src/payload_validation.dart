import 'dart:convert';

/// Returns the original UTF-8 length for a permitted payload, otherwise null.
int? validQrPayloadLength(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit <= 0x1f || (unit >= 0x7f && unit <= 0x9f)) return null;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= units.length ||
          units[index + 1] < 0xdc00 ||
          units[index + 1] > 0xdfff) {
        return null;
      }
      index++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return null;
    }
  }
  try {
    return utf8.encode(value).length;
  } on Object {
    return null;
  }
}
