// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: lines_longer_than_80_chars, require_trailing_commas, cast_nullable_to_non_nullable, unnecessary_null_checks, strict_raw_type, duplicate_ignore, prefer_const_constructors

part of 'pnv_config.dart';

// **************************************************************************
// AutoequalGenerator
// **************************************************************************

extension _$PnvConfigAutoequal on PnvConfig {
  List<Object?> get _$props => [
        storage,
        flavors,
      ];
}

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PnvConfig _$PnvConfigFromJson(Map json) => PnvConfig(
      storage: json['storage'] as String,
      flavors: (json['flavors'] as Map?)?.map(
        (k, e) => MapEntry(
            k as String, (e as List<dynamic>).map((e) => e as String).toList()),
      ),
    );

Map<String, dynamic> _$PnvConfigToJson(PnvConfig instance) => <String, dynamic>{
      'storage': instance.storage,
      'flavors': instance.flavors,
    };
