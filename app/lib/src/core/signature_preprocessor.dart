import 'dart:math' as math;

class SignatureFeatureResult {
  final List<List<double>> sequence;
  final double qualityScore;

  const SignatureFeatureResult({
    required this.sequence,
    required this.qualityScore,
  });
}

class SignaturePreprocessor {
  static const int sequenceLength = 192;
  static const int baseFeatures = 16;
  static const int inputFeatures = 37;

  static SignatureFeatureResult preprocess(Map<String, dynamic> sample) {
    final rawPoints = sample['points'];
    if (rawPoints is! List || rawPoints.length < 12) {
      throw const FormatException(
        'A signature requires at least 12 captured points.',
      );
    }

    final points = rawPoints
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);

    final canvasWidth = _number(sample['canvas_width']);
    final canvasHeight = _number(sample['canvas_height']);
    if (canvasWidth <= 0 || canvasHeight <= 0) {
      throw const FormatException('The signature canvas size is invalid.');
    }

    final rawX = <double>[];
    final rawY = <double>[];
    final timestamps = <double>[];
    final pressureRaw = <double>[];
    final touchRaw = <double>[];
    final pointerTypes = <String>{};

    for (final point in points) {
      rawX.add(_number(point['x']) / canvasWidth);
      rawY.add(_number(point['y']) / canvasHeight);
      timestamps.add(_number(point['timestamp_ms']));
      pressureRaw.add(_number(point['pressure']));
      touchRaw.add(_number(point['touch_area']));
      pointerTypes.add(
        (point['pointer_type']?.toString() ?? 'touch').toLowerCase(),
      );
    }

    final x = _robustScale(rawX);
    final y = _robustScale(rawY);

    final dt = List<double>.filled(points.length, 0.0);
    for (var index = 1; index < timestamps.length; index++) {
      dt[index] = timestamps[index] - timestamps[index - 1];
    }

    final positiveDt = dt.where((value) => value > 0).toList(growable: false);
    final replacement = positiveDt.isEmpty ? 10.0 : _percentile(positiveDt, 0.5);
    for (var index = 0; index < dt.length; index++) {
      if (dt[index] <= 0 || !dt[index].isFinite) {
        dt[index] = replacement;
      }
    }

    final dx = List<double>.filled(points.length, 0.0);
    final dy = List<double>.filled(points.length, 0.0);
    for (var index = 1; index < points.length; index++) {
      dx[index] = x[index] - x[index - 1];
      dy[index] = y[index] - y[index - 1];
    }

    final speed = List<double>.filled(points.length, 0.0);
    final acceleration = List<double>.filled(points.length, 0.0);
    final direction = List<double>.filled(points.length, 0.0);

    for (var index = 0; index < points.length; index++) {
      final safeDt = math.max(dt[index].abs(), 1e-6);
      speed[index] = math.sqrt(dx[index] * dx[index] + dy[index] * dy[index]) / safeDt;
      direction[index] = math.atan2(dy[index], dx[index]);
    }

    for (var index = 1; index < points.length; index++) {
      final safeDt = math.max(dt[index].abs(), 1e-6);
      acceleration[index] = (speed[index] - speed[index - 1]) / safeDt;
    }

    final features = List<List<double>>.generate(
      points.length,
      (_) => List<double>.filled(baseFeatures, 0.0),
    );
    final masks = List<List<double>>.generate(
      points.length,
      (_) => List<double>.filled(baseFeatures, 0.0),
    );

    void populate(int featureIndex, List<double> values) {
      for (var row = 0; row < points.length; row++) {
        features[row][featureIndex] = values[row];
        masks[row][featureIndex] = 1.0;
      }
    }

    populate(0, x);
    populate(1, y);
    populate(2, _robustScale(dt));
    populate(5, _robustScale(dx));
    populate(6, _robustScale(dy));
    populate(7, _robustScale(speed));
    populate(8, _robustScale(acceleration));
    populate(9, direction.map(math.sin).toList(growable: false));
    populate(10, direction.map(math.cos).toList(growable: false));

    final pressureAvailable =
        _standardDeviation(pressureRaw) > 1e-6 || _maximum(pressureRaw) > 0.05;
    final touchAvailable =
        _standardDeviation(touchRaw) > 1e-6 || _maximum(touchRaw) > 0.0;

    if (pressureAvailable) {
      populate(3, _minMax01(pressureRaw));
    }
    if (touchAvailable) {
      populate(4, _minMax01(touchRaw));
    }

    final finger = pointerTypes.any((value) => value == 'touch' || value == 'finger')
        ? 1.0
        : 0.0;
    final stylus = pointerTypes.contains('stylus') ? 1.0 : 0.0;
    final samplingRate = _number(sample['sampling_rate'], fallback: 100.0);
    final session = _number(sample['session']);

