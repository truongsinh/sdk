// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This library implements a kernel2kernel constant evaluation transformation.
///
/// Even though it is expected that the frontend does not emit kernel AST which
/// contains compile-time errors, this transformation still performs some
/// valiation and throws a [ConstantEvaluationError] if there was a compile-time
/// errors.
///
/// Due to the lack information which is is only available in the front-end,
/// this validation is incomplete (e.g. whether an integer literal used the
/// hexadecimal syntax or not).
///
/// Furthermore due to the lowering of certain constructs in the front-end
/// (e.g. '??') we need to support a super-set of the normal constant expression
/// language.  Issue(http://dartbug.com/31799)
library fasta.constant_evaluator;

import 'dart:core' hide MapEntry;

import 'dart:io' as io;

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/type_algebra.dart';
import 'package:kernel/type_environment.dart';

import 'package:kernel/target/targets.dart';

import '../fasta_codes.dart'
    show
        LocatedMessage,
        Message,
        messageConstEvalCircularity,
        messageConstEvalContext,
        messageConstEvalFailedAssertion,
        messageConstEvalNullValue,
        noLength,
        templateConstEvalDeferredLibrary,
        templateConstEvalDuplicateKey,
        templateConstEvalFailedAssertionWithMessage,
        templateConstEvalFreeTypeParameter,
        templateConstEvalInvalidType,
        templateConstEvalInvalidBinaryOperandType,
        templateConstEvalInvalidMethodInvocation,
        templateConstEvalInvalidPropertyGet,
        templateConstEvalInvalidStaticInvocation,
        templateConstEvalInvalidStringInterpolationOperand,
        templateConstEvalInvalidSymbolName,
        templateConstEvalNegativeShift,
        templateConstEvalNonConstantLiteral,
        templateConstEvalNonConstantVariableGet,
        templateConstEvalZeroDivisor;

Component transformComponent(Component component, ConstantsBackend backend,
    Map<String, String> environmentDefines, ErrorReporter errorReporter,
    {bool keepFields: true,
    bool enableAsserts: false,
    bool evaluateAnnotations: true,
    CoreTypes coreTypes,
    ClassHierarchy hierarchy}) {
  coreTypes ??= new CoreTypes(component);
  hierarchy ??= new ClassHierarchy(component);

  final typeEnvironment = new TypeEnvironment(coreTypes, hierarchy);

  transformLibraries(component.libraries, backend, environmentDefines,
      typeEnvironment, errorReporter,
      keepFields: keepFields,
      enableAsserts: enableAsserts,
      evaluateAnnotations: evaluateAnnotations);
  return component;
}

void transformLibraries(
    List<Library> libraries,
    ConstantsBackend backend,
    Map<String, String> environmentDefines,
    TypeEnvironment typeEnvironment,
    ErrorReporter errorReporter,
    {bool keepFields: true,
    bool keepVariables: false,
    bool evaluateAnnotations: true,
    bool enableAsserts: false}) {
  final ConstantsTransformer constantsTransformer = new ConstantsTransformer(
      backend,
      environmentDefines,
      keepFields,
      keepVariables,
      evaluateAnnotations,
      typeEnvironment,
      enableAsserts,
      errorReporter);
  for (final Library library in libraries) {
    constantsTransformer.convertLibrary(library);
  }
}

class ConstantsTransformer extends Transformer {
  final ConstantEvaluator constantEvaluator;
  final TypeEnvironment typeEnvironment;

  /// Whether to preserve constant [Field]s.  All use-sites will be rewritten.
  final bool keepFields;
  final bool keepVariables;
  final bool evaluateAnnotations;

  ConstantsTransformer(
      ConstantsBackend backend,
      Map<String, String> environmentDefines,
      this.keepFields,
      this.keepVariables,
      this.evaluateAnnotations,
      this.typeEnvironment,
      bool enableAsserts,
      ErrorReporter errorReporter)
      : constantEvaluator = new ConstantEvaluator(backend, environmentDefines,
            typeEnvironment, enableAsserts, errorReporter);

  // Transform the library/class members:

  void convertLibrary(Library library) {
    transformAnnotations(library.annotations, library);

    transformList(library.dependencies, this, library);
    transformList(library.parts, this, library);
    transformList(library.typedefs, this, library);
    transformList(library.classes, this, library);
    transformList(library.procedures, this, library);
    transformList(library.fields, this, library);

    if (!keepFields) {
      // The transformer API does not iterate over `Library.additionalExports`,
      // so we manually delete the references to shaken nodes.
      library.additionalExports.removeWhere((Reference reference) {
        return reference.node is Field && reference.canonicalName == null;
      });
    }
  }

  visitLibraryPart(LibraryPart node) {
    constantEvaluator.withNewEnvironment(() {
      transformAnnotations(node.annotations, node);
    });
    return node;
  }

  visitLibraryDependency(LibraryDependency node) {
    constantEvaluator.withNewEnvironment(() {
      transformAnnotations(node.annotations, node);
    });
    return node;
  }

  visitClass(Class node) {
    constantEvaluator.withNewEnvironment(() {
      transformAnnotations(node.annotations, node);
      transformList(node.fields, this, node);
      transformList(node.typeParameters, this, node);
      transformList(node.constructors, this, node);
      transformList(node.procedures, this, node);
      transformList(node.redirectingFactoryConstructors, this, node);
    });
    return node;
  }

  visitProcedure(Procedure node) {
    constantEvaluator.withNewEnvironment(() {
      transformAnnotations(node.annotations, node);
      node.function = node.function.accept(this)..parent = node;
    });
    return node;
  }

  visitConstructor(Constructor node) {
    constantEvaluator.withNewEnvironment(() {
      transformAnnotations(node.annotations, node);
      transformList(node.initializers, this, node);
      node.function = node.function.accept(this)..parent = node;
    });
    return node;
  }

  visitTypedef(Typedef node) {
    constantEvaluator.withNewEnvironment(() {
      transformAnnotations(node.annotations, node);
      transformList(node.typeParameters, this, node);
      transformList(node.typeParametersOfFunctionType, this, node);
      transformList(node.positionalParameters, this, node);
      transformList(node.namedParameters, this, node);
    });
    return node;
  }

  visitRedirectingFactoryConstructor(RedirectingFactoryConstructor node) {
    constantEvaluator.withNewEnvironment(() {
      transformAnnotations(node.annotations, node);
      transformList(node.typeParameters, this, node);
      transformList(node.positionalParameters, this, node);
      transformList(node.namedParameters, this, node);
    });
    return node;
  }

  visitTypeParameter(TypeParameter node) {
    transformAnnotations(node.annotations, node);
    return node;
  }

  void transformAnnotations(List<Expression> nodes, TreeNode parent) {
    if (evaluateAnnotations && nodes.length > 0) {
      transformExpressions(nodes, parent);
    }
  }

  void transformExpressions(List<Expression> nodes, TreeNode parent) {
    constantEvaluator.withNewEnvironment(() {
      for (int i = 0; i < nodes.length; ++i) {
        nodes[i] = tryEvaluateAndTransformWithContext(parent, nodes[i])
          ..parent = parent;
      }
    });
  }

  // Handle definition of constants:

