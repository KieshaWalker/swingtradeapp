// =============================================================================
// services/math/nelder_mead.dart
// =============================================================================
// Derivative-free Nelder-Mead simplex optimizer.
//
// Usage:
//   final result = NelderMead.minimize(
//     objective: (x) => (x[0] - 3).pow(2) + (x[1] + 1).pow(2),
//     initial:   [0.0, 0.0],
//     bounds:    [(-10.0, 10.0), (-10.0, 10.0)],  // optional box constraints
//   );
//   print(result.x);  // [3.0, -1.0]
//
// Parameters follow Gao & Han (2012) recommendations:
//   α = 1.0  (reflection)
//   γ = 2.0  (expansion)
//   ρ = 0.5  (contraction)
//   σ = 0.5  (shrink)
// =============================================================================

/// Result of a Nelder-Mead minimization.
class NmResult {
  /// Best parameter vector found.
  final List<double> x;

  /// Objective function value at [x].
  final double fValue;

  /// Number of function evaluations used.
  final int iterations;

  /// Whether the optimizer converged within tolerance.
  final bool converged;

  const NmResult({
    required this.x,
    required this.fValue,
    required this.iterations,
    required this.converged,
  });
}

class NelderMead {
  NelderMead._();

  static const double _alpha = 1.0; // reflection
  static const double _gamma = 2.0; // expansion
  static const double _rho   = 0.5; // contraction
  static const double _sigma = 0.5; // shrink

