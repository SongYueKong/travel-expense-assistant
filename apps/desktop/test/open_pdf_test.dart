import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_assistant/open_pdf.dart';

void main() {
  test('Unicode and shell characters are passed as a literal file path',
      () async {
    final directory = await Directory.systemTemp.createTemp('open-pdf-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/${r"凭证 $ & ' [1].pdf"}');
    await file.writeAsString('test fixture');
    var calls = 0;
    await openPdfWithDefaultApp(file.path,
        launcher: (program, args, env) async {
      calls++;
      expect(program, endsWith(r'WindowsPowerShell\v1.0\powershell.exe'));
      expect(env['TRAVEL_ASSISTANT_OPEN_PDF'], file.absolute.path);
      expect(args.join(' '), isNot(contains(file.path)));
      expect(
          args,
          containsAll(
              ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden']));
      expect(args.last, contains(r'$env:TRAVEL_ASSISTANT_OPEN_PDF'));
      return ProcessResult(1, 0, '', '');
    });
    expect(calls, 1);
  });

  test('missing and non-PDF files do not start another application', () async {
    final directory = await Directory.systemTemp.createTemp('open-pdf-test-');
    addTearDown(() => directory.delete(recursive: true));
    var calls = 0;
    Future<ProcessResult> launch(
        String _, List<String> __, Map<String, String> ___) async {
      calls++;
      return ProcessResult(1, 0, '', '');
    }

    await expectLater(
        openPdfWithDefaultApp('${directory.path}/missing.pdf',
            launcher: launch),
        throwsA(isA<FileSystemException>()));
    final file = File('${directory.path}/not-pdf.exe');
    await file.writeAsString('fixture');
    await expectLater(openPdfWithDefaultApp(file.path, launcher: launch),
        throwsFormatException);
    expect(calls, 0);
  });

  test('association and process errors provide an actionable message',
      () async {
    final directory = await Directory.systemTemp.createTemp('open-pdf-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.pdf');
    await file.writeAsString('fixture');
    await expectLater(
        openPdfWithDefaultApp(file.path,
            launcher: (_, __, ___) async =>
                ProcessResult(1, 1, '', 'native error')),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('默认应用'))));
    await expectLater(
        openPdfWithDefaultApp(file.path,
            launcher: (_, __, ___) async =>
                throw const ProcessException('missing.exe', [])),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('默认应用'))));
  });
}