  visitFunctionNode(FunctionNode node) {
    final positionalParameterCount = node.positionalParameters.length;
    for (int i = 0; i < positionalParameterCount; ++i) {
      final VariableDeclaration variable = node.positionalParameters[i];
      transformAnnotations(variable.annotations, variable);
      if (variable.initializer != null) {
        variable.initializer =
            tryEvaluateAndTransformWithContext(variable, variable.initializer)
              ..parent = variable;
      }
    }
    for (final VariableDeclaration variable in node.namedParameters) {
      transformAnnotations(variable.annotations, variable);
      if (variable.initializer != null) {
        variable.initializer =
            tryEvaluateAndTransformWithContext(variable, variable.initializer)
              ..parent = variable;
      }
    }
    if (node.body != null) {
      node.body = node.body.accept(this)..parent = node;
    }
    return node;
  }

  visitVariableDeclaration(VariableDeclaration node) {
    transformAnnotations(node.annotations, node);

    if (node.initializer != null) {
      if (node.isConst) {
        final Constant constant =
            tryEvaluateWithContext(node, node.initializer);

        // If there was a constant evaluation error we will not continue and
        // simply keep the old [node].
        if (constant != null) {
          constantEvaluator.env.addVariableValue(node, constant);

          if (keepVariables) {
            // So the value of the variable is still available for debugging
            // purposes we convert the constant variable to be a final variable
            // initialized to the evaluated constant expression.
            node.initializer = new ConstantExpression(constant)..parent = node;
            node.isFinal = true;
            node.isConst = false;
          } else {
            // Since we convert all use-sites of constants, the constant
            // [VariableDeclaration] is unused and we'll therefore remove it.
            return null;
          }
        }
      } else {
        node.initializer = node.initializer.accept(this)..parent = node;
      }
    }
    return node;
  }

  visitField(Field node) {
    return constantEvaluator.withNewEnvironment(() {
      if (node.isConst) {
        // Since we convert all use-sites of constants, the constant [Field]
        // cannot be referenced anymore.  We therefore get rid of it if
        // [keepFields] was not specified.
        if (!keepFields) {
          return null;
        }

        // Otherwise we keep the constant [Field] and convert it's initializer.
        transformAnnotations(node.annotations, node);
        if (node.initializer != null) {
          node.initializer =
              tryEvaluateAndTransformWithContext(node, node.initializer)
                ..parent = node;
        }
      } else {
        transformAnnotations(node.annotations, node);
        if (node.initializer != null) {
          node.initializer = node.initializer.accept(this)..parent = node;
        }
      }
      return node;
    });
  }

  // Handle use-sites of constants (and "inline" constant expressions):

  visitSymbolLiteral(SymbolLiteral node) {
    return new ConstantExpression(constantEvaluator.evaluate(node));
  }

  visitStaticGet(StaticGet node) {
    final Member target = node.target;
    if (target is Field && target.isConst) {
      final Constant constant =
          tryEvaluateWithContext(node, target.initializer);
      return constant != null ? new ConstantExpression(constant) : node;
    } else if (target is Procedure && target.kind == ProcedureKind.Method) {
      return tryEvaluateAndTransformWithContext(node, node);
    }
    return super.visitStaticGet(node);
  }

  visitSwitchCase(SwitchCase node) {
    transformExpressions(node.expressions, node);
    return super.visitSwitchCase(node);
  }

  visitVariableGet(VariableGet node) {
    if (node.variable.isConst) {
      return tryEvaluateAndTransformWithContext(node, node);
    }
    return super.visitVariableGet(node);
  }

  visitListLiteral(ListLiteral node) {
    if (node.isConst) {
      return tryEvaluateAndTransformWithContext(node, node);
    }
    return super.visitListLiteral(node);
  }

  visitMapLiteral(MapLiteral node) {
    if (node.isConst) {
      return tryEvaluateAndTransformWithContext(node, node);
    }
    return super.visitMapLiteral(node);
  }

  visitConstructorInvocation(ConstructorInvocation node) {
    if (node.isConst) {
      return tryEvaluateAndTransformWithContext(node, node);
    }
    return super.visitConstructorInvocation(node);
  }

  visitStaticInvocation(StaticInvocation node) {
    if (node.isConst) {
      return tryEvaluateAndTransformWithContext(node, node);
    }
    return super.visitStaticInvocation(node);
  }

  visitConstantExpression(ConstantExpression node) {
    Constant constant = node.constant;
    if (constant is UnevaluatedConstant) {
      Expression expression = constant.expression;
      return tryEvaluateAndTransformWithContext(expression, expression);
    } else {
      node.constant = constantEvaluator.canonicalize(constant);
      return node;
    }
  }

  tryEvaluateAndTransformWithContext(TreeNode treeContext, Expression node) {
    final Constant constant = tryEvaluateWithContext(treeContext, node);
    return constant != null ? new ConstantExpression(constant) : node;
  }

  tryEvaluateWithContext(TreeNode treeContext, Expression node) {
    if (treeContext == node) {
      return constantEvaluator.evaluate(node);
    }

    return constantEvaluator.runInsideContext(treeContext, () {
      return constantEvaluator.evaluate(node);
    });
  }
}

class ConstantEvaluator extends RecursiveVisitor<Constant> {
  final ConstantsBackend backend;
  final NumberSemantics numberSemantics;
  Map<String, String> environmentDefines;
  final CoreTypes coreTypes;
  final TypeEnvironment typeEnvironment;
  final bool enableAsserts;
  final ErrorReporter errorReporter;

  final isInstantiated = new IsInstantiatedVisitor().isInstantiated;

  final Map<Constant, Constant> canonicalizationCache;
  final Map<Node, Object> nodeCache;
  final CloneVisitor cloner = new CloneVisitor();

  final NullConstant nullConstant = new NullConstant();
  final BoolConstant trueConstant = new BoolConstant(true);
  final BoolConstant falseConstant = new BoolConstant(false);

  final List<TreeNode> contextChain = [];

  InstanceBuilder instanceBuilder;
  EvaluationEnvironment env;
  Set<Expression> replacementNodes = new Set<Expression>.identity();

  bool seenUnevaluatedChild; // Any children that were left unevaluated?
  int lazyDepth; // Current nesting depth of lazy regions.

  bool get shouldBeUnevaluated => seenUnevaluatedChild || lazyDepth != 0;

  bool get targetingJavaScript => numberSemantics == NumberSemantics.js;

  ConstantEvaluator(this.backend, this.environmentDefines, this.typeEnvironment,
      this.enableAsserts, this.errorReporter)
      : numberSemantics = backend.numberSemantics,
        coreTypes = typeEnvironment.coreTypes,
        canonicalizationCache = <Constant, Constant>{},
        nodeCache = <Node, Constant>{},
        env = new EvaluationEnvironment();

  Uri getFileUri(TreeNode node) {
    while (node != null && node is! FileUriNode) {
      node = node.parent;
    }
    return (node as FileUriNode)?.fileUri;
  }

  int getFileOffset(Uri uri, TreeNode node) {
    if (uri == null) return TreeNode.noOffset;
    while (node != null && node.fileOffset == TreeNode.noOffset) {
      node = node.parent;
    }
    return node == null ? TreeNode.noOffset : node.fileOffset;
  }

