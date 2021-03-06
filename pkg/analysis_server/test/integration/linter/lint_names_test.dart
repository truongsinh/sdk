// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/scanner/reader.dart';
import 'package:analyzer/src/dart/scanner/scanner.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/lint/linter.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:analyzer/src/string_source.dart';
import 'package:linter/src/rules.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

main() {
  // Set prefix for local or bot execution.
  final pathPrefix =
      FileSystemEntity.isDirectorySync(path.join('test', 'integration'))
          ? ''
          : path.join('pkg', 'analysis_server');

  /// Ensure server lint name representations correspond w/ actual lint rules.
  /// See, e.g., https://dart-review.googlesource.com/c/sdk/+/95743.
  group('lint_names', () {
    var fixFileContents = new File(path.join(pathPrefix, 'lib', 'src',
            'services', 'correction', 'fix_internal.dart'))
        .readAsStringSync();
    var parser = new CompilationUnitParser();
    var cu = parser.parse(contents: fixFileContents, name: 'fix_internal.dart');
    var lintNamesClass = cu.declarations
        .firstWhere((m) => m is ClassDeclaration && m.name.name == 'LintNames');

    var collector = new _FixCollector();
    lintNamesClass.accept(collector);
    for (var name in collector.lintNames) {
      test(name, () {
        expect(registeredLintNames, contains(name));
      });
    }
  });
}

List<LintRule> _registeredLints;

Iterable<String> get registeredLintNames => registeredLints.map((r) => r.name);

List<LintRule> get registeredLints {
  if (_registeredLints == null) {
    if (Registry.ruleRegistry.isEmpty) {
      registerLintRules();
    }
    _registeredLints = Registry.ruleRegistry.toList();
  }
  return _registeredLints;
}

class CompilationUnitParser {
  CompilationUnit parse({@required String contents, @required String name}) {
    var reader = new CharSequenceReader(contents);
    var stringSource = new StringSource(contents, name);
    var errorListener = new _ErrorListener();
    var scanner = new Scanner(stringSource, reader, errorListener);
    var startToken = scanner.tokenize();
    errorListener.throwIfErrors();

    var parser = new Parser(stringSource, errorListener);
    var cu = parser.parseCompilationUnit(startToken);
    errorListener.throwIfErrors();

    return cu;
  }
}

class _ErrorListener implements AnalysisErrorListener {
  final errors = <AnalysisError>[];

  @override
  void onError(AnalysisError error) {
    errors.add(error);
  }

  void throwIfErrors() {
    if (errors.isNotEmpty) {
      throw new Exception(errors);
    }
  }
}

class _FixCollector extends GeneralizingAstVisitor<void> {
  final List<String> lintNames = <String>[];

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (var v in node.fields.variables) {
      lintNames.add(v.name.name);
    }
  }
}
