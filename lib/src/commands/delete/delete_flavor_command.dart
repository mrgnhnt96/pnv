import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pnv/src/handlers/flavor_handler.dart';

class DeleteFlavorCommand extends Command<int> {
  DeleteFlavorCommand({
    required this.flavorHandler,
    required this.logger,
  }) {
    argParser
      ..addMultiOption(
        'name',
        abbr: 'n',
        help: 'The flavor to delete',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Force delete the flavor',
        negatable: false,
      );
  }

  final FlavorHandler flavorHandler;
  final Logger logger;

  @override
  String get description => 'Delete a flavor';

  @override
  String get name => 'flavor';

  bool get force => switch (argResults?['force']) {
        true => true,
        _ => false,
      };

  List<String> get flavorNames => switch (argResults?['name']) {
        final List<String> names when names.isNotEmpty => names,
        _ => [],
      };

  List<String> flavorsToDelete() {
    if (flavorNames.isNotEmpty) {
      return flavorNames;
    }

    final flavors = flavorHandler.flavors();

    final choices = logger.chooseAny(
      'Which flavor do you want to delete?',
      choices: flavors,
    );

    return choices;
  }

  @override
  Future<int> run() async {
    final flavors = flavorsToDelete();

    if (flavors.isEmpty) {
      logger.err('Aborting...');
      return 1;
    }

    for (final flavor in flavors) {
      if (!force) {
        final confirm = logger.confirm(
          'Are you sure you want to ${red.wrap('delete')} the flavor '
          '${cyan.wrap(flavor)}? '
          '${yellow.wrap('This action cannot be undone.')}',
        );

        if (!confirm) {
          logger.err('Aborting...');
          continue;
        }
      }

      final progress = logger.progress('Deleting flavor: ${cyan.wrap(flavor)}');
      flavorHandler.delete(flavor);
      progress.complete('Deleted flavor: ${cyan.wrap(flavor)}');
    }

    return 0;
  }
}