  /// Evaluate [node] and possibly cache the evaluation result.
  /// Returns UnevaluatedConstant if the constant could not be evaluated.
  /// If the expression in the UnevaluatedConstant is an InvalidExpression,
  /// an error occurred during constant evaluation.
  Constant evaluate(Expression node) {
    seenUnevaluatedChild = false;
    lazyDepth = 0;
    try {
      return _evaluateSubexpression(node);
    } on _AbortDueToError catch (e) {
      final Uri uri = getFileUri(e.node);
      final int fileOffset = getFileOffset(uri, e.node);
      final locatedMessage = e.message.withLocation(uri, fileOffset, noLength);

      final contextMessages = <LocatedMessage>[];
      if (e.context != null) contextMessages.addAll(e.context);
      for (final TreeNode node in contextChain) {
        final Uri uri = getFileUri(node);
        final int fileOffset = getFileOffset(uri, node);
        contextMessages.add(
            messageConstEvalContext.withLocation(uri, fileOffset, noLength));
      }
      errorReporter.report(locatedMessage, contextMessages);
      return new UnevaluatedConstant(new InvalidExpression(e.message.message));
    } on _AbortDueToInvalidExpression catch (e) {
      // TODO(askesc): Copy position from erroneous node.
      // Currently not possible, as it might be in a different file.
      // Can be done if we add an explicit URI to InvalidExpression.
      InvalidExpression invalid = new InvalidExpression(e.message);
      if (invalid.fileOffset == TreeNode.noOffset) {
        invalid.fileOffset = node.fileOffset;
      }
      errorReporter.reportInvalidExpression(invalid);
      return new UnevaluatedConstant(invalid);
    }
  }

  /// Report an error that has been detected during constant evaluation.
  Null report(TreeNode node, Message message, {List<LocatedMessage> context}) {
    throw new _AbortDueToError(node, message, context: context);
  }

  /// Report a construct that should not occur inside a potentially constant
  /// expression. It is assumed that an error has already been reported.
  Null reportInvalid(TreeNode node, String message) {
    throw new _AbortDueToInvalidExpression(node, message);
  }

  /// Produce an unevaluated constant node for an expression.
  Constant unevaluated(Expression original, Expression replacement) {
    replacement.fileOffset = original.fileOffset;
    return new UnevaluatedConstant(replacement);
  }

  /// Extract an expression from a (possibly unevaluated) constant to become
  /// part of the expression tree of another unevaluated constant.
  /// Makes sure a particular expression occurs only once in the tree by
  /// cloning further instances.
  Expression extract(Constant constant) {
    Expression expression = constant.asExpression();
    if (!replacementNodes.add(expression)) {
      expression = cloner.clone(expression);
      replacementNodes.add(expression);
    }
    return expression;
  }

  /// Enter a region of lazy evaluation. All leaf nodes are evaluated normally
  /// (to ensure inlining of referenced local variables), but composite nodes
  /// always treat their children as unevaluated, resulting in a partially
  /// evaluated clone of the original expression tree.
  /// Lazy evaluation is used for the subtrees of lazy operations with
  /// unevaluated conditions to ensure no errors are reported for problems
  /// in the subtree as long as the subtree is potentially constant.
  void enterLazy() => lazyDepth++;

  /// Leave a (possibly nested) region of lazy evaluation.
  void leaveLazy() => lazyDepth--;

  /// Evaluate [node] and possibly cache the evaluation result.
  /// @throws _AbortDueToError or _AbortDueToInvalidExpression if expression
  /// can't be evaluated.
  Constant _evaluateSubexpression(Expression node) {
    if (node == null) return nullConstant;
    bool wasUnevaluated = seenUnevaluatedChild;
    seenUnevaluatedChild = false;
    Constant result;
    if (env.isEmpty) {
      // We only try to evaluate the same [node] *once* within an empty
      // environment.
      if (nodeCache.containsKey(node)) {
        result = nodeCache[node] ?? report(node, messageConstEvalCircularity);
      } else {
        nodeCache[node] = null;
        result = nodeCache[node] = node.accept(this);
      }
    } else {
      result = node.accept(this);
    }
    seenUnevaluatedChild = wasUnevaluated || result is UnevaluatedConstant;
    return result;
  }

  Constant runInsideContext(TreeNode node, Constant fun()) {
    try {
      pushContext(node);
      return fun();
    } finally {
      popContext(node);
    }
  }

  Constant runInsideContextIfNoContext(TreeNode node, Constant fun()) {
    if (contextChain.isEmpty) {
      return runInsideContext(node, fun);
    } else {
      return fun();
    }
  }

  pushContext(TreeNode contextNode) {
    contextChain.add(contextNode);
  }

  popContext(TreeNode contextNode) {
    assert(contextChain.last == contextNode);
    contextChain.length = contextChain.length - 1;
  }

  defaultTreeNode(Node node) {
    // Only a subset of the expression language is valid for constant
    // evaluation.
    return reportInvalid(
        node, 'Constant evaluation has no support for ${node.runtimeType}!');
  }

  visitNullLiteral(NullLiteral node) => nullConstant;

  visitBoolLiteral(BoolLiteral node) {
    return node.value ? trueConstant : falseConstant;
  }

  visitIntLiteral(IntLiteral node) {
    // The frontend will ensure the integer literals are in signed 64-bit
    // range.
    return canonicalize(new IntConstant(node.value));
  }

  visitDoubleLiteral(DoubleLiteral node) {
    return canonicalize(makeDoubleConstant(node.value));
  }

  visitStringLiteral(StringLiteral node) {
    return canonicalize(new StringConstant(node.value));
  }

  visitTypeLiteral(TypeLiteral node) {
    final DartType type = evaluateDartType(node, node.type);
    return canonicalize(new TypeLiteralConstant(type));
  }

  visitConstantExpression(ConstantExpression node) {
    // If there were already constants in the AST then we make sure we
    // re-canonicalize them.  After running the transformer we will therefore
    // have a fully-canonicalized constant DAG with roots coming from the
    // [ConstantExpression] nodes in the AST.
    return canonicalize(node.constant);
  }

  visitListLiteral(ListLiteral node) {
    if (!node.isConst) {
      return report(
          node, templateConstEvalNonConstantLiteral.withArguments('List'));
    }
    final List<Constant> entries = new List<Constant>(node.expressions.length);
    for (int i = 0; i < node.expressions.length; ++i) {
      entries[i] = _evaluateSubexpression(node.expressions[i]);
    }
    if (shouldBeUnevaluated) {
      final expressions = new List<Expression>(node.expressions.length);
      for (int i = 0; i < node.expressions.length; ++i) {
        expressions[i] = extract(entries[i]);
      }
      return unevaluated(
          node,
          new ListLiteral(expressions,
              typeArgument: node.typeArgument, isConst: true));
    }
    final DartType typeArgument = evaluateDartType(node, node.typeArgument);
    return canonicalize(
        backend.lowerListConstant(new ListConstant(typeArgument, entries)));
  }

  visitSetLiteral(SetLiteral node) {
    if (!node.isConst) {
      return report(
          node, templateConstEvalNonConstantLiteral.withArguments('Set'));
    }
    final List<Constant> entries = new List<Constant>(node.expressions.length);
    for (int i = 0; i < node.expressions.length; ++i) {
      entries[i] = _evaluateSubexpression(node.expressions[i]);
    }
    if (shouldBeUnevaluated) {
      final expressions = new List<Expression>(node.expressions.length);
      for (int i = 0; i < node.expressions.length; ++i) {
        expressions[i] = extract(entries[i]);
      }
      return unevaluated(
          node,
          new SetLiteral(expressions,
              typeArgument: node.typeArgument, isConst: true));
    }
    final DartType typeArgument = evaluateDartType(node, node.typeArgument);
    return canonicalize(
        backend.lowerSetConstant(new SetConstant(typeArgument, entries)));
  }

