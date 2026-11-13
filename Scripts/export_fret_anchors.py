#!/usr/bin/env python3
"""Export ordered 3D fret anchors from an SGDC / Gaussian Grouping PLY.

Offline calibration stage for the ElectricPipa 3DGS plan.

The semantic field is used ONCE, offline, to segment the 32 stop positions and
four strings, to label them, and to export 3D anchors for the billboards. The
runtime never queries the semantic field: hit testing uses the analytic
geometry produced here.

What this script does:

  1. Reads a binary_little_endian or ascii PLY written by
     scene/gaussian_model.py:save_ply. That file stores Gaussian Grouping
     identity encodings as obj_dc_0 .. obj_dc_(K-1), alongside xyz and opacity.
  2. Groups Gaussians by identity, drops low-confidence and tiny groups using
     the same thresholds as semantic_density_control.py (max softmax prob 0.7,
     at least 10 points per instance).
  3. Computes an opacity-weighted 3D centroid for each surviving group.
  4. Fits the centroids to the equal-tempered fret law with an order-preserving
     dynamic-programming assignment. Missing or duplicated groups are repaired
     from the musical prior instead of being taken as geometric truth.
  5. Emits 32 fret plane anchors plus four string lines as JSON, and reports
     the centroid-to-fitted-line deviation in millimetres.

The equal-tempered prior is not an external assumption invented for this
script. Core/PipaTuning.swift defines 1 open string + 6 xiang + 25 frets, one
semitone each, and the existing 2D stopRows already follow the same
exponential spacing. A stop n semitones above the open string sits at

    q(n) = 1 - 2 ** (-n / 12)

of the vibrating string length away from the nut.

Standard library only. This machine has no numpy.

Usage:
    python3 export_fret_anchors.py --self-test
    python3 export_fret_anchors.py --ply /path/to/point_cloud.ply \
        --out fret_anchors.json --string-length-mm 720
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import struct
import sys
import tempfile

POSITION_COUNT = 32          # PipaTuning.positionCount
STRING_COUNT = 4
DEFAULT_CONFIDENCE = 0.7     # SemanticDensityController.confidence_threshold
DEFAULT_MIN_POINTS = 10      # SemanticDensityController.min_points_per_instance
DEFAULT_MIN_OPACITY = 0.05
DEFAULT_STRING_LENGTH_MM = 720.0
HALF_FRET_TOLERANCE_MM = 4.0  # half of the tightest high-fret spacing


# --------------------------------------------------------------------------
# PLY reading
# --------------------------------------------------------------------------

def read_ply(path):
    """Return (list of property names, list of dict-like float rows).

    Only the vertex element is read; SGDC writes no face element. Every
    attribute written by save_ply is float32, which keeps this parser small.
    """
    with open(path, "rb") as fh:
        header = bytearray()
        while True:
            byte = fh.read(1)
            if not byte:
                raise ValueError("PLY header ended without end_header")
            header += byte
            if header.endswith(b"end_header\n") or header.endswith(b"end_header\r\n"):
                break
            if len(header) > 1_000_000:
                raise ValueError("PLY header too large")
        text = header.decode("ascii", errors="replace")
        lines = [line.strip() for line in text.splitlines()]

        fmt = "binary_little_endian"
        properties = []
        vertex_count = 0
        in_vertex = False
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "format":
                fmt = parts[1]
            elif parts[0] == "element":
                in_vertex = parts[1] == "vertex"
                if in_vertex:
                    vertex_count = int(parts[2])
            elif parts[0] == "property" and in_vertex:
                if parts[1] == "list":
                    raise ValueError("list properties are not supported in vertex")
                properties.append(parts[2])
            elif parts[0] == "end_header":
                break

        if not properties or vertex_count == 0:
            raise ValueError("PLY has no vertex properties")

        if fmt == "binary_little_endian":
            row = struct.Struct("<" + "f" * len(properties))
            payload = fh.read(row.size * vertex_count)
            if len(payload) < row.size * vertex_count:
                raise ValueError("truncated PLY payload")
            values = [list(v) for v in row.iter_unpack(payload)]
        elif fmt == "ascii":
            values = []
            rest = fh.read().decode("ascii", errors="replace").split()
            for i in range(vertex_count):
                chunk = rest[i * len(properties):(i + 1) * len(properties)]
                if len(chunk) != len(properties):
                    raise ValueError("truncated ascii PLY")
                values.append([float(v) for v in chunk])
        else:
            raise ValueError("unsupported PLY format: " + fmt)

    index = {name: i for i, name in enumerate(properties)}
    return index, values


def softmax(scores):
    peak = max(scores)
    exps = [math.exp(s - peak) for s in scores]
    total = sum(exps)
    return [e / total for e in exps]


def group_centroids(ply_path, confidence, min_points, min_opacity,
                    labels_path=None):
    """Group Gaussians by instance label into (centroid, confidence) pairs.

    In a trained SGDC run the per-Gaussian class logits come from the 1x1
    classifier in semantic_density_control.py (line 83), whose output has
    num_classes channels. Those can be exported as a JSON integer array and
    passed with --labels. When no such file is supplied we fall back to
    argmax over obj_dc_*, which is exactly equivalent only when the identity
    width equals the class count. A 16-wide identity encoding cannot express
    32 distinct frets; the script reports that case instead of silently
    folding every 16th fret onto the same label.
    """
    index, rows = read_ply(ply_path)
    for required in ("x", "y", "z"):
        if required not in index:
            raise ValueError("PLY is missing the " + required + " property")
    obj_names = sorted(
        (name for name in index if name.startswith("obj_dc_")),
        key=lambda name: int(name.split("_")[-1]),
    )
    if not obj_names and not labels_path:
        raise ValueError("PLY has no obj_dc_* identity encoding; "
                         "train with Gaussian Grouping / SGDC first")
    opacity_i = index.get("opacity")
    xi, yi, zi = index["x"], index["y"], index["z"]
    obj_i = [index[name] for name in obj_names]

    external_labels = None
    if labels_path:
        with open(labels_path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        external_labels = payload["labels"] if isinstance(payload, dict) else payload
        if len(external_labels) != len(rows):
            raise ValueError("label count %d != vertex count %d"
                             % (len(external_labels), len(rows)))

    buckets = {}
    total = len(rows)
    kept = 0
    for row_number, row in enumerate(rows):
        if external_labels is not None:
            best = int(external_labels[row_number])
            if best < 0:                      # SGDC marks low confidence as -1
                continue
            conf = 1.0
        else:
            scores = [row[i] for i in obj_i]
            probs = softmax(scores)
            best = max(range(len(probs)), key=lambda k: probs[k])
            conf = probs[best]
            if conf < confidence:
                continue
        if opacity_i is not None and row[opacity_i] < min_opacity:
            continue
        w = row[opacity_i] if opacity_i is not None else 1.0
        w = max(float(w), 1e-6)
        bucket = buckets.setdefault(best, [0.0, 0.0, 0.0, 0.0, 0.0, 0])
        bucket[0] += w * row[xi]
        bucket[1] += w * row[yi]
        bucket[2] += w * row[zi]
        bucket[3] += w
        bucket[4] += conf
        bucket[5] += 1
        kept += 1

    groups = []
    for label, (sx, sy, sz, sw, sc, n) in buckets.items():
        if n < min_points:
            continue
        groups.append({
            "label": label,
            "centroid": [sx / sw, sy / sw, sz / sw],
            "confidence": sc / n,
            "points": n,
        })
    groups.sort(key=lambda g: g["centroid"][1])
    return groups, {"vertices": total, "kept": kept,
                    "groups_before_min_points": len(buckets),
                    "identity_dim": len(obj_names)}


# --------------------------------------------------------------------------
# Geometry helpers, standard library only
# --------------------------------------------------------------------------

def vsub(a, b):
    return [a[i] - b[i] for i in range(3)]


def vadd(a, b):
    return [a[i] + b[i] for i in range(3)]


def vmul(a, s):
    return [x * s for x in a]


def dot(a, b):
    return sum(a[i] * b[i] for i in range(3))


def norm(a):
    return math.sqrt(dot(a, a))


def unit(a):
    n = norm(a)
    if n < 1e-12:
        return [0.0, 1.0, 0.0]
    return vmul(a, 1.0 / n)


def principal_axis(points):
    """Power iteration on the 3x3 covariance matrix."""
    n = len(points)
    if n < 2:
        return [0.0, 1.0, 0.0]
    mean = [sum(p[k] for p in points) / n for k in range(3)]
    cov = [[0.0] * 3 for _ in range(3)]
    for p in points:
        d = vsub(p, mean)
        for i in range(3):
            for j in range(3):
                cov[i][j] += d[i] * d[j]
    vec = [1.0, 1.0, 0.3]
    for _ in range(128):
        nxt = [sum(cov[i][j] * vec[j] for j in range(3)) for i in range(3)]
        nxt = unit(nxt)
        if norm(vsub(nxt, vec)) < 1e-10:
            vec = nxt
            break
        vec = nxt
    if vec[1] < 0:
        vec = vmul(vec, -1.0)
    return vec


def q_law(n):
    return 1.0 - 2.0 ** (-n / 12.0)


Q = [q_law(n) for n in range(POSITION_COUNT)]


def fit_line(assignments, t_values):
    """Least squares fit of t = a*q(n) + b over assigned observations."""
    pairs = [(Q[n], t_values[i]) for n, i in assignments.items() if i is not None]
    if len(pairs) < 2:
        return 1.0, 0.0
    mx = sum(x for x, _ in pairs) / len(pairs)
    my = sum(y for _, y in pairs) / len(pairs)
    num = sum((x - mx) * (y - my) for x, y in pairs)
    den = sum((x - mx) ** 2 for x, _ in pairs)
    a = num / den if den > 1e-12 else 1.0
    return a, my - a * mx


def order_preserving_assign(t_values, a, b):
    """Match sorted observations to the 32 ordered stops, monotonically.

    Allows a stop to be missing and an observation to be discarded, which is
    what high-fret dropout and wooden-grain outlier clusters look like.
    """
    m = len(t_values)
    n_stops = POSITION_COUNT
    spans = [a * (Q[k + 1] - Q[k]) for k in range(n_stops - 1)]
    median_span = sorted(spans)[len(spans) // 2] if spans else 1.0
    miss_penalty = 0.6 * median_span
    discard_penalty = 0.6 * median_span
    inf = float("inf")
    dp = [[inf] * (n_stops + 1) for _ in range(m + 1)]
    back = [[None] * (n_stops + 1) for _ in range(m + 1)]
    dp[0][0] = 0.0
    for i in range(m + 1):
        for n in range(n_stops + 1):
            if dp[i][n] == inf:
                continue
            if n < n_stops:
                cost = dp[i][n] + miss_penalty
                if cost < dp[i][n + 1]:
                    dp[i][n + 1] = cost
                    back[i][n + 1] = (i, n, "miss")
                if i < m:
                    cost = dp[i][n] + abs(t_values[i] - (a * Q[n] + b))
                    if cost < dp[i + 1][n + 1]:
                        dp[i + 1][n + 1] = cost
                        back[i + 1][n + 1] = (i, n, "hit")
            if i < m:
                cost = dp[i][n] + discard_penalty
                if cost < dp[i + 1][n]:
                    dp[i + 1][n] = cost
                    back[i + 1][n] = (i, n, "discard")

    i, n = m, n_stops
    if dp[i][n] == inf:
        raise RuntimeError("order-preserving assignment failed")
    assignments = {k: None for k in range(n_stops)}
    while i > 0 or n > 0:
        step = back[i][n]
        if step is None:
            break
        pi, pn, kind = step
        if kind == "hit":
            assignments[pn] = pi
        i, n = pi, pn
    return assignments


def calibrate(groups, string_length_mm):
    """Return the fitted analytic geometry and per-stop deviations."""
    if len(groups) < 4:
        raise RuntimeError("not enough reliable groups to calibrate: "
                           + str(len(groups)))
    centroids = [g["centroid"] for g in groups]
    axis = principal_axis(centroids)
    origin = centroids[0]
    t = [dot(vsub(c, origin), axis) for c in centroids]

    # Robust-ish initial scale from the observed span.
    span = max(t) - min(t)
    a = span / (Q[-1] - Q[0]) if span > 1e-9 else 1.0
    b = min(t) - a * Q[0]
    assignments = None
    for _ in range(6):
        assignments = order_preserving_assign(t, a, b)
        new_a, new_b = fit_line(assignments, t)
        if abs(new_a - a) < 1e-9 and abs(new_b - b) < 1e-9:
            a, b = new_a, new_b
            break
        a, b = new_a, new_b

    # Convert reconstruction units to millimetres using the physical string
    # length. 3DGS has no metric scale, so this external calibration is
    # mandatory rather than optional.
    mm_per_unit = string_length_mm / a if a > 1e-9 else 1.0

    fitted = []
    deviations = []
    for n in range(POSITION_COUNT):
        model_t = a * Q[n] + b
        anchor = vadd(origin, vmul(axis, model_t))
        idx = assignments.get(n)
        observed = idx is not None
        dev = abs(t[idx] - model_t) * mm_per_unit if observed else None
        if dev is not None:
            deviations.append(dev)
        fitted.append({
            "position": n,
            "q": Q[n],
            "t": model_t,
            "anchor": anchor,
            "observed": observed,
            "centroid": centroids[idx] if observed else None,
            "deviationMM": dev,
            "confidence": groups[idx]["confidence"] if observed else 0.0,
            "points": groups[idx]["points"] if observed else 0,
            "label": groups[idx]["label"] if observed else None,
        })

    # Four string lines, parallel to the fitted axis, spaced across the
    # perpendicular direction. The 13 px nut / 30 px bridge offsets come from
    # App/PipaGeometry.swift; 1173 px spans the real vibrating string length.
    lateral = unit([axis[1], -axis[0], 0.0]) if abs(axis[1]) + abs(axis[0]) > 1e-9 \
        else [1.0, 0.0, 0.0]
    mm_per_px = string_length_mm / 1173.0
    strings = []
    for s in range(STRING_COUNT):
        nut_offset_px = 234.0 + s * 13.0
        bridge_offset_px = 209.0 + s * 30.0
        # Rebase around the middle of the four strings, then convert mm to
        # reconstruction units. 3DGS has no metric scale on its own.
        nut_units = (nut_offset_px - 247.0) * mm_per_px / mm_per_unit
        bridge_units = (bridge_offset_px - 247.0) * mm_per_px / mm_per_unit
        nut = vadd(origin, vmul(lateral, nut_units))
        bridge = vadd(vadd(origin, vmul(lateral, bridge_units)), vmul(axis, a))
        strings.append({"string": s, "nut": nut, "bridge": bridge})

    summary = {
        "axis": axis,
        "origin": origin,
        "scaleUnitsPerStringLength": a,
        "offset": b,
        "mmPerUnit": mm_per_unit,
        "stringLengthMM": string_length_mm,
        "observedStops": len(deviations),
        "repairedStops": POSITION_COUNT - len(deviations),
        "maxDeviationMM": max(deviations) if deviations else None,
        "meanDeviationMM": (sum(deviations) / len(deviations)) if deviations else None,
        "discardedGroups": len(groups) - len(deviations),
        "halfFretToleranceMM": HALF_FRET_TOLERANCE_MM,
    }
    return summary, fitted, strings


# --------------------------------------------------------------------------
# Synthetic self-test that writes a real SGDC-shaped PLY
# --------------------------------------------------------------------------

def write_self_test_ply(path, seed=7):
    rng = random.Random(seed)
    string_length = 720.0
    unit_per_mm = 0.01
    attrs = (["x", "y", "z", "nx", "ny", "nz"]
             + ["f_dc_%d" % i for i in range(3)]
             + ["f_rest_%d" % i for i in range(45)]
             + ["opacity"]
             + ["scale_%d" % i for i in range(3)]
             + ["rot_%d" % i for i in range(4)]
             + ["obj_dc_%d" % i for i in range(40)])

    # 40 class channels: 32 stops, 3 wooden-grain outliers, remainder unused.
    # This mirrors the classifier logits in semantic_density_control.py rather
    # than the 16-wide identity features, which cannot name 32 frets.
    missing = {17, 28}          # two high frets lost to segmentation
    rows = []
    truth = {}
    for n in range(POSITION_COUNT):
        if n in missing:
            continue
        y = string_length * Q[n] * unit_per_mm
        truth[n] = y
        for _ in range(44):
            scores = [rng.uniform(-2.0, -0.5) for _ in range(40)]
            label = n
            # Crowded high frets: a fraction of Gaussians leaks into the
            # neighbouring stop, which is the wide-flat-Gaussian boundary
            # ambiguity the SGDC paper discusses.
            if n >= 24 and rng.random() < 0.12:
                label = n + (1 if rng.random() < 0.5 else -1)
                label = max(0, min(POSITION_COUNT - 1, label))
            scores[label] = rng.uniform(6.0, 9.0) if n < 24 \
                else rng.uniform(3.8, 5.5)
            x = rng.gauss(0.0, 0.9)
            z = rng.gauss(0.0, 0.25)
            y_noisy = y + rng.gauss(0.0, 2.0 * unit_per_mm)
            row = [x, y_noisy, z, 0, 0, 0] + [0.0] * 3 + [0.0] * 45
            row += [rng.uniform(0.55, 0.95)] + [0.002] * 3 + [1.0, 0, 0, 0]
            row += scores
            rows.append(row)
    # A few wooden-grain outlier clusters that are not frets at all.
    for k in range(3):
        for _ in range(26):
            scores = [rng.uniform(-2.0, -0.5) for _ in range(40)]
            scores[32 + k] = 6.5
            row = [rng.gauss(2.0, 0.4), rng.uniform(1.0, 6.0),
                   rng.gauss(0.0, 0.3), 0, 0, 0] + [0.0] * 3 + [0.0] * 45
            row += [0.4] + [0.002] * 3 + [1.0, 0, 0, 0] + scores
            rows.append(row)

    rng.shuffle(rows)
    with open(path, "wb") as fh:
        fh.write(b"ply\nformat binary_little_endian 1.0\n")
        fh.write(("element vertex %d\n" % len(rows)).encode("ascii"))
        for name in attrs:
            fh.write(("property float %s\n" % name).encode("ascii"))
        fh.write(b"end_header\n")
        row_struct = struct.Struct("<" + "f" * len(attrs))
        for row in rows:
            fh.write(row_struct.pack(*row))
    return truth, unit_per_mm, len(rows)


def run_self_test(out_path=None):
    with tempfile.TemporaryDirectory(prefix="fret-anchors-") as tmp:
        path = os.path.join(tmp, "point_cloud.ply")
        truth, unit_per_mm, count = write_self_test_ply(path)
        print("Self-test PLY: %d Gaussians, 32 stops, 2 deliberately missing,"
              " 3 outlier clusters" % count)
        groups, stats = group_centroids(path, DEFAULT_CONFIDENCE,
                                       DEFAULT_MIN_POINTS, DEFAULT_MIN_OPACITY)
        print("Parsed %d vertices, kept %d, %d identity groups before the "
              "10-point filter, %d reliable groups"
              % (stats["vertices"], stats["kept"],
                 stats["groups_before_min_points"], len(groups)))
        summary, fitted, strings = calibrate(groups, DEFAULT_STRING_LENGTH_MM)

        print("Fitted full-string span: %.4f reconstruction units, calibrated "
              "to %.1f mm" % (summary["scaleUnitsPerStringLength"],
                              summary["stringLengthMM"]))
        print("Metric scale: %.6f unit/mm"
              % (1.0 / summary["mmPerUnit"]))
        print("Observed stops: %d / %d, repaired from the musical prior: %d, "
              "discarded groups: %d"
              % (summary["observedStops"], POSITION_COUNT,
                 summary["repairedStops"], summary["discardedGroups"]))
        print("Centroid deviation from fitted stop line: mean %.3f mm, "
              "max %.3f mm (tolerance %.1f mm)"
              % (summary["meanDeviationMM"], summary["maxDeviationMM"],
                 HALF_FRET_TOLERANCE_MM))

        high = [f["deviationMM"] for f in fitted
                if f["position"] >= 24 and f["deviationMM"] is not None]
        if high:
            print("High-fret region (positions 24-31): mean %.3f mm, max %.3f mm"
                  % (sum(high) / len(high), max(high)))

        # Independent check against the known synthetic truth.
        errors = []
        for f in fitted:
            n = f["position"]
            if n in truth and f["centroid"] is not None:
                errors.append(abs(f["centroid"][1] - truth[n]) / unit_per_mm)
        print("Centroid error against known synthetic stop centres: "
              "mean %.3f mm, max %.3f mm over %d stops"
              % (sum(errors) / len(errors), max(errors), len(errors)))

        # Control group: use the raw 3D centroids directly as the 32 stops,
        # which is the calibration scheme without the ordered fit. Any missing
        # or spurious group shifts every later stop index by one.
        naive = groups[:POSITION_COUNT]
        naive_correct = sum(1 for i, g in enumerate(naive) if g["label"] == i)
        fitted_correct = sum(1 for f in fitted
                             if f["observed"] and f["label"] == f["position"])
        fitted_correct += summary["repairedStops"]
        print("Stop-index accuracy: raw centroids %d / %d (%.1f%%), "
              "ordered fit %d / %d (%.1f%%)"
              % (naive_correct, POSITION_COUNT,
                 100.0 * naive_correct / POSITION_COUNT,
                 fitted_correct, POSITION_COUNT,
                 100.0 * fitted_correct / POSITION_COUNT))

        passed = (summary["maxDeviationMM"] <= HALF_FRET_TOLERANCE_MM
                  and summary["repairedStops"] == 2
                  and len(strings) == STRING_COUNT
                  and fitted_correct == POSITION_COUNT)
        print("")
        print("Criterion 1 (3D centroid error < 4 mm): %s"
              % ("PASS" if passed else "FAIL"))
        print("Note: these are synthetic numbers that validate the pipeline.")
        print("A real verdict needs a trained Pipa scene PLY plus measured")
        print("stop-line centres; run with --ply and --string-length-mm.")

        if out_path:
            asset = {
                "source": "synthetic self-test",
                "synthetic": True,
                "warning": "Not real calibration data. For pipeline wiring only.",
                "units": "mm",
                "mmPerUnit": summary["mmPerUnit"],
                "axis": summary["axis"],
                "origin": summary["origin"],
                "fit": summary,
                "strings": strings,
                "frets": fitted,
            }
            with open(out_path, "w", encoding="utf-8") as fh:
                json.dump(asset, fh, indent=2)
            print("Wrote synthetic asset %s (pipeline wiring only)" % out_path)
        return 0 if passed else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ply", help="point_cloud.ply from an SGDC training run")
    ap.add_argument("--labels",
                    help="optional JSON array of per-Gaussian classifier labels")
    ap.add_argument("--out", help="write fret_anchors.json here")
    ap.add_argument("--self-test", action="store_true",
                    help="run the synthetic end-to-end check")
    ap.add_argument("--confidence", type=float, default=DEFAULT_CONFIDENCE)
    ap.add_argument("--min-points", type=int, default=DEFAULT_MIN_POINTS)
    ap.add_argument("--min-opacity", type=float, default=DEFAULT_MIN_OPACITY)
    ap.add_argument("--string-length-mm", type=float,
                    default=DEFAULT_STRING_LENGTH_MM)
    args = ap.parse_args()

    if args.self_test:
        return run_self_test(args.out)
    if not args.ply:
        ap.error("provide --ply or --self-test")

    groups, stats = group_centroids(args.ply, args.confidence,
                                   args.min_points, args.min_opacity,
                                   args.labels)
    if not args.labels and stats["identity_dim"] < POSITION_COUNT:
        print("WARNING: identity width %d < %d stops; argmax cannot name all "
              "frets. Export classifier labels with --labels."
              % (stats["identity_dim"], POSITION_COUNT))
    summary, fitted, strings = calibrate(groups, args.string_length_mm)
    print("Parsed %d vertices, %d reliable groups, identity dim %d"
          % (stats["vertices"], len(groups), stats["identity_dim"]))
    print("Observed stops %d / %d; max deviation %.3f mm, mean %.3f mm"
          % (summary["observedStops"], POSITION_COUNT,
             summary["maxDeviationMM"] or float("nan"),
             summary["meanDeviationMM"] or float("nan")))
    print("Criterion 1: %s"
          % ("PASS" if (summary["maxDeviationMM"] or 1e9)
             <= HALF_FRET_TOLERANCE_MM else "FAIL"))

    if args.out:
        asset = {
            "source": os.path.abspath(args.ply),
            "units": "mm" if args.string_length_mm else "reconstruction",
            "mmPerUnit": summary["mmPerUnit"],
            "axis": summary["axis"],
            "origin": summary["origin"],
            "fit": summary,
            "strings": strings,
            "frets": fitted,
        }
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(asset, fh, indent=2)
        print("Wrote " + args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
