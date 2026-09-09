import 'dart:io';

import 'package:app18_hko/services/city_timezones.dart';
import 'package:app18_hko/services/hko_csv_archive.dart';

/// Headless HKO CSV collector for GitHub Actions / manual runs.
///
/// Usage: dart run tool/collect_hko_data.dart [output_dir]
/// Default output: data/hko
Future<void> main(List<String> args) async {
  CityTimezones.ensureInitialized();

  final outDir = args.isNotEmpty ? args.first : 'data/hko';
  final root = Directory(outDir);
  final archive = HkoCsvArchive(rootDir: root);

  stdout.writeln('Collecting HKO data → ${root.path}');
  final result = await archive.collect();
  archive.close();

  stdout.writeln(
    'Obs rows added: ${result.obsRowsAdded}, '
    'forecast written: ${result.forecastWritten}, '
    'ModelTime: ${result.modelTime ?? "(unchanged)"}',
  );

  if (result.obsRowsAdded == 0 && !result.forecastWritten) {
    stdout.writeln('No changes');
  }
}