  visitMapLiteral(MapLiteral node) {
    if (!node.isConst) {
      return report(
          node, templateConstEvalNonConstantLiteral.withArguments('Map'));
    }
    final List<ConstantMapEntry> entries =
        new List<ConstantMapEntry>(node.entries.length);
    for (int i = 0; i < node.entries.length; ++i) {
      final key = _evaluateSubexpression(node.entries[i].key);
      final value = _evaluateSubexpression(node.entries[i].value);
      entries[i] = new ConstantMapEntry(key, value);
    }
    if (shouldBeUnevaluated) {
      final mapEntries = new List<MapEntry>(node.entries.length);
      for (int i = 0; i < node.entries.length; ++i) {
        mapEntries[i] =
            new MapEntry(extract(entries[i].key), extract(entries[i].value));
      }
      return unevaluated(
          node,
          new MapLiteral(mapEntries,
              keyType: node.keyType, valueType: node.valueType, isConst: true));
    }
    final Set<Constant> usedKeys = new Set<Constant>();
    for (int i = 0; i < node.entries.length; ++i) {
      if (!usedKeys.add(entries[i].key)) {
        // TODO(kustermann): We should change the context handling from just
        // capturing the `TreeNode`s to a `(TreeNode, String message)` tuple and
        // report where the first key with the same value was.
        return report(node.entries[i],
            templateConstEvalDuplicateKey.withArguments(entries[i].key));
      }
    }
    final DartType keyType = evaluateDartType(node, node.keyType);
    final DartType valueType = evaluateDartType(node, node.valueType);
    return canonicalize(
        backend.lowerMapConstant(new MapConstant(keyType, valueType, entries)));
  }

  visitFunctionExpression(FunctionExpression node) {
    return report(
        node, templateConstEvalNonConstantLiteral.withArguments('Function'));
  }

  visitConstructorInvocation(ConstructorInvocation node) {
    final Constructor constructor = node.target;
    final Class klass = constructor.enclosingClass;
    if (!constructor.isConst) {
      return reportInvalid(node, 'Non-const constructor invocation.');
    }
    if (constructor.function.body != null &&
        constructor.function.body is! EmptyStatement) {
      return reportInvalid(
          node,
          'Constructor "$node" has non-trivial body '
          '"${constructor.function.body.runtimeType}".');
    }
    if (klass.isAbstract) {
      return reportInvalid(
          node, 'Constructor "$node" belongs to abstract class "${klass}".');
    }

    final positionals = evaluatePositionalArguments(node.arguments);
    final named = evaluateNamedArguments(node.arguments);

    // Is the constructor unavailable due to separate compilation?
    bool isUnavailable = constructor.isInExternalLibrary &&
        constructor.initializers.isEmpty &&
        constructor.enclosingClass.supertype != null;

    if (isUnavailable || shouldBeUnevaluated) {
      return unevaluated(
          node,
          new ConstructorInvocation(constructor,
              unevaluatedArguments(positionals, named, node.arguments.types),
              isConst: true));
    }

    final typeArguments = evaluateTypeArguments(node, node.arguments);

    // Fill in any missing type arguments with "dynamic".
    for (int i = typeArguments.length; i < klass.typeParameters.length; i++) {
      typeArguments.add(const DynamicType());
    }

    // Start building a new instance.
    return withNewInstanceBuilder(klass, typeArguments, () {
      return runInsideContextIfNoContext(node, () {
        // "Run" the constructor (and any super constructor calls), which will
        // initialize the fields of the new instance.
        handleConstructorInvocation(
            constructor, typeArguments, positionals, named);
        final InstanceConstant result = instanceBuilder.buildInstance();

        // Special case the dart:core's Symbol class here and convert it to a
        // [SymbolConstant].  For invalid values we report a compile-time error.
        if (result.classNode == coreTypes.internalSymbolClass) {
          // The dart:_internal's Symbol class has only the name field.
          assert(coreTypes.internalSymbolClass.fields
                  .where((f) => !f.isStatic)
                  .length ==
              1);
          final nameValue = result.fieldValues.values.single;

          if (nameValue is StringConstant &&
              isValidSymbolName(nameValue.value)) {
            return canonicalize(new SymbolConstant(nameValue.value, null));
          }
          return report(node.arguments.positional.first,
              templateConstEvalInvalidSymbolName.withArguments(nameValue));
        }

        return canonicalize(result);
      });
    });
  }

  bool isValidSymbolName(String name) {
    // See https://api.dartlang.org/stable/2.0.0/dart-core/Symbol/Symbol.html:
    //
    //  A qualified name is a valid name preceded by a public identifier name and
    //  a '.', e.g., foo.bar.baz= is a qualified version of baz=.
    //
    //  That means that the content of the name String must be either
    //     - a valid public Dart identifier (that is, an identifier not
    //       starting with "_"),
    //     - such an identifier followed by "=" (a setter name),
    //     - the name of a declarable operator,
    //     - any of the above preceded by any number of qualifiers, where a
    //       qualifier is a non-private identifier followed by '.',
    //     - or the empty string (the default name of a library with no library
    //       name declaration).

    const operatorNames = const <String>[
      '+',
      '-',
      '*',
      '/',
      '%',
      '~/',
      '&',
      '|',
      '^',
      '~',
      '<<',
      '>>',
      '<',
      '<=',
      '>',
      '>=',
      '==',
      '[]',
      '[]=',
      'unary-'
    ];

    if (name == null) return false;
    if (name == '') return true;

    final parts = name.split('.');

    // Each qualifier must be a public identifier.
    for (int i = 0; i < parts.length - 1; ++i) {
      if (!isValidPublicIdentifier(parts[i])) return false;
    }

    String last = parts.last;
    if (operatorNames.contains(last)) {
      return true;
    }
    if (last.endsWith('=')) {
      last = last.substring(0, last.length - 1);
    }
    if (!isValidPublicIdentifier(last)) return false;

    return true;
  }

  /// From the Dart Language specification:
  ///
  ///   IDENTIFIER:
  ///     IDENTIFIER_START IDENTIFIER_PART*
  ///
  ///   IDENTIFIER_START:
  ///       IDENTIFIER_START_NO_DOLLAR | ‘$’
  ///
  ///   IDENTIFIER_PART:
  ///       IDENTIFIER_START | DIGIT
  ///
  ///   IDENTIFIER_NO_DOLLAR:
  ///     IDENTIFIER_START_NO_DOLLAR IDENTIFIER_PART_NO_DOLLAR*
  ///
  ///   IDENTIFIER_START_NO_DOLLAR:
  ///       LETTER | '_'
  ///
  ///   IDENTIFIER_PART_NO_DOLLAR:
  ///       IDENTIFIER_START_NO_DOLLAR | DIGIT
  ///
  static final publicIdentifierRegExp =
      new RegExp(r'^[a-zA-Z$][a-zA-Z0-9_$]*$');

  static const nonUsableKeywords = const <String>[
    'assert',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'default',
    'do',
    'else',
    'enum',
    'extends',
    'false',
    'final',
    'finally',
    'for',
    'if',
    'in',
    'is',
    'new',
    'null',
    'rethrow',
    'return',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'try',
    'var',
    'while',
    'with',
  ];

  bool isValidPublicIdentifier(String name) {
    return publicIdentifierRegExp.hasMatch(name) &&
        !nonUsableKeywords.contains(name);
  }

