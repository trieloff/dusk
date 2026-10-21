import Foundation

/// One training example: the features at some moment, and whether the user
/// wanted dark mode then.
public struct Example: Sendable {
    public var time: Date
    public var features: [String: Double]
    public var dark: Bool
    /// 1 for a confirmed manual correction; small for an "accepted" moment
    /// (nobody complained), which is weaker evidence.
    public var weight: Double
    public var isCorrection: Bool { weight >= 1 }

    public init(time: Date, features: [String: Double], dark: Bool, weight: Double) {
        self.time = time
        self.features = features
        self.dark = dark
        self.weight = weight
    }
}

/// A logistic model over one or two features. Small on purpose: with a handful
/// of corrections, anything bigger would memorise them.
public struct Model: Codable, Sendable, Equatable {
    public var features: [String]
    public var mean: [Double]
    public var scale: [Double]
    public var weights: [Double]
    public var bias: Double
    // How it was chosen.
    public var corrections: Int
    public var examples: Int
    /// Cross-validated accuracy on the corrections alone.
    public var correctionAccuracy: Double
    /// Cross-validated weighted log-loss over all examples (lower is better).
    public var loss: Double
    public var trainedAt: Date

    public func probabilityDark(_ f: [String: Double]) -> Double? {
        var z = bias
        for (i, name) in features.enumerated() {
            guard let x = f[name] else { return nil }
            z += weights[i] * (x - mean[i]) / scale[i]
        }
        return sigmoid(z)
    }

    /// For one-feature models: the value where the model is undecided.
    public var threshold: Double? {
        guard features.count == 1, weights[0] != 0 else { return nil }
        return mean[0] - bias * scale[0] / weights[0]
    }

    public var summary: String {
        if let t = threshold {
            return "dark when \(Self.label(features[0])) \(weights[0] < 0 ? "<" : ">") \(Self.value(features[0], t))"
        }
        let parts = features.enumerated().map { i, n in "\(Self.label(n)) \(weights[i] < 0 ? "↓" : "↑")" }
        return "dark from " + parts.joined(separator: " and ")
    }

    static func label(_ name: String) -> String {
        name.hasPrefix("log ") ? String(name.dropFirst(4)) : name
    }

    static func value(_ name: String, _ v: Double) -> String {
        if name.hasPrefix("log ") {
            let x = pow(10, v) - 0.1
            let unit = name.contains("irradiance") || name.contains("diffuse") ? "W/m²" : "lx"
            return (x < 10 ? String(format: "%.1f", x) : String(format: "%.0f", x)) + " " + unit
        }
        if name.contains("elevation") { return String(format: "%.1f°", v) }
        if name.contains("minutes") { return String(format: "%.0f min", v) }
        if name.contains("kelvin") { return String(format: "%.0f K", v) }
        return String(format: "%.2f", v)
    }
}

public enum Trainer {
    /// Picks the feature (or pair) that best predicts the user's choices, by
    /// k-fold cross-validated log-loss; a pair must beat the best single
    /// feature by 5%. Returns nil until there is something to
    /// learn from: a correction, and both appearances among the examples.
    public static func train(_ examples: [Example], now: Date = Date(),
                             maxFeatures: Int = 2, folds: Int = 5) -> Model? {
        let corrections = examples.filter(\.isCorrection)
        guard !corrections.isEmpty,
              examples.contains(where: \.dark), examples.contains(where: { !$0.dark })
        else { return nil }

        // Candidate features: present in every correction, and varying.
        var names = Set(corrections[0].features.keys)
        for c in corrections.dropFirst() { names.formIntersection(c.features.keys) }
        let usable = names.sorted().filter { n in
            let xs = examples.compactMap { $0.features[n] }
            guard let lo = xs.min(), let hi = xs.max() else { return false }
            return hi - lo > 1e-9
        }
        var candidates: [[String]] = usable.map { [$0] }
        if maxFeatures >= 2 {
            for i in usable.indices {
                for j in usable.indices where j > i { candidates.append([usable[i], usable[j]]) }
            }
        }

        var best: [Int: (model: Model, loss: Double)] = [:]  // by feature count
        for set in candidates {
            let rows = examples.filter { e in set.allSatisfy { e.features[$0] != nil } }
            guard rows.contains(where: \.dark), rows.contains(where: { !$0.dark }) else { continue }
            let cv = crossValidate(rows, features: set, folds: folds)
            guard best[set.count].map({ cv.loss < $0.loss }) ?? true else { continue }
            var m = fit(rows, features: set)
            m.corrections = rows.filter(\.isCorrection).count
            m.examples = rows.count
            m.correctionAccuracy = cv.correctionAccuracy
            m.loss = cv.loss
            m.trainedAt = now
            best[set.count] = (m, cv.loss)
        }
        // A pair has to earn its place: clearly lower loss than the best single
        // feature, not a rounding error's worth that noise can fake.
        guard let single = best[1] else { return best[2]?.model }
        if let pair = best[2], pair.loss < single.loss * 0.95 - 0.005 { return pair.model }
        return single.model
    }

