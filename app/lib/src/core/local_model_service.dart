import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'local_exception.dart';
import 'signature_preprocessor.dart';

class LocalModelOutput {
  final double probability;
  final double calibratedLogit;
  final double cosineSimilarity;

  const LocalModelOutput({
    required this.probability,
    required this.calibratedLogit,
    required this.cosineSimilarity,
  });
}

class LocalSignatureModelService {
  LocalSignatureModelService._();

  static final instance = LocalSignatureModelService._();

  static const String modelArchiveAsset =
      'assets/model_bundle/GLOBAL_SIGNATURE_STRONG_V2_DEPLOYMENT.zip';

  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _session;
  Future<void>? _loadingFuture;
  Map<String, dynamic> _config = const {};
  String? _error;

  bool get ready => _session != null;
  String? get error => _error;

  Map<String, double> get thresholds {
    final raw = _config['thresholds'];
    final values = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};

    return {
      'balanced': _asDouble(
        values['balanced_eer_threshold'] ??
            values['eer_threshold'] ??
            _config['balanced_threshold'] ??
            _config['decision_threshold'],
        0.5623770426981638,
      ),
      'secure': _asDouble(
        values['secure_threshold'] ?? _config['secure_threshold'],
        0.840702876906377,
      ),
    };
  }

  Future<void> ensureLoaded() {
    if (_session != null) return Future.value();
    return _loadingFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final runtimeRoot = await getApplicationSupportDirectory();
      final modelDirectory = Directory(
        path.join(runtimeRoot.path, 'signatrust_ai_model'),
      );
      await modelDirectory.create(recursive: true);

      final onnxFile = File(
        path.join(modelDirectory.path, 'global_signature_strong_v2.onnx'),
      );
      final configFile = File(
        path.join(modelDirectory.path, 'model_config.json'),
      );

      if (!await onnxFile.exists() || !await configFile.exists()) {
        await _extractModelBundle(
          onnxDestination: onnxFile,
          configDestination: configFile,
        );
      }

      _config = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      _session = await _runtime.createSession(onnxFile.path);

      final inputs = _session!.inputNames.toSet();
      if (!inputs.contains('reference_sequences') ||
          !inputs.contains('query_sequence')) {
        throw LocalAppException(
          'The local AI model has unexpected input names: ${_session!.inputNames.join(', ')}',
        );
      }

      await _runProbe();
      _error = null;
    } catch (error) {
      _session = null;
      _error = _friendlyLoadError(error);
      _loadingFuture = null;
      throw LocalAppException(_error!);
    }
  }

  Future<void> _extractModelBundle({
    required File onnxDestination,
    required File configDestination,
  }) async {
    ByteData assetData;
    try {
      assetData = await rootBundle.load(modelArchiveAsset);
    } catch (_) {
      throw const LocalAppException(
        'The AI model bundle is missing. Add GLOBAL_SIGNATURE_STRONG_V2_DEPLOYMENT.zip to assets/model_bundle and rebuild the app.',
      );
    }

    final bytes = assetData.buffer.asUint8List(
      assetData.offsetInBytes,
      assetData.lengthInBytes,
    );
    final bundle = ZipDecoder().decodeBytes(bytes);

    ArchiveFile? onnxEntry;
    ArchiveFile? configEntry;

    for (final entry in bundle) {
      if (!entry.isFile) continue;
      final normalized = entry.name.replaceAll('\\', '/').toLowerCase();
      if (normalized.endsWith('global_signature_strong_v2.onnx')) {
        onnxEntry = entry;
      } else if (normalized.endsWith('model_config.json')) {
        configEntry = entry;
      }
    }

    if (onnxEntry == null || configEntry == null) {
      throw const LocalAppException(
        'The model bundle does not contain the required ONNX model and model_config.json files.',
      );
    }

    await onnxDestination.parent.create(recursive: true);
    await onnxDestination.writeAsBytes(
      onnxEntry.readBytes()!,
      flush: true,
    );
    await configDestination.writeAsBytes(
      configEntry.readBytes()!,
      flush: true,
    );
  }

  Future<void> _runProbe() async {
    final references = Float32List(1 * 5 * 192 * 37);
    final query = Float32List(1 * 192 * 37);

    final referenceTensor = await OrtValue.fromList(
      references,
      const [1, 5, 192, 37],
    );
    final queryTensor = await OrtValue.fromList(
      query,
      const [1, 192, 37],
    );

    Map<String, OrtValue>? outputs;
    try {
      outputs = await _session!.run({
        'reference_sequences': referenceTensor,
        'query_sequence': queryTensor,
      });
      final outputName = _session!.outputNames.first;
      final values = _flattenNumbers(await outputs[outputName]!.asList());
      if (values.length < 3 || values.take(3).any((value) => !value.isFinite)) {
        throw const LocalAppException(
          'The local AI model returned an invalid output.',
        );
      }
    } finally {
      await referenceTensor.dispose();
      await queryTensor.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  Future<LocalModelOutput> verify({
    required List<List<List<double>>> references,
    required List<List<double>> query,
  }) async {
    await ensureLoaded();

    if (references.length != 5 ||
        references.any(
          (sequence) =>
              sequence.length != SignaturePreprocessor.sequenceLength ||
              sequence.any(
                (row) => row.length != SignaturePreprocessor.inputFeatures,
              ),
        )) {
      throw const LocalAppException(
        'Exactly five valid reference signatures are required.',
      );
    }

    if (query.length != SignaturePreprocessor.sequenceLength ||
        query.any(
          (row) => row.length != SignaturePreprocessor.inputFeatures,
        )) {
      throw const LocalAppException('The captured signature data is invalid.');
    }

    final flattenedReferences = Float32List.fromList(<double>[
      for (final sequence in references)
        for (final row in sequence) ...row,
    ]);
    final flattenedQuery = Float32List.fromList(
      SignaturePreprocessor.flattenSequence(query),
    );

    final referenceTensor = await OrtValue.fromList(
      flattenedReferences,
      const [1, 5, 192, 37],
    );
    final queryTensor = await OrtValue.fromList(
      flattenedQuery,
      const [1, 192, 37],
    );

    Map<String, OrtValue>? outputs;
    try {
      outputs = await _session!.run({
        'reference_sequences': referenceTensor,
        'query_sequence': queryTensor,
      });

      final outputName = _session!.outputNames.first;
      final values = _flattenNumbers(await outputs[outputName]!.asList());
      if (values.length < 3) {
        throw const LocalAppException(
          'The local AI model returned an unexpected result.',
        );
      }

      return LocalModelOutput(
        probability: values[0],
        calibratedLogit: values[1],
        cosineSimilarity: values[2],
      );
    } catch (error) {
      if (error is LocalAppException) rethrow;
      throw const LocalAppException(
        'Local signature analysis could not be completed.',
      );
    } finally {
      await referenceTensor.dispose();
      await queryTensor.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  List<double> _flattenNumbers(dynamic value) {
    final output = <double>[];

    void visit(dynamic item) {
      if (item is num) {
        output.add(item.toDouble());
      } else if (item is Iterable) {
        for (final child in item) {
          visit(child);
        }
      }
    }

    visit(value);
    return output;
  }

  double _asDouble(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  String _friendlyLoadError(Object error) {
    if (error is LocalAppException) return error.message;
    return 'The local AI model could not be loaded.';
  }
}