  handleConstructorInvocation(
      Constructor constructor,
      List<DartType> typeArguments,
      List<Constant> positionalArguments,
      Map<String, Constant> namedArguments) {
    return runInsideContext(constructor, () {
      return withNewEnvironment(() {
        final Class klass = constructor.enclosingClass;
        final FunctionNode function = constructor.function;

        // We simulate now the constructor invocation.

        // Step 1) Map type arguments and normal arguments from caller to callee.
        for (int i = 0; i < klass.typeParameters.length; i++) {
          env.addTypeParameterValue(klass.typeParameters[i], typeArguments[i]);
        }
        for (int i = 0; i < function.positionalParameters.length; i++) {
          final VariableDeclaration parameter =
              function.positionalParameters[i];
          final Constant value = (i < positionalArguments.length)
              ? positionalArguments[i]
              : _evaluateSubexpression(parameter.initializer);
          env.addVariableValue(parameter, value);
        }
        for (final VariableDeclaration parameter in function.namedParameters) {
          final Constant value = namedArguments[parameter.name] ??
              _evaluateSubexpression(parameter.initializer);
          env.addVariableValue(parameter, value);
        }

        // Step 2) Run all initializers (including super calls) with environment setup.
        for (final Field field in klass.fields) {
          if (!field.isStatic) {
            instanceBuilder.setFieldValue(
                field, _evaluateSubexpression(field.initializer));
          }
        }
        for (final Initializer init in constructor.initializers) {
          if (init is FieldInitializer) {
            instanceBuilder.setFieldValue(
                init.field, _evaluateSubexpression(init.value));
          } else if (init is LocalInitializer) {
            final VariableDeclaration variable = init.variable;
            env.addVariableValue(
                variable, _evaluateSubexpression(variable.initializer));
          } else if (init is SuperInitializer) {
            handleConstructorInvocation(
                init.target,
                evaluateSuperTypeArguments(
                    init, constructor.enclosingClass.supertype),
                evaluatePositionalArguments(init.arguments),
                evaluateNamedArguments(init.arguments));
          } else if (init is RedirectingInitializer) {
            // Since a redirecting constructor targets a constructor of the same
            // class, we pass the same [typeArguments].
            handleConstructorInvocation(
                init.target,
                typeArguments,
                evaluatePositionalArguments(init.arguments),
                evaluateNamedArguments(init.arguments));
          } else if (init is AssertInitializer) {
            if (enableAsserts) {
              final Constant condition =
                  _evaluateSubexpression(init.statement.condition);

              if (condition is BoolConstant) {
                if (!condition.value) {
                  if (init.statement.message == null) {
                    return report(init.statement.condition,
                        messageConstEvalFailedAssertion);
                  }
                  final Constant message =
                      _evaluateSubexpression(init.statement.message);
                  if (message is StringConstant) {
                    return report(
                        init.statement.condition,
                        templateConstEvalFailedAssertionWithMessage
                            .withArguments(message.value));
                  }
                  return report(
                      init.statement.message,
                      templateConstEvalInvalidType.withArguments(
                          message,
                          typeEnvironment.stringType,
                          message.getType(typeEnvironment)));
                }
              } else {
                return report(
                    init.statement.condition,
                    templateConstEvalInvalidType.withArguments(
                        condition,
                        typeEnvironment.boolType,
                        condition.getType(typeEnvironment)));
              }
            }
          } else {
            return reportInvalid(
                constructor,
                'No support for handling initializer of type '
                '"${init.runtimeType}".');
          }
        }
      });
    });
  }

  visitInvalidExpression(InvalidExpression node) {
    return reportInvalid(node, node.message);
  }

  visitMethodInvocation(MethodInvocation node) {
    // We have no support for generic method invocation atm.
    assert(node.arguments.named.isEmpty);

    final Constant receiver = _evaluateSubexpression(node.receiver);
    final List<Constant> arguments =
        evaluatePositionalArguments(node.arguments);

    if (shouldBeUnevaluated) {
      return unevaluated(
          node,
          new MethodInvocation(extract(receiver), node.name,
              unevaluatedArguments(arguments, {}, node.arguments.types)));
    }

    // TODO(http://dartbug.com/31799): Ensure we only invoke ==/!= on
    // null/bool/int/double/String objects.

    // Handle == and != first (it's common between all types).
    if (arguments.length == 1 && node.name.name == '==') {
      final right = arguments[0];
      return receiver == right ? trueConstant : falseConstant;
    }
    if (arguments.length == 1 && node.name.name == '!=') {
      final right = arguments[0];
      return receiver != right ? trueConstant : falseConstant;
    }

    // This is a white-listed set of methods we need to support on constants.
    if (receiver is StringConstant) {
      if (arguments.length == 1) {
        switch (node.name.name) {
          case '+':
            final Constant other = arguments[0];
            if (other is StringConstant) {
              return canonicalize(
                  new StringConstant(receiver.value + other.value));
            }
            return report(
                node,
                templateConstEvalInvalidBinaryOperandType.withArguments(
                    '+',
                    receiver,
                    typeEnvironment.stringType,
                    other.getType(typeEnvironment)));
        }
      }
    } else if (receiver is IntConstant) {
      if (arguments.length == 0) {
        switch (node.name.name) {
          case 'unary-':
            return canonicalize(new IntConstant(-receiver.value));
          case '~':
            return canonicalize(new IntConstant(~receiver.value));
        }
      } else if (arguments.length == 1) {
        final Constant other = arguments[0];
        final op = node.name.name;
        if (other is IntConstant) {
          if ((op == '<<' || op == '>>' || op == '>>>') && other.value < 0) {
            return report(
                node.arguments.positional.first,
                // TODO(askesc): Change argument types in template to constants.
                templateConstEvalNegativeShift.withArguments(
                    op, '${receiver.value}', '${other.value}'));
          }
          switch (op) {
            case '|':
              return canonicalize(
                  new IntConstant(receiver.value | other.value));
            case '&':
              return canonicalize(
                  new IntConstant(receiver.value & other.value));
            case '^':
              return canonicalize(
                  new IntConstant(receiver.value ^ other.value));
            case '<<':
              return canonicalize(
                  new IntConstant(receiver.value << other.value));
            case '>>':
              return canonicalize(
                  new IntConstant(receiver.value >> other.value));
            case '>>>':
              int result = other.value >= 64
                  ? 0
                  : (receiver.value >> other.value) &
                      ((1 << (64 - other.value)) - 1);
              return canonicalize(new IntConstant(result));
          }
        }

        if (other is IntConstant) {
          if (other.value == 0 && (op == '%' || op == '~/')) {
            return report(
                node.arguments.positional.first,
                // TODO(askesc): Change argument type in template to constant.
                templateConstEvalZeroDivisor.withArguments(
                    op, '${receiver.value}'));
          }

          return evaluateBinaryNumericOperation(
              node.name.name, receiver.value, other.value, node);
        } else if (other is DoubleConstant) {
          return evaluateBinaryNumericOperation(
              node.name.name, receiver.value, other.value, node);
        }
        return report(
            node,
            templateConstEvalInvalidBinaryOperandType.withArguments(
                node.name.name,
                receiver,
                typeEnvironment.numType,
                other.getType(typeEnvironment)));
      }
    } else if (receiver is DoubleConstant) {
      if (arguments.length == 0) {
        switch (node.name.name) {
          case 'unary-':
            return canonicalize(makeDoubleConstant(-receiver.value));
        }
      } else if (arguments.length == 1) {
        final Constant other = arguments[0];

        if (other is IntConstant || other is DoubleConstant) {
          final num value = (other is IntConstant)
              ? other.value
              : (other as DoubleConstant).value;
          return evaluateBinaryNumericOperation(
              node.name.name, receiver.value, value, node);
        }
        return report(
            node,
            templateConstEvalInvalidBinaryOperandType.withArguments(
                node.name.name,
                receiver,
                typeEnvironment.numType,
                other.getType(typeEnvironment)));
      }
    } else if (receiver is BoolConstant) {
      if (arguments.length == 1) {
        final Constant other = arguments[0];
        if (other is BoolConstant) {
          switch (node.name.name) {
            case '|':
              return canonicalize(
                  new BoolConstant(receiver.value || other.value));
            case '&':
              return canonicalize(
                  new BoolConstant(receiver.value && other.value));
            case '^':
              return canonicalize(
                  new BoolConstant(receiver.value != other.value));
          }
        }
      }
    } else if (receiver is NullConstant) {
      return report(node, messageConstEvalNullValue);
    }

    return report(
        node,
        templateConstEvalInvalidMethodInvocation.withArguments(
            node.name.name, receiver));
  }

