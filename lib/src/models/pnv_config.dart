import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'pnv_config.g.dart';

@JsonSerializable()
class PnvConfig extends Equatable {
  PnvConfig({
    required this.storage,
    Map<String, List<String>>? flavors,
  }) : flavors = flavors ?? {};

  factory PnvConfig.fromJson(Map<String, dynamic> json) {
    final config = _$PnvConfigFromJson(json);

    if (config.hasConflicts()) {
      throw ArgumentError(
        'Flavors have conflicts. Every flavor and extension '
        'must be unique.',
      );
    }

    return config;
  }

  bool hasConflicts() {
    final all = flavors.entries.expand((e) => [e.key, ...e.value]).toList();
    final unique = all.toSet();

    return all.length != unique.length;
  }

  final String storage;
  final Map<String, List<String>> flavors;

  Map<String, dynamic> toJson() => _$PnvConfigToJson(this);

  @override
  List<Object?> get props => _$props;

  void addFlavor(String newFlavor) {
    flavors[newFlavor] = [];
  }

  Set<String>? flavorsFor(String? flavor) {
    if (flavor == null) return null;

    if (flavors[flavor] case final List<String> extensions) {
      return {flavor, ...extensions};
    }

    for (final MapEntry(:key, value: extensions) in flavors.entries) {
      if (extensions.contains(flavor)) {
        return {key, ...extensions};
      }
    }

    return null;
  }
}