    final metadata = <double>[
      finger,
      stylus,
      pressureAvailable ? 1.0 : 0.0,
      math.min(samplingRate / 250.0, 2.0),
      math.min(session / 5.0, 1.0),
    ];

    final combined = List<List<double>>.generate(points.length, (row) {
      return <double>[
        ...features[row],
        ...masks[row],
        ...metadata,
      ];
    });

    final sequence = _resample(combined, sequenceLength);

    final durationMs = math.max(timestamps.last - timestamps.first, 1.0);
    var pathLength = 0.0;
    for (var index = 1; index < points.length; index++) {
      final deltaX = rawX[index] - rawX[index - 1];
      final deltaY = rawY[index] - rawY[index - 1];
      pathLength += math.sqrt(deltaX * deltaX + deltaY * deltaY);
    }

    final pointComponent = math.min(points.length / 120.0, 1.0);
    final durationComponent = durationMs <= 10000
        ? math.min(durationMs / 1200.0, 1.0)
        : 0.5;
    final pathComponent = math.min(pathLength / 1.2, 1.0);
    final quality = (0.35 * pointComponent +
            0.35 * durationComponent +
            0.30 * pathComponent)
        .clamp(0.0, 1.0)
        .toDouble();

    return SignatureFeatureResult(
      sequence: sequence,
      qualityScore: quality,
    );
  }

  static List<double> flattenSequence(List<List<double>> sequence) {
    return [for (final row in sequence) ...row];
  }

  static List<double> _robustScale(List<double> input) {
    final finite = input.where((value) => value.isFinite).toList(growable: false);
    if (finite.isEmpty) return List<double>.filled(input.length, 0.0);

    final median = _percentile(finite, 0.5);
    final q1 = _percentile(finite, 0.25);
    final q3 = _percentile(finite, 0.75);
    final scale = math.max(q3 - q1, 1e-6);

    return input.map((value) {
      final clean = value.isFinite ? value : median;
      return ((clean - median) / scale).clamp(-8.0, 8.0).toDouble();
    }).toList(growable: false);
  }

  static List<double> _minMax01(List<double> input) {
    final clean = input
        .map((value) => value.isFinite ? value : 0.0)
        .toList(growable: false);
    if (clean.isEmpty) return const <double>[];

    final low = clean.length > 4 ? _percentile(clean, 0.01) : _minimum(clean);
    final high = clean.length > 4 ? _percentile(clean, 0.99) : _maximum(clean);
    if (high <= low + 1e-8) return List<double>.filled(clean.length, 0.0);

    return clean
        .map((value) => ((value - low) / (high - low)).clamp(0.0, 1.0).toDouble())
        .toList(growable: false);
  }

  static List<List<double>> _resample(
    List<List<double>> features,
    int length,
  ) {
    if (features.length == length) {
      return features
          .map((row) => List<double>.from(row, growable: false))
          .toList(growable: false);
    }

    final sourceLength = features.length;
    final featureCount = features.first.length;
    final output = List<List<double>>.generate(
      length,
      (_) => List<double>.filled(featureCount, 0.0),
    );

    for (var targetIndex = 0; targetIndex < length; targetIndex++) {
      final sourcePosition = length == 1
          ? 0.0
          : targetIndex * (sourceLength - 1) / (length - 1);
      final left = sourcePosition.floor();
      final right = math.min(left + 1, sourceLength - 1);
      final weight = sourcePosition - left;

      for (var featureIndex = 0; featureIndex < featureCount; featureIndex++) {
        final leftValue = features[left][featureIndex];
        final rightValue = features[right][featureIndex];
        output[targetIndex][featureIndex] =
            leftValue + (rightValue - leftValue) * weight;
      }
    }

    return output;
  }

  static double _percentile(List<double> values, double fraction) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.from(values)..sort();
    if (sorted.length == 1) return sorted.first;

    final position = (sorted.length - 1) * fraction;
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];

    final weight = position - lower;
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight;
  }

  static double _standardDeviation(List<double> values) {
    if (values.isEmpty) return 0.0;
    final mean = values.fold<double>(0.0, (sum, value) => sum + value) / values.length;
    var variance = 0.0;
    for (final value in values) {
      final delta = value - mean;
      variance += delta * delta;
    }
    return math.sqrt(variance / values.length);
  }

  static double _minimum(List<double> values) {
    if (values.isEmpty) return 0.0;
    var result = values.first;
    for (final value in values.skip(1)) {
      if (value < result) result = value;
    }
    return result;
  }

  static double _maximum(List<double> values) {
    if (values.isEmpty) return 0.0;
    var result = values.first;
    for (final value in values.skip(1)) {
      if (value > result) result = value;
    }
    return result;
  }

  static double _number(dynamic value, {double fallback = 0.0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