  visitLogicalExpression(LogicalExpression node) {
    final Constant left = _evaluateSubexpression(node.left);
    if (shouldBeUnevaluated) {
      enterLazy();
      Constant right = _evaluateSubexpression(node.right);
      leaveLazy();
      return unevaluated(node,
          new LogicalExpression(extract(left), node.operator, extract(right)));
    }
    switch (node.operator) {
      case '||':
        if (left is BoolConstant) {
          if (left.value) return trueConstant;

          final Constant right = _evaluateSubexpression(node.right);
          if (right is BoolConstant || right is UnevaluatedConstant) {
            return right;
          }

          return report(
              node,
              templateConstEvalInvalidBinaryOperandType.withArguments(
                  node.operator,
                  left,
                  typeEnvironment.boolType,
                  right.getType(typeEnvironment)));
        }
        return report(
            node,
            templateConstEvalInvalidMethodInvocation.withArguments(
                node.operator, left));
      case '&&':
        if (left is BoolConstant) {
          if (!left.value) return falseConstant;

          final Constant right = _evaluateSubexpression(node.right);
          if (right is BoolConstant || right is UnevaluatedConstant) {
            return right;
          }

          return report(
              node,
              templateConstEvalInvalidBinaryOperandType.withArguments(
                  node.operator,
                  left,
                  typeEnvironment.boolType,
                  right.getType(typeEnvironment)));
        }
        return report(
            node,
            templateConstEvalInvalidMethodInvocation.withArguments(
                node.operator, left));
      case '??':
        return (left is! NullConstant)
            ? left
            : _evaluateSubexpression(node.right);
      default:
        return report(
            node,
            templateConstEvalInvalidMethodInvocation.withArguments(
                node.operator, left));
    }
  }

  visitConditionalExpression(ConditionalExpression node) {
    final Constant condition = _evaluateSubexpression(node.condition);
    if (condition == trueConstant) {
      return _evaluateSubexpression(node.then);
    } else if (condition == falseConstant) {
      return _evaluateSubexpression(node.otherwise);
    } else if (shouldBeUnevaluated) {
      enterLazy();
      Constant then = _evaluateSubexpression(node.then);
      Constant otherwise = _evaluateSubexpression(node.otherwise);
      leaveLazy();
      return unevaluated(
          node,
          new ConditionalExpression(extract(condition), extract(then),
              extract(otherwise), node.staticType));
    } else {
      return report(
          node,
          templateConstEvalInvalidType.withArguments(condition,
              typeEnvironment.boolType, condition.getType(typeEnvironment)));
    }
  }

  visitPropertyGet(PropertyGet node) {
    if (node.receiver is ThisExpression) {
      // Access "this" during instance creation.
      if (instanceBuilder == null) {
        return reportInvalid(node, 'Instance field access outside constructor');
      }
      for (final Field field in instanceBuilder.fields.keys) {
        if (field.name == node.name) {
          return instanceBuilder.fields[field];
        }
      }
      return reportInvalid(node,
          'Could not evaluate field get ${node.name} on incomplete instance');
    }

    final Constant receiver = _evaluateSubexpression(node.receiver);
    if (receiver is StringConstant && node.name.name == 'length') {
      return canonicalize(new IntConstant(receiver.value.length));
    } else if (receiver is InstanceConstant) {
      for (final Reference fieldRef in receiver.fieldValues.keys) {
        if (fieldRef.asField.name == node.name) {
          return receiver.fieldValues[fieldRef];
        }
      }
    } else if (shouldBeUnevaluated) {
      return unevaluated(node,
          new PropertyGet(extract(receiver), node.name, node.interfaceTarget));
    } else if (receiver is NullConstant) {
      return report(node, messageConstEvalNullValue);
    }
    return report(
        node,
        templateConstEvalInvalidPropertyGet.withArguments(
            node.name.name, receiver));
  }

  visitLet(Let node) {
    env.addVariableValue(
        node.variable, _evaluateSubexpression(node.variable.initializer));
    return _evaluateSubexpression(node.body);
  }

  visitVariableGet(VariableGet node) {
    // Not every variable which a [VariableGet] refers to must be marked as
    // constant.  For example function parameters as well as constructs
    // desugared to [Let] expressions are ok.
    //
    // TODO(kustermann): The heuristic of allowing all [VariableGet]s on [Let]
    // variables might allow more than it should.
    final VariableDeclaration variable = node.variable;
    if (variable.parent is Let || _isFormalParameter(variable)) {
      return env.lookupVariable(node.variable) ??
          report(
              node,
              templateConstEvalNonConstantVariableGet
                  .withArguments(variable.name));
    }
    if (variable.isConst) {
      return _evaluateSubexpression(variable.initializer);
    }
    return reportInvalid(node, 'Variable get of a non-const variable.');
  }

  visitStaticGet(StaticGet node) {
    return withNewEnvironment(() {
      final Member target = node.target;
      if (target is Field) {
        if (target.isConst) {
          if (target.isInExternalLibrary && target.initializer == null) {
            // The variable is unavailable due to separate compilation.
            return unevaluated(node, new StaticGet(target));
          }
          return runInsideContext(target, () {
            return _evaluateSubexpression(target.initializer);
          });
        }
        return report(
            node,
            templateConstEvalInvalidStaticInvocation
                .withArguments(target.name.name));
      } else if (target is Procedure) {
        if (target.kind == ProcedureKind.Method) {
          return canonicalize(new TearOffConstant(target));
        }
        return report(
            node,
            templateConstEvalInvalidStaticInvocation
                .withArguments(target.name.name));
      } else {
        reportInvalid(
            node, 'No support for ${target.runtimeType} in a static-get.');
      }
    });
  }

  visitStringConcatenation(StringConcatenation node) {
    final List<Object> concatenated = <Object>[new StringBuffer()];
    for (int i = 0; i < node.expressions.length; i++) {
      Constant constant = _evaluateSubexpression(node.expressions[i]);
      if (constant is PrimitiveConstant<Object>) {
        String value = constant.value.toString();
        Object last = concatenated.last;
        if (last is StringBuffer) {
          last.write(value);
        } else {
          concatenated.add(new StringBuffer(value));
        }
      } else if (shouldBeUnevaluated) {
        concatenated.add(constant);
      } else {
        return report(
            node,
            templateConstEvalInvalidStringInterpolationOperand
                .withArguments(constant));
      }
    }
    if (concatenated.length > 1) {
      final expressions = new List<Expression>(concatenated.length);
      for (int i = 0; i < concatenated.length; i++) {
        Object value = concatenated[i];
        if (value is UnevaluatedConstant) {
          expressions[i] = extract(value);
        } else {
          expressions[i] = new ConstantExpression(
              canonicalize(new StringConstant(value.toString())));
        }
      }
      return unevaluated(node, new StringConcatenation(expressions));
    }
    return canonicalize(new StringConstant(concatenated.single.toString()));
  }