    struct CV { var loss: Double; var correctionAccuracy: Double }

    static func crossValidate(_ rows: [Example], features: [String], folds: Int) -> CV {
        let k = max(2, min(folds, rows.count))
        var loss = 0.0, weight = 0.0, hits = 0.0, corrections = 0.0
        for fold in 0..<k {
            let train = rows.enumerated().filter { $0.offset % k != fold }.map(\.element)
            let test = rows.enumerated().filter { $0.offset % k == fold }.map(\.element)
            guard !test.isEmpty, !train.isEmpty else { continue }
            let m = fit(train, features: features)
            for e in test {
                guard let p = m.probabilityDark(e.features) else { continue }
                let q = min(max(p, 1e-6), 1 - 1e-6)
                loss += -e.weight * (e.dark ? log(q) : log(1 - q))
                weight += e.weight
                if e.isCorrection {
                    corrections += 1
                    if (p >= 0.5) == e.dark { hits += 1 }
                }
            }
        }
        return CV(loss: weight > 0 ? loss / weight : .infinity,
                  correctionAccuracy: corrections > 0 ? hits / corrections : 0)
    }

    /// Weighted, L2-regularised logistic regression on standardised features,
    /// fitted by Newton's method (two or three parameters, so it is exact and fast).
    static func fit(_ rows: [Example], features: [String], lambda: Double = 0.5) -> Model {
        let n = features.count
        var mean = [Double](repeating: 0, count: n), scale = [Double](repeating: 1, count: n)
        let total = rows.reduce(0) { $0 + $1.weight }
        for (i, name) in features.enumerated() {
            let xs = rows.map { ($0.features[name]!, $0.weight) }
            let m = xs.reduce(0) { $0 + $1.0 * $1.1 } / total
            let v = xs.reduce(0) { $0 + $1.1 * pow($1.0 - m, 2) } / total
            mean[i] = m
            scale[i] = v > 1e-12 ? sqrt(v) : 1
        }
        let x = rows.map { r in features.enumerated().map { (r.features[$1]! - mean[$0]) / scale[$0] } }
        // theta = [bias, w...]
        var theta = [Double](repeating: 0, count: n + 1)
        for _ in 0..<25 {
            var g = [Double](repeating: 0, count: n + 1)
            var h = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
            for (r, row) in rows.enumerated() {
                let xi = [1.0] + x[r]
                let p = sigmoid(zip(theta, xi).reduce(0) { $0 + $1.0 * $1.1 })
                let y = row.dark ? 1.0 : 0.0
                for a in 0...n {
                    g[a] += row.weight * (p - y) * xi[a]
                    for b in 0...n { h[a][b] += row.weight * p * (1 - p) * xi[a] * xi[b] }
                }
            }
            for a in 1...n {  // do not regularise the bias
                g[a] += lambda * theta[a]
                h[a][a] += lambda
            }
            h[0][0] += 1e-6
            guard let step = solve(h, g) else { break }
            for a in 0...n { theta[a] -= step[a] }
            if step.map(abs).max() ?? 0 < 1e-8 { break }
        }
        return Model(features: features, mean: mean, scale: scale,
                     weights: Array(theta.dropFirst()), bias: theta[0],
                     corrections: 0, examples: rows.count, correctionAccuracy: 0,
                     loss: 0, trainedAt: Date(timeIntervalSince1970: 0))
    }

    /// Gaussian elimination with partial pivoting; nil if singular.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        let n = v.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p); v.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = m[r][c] / m[c][c]
                for k in c..<n { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        return (0..<n).map { v[$0] / m[$0][$0] }
    }
}

/// Builds training examples from stored history: every confirmed correction at
/// full weight, plus one "accepted" moment per hour in which nobody touched the
/// appearance, at low weight. The accepted moments keep the model honest about
/// all the times it was already right.
public func examples(corrections: [Correction], samples: [Sample],
                     acceptedWeight: Double = 0.15, quietMargin: TimeInterval = 3600) -> [Example] {
    var out = corrections.map {
        Example(time: $0.time, features: $0.sample.features, dark: $0.to == .dark, weight: 1)
    }
    var hours = Set<Int>()
    let touched = corrections.map(\.time)
    for s in samples {
        let hour = Int(s.time.timeIntervalSince1970 / 3600)
        guard !hours.contains(hour),
              !touched.contains(where: { abs($0.timeIntervalSince(s.time)) < quietMargin })
        else { continue }
        hours.insert(hour)
        out.append(Example(time: s.time, features: s.features, dark: s.appearance == .dark,
                           weight: acceptedWeight))
    }
    return out
}

@inline(__always) func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-z)) }