  /// Minimize [objective] starting from [initial].
  ///
  /// [bounds] — optional list of (min, max) pairs, one per parameter.
  ///   Parameters are clamped to bounds after every step.
  ///   Pass null entries for unconstrained parameters.
  ///
  /// [maxIter]   — maximum function evaluations (default 2000).
  /// [xTol]      — convergence tolerance on parameter change (default 1e-7).
  /// [fTol]      — convergence tolerance on function value change (default 1e-7).
  /// [stepSize]  — initial simplex step size (default 0.05, or 0.00025 if initial=0).
  static NmResult minimize({
    required double Function(List<double> x) objective,
    required List<double> initial,
    List<(double, double)?>? bounds,
    int    maxIter  = 2000,
    double xTol     = 1e-7,
    double fTol     = 1e-7,
    double stepSize = 0.05,
  }) {
    final n = initial.length;

    // ── Build initial simplex ─────────────────────────────────────────────────
    // n+1 vertices; vertex 0 = initial, vertices 1..n perturb one coordinate.
    final simplex = List.generate(n + 1, (i) {
      final v = List<double>.from(initial);
      if (i > 0) {
        final d = v[i - 1].abs() < 1e-10 ? 0.00025 : stepSize * v[i - 1].abs();
        v[i - 1] += d;
      }
      return _clamp(v, bounds);
    });

    var fSimplex = simplex.map(objective).toList();
    var evals = n + 1;

    for (var iter = 0; iter < maxIter; iter++) {
      // ── Sort: best (lowest f) first ──────────────────────────────────────
      final order = List.generate(n + 1, (i) => i)
        ..sort((a, b) => fSimplex[a].compareTo(fSimplex[b]));

      final sorted   = order.map((i) => simplex[i]).toList();
      final fSorted  = order.map((i) => fSimplex[i]).toList();

      // ── Convergence check ─────────────────────────────────────────────────
      final fRange = fSorted.last - fSorted.first;
      double xRange = 0;
      for (var j = 1; j <= n; j++) {
        for (var k = 0; k < n; k++) {
          xRange = xRange > (sorted[j][k] - sorted[0][k]).abs()
              ? xRange
              : (sorted[j][k] - sorted[0][k]).abs();
        }
      }
      if (fRange < fTol && xRange < xTol) {
        return NmResult(
          x:          sorted[0],
          fValue:     fSorted[0],
          iterations: evals,
          converged:  true,
        );
      }

      // ── Centroid of all but worst ─────────────────────────────────────────
      final centroid = List<double>.filled(n, 0);
      for (var j = 0; j < n; j++) {
        for (var k = 0; k < n; k++) {
          centroid[k] += sorted[j][k] / n;
        }
      }

      final worst  = sorted[n];
      final fWorst = fSorted[n];
      final best   = sorted[0];
      final fBest  = fSorted[0];
      final fSecondWorst = fSorted[n - 1];

      // ── Reflection ────────────────────────────────────────────────────────
      final reflected = _clamp(
          _add(centroid, _scale(_sub(centroid, worst), _alpha)), bounds);
      final fReflected = objective(reflected);
      evals++;

      if (fReflected >= fBest && fReflected < fSecondWorst) {
        // Accept reflection
        sorted[n]  = reflected;
        fSorted[n] = fReflected;
        _updateSimplex(simplex, fSimplex, sorted, fSorted, order);
        continue;
      }

      if (fReflected < fBest) {
        // ── Expansion ──────────────────────────────────────────────────────
        final expanded = _clamp(
            _add(centroid, _scale(_sub(reflected, centroid), _gamma)), bounds);
        final fExpanded = objective(expanded);
        evals++;
        if (fExpanded < fReflected) {
          sorted[n]  = expanded;
          fSorted[n] = fExpanded;
        } else {
          sorted[n]  = reflected;
          fSorted[n] = fReflected;
        }
        _updateSimplex(simplex, fSimplex, sorted, fSorted, order);
        continue;
      }

      // ── Contraction ───────────────────────────────────────────────────────
      if (fReflected < fWorst) {
        // Outside contraction
        final contracted = _clamp(
            _add(centroid, _scale(_sub(reflected, centroid), _rho)), bounds);
        final fContracted = objective(contracted);
        evals++;
        if (fContracted <= fReflected) {
          sorted[n]  = contracted;
          fSorted[n] = fContracted;
          _updateSimplex(simplex, fSimplex, sorted, fSorted, order);
          continue;
        }
      } else {
        // Inside contraction
        final contracted = _clamp(
            _add(centroid, _scale(_sub(worst, centroid), _rho)), bounds);
        final fContracted = objective(contracted);
        evals++;
        if (fContracted < fWorst) {
          sorted[n]  = contracted;
          fSorted[n] = fContracted;
          _updateSimplex(simplex, fSimplex, sorted, fSorted, order);
          continue;
        }
      }

      // ── Shrink ────────────────────────────────────────────────────────────
      for (var j = 1; j <= n; j++) {
        sorted[j] = _clamp(
            _add(best, _scale(_sub(sorted[j], best), _sigma)), bounds);
        fSorted[j] = objective(sorted[j]);
        evals++;
      }
      _updateSimplex(simplex, fSimplex, sorted, fSorted, order);
    }

    // Max iterations reached — return best found
    final order = List.generate(n + 1, (i) => i)
      ..sort((a, b) => fSimplex[a].compareTo(fSimplex[b]));
    return NmResult(
      x:          simplex[order[0]],
      fValue:     fSimplex[order[0]],
      iterations: evals,
      converged:  false,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static void _updateSimplex(
    List<List<double>> simplex,
    List<double>       fSimplex,
    List<List<double>> sorted,
    List<double>       fSorted,
    List<int>          order,
  ) {
    for (var i = 0; i <= order.length - 1; i++) {
      simplex[order[i]]  = sorted[i];
      fSimplex[order[i]] = fSorted[i];
    }
  }

  static List<double> _add(List<double> a, List<double> b) =>
      List.generate(a.length, (i) => a[i] + b[i]);

  static List<double> _sub(List<double> a, List<double> b) =>
      List.generate(a.length, (i) => a[i] - b[i]);

  static List<double> _scale(List<double> a, double s) =>
      a.map((v) => v * s).toList();

  static List<double> _clamp(List<double> x, List<(double, double)?>? bounds) {
    if (bounds == null) return x;
    return List.generate(x.length, (i) {
      final b = bounds[i];
      if (b == null) return x[i];
      return x[i].clamp(b.$1, b.$2);
    });
  }
}