  visitStaticInvocation(StaticInvocation node) {
    final Procedure target = node.target;
    final Arguments arguments = node.arguments;
    final positionals = evaluatePositionalArguments(arguments);
    final named = evaluateNamedArguments(arguments);
    if (shouldBeUnevaluated) {
      return unevaluated(
          node,
          new StaticInvocation(
              target, unevaluatedArguments(positionals, named, arguments.types),
              isConst: true));
    }
    if (target.kind == ProcedureKind.Factory) {
      if (target.isConst &&
          target.name.name == "fromEnvironment" &&
          target.enclosingLibrary == coreTypes.coreLibrary &&
          positionals.length == 1) {
        if (environmentDefines != null) {
          // Evaluate environment constant.
          Constant name = positionals.single;
          if (name is StringConstant) {
            String value = environmentDefines[name.value];
            Constant defaultValue = named["defaultValue"];

            if (target.enclosingClass == coreTypes.boolClass) {
              Constant boolConstant = value == "true"
                  ? trueConstant
                  : value == "false"
                      ? falseConstant
                      : defaultValue is BoolConstant
                          ? defaultValue.value ? trueConstant : falseConstant
                          : defaultValue is NullConstant
                              ? nullConstant
                              : falseConstant;
              return boolConstant;
            } else if (target.enclosingClass == coreTypes.intClass) {
              int intValue = value != null ? int.tryParse(value) : null;
              intValue ??=
                  defaultValue is IntConstant ? defaultValue.value : null;
              if (intValue == null) return nullConstant;
              return canonicalize(new IntConstant(intValue));
            } else if (target.enclosingClass == coreTypes.stringClass) {
              value ??=
                  defaultValue is StringConstant ? defaultValue.value : null;
              if (value == null) return nullConstant;
              return canonicalize(new StringConstant(value));
            }
          } else if (name is NullConstant) {
            return report(node, messageConstEvalNullValue);
          }
        } else {
          // Leave environment constant unevaluated.
          return unevaluated(
              node,
              new StaticInvocation(target,
                  unevaluatedArguments(positionals, named, arguments.types),
                  isConst: true));
        }
      }
    } else if (target.name.name == 'identical') {
      // Ensure the "identical()" function comes from dart:core.
      final parent = target.parent;
      if (parent is Library && parent == coreTypes.coreLibrary) {
        final Constant left = positionals[0];
        final Constant right = positionals[1];
        // Since we canonicalize constants during the evaluation, we can use
        // identical here.
        return identical(left, right) ? trueConstant : falseConstant;
      }
    }

    // TODO(kmillikin) For an invalid factory invocation we should adopt a
    // better message.  This will show something like:
    //
    // "The invocation of 'List' is not allowed within a const context."
    //
    // Which is not quite right when the code was "new List()".
    String name = target.name.name;
    if (target is Procedure && target.isFactory) {
      if (name.isEmpty) {
        name = target.enclosingClass.name;
      } else {
        name = '${target.enclosingClass.name}.${name}';
      }
    }
    return report(
        node, templateConstEvalInvalidStaticInvocation.withArguments(name));
  }

  visitAsExpression(AsExpression node) {
    final Constant constant = _evaluateSubexpression(node.operand);
    if (shouldBeUnevaluated) {
      return unevaluated(node, new AsExpression(extract(constant), node.type));
    }
    return ensureIsSubtype(constant, evaluateDartType(node, node.type), node);
  }

  visitIsExpression(IsExpression node) {
    final Constant constant = node.operand.accept(this);
    if (shouldBeUnevaluated) {
      return unevaluated(node, new IsExpression(extract(constant), node.type));
    }
    if (constant is NullConstant) {
      return node.type == typeEnvironment.nullType ||
              node.type == typeEnvironment.objectType ||
              node.type is DynamicType
          ? trueConstant
          : falseConstant;
    }
    return isSubtype(constant, evaluateDartType(node, node.type))
        ? trueConstant
        : falseConstant;
  }

  visitNot(Not node) {
    final Constant constant = _evaluateSubexpression(node.operand);
    if (constant is BoolConstant) {
      return constant == trueConstant ? falseConstant : trueConstant;
    }
    if (shouldBeUnevaluated) {
      return unevaluated(node, new Not(extract(constant)));
    }
    return report(
        node,
        templateConstEvalInvalidType.withArguments(constant,
            typeEnvironment.boolType, constant.getType(typeEnvironment)));
  }

  visitSymbolLiteral(SymbolLiteral node) {
    final libraryReference =
        node.value.startsWith('_') ? libraryOf(node).reference : null;
    return canonicalize(new SymbolConstant(node.value, libraryReference));
  }

  visitInstantiation(Instantiation node) {
    final Constant constant = _evaluateSubexpression(node.expression);
    if (shouldBeUnevaluated) {
      return unevaluated(
          node, new Instantiation(extract(constant), node.typeArguments));
    }
    if (constant is TearOffConstant) {
      if (node.typeArguments.length ==
          constant.procedure.function.typeParameters.length) {
        final typeArguments = evaluateDartTypes(node, node.typeArguments);
        return canonicalize(
            new PartialInstantiationConstant(constant, typeArguments));
      }
      return reportInvalid(
          node,
          'The number of type arguments supplied in the partial instantiation '
          'does not match the number of type arguments of the $constant.');
    }
    // The inner expression in an instantiation can never be null, since
    // instantiations are only inferred on direct references to declarations.
    return reportInvalid(
        node, 'Only tear-off constants can be partially instantiated.');
  }

  @override
  visitCheckLibraryIsLoaded(CheckLibraryIsLoaded node) {
    return report(
        node, templateConstEvalDeferredLibrary.withArguments(node.import.name));
  }

  // Helper methods:

  Constant makeDoubleConstant(double value) {
    if (targetingJavaScript) {
      // Convert to an integer when possible (matching the runtime behavior
      // of `is int`).
      if (value.isFinite) {
        var i = value.toInt();
        if (value == i.toDouble()) return new IntConstant(i);
      }
    }
    return new DoubleConstant(value);
  }

  bool isSubtype(Constant constant, DartType type) {
    DartType constantType = constant.getType(typeEnvironment);
    return typeEnvironment.isSubtypeOf(constantType, type);
  }

  Constant ensureIsSubtype(Constant constant, DartType type, TreeNode node) {
    if (!isSubtype(constant, type)) {
      return report(
          node,
          templateConstEvalInvalidType.withArguments(
              constant, type, constant.getType(typeEnvironment)));
    }
    return constant;
  }

  List<DartType> evaluateTypeArguments(TreeNode node, Arguments arguments) {
    return evaluateDartTypes(node, arguments.types);
  }

  List<DartType> evaluateSuperTypeArguments(TreeNode node, Supertype type) {
    return evaluateDartTypes(node, type.typeArguments);
  }

  List<DartType> evaluateDartTypes(TreeNode node, List<DartType> types) {
    // TODO: Once the frontend gurantees that there are no free type variables
    // left over after stubstitution, we can enable this shortcut again:
    // if (env.isEmpty) return types;
    return types.map((t) => evaluateDartType(node, t)).toList();
  }

  DartType evaluateDartType(TreeNode node, DartType type) {
    final result = env.subsituteType(type);

    if (!isInstantiated(result)) {
      return report(
          node, templateConstEvalFreeTypeParameter.withArguments(type));
    }

    return result;
  }

  List<Constant> evaluatePositionalArguments(Arguments arguments) {
    return arguments.positional.map((Expression node) {
      return _evaluateSubexpression(node);
    }).toList();
  }

