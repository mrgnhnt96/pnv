/// Why a plaintext value looks like it should have been encrypted.
class PlaintextSuspicion {
  const PlaintextSuspicion(this.reason);

  final String reason;
}

/// The comment that says "yes, this one is meant to be readable".
///
/// Reuses the trailing-comment convention already used for `# int` type
/// declarations, so there is one place values are annotated, not two.
const plaintextMarker = 'plaintext';

/// Key names that almost always hold a secret.
final _riskyKey = RegExp(
  '(^|[-_.])'
  '(key|secret|token|password|passwd|pwd|credential|credentials|'
  'auth|apikey|private|cert|signature|salt)'
  r'([-_.]|$)',
  caseSensitive: false,
);

/// Names that match [_riskyKey] but are routinely public.
final _benignKey = RegExp(
  '(^|[-_.])'
  '(public[-_.]?key|key[-_.]?name|key[-_.]?id|auth[-_.]?url|'
  'auth[-_.]?domain|token[-_.]?url|token[-_.]?name)'
  r'([-_.]|$)',
  caseSensitive: false,
);

/// Values whose shape identifies them as a live credential regardless of the
/// key they sit under.
final _credentialShapes = <String, RegExp>{
  'an OpenAI-style API key': RegExp(r'^sk-[A-Za-z0-9_-]{16,}$'),
  'a GitHub token': RegExp(r'^(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}$'),
  'a GitHub fine-grained token': RegExp(r'^github_pat_[A-Za-z0-9_]{20,}$'),
  'an AWS access key id': RegExp(r'^(AKIA|ASIA)[0-9A-Z]{16}$'),
  'a Slack token': RegExp(r'^xox[baprs]-[A-Za-z0-9-]{10,}$'),
  'a Stripe key': RegExp(r'^(sk|rk)_(live|test)_[A-Za-z0-9]{16,}$'),
  'a Google API key': RegExp(r'^AIza[A-Za-z0-9_-]{35}$'),
  'a JWT': RegExp(r'^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'),
  'a private key block': RegExp('-----BEGIN [A-Z ]*PRIVATE KEY-----'),
  'a connection string with a password':
      RegExp(r'^[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@', caseSensitive: false),
};

/// Whether [value], sitting at [keyPath], looks like a secret left in the open.
///
/// The premise of this package is that the YAML is safe to publish, so this is
/// the check that premise never had. It errs toward speaking up: a false
/// positive costs one `# plaintext` comment, a false negative publishes a
/// live credential.
PlaintextSuspicion? suspectPlaintext({
  required String keyPath,
  required String value,
  String? comment,
}) {
  if (comment != null && comment.toLowerCase().contains(plaintextMarker)) {
    return null;
  }

  final trimmed = value.trim();

  if (trimmed.isEmpty) return null;

  for (final MapEntry(key: what, value: pattern) in _credentialShapes.entries) {
    if (pattern.hasMatch(trimmed)) {
      return PlaintextSuspicion('looks like $what');
    }
  }

  final leaf = keyPath.split('.').last;

  if (_riskyKey.hasMatch(leaf) && !_benignKey.hasMatch(leaf)) {
    // A name that promises a secret, holding something that could be one.
    // Short or obviously-placeholder values are left alone: "key: name" and
    // "password: changeme" are noise, not leaks.
    if (trimmed.length >= 8 && !_looksLikePlaceholder(trimmed)) {
      return PlaintextSuspicion(
        'the key is named "$leaf" but the value is not encrypted',
      );
    }
  }

  return null;
}

final _placeholders = {
  'changeme',
  'change-me',
  'replace',
  'replaceme',
  'replace-me',
  'placeholder',
  'todo',
  'unset',
  'none',
  'null',
  'example',
  'xxxxxxxx',
};

bool _looksLikePlaceholder(String value) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'[\s_]'), '');

  return _placeholders.contains(normalized) ||
      normalized.startsWith('<') ||
      normalized.startsWith(r'${') ||
      normalized.startsWith('your-') ||
      normalized.startsWith('my-');
}
