import 'package:pnv/src/crypto/plaintext_detector.dart';
import 'package:test/test.dart';

void main() {
  String? reasonFor(String keyPath, String value, {String? comment}) {
    return suspectPlaintext(
      keyPath: keyPath,
      value: value,
      comment: comment,
    )?.reason;
  }

  group('flags a value whose shape is a credential', () {
    const shapes = {
      'an OpenAI-style API key': 'sk-live-1234567890abcdefghij',
      'a GitHub token': 'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
      'an AWS access key id': 'AKIAIOSFODNN7EXAMPLE',
      'a Slack token': 'xoxb-1234567890-abcdefghij',
      'a JWT': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123def456',
      'a connection string with a password':
          'postgres://user:pa55word@db.example.com:5432/app',
    };

    for (final MapEntry(key: what, value: value) in shapes.entries) {
      test(what, () {
        // Under a key name that raises no suspicion of its own, so the shape
        // is doing all the work.
        expect(reasonFor('app.value', value), contains(what));
      });
    }

    test('a private key block', () {
      expect(
        reasonFor('app.blob', '-----BEGIN RSA PRIVATE KEY-----\nMIIE'),
        contains('private key'),
      );
    });
  });

  group('flags a plain value under a name that promises a secret', () {
    for (final key in const [
      'app.password',
      'db.api_key',
      'service.token',
      'x.client-secret',
      'y.credentials',
    ]) {
      test(key, () {
        expect(reasonFor(key, 'somethingreal123'), isNotNull);
      });
    }
  });

  group('stays quiet where it should', () {
    test('a name that is public by convention', () {
      expect(reasonFor('app.public-key', 'ssh-rsa AAAAB3Nz'), isNull);
      expect(reasonFor('app.key-name', 'primary-key-name'), isNull);
      expect(reasonFor('app.key_id', 'abcdef123456'), isNull);
      expect(reasonFor('auth.auth-url', 'https://auth.example.com'), isNull);
    });

    test('a name that promises nothing', () {
      expect(reasonFor('app.host', 'localhost'), isNull);
      expect(reasonFor('app.base-url', 'http://localhost:3000'), isNull);
      expect(reasonFor('app.port', '8080'), isNull);
    });

    test('an obvious placeholder', () {
      for (final value in const [
        'change-me',
        'replace-me',
        'placeholder',
        '<your-key-here>',
        r'${API_KEY}',
        'your-token-here',
      ]) {
        expect(reasonFor('app.password', value), isNull, reason: value);
      }
    });

    test('an empty value', () {
      expect(reasonFor('app.password', ''), isNull);
      expect(reasonFor('app.password', '   '), isNull);
    });

    test('a value too short to be a real secret', () {
      expect(reasonFor('app.password', 'abc'), isNull);
    });

    test('a value marked "# plaintext"', () {
      expect(
        reasonFor(
          'app.demo-token',
          'sk-live-1234567890abcdefghij',
          comment: 'plaintext -- a public demo key',
        ),
        isNull,
      );
    });

    test('the marker still wins over a name-based suspicion', () {
      expect(
        reasonFor('app.password', 'somethingreal123', comment: 'plaintext'),
        isNull,
      );
    });

    test('an unrelated comment does not suppress anything', () {
      expect(
        reasonFor('app.password', 'somethingreal123', comment: 'int'),
        isNotNull,
      );
    });
  });
}
