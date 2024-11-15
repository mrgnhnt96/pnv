import 'pnv.dart' as secrets;

void main() async {
  secrets.main([
    'env',
    '-f',
    'tmp.key',
    '-i',
    'example/local.yaml',
  ]);
}
