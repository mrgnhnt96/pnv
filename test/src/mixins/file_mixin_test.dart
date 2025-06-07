import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pnv/src/mixins/file_mixin.dart';
import 'package:test/test.dart';

void main() {
  group(FileMixin, () {
    late _Test instance;
    late Logger logger;
    late FileSystem fs;

    setUp(() {
      logger = _MockLogger();
      fs = MemoryFileSystem.test();
      instance = _Test(logger: logger, fs: fs);
    });

    group('getValueType', () {
      test('should infer the type from the value as num', () {
        expect(instance.getValueType('123'), ValueType.num);
      });

      test('should infer the type from the value as string', () {
        expect(instance.getValueType('hello'), ValueType.string);
      });

      test('should infer the type from the value as bool (true)', () {
        expect(instance.getValueType('true'), ValueType.bool);
      });

      test('should infer the type from the value as bool (false)', () {
        expect(instance.getValueType('false'), ValueType.bool);
      });

      test('should return the type of the value when declared', () {
        expect(instance.getValueType('123 #num'), ValueType.num);
        expect(instance.getValueType('123 #NUM'), ValueType.num);
      });

      test(
          'should return the type when the value is missing but declared (num)',
          () {
        expect(instance.getValueType(' #num'), ValueType.num);
        expect(instance.getValueType(' #NUM'), ValueType.num);
      });

      test(
          'should return the type when the value is '
          'missing but declared (string)', () {
        expect(instance.getValueType(' #string'), ValueType.string);
        expect(instance.getValueType(' #STRING'), ValueType.string);
      });

      test(
          'should return the type when the value is '
          'missing but declared (bool)', () {
        expect(instance.getValueType(' #bool'), ValueType.bool);
        expect(instance.getValueType(' #BOOL'), ValueType.bool);
      });
    });
  });
}

class _Test with FileMixin {
  _Test({
    required this.logger,
    required this.fs,
  });

  @override
  final Logger logger;
  @override
  final FileSystem fs;

  @override
  String decrypt(String value, List<int> keyHash) {
    return value;
  }

  @override
  String? input;
}

class _MockLogger extends Mock implements Logger {}