  Map<String, Constant> evaluateNamedArguments(Arguments arguments) {
    if (arguments.named.isEmpty) return const <String, Constant>{};

    final Map<String, Constant> named = {};
    arguments.named.forEach((NamedExpression pair) {
      named[pair.name] = _evaluateSubexpression(pair.value);
    });
    return named;
  }

  Arguments unevaluatedArguments(List<Constant> positionalArgs,
      Map<String, Constant> namedArgs, List<DartType> types) {
    final positional = new List<Expression>(positionalArgs.length);
    final named = new List<NamedExpression>(namedArgs.length);
    for (int i = 0; i < positionalArgs.length; ++i) {
      positional[i] = extract(positionalArgs[i]);
    }
    int i = 0;
    namedArgs.forEach((String name, Constant value) {
      named[i++] = new NamedExpression(name, extract(value));
    });
    return new Arguments(positional, named: named, types: types);
  }

  Constant canonicalize(Constant constant) {
    return canonicalizationCache.putIfAbsent(constant, () => constant);
  }

  withNewInstanceBuilder(Class klass, List<DartType> typeArguments, fn()) {
    InstanceBuilder old = instanceBuilder;
    try {
      instanceBuilder = new InstanceBuilder(klass, typeArguments);
      return fn();
    } finally {
      instanceBuilder = old;
    }
  }

  withNewEnvironment(fn()) {
    final EvaluationEnvironment oldEnv = env;
    try {
      env = new EvaluationEnvironment();
      return fn();
    } finally {
      env = oldEnv;
    }
  }

  Constant evaluateBinaryNumericOperation(
      String op, num a, num b, TreeNode node) {
    if (targetingJavaScript) {
      a = a.toDouble();
      b = b.toDouble();
    }
    num result;
    switch (op) {
      case '+':
        result = a + b;
        break;
      case '-':
        result = a - b;
        break;
      case '*':
        result = a * b;
        break;
      case '/':
        result = a / b;
        break;
      case '~/':
        result = a ~/ b;
        break;
      case '%':
        result = a % b;
        break;
    }

    if (result is int) {
      return canonicalize(new IntConstant(result.toSigned(64)));
    }
    if (result is double) {
      return canonicalize(makeDoubleConstant(result));
    }

    switch (op) {
      case '<':
        return a < b ? trueConstant : falseConstant;
      case '<=':
        return a <= b ? trueConstant : falseConstant;
      case '>=':
        return a >= b ? trueConstant : falseConstant;
      case '>':
        return a > b ? trueConstant : falseConstant;
    }

    return reportInvalid(node, "Unexpected binary numeric operation '$op'.");
  }

  Library libraryOf(TreeNode node) {
    // The tree structure of the kernel AST ensures we always have an enclosing
    // library.
    while (true) {
      if (node is Library) return node;
      node = node.parent;
    }
  }
}

/// Holds the necessary information for a constant object, namely
///   * the [klass] being instantiated
///   * the [typeArguments] used for the instantiation
///   * the [fields] the instance will obtain (all fields from the
///     instantiated [klass] up to the [Object] klass).
class InstanceBuilder {
  /// The class of the new instance.
  final Class klass;

  /// The values of the type parameters of the new instance.
  final List<DartType> typeArguments;

  /// The field values of the new instance.
  final Map<Field, Constant> fields = <Field, Constant>{};

  InstanceBuilder(this.klass, this.typeArguments);

  void setFieldValue(Field field, Constant constant) {
    fields[field] = constant;
  }

  InstanceConstant buildInstance() {
    final Map<Reference, Constant> fieldValues = <Reference, Constant>{};
    fields.forEach((Field field, Constant value) {
      fieldValues[field.reference] = value;
    });
    return new InstanceConstant(klass.reference, typeArguments, fieldValues);
  }
}

/// Holds an environment of type parameters, parameters and variables.
class EvaluationEnvironment {
  /// The values of the type parameters in scope.
  final Map<TypeParameter, DartType> _typeVariables =
      <TypeParameter, DartType>{};

  /// The values of the parameters/variables in scope.
  final Map<VariableDeclaration, Constant> _variables =
      <VariableDeclaration, Constant>{};

  /// Whether the current environment is empty.
  bool get isEmpty => _typeVariables.isEmpty && _variables.isEmpty;

  void addTypeParameterValue(TypeParameter parameter, DartType value) {
    assert(!_typeVariables.containsKey(parameter));
    _typeVariables[parameter] = value;
  }

  void addVariableValue(VariableDeclaration variable, Constant value) {
    assert(!_variables.containsKey(variable));
    _variables[variable] = value;
  }

  DartType lookupParameterValue(TypeParameter parameter) {
    final DartType value = _typeVariables[parameter];
    assert(value != null);
    return value;
  }

  Constant lookupVariable(VariableDeclaration variable) {
    return _variables[variable];
  }

  DartType subsituteType(DartType type) {
    if (_typeVariables.isEmpty) return type;
    return substitute(type, _typeVariables);
  }
}

// Used as control-flow to abort the current evaluation.
class _AbortDueToError {
  final TreeNode node;
  final Message message;
  final List<LocatedMessage> context;

  _AbortDueToError(this.node, this.message, {this.context});
}

class _AbortDueToInvalidExpression {
  final TreeNode node;
  final String message;

  _AbortDueToInvalidExpression(this.node, this.message);
}

abstract class ErrorReporter {
  const ErrorReporter();

  void report(LocatedMessage message, List<LocatedMessage> context);

  void reportInvalidExpression(InvalidExpression node);
}

class SimpleErrorReporter implements ErrorReporter {
  const SimpleErrorReporter();

  @override
  void report(LocatedMessage message, List<LocatedMessage> context) {
    _report(message);
    for (LocatedMessage contextMessage in context) {
      _report(contextMessage);
    }
  }

  @override
  void reportInvalidExpression(InvalidExpression node) {
    // Ignored
  }

  void _report(LocatedMessage message) {
    reportMessage(message.uri, message.charOffset, message.message);
  }

  void reportMessage(Uri uri, int offset, String message) {
    io.exitCode = 42;
    io.stderr.writeln('$uri:$offset Constant evaluation error: $message');
  }
}

class IsInstantiatedVisitor extends DartTypeVisitor<bool> {
  final _availableVariables = new Set<TypeParameter>();

  bool isInstantiated(DartType type) {
    return type.accept(this);
  }

  bool defaultDartType(DartType node) {
    throw 'A visitor method seems to be unimplemented!';
  }

  bool visitInvalidType(InvalidType node) => true;
  bool visitDynamicType(DynamicType node) => true;
  bool visitVoidType(VoidType node) => true;
  bool visitBottomType(BottomType node) => true;

  bool visitTypeParameterType(TypeParameterType node) {
    return _availableVariables.contains(node.parameter);
  }

  bool visitInterfaceType(InterfaceType node) {
    return node.typeArguments
        .every((DartType typeArgument) => typeArgument.accept(this));
  }

  bool visitFunctionType(FunctionType node) {
    final parameters = node.typeParameters;
    _availableVariables.addAll(parameters);
    final bool result = node.returnType.accept(this) &&
        node.positionalParameters.every((p) => p.accept(this)) &&
        node.namedParameters.every((p) => p.type.accept(this));
    _availableVariables.removeAll(parameters);
    return result;
  }

  bool visitTypedefType(TypedefType node) {
    return node.unalias.accept(this);
  }
}

bool _isFormalParameter(VariableDeclaration variable) {
  final parent = variable.parent;
  if (parent is FunctionNode) {
    return parent.positionalParameters.contains(variable) ||
        parent.namedParameters.contains(variable);
  }
  return false;
}
