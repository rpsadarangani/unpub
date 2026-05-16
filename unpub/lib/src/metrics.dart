/// Tiny Prometheus exposition-format metrics. No external deps — just the
/// pieces unpub needs: counters, histograms, gauges, plus a registry that
/// renders to text/plain over HTTP.
///
/// Histogram buckets follow the Prometheus convention (seconds-friendly).

class Metrics {
  final List<_Metric> _series = [];

  Counter counter({
    required String name,
    required String help,
    List<String> labelNames = const [],
  }) {
    final c = Counter._(name, help, labelNames);
    _series.add(c);
    return c;
  }

  Histogram histogram({
    required String name,
    required String help,
    List<String> labelNames = const [],
    List<double>? buckets,
  }) {
    final h = Histogram._(
      name,
      help,
      labelNames,
      buckets ?? _defaultBuckets,
    );
    _series.add(h);
    return h;
  }

  Gauge gauge({
    required String name,
    required String help,
    List<String> labelNames = const [],
  }) {
    final g = Gauge._(name, help, labelNames);
    _series.add(g);
    return g;
  }

  /// Render all collected series to Prometheus text format.
  String render() {
    final buf = StringBuffer();
    for (final s in _series) {
      s._write(buf);
    }
    return buf.toString();
  }

  static const List<double> _defaultBuckets = [
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10
  ];
}

abstract class _Metric {
  final String name;
  final String help;
  final List<String> labelNames;

  _Metric(this.name, this.help, this.labelNames);

  String get type;

  void _write(StringBuffer buf) {
    buf.writeln('# HELP $name $help');
    buf.writeln('# TYPE $name $type');
    _writeSamples(buf);
  }

  void _writeSamples(StringBuffer buf);

  String _formatLabels(List<String> values, {Map<String, String>? extra}) {
    final parts = <String>[];
    for (var i = 0; i < labelNames.length; i++) {
      parts.add('${labelNames[i]}="${_escape(values[i])}"');
    }
    if (extra != null) {
      extra.forEach((k, v) => parts.add('$k="${_escape(v)}"'));
    }
    if (parts.isEmpty) return '';
    return '{${parts.join(',')}}';
  }

  static String _escape(String v) =>
      v.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n');

  static String _labelKey(List<String> values) => values.join('');
}

class Counter extends _Metric {
  final Map<String, _LabeledCounter> _values = {};

  Counter._(super.name, super.help, super.labelNames);

  @override
  String get type => 'counter';

  void inc([List<String> labelValues = const [], double by = 1]) {
    _check(labelValues);
    final key = _Metric._labelKey(labelValues);
    final node = _values.putIfAbsent(
        key, () => _LabeledCounter(labelValues));
    node.value += by;
  }

  void _check(List<String> labelValues) {
    if (labelValues.length != labelNames.length) {
      throw ArgumentError(
          'Counter $name expects ${labelNames.length} labels, got ${labelValues.length}');
    }
  }

  @override
  void _writeSamples(StringBuffer buf) {
    if (_values.isEmpty && labelNames.isEmpty) {
      buf.writeln('$name 0');
      return;
    }
    for (final node in _values.values) {
      buf.writeln('$name${_formatLabels(node.labels)} ${_fmt(node.value)}');
    }
  }
}

class Gauge extends _Metric {
  final Map<String, _LabeledCounter> _values = {};

  Gauge._(super.name, super.help, super.labelNames);

  @override
  String get type => 'gauge';

  void set(double value, [List<String> labelValues = const []]) {
    _check(labelValues);
    final key = _Metric._labelKey(labelValues);
    _values.update(
      key,
      (node) => node..value = value,
      ifAbsent: () => _LabeledCounter(labelValues)..value = value,
    );
  }

  void inc([List<String> labelValues = const [], double by = 1]) {
    _check(labelValues);
    final key = _Metric._labelKey(labelValues);
    final node = _values.putIfAbsent(key, () => _LabeledCounter(labelValues));
    node.value += by;
  }

  void dec([List<String> labelValues = const [], double by = 1]) =>
      inc(labelValues, -by);

  void _check(List<String> labelValues) {
    if (labelValues.length != labelNames.length) {
      throw ArgumentError(
          'Gauge $name expects ${labelNames.length} labels, got ${labelValues.length}');
    }
  }

  @override
  void _writeSamples(StringBuffer buf) {
    if (_values.isEmpty && labelNames.isEmpty) {
      buf.writeln('$name 0');
      return;
    }
    for (final node in _values.values) {
      buf.writeln('$name${_formatLabels(node.labels)} ${_fmt(node.value)}');
    }
  }
}

class Histogram extends _Metric {
  final List<double> buckets;
  final Map<String, _HistogramSeries> _values = {};

  Histogram._(super.name, super.help, super.labelNames, this.buckets);

  @override
  String get type => 'histogram';

  void observe(double seconds, [List<String> labelValues = const []]) {
    if (labelValues.length != labelNames.length) {
      throw ArgumentError(
          'Histogram $name expects ${labelNames.length} labels, got ${labelValues.length}');
    }
    final key = _Metric._labelKey(labelValues);
    final node = _values.putIfAbsent(
        key, () => _HistogramSeries(labelValues, buckets.length));
    node.sum += seconds;
    node.count += 1;
    for (var i = 0; i < buckets.length; i++) {
      if (seconds <= buckets[i]) node.bucketCounts[i] += 1;
    }
  }

  /// Convenience: time an async operation and record duration in seconds.
  Future<T> time<T>(
    Future<T> Function() body, [
    List<String> labelValues = const [],
  ]) async {
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      observe(sw.elapsedMicroseconds / 1e6, labelValues);
    }
  }

  @override
  void _writeSamples(StringBuffer buf) {
    for (final node in _values.values) {
      // bucketCounts[i] already stores the cumulative number of observations
      // with value <= buckets[i] (each `observe` increments every bucket it
      // fits), so emit them directly.
      for (var i = 0; i < buckets.length; i++) {
        buf.writeln(
            '${name}_bucket${_formatLabels(node.labels, extra: {'le': _fmt(buckets[i])})} ${node.bucketCounts[i]}');
      }
      buf.writeln(
          '${name}_bucket${_formatLabels(node.labels, extra: {'le': '+Inf'})} ${node.count}');
      buf.writeln('${name}_sum${_formatLabels(node.labels)} ${_fmt(node.sum)}');
      buf.writeln('${name}_count${_formatLabels(node.labels)} ${node.count}');
    }
  }
}

class _LabeledCounter {
  final List<String> labels;
  double value = 0;
  _LabeledCounter(this.labels);
}

class _HistogramSeries {
  final List<String> labels;
  final List<int> bucketCounts;
  double sum = 0;
  int count = 0;
  _HistogramSeries(this.labels, int n) : bucketCounts = List.filled(n, 0);
}

String _fmt(double v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v.isNegative ? '-Inf' : '+Inf';
  if (v == v.roundToDouble() && v.abs() < 1e16) {
    return v.toInt().toString();
  }
  return v.toStringAsFixed(6);
}
