/// A failure caused by input, not by a bug.
///
/// These were `ArgumentError`s, which meant every call site had to catch a
/// subclass of `Error` — the thing you are meant to let crash — to report a
/// bad key or a missing file.
class PnvException implements Exception {
  const PnvException(this.message);

  final String message;

  @override
  String toString() => message;
}
