import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'pnv_config.g.dart';

@JsonSerializable()
class PnvConfig extends Equatable {
  const PnvConfig({
    required this.storage,
    required this.flavors,
  });

  factory PnvConfig.fromJson(Map<String, dynamic> json) =>
      _$PnvConfigFromJson(json);

  final String storage;
  final Map<String, List<String>> flavors;

  Map<String, dynamic> toJson() => _$PnvConfigToJson(this);

  @override
  List<Object?> get props => _$props;

  void addFlavor(String newFlavor) {
    flavors[newFlavor] = [newFlavor];
  }
}
