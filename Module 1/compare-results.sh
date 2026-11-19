#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$HOME/llm-server/results}"
MODEL_LABEL="${MODEL_LABEL:-Qwen-SEA-LION-v4.5-27B-IT}"
WORKLOAD_LABEL="${WORKLOAD_LABEL:-PP512 / TG128}"
TARGET_TP="${TARGET_TP:-}"

OUT_CSV="${OUT_CSV:-$ROOT/comparison.csv}"
OUT_MD="${OUT_MD:-$ROOT/comparison.md}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d "$ROOT" ]] ||
    die "Results directory not found: $ROOT"

TP1_BENCH="$ROOT/tp1/bench-concurrency-tp1.csv"

[[ -f "$TP1_BENCH" ]] ||
    die "Missing TP=1 benchmark: $TP1_BENCH"

#
# Discover completed non-TP1 benchmark results.
#
declare -a DISCOVERED_TPS=()

while IFS= read -r file; do
    directory="$(basename "$(dirname "$file")")"
    filename="$(basename "$file")"

    if [[ "$directory" =~ ^tp([0-9]+)$ ]]; then
        tp="${BASH_REMATCH[1]}"

        if (( tp > 1 )) &&
           [[ "$filename" == "bench-concurrency-tp${tp}.csv" ]]; then
            DISCOVERED_TPS+=("$tp")
        fi
    fi
done < <(
    find "$ROOT" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name 'bench-concurrency-tp*.csv' \
        -print |
    sort -V
)

if ((${#DISCOVERED_TPS[@]} > 0)); then
    mapfile -t DISCOVERED_TPS < <(
        printf '%s\n' "${DISCOVERED_TPS[@]}" |
        sort -n -u
    )
fi

#
# Select TP=N.
#
if [[ -n "$TARGET_TP" ]]; then
    [[ "$TARGET_TP" =~ ^[0-9]+$ ]] ||
        die "TARGET_TP must be a positive integer"

    (( TARGET_TP > 1 )) ||
        die "TARGET_TP must be greater than 1"

    TPN="$TARGET_TP"

    found=0

    for tp in "${DISCOVERED_TPS[@]}"; do
        if [[ "$tp" == "$TPN" ]]; then
            found=1
            break
        fi
    done

    (( found == 1 )) ||
        die "No completed TP=$TPN benchmark found under $ROOT/tp$TPN"
else
    case "${#DISCOVERED_TPS[@]}" in
        0)
            die "Only TP=1 results exist. Run the TP=N benchmark first."
            ;;
        1)
            TPN="${DISCOVERED_TPS[0]}"
            ;;
        *)
            {
                printf 'ERROR: multiple non-TP1 benchmark results exist:'
                printf ' TP=%s' "${DISCOVERED_TPS[@]}"
                printf '\n'
                printf 'Select one explicitly, for example:\n'
                printf '  TARGET_TP=4 %s\n' "$0"
            } >&2
            exit 1
            ;;
    esac
fi

TPN_BENCH="$ROOT/tp${TPN}/bench-concurrency-tp${TPN}.csv"

[[ -f "$TPN_BENCH" ]] ||
    die "Missing TP=$TPN benchmark: $TPN_BENCH"

#
# Validate XPU-SMI telemetry.
#
TP1_GPU="$ROOT/tp1/xpu-concurrency-tp1-gpu0.csv"

[[ -f "$TP1_GPU" ]] ||
    die "Missing TP=1 XPU-SMI dump: $TP1_GPU"

for ((gpu=0; gpu<TPN; gpu++)); do
    telemetry="$ROOT/tp${TPN}/xpu-concurrency-tp${TPN}-gpu${gpu}.csv"

    [[ -f "$telemetry" ]] ||
        die "Missing TP=$TPN XPU-SMI dump for GPU $gpu: $telemetry"
done

mkdir -p "$(dirname "$OUT_CSV")"
mkdir -p "$(dirname "$OUT_MD")"

echo
echo "TP=1 versus TP=$TPN comparison"
echo "================================"
printf '%-19s %s\n' "Model:" "$MODEL_LABEL"
printf '%-19s %s\n' "Results directory:" "$ROOT"
printf '%-19s %s\n' "TP=1 benchmark:" "$TP1_BENCH"
printf '%-19s %s\n' "TP=$TPN benchmark:" "$TPN_BENCH"
printf '%-19s %s\n' "TP=1 SMI dumps:" "1"
printf '%-19s %s\n' "TP=$TPN SMI dumps:" "$TPN"
echo

python3 - \
    "$TP1_BENCH" \
    "$TPN_BENCH" \
    "$ROOT" \
    "$TPN" \
    "$MODEL_LABEL" \
    "$WORKLOAD_LABEL" \
    "$OUT_CSV" \
    "$OUT_MD" <<'PY'
import csv
import glob
import math
import os
import re
import statistics
import sys
from pathlib import Path

(
    tp1_benchmark_path,
    tpn_benchmark_path,
    root,
    tpn_text,
    model_label,
    workload_label,
    output_csv,
    output_markdown,
) = sys.argv[1:]

tpn = int(tpn_text)


def number(value):
    if value is None:
        return None

    text = str(value).strip()

    if not text or text.lower() in {
        "n/a",
        "na",
        "nan",
        "none",
        "-",
        "null",
    }:
        return None

    text = (
        text.replace("%", "")
        .replace("MiB", "")
        .replace("MHz", "")
        .replace("W", "")
        .strip()
    )

    try:
        value = float(text)
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def fmt(value, digits=2, suffix=""):
    if value is None:
        return "N/A"

    return f"{value:.{digits}f}{suffix}"


def percent_change(base, target):
    if base in (None, 0) or target is None:
        return None

    return (target / base - 1) * 100


def reduction(base, target):
    if base in (None, 0) or target is None:
        return None

    return (1 - target / base) * 100


def concurrency_from_name(name):
    match = re.search(r"\(c(\d+)\)", name or "")
    return int(match.group(1)) if match else 1


def read_benchmark(path):
    results = {}

    with open(path, newline="", errors="replace") as handle:
        reader = csv.DictReader(handle)

        if not reader.fieldnames or "test_name" not in reader.fieldnames:
            raise RuntimeError(
                f"Benchmark CSV does not contain test_name: {path}"
            )

        for row in reader:
            test_name = row.get("test_name", "")
            concurrency = concurrency_from_name(test_name)
            result = results.setdefault(concurrency, {})

            if test_name.startswith("pp"):
                result.update(
                    pp=number(row.get("t_s_mean")),
                    pp_request=number(row.get("t_s_req_mean")),
                    ttft=number(
                        row.get("e2e_ttft_mean")
                        or row.get("ttfr_mean")
                    ),
                    ppt=number(row.get("est_ppt_mean")),
                )

            elif test_name.startswith("tg"):
                result.update(
                    tg=number(row.get("t_s_mean")),
                    tg_request=number(row.get("t_s_req_mean")),
                    peak=number(row.get("peak_ts_mean")),
                )

    if not results:
        raise RuntimeError(f"No benchmark rows found in {path}")

    return results


TELEMETRY_PATTERNS = {
    "power": [
        r"power.*draw",
        r"gpu.*power",
        r"power.*\(w\)",
    ],
    "memory": [
        r"memory.*used",
    ],
    "memory_percent": [
        r"memory.*util",
    ],
    "frequency": [
        r"frequency",
        r"clock.*graphics",
    ],
}


def gpu_number(path):
    match = re.search(r"-gpu(\d+)\.csv$", path)

    if not match:
        raise ValueError(f"Cannot determine GPU number from {path}")

    return int(match.group(1))


def read_telemetry(path):
    with open(path, newline="", errors="replace") as handle:
        reader = csv.DictReader(handle)
        headers = reader.fieldnames or []
        mapped_headers = {}

        for header in headers:
            lowered = header.lower()

            for metric, patterns in TELEMETRY_PATTERNS.items():
                if metric in mapped_headers:
                    continue

                if any(
                    re.search(pattern, lowered)
                    for pattern in patterns
                ):
                    mapped_headers[metric] = header

        values = {
            metric: []
            for metric in TELEMETRY_PATTERNS
        }

        for row in reader:
            for metric, header in mapped_headers.items():
                value = number(row.get(header))

                if value is not None:
                    values[metric].append(value)

    result = {
        "path": path,
        "mapped_headers": mapped_headers,
    }

    for metric, samples in values.items():
        result[f"{metric}_average"] = (
            statistics.mean(samples)
            if samples
            else None
        )

        result[f"{metric}_peak"] = (
            max(samples)
            if samples
            else None
        )

    return result


def saturation_knee(results):
    points = sorted(
        concurrency
        for concurrency, data in results.items()
        if data.get("tg") is not None
    )

    for current, following in zip(points, points[1:]):
        current_value = results[current].get("tg")
        next_value = results[following].get("tg")

        if current_value in (None, 0) or next_value is None:
            continue

        gain = (next_value / current_value - 1) * 100

        if gain < 5:
            return current, following, gain

    return None


tp1_results = read_benchmark(tp1_benchmark_path)
tpn_results = read_benchmark(tpn_benchmark_path)

concurrencies = sorted(
    set(tp1_results) | set(tpn_results)
)

common_concurrencies = sorted(
    set(tp1_results) & set(tpn_results)
)

if not common_concurrencies:
    raise RuntimeError(
        "TP=1 and TP=N do not contain matching concurrency levels"
    )

tp1_knee = saturation_knee(tp1_results)
tpn_knee = saturation_knee(tpn_results)

tp1_telemetry_files = sorted(
    glob.glob(
        os.path.join(
            root,
            "tp1",
            "xpu-concurrency-tp1-gpu*.csv",
        )
    ),
    key=gpu_number,
)

tpn_telemetry_files = sorted(
    glob.glob(
        os.path.join(
            root,
            f"tp{tpn}",
            f"xpu-concurrency-tp{tpn}-gpu*.csv",
        )
    ),
    key=gpu_number,
)

tp1_telemetry = [
    (gpu_number(path), read_telemetry(path))
    for path in tp1_telemetry_files
]

tpn_telemetry = [
    (gpu_number(path), read_telemetry(path))
    for path in tpn_telemetry_files
]

expected_tp1_gpus = {0}
actual_tp1_gpus = {
    gpu
    for gpu, _ in tp1_telemetry
}

expected_tpn_gpus = set(range(tpn))
actual_tpn_gpus = {
    gpu
    for gpu, _ in tpn_telemetry
}

if actual_tp1_gpus != expected_tp1_gpus:
    raise RuntimeError(
        "TP=1 telemetry GPU set is invalid: "
        f"expected {sorted(expected_tp1_gpus)}, "
        f"found {sorted(actual_tp1_gpus)}"
    )

if actual_tpn_gpus != expected_tpn_gpus:
    raise RuntimeError(
        f"TP={tpn} telemetry GPU set is invalid: "
        f"expected {sorted(expected_tpn_gpus)}, "
        f"found {sorted(actual_tpn_gpus)}"
    )

#
# CSV report.
#
csv_columns = [
    "concurrency",
    "tp1_pp_tps",
    f"tp{tpn}_pp_tps",
    "pp_gain_pct",
    "tp1_tg_tps",
    f"tp{tpn}_tg_tps",
    "tg_gain_pct",
    "tp1_tg_req_tps",
    f"tp{tpn}_tg_req_tps",
    "tp1_ttft_ms",
    f"tp{tpn}_ttft_ms",
    "ttft_reduction_pct",
]

with open(output_csv, "w", newline="") as handle:
    writer = csv.DictWriter(
        handle,
        fieldnames=csv_columns,
    )

    writer.writeheader()

    for concurrency in concurrencies:
        base = tp1_results.get(concurrency, {})
        target = tpn_results.get(concurrency, {})

        writer.writerow({
            "concurrency": concurrency,
            "tp1_pp_tps": base.get("pp"),
            f"tp{tpn}_pp_tps": target.get("pp"),
            "pp_gain_pct": percent_change(
                base.get("pp"),
                target.get("pp"),
            ),
            "tp1_tg_tps": base.get("tg"),
            f"tp{tpn}_tg_tps": target.get("tg"),
            "tg_gain_pct": percent_change(
                base.get("tg"),
                target.get("tg"),
            ),
            "tp1_tg_req_tps": base.get("tg_request"),
            f"tp{tpn}_tg_req_tps": target.get("tg_request"),
            "tp1_ttft_ms": base.get("ttft"),
            f"tp{tpn}_ttft_ms": target.get("ttft"),
            "ttft_reduction_pct": reduction(
                base.get("ttft"),
                target.get("ttft"),
            ),
        })

#
# Markdown report.
#
markdown = [
    f"# TP=1 vs TP={tpn} Comparison",
    "",
    f"**Model:** {model_label}",
    "",
    f"**Workload:** {workload_label}",
    "",
    "## Performance comparison",
    "",
    "| C | TP1 PP | "
    f"TP{tpn} PP | PP gain | "
    f"TP1 TG | TP{tpn} TG | TG gain | "
    f"TP1 TTFT ms | TP{tpn} TTFT ms | "
    "TTFT reduction |",
    "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
]

for concurrency in concurrencies:
    base = tp1_results.get(concurrency, {})
    target = tpn_results.get(concurrency, {})

    markdown.append(
        f"| {concurrency} "
        f"| {fmt(base.get('pp'))} "
        f"| {fmt(target.get('pp'))} "
        f"| {fmt(percent_change(base.get('pp'), target.get('pp')), 1, '%')} "
        f"| {fmt(base.get('tg'))} "
        f"| {fmt(target.get('tg'))} "
        f"| {fmt(percent_change(base.get('tg'), target.get('tg')), 1, '%')} "
        f"| {fmt(base.get('ttft'))} "
        f"| {fmt(target.get('ttft'))} "
        f"| {fmt(reduction(base.get('ttft'), target.get('ttft')), 1, '%')} |"
    )

markdown.extend([
    "",
    "## Saturation analysis",
    "",
])

if tp1_knee:
    markdown.append(
        f"- TP=1 knee: C{tp1_knee[0]} to C{tp1_knee[1]}, "
        f"TG change {tp1_knee[2]:+.1f}%."
    )
else:
    markdown.append(
        "- TP=1 saturation was not detected "
        "at the tested concurrency levels."
    )

if tpn_knee:
    markdown.append(
        f"- TP={tpn} knee: C{tpn_knee[0]} to C{tpn_knee[1]}, "
        f"TG change {tpn_knee[2]:+.1f}%."
    )
else:
    markdown.append(
        f"- TP={tpn} saturation was not detected "
        "at the tested concurrency levels."
    )

markdown.extend([
    "",
    "## GPU telemetry",
    "",
    "| Topology | GPU | Avg power | Peak power | "
    "Peak memory | Avg memory utilization |",
    "|---|---:|---:|---:|---:|---:|",
])


def add_markdown_telemetry(topology, telemetry):
    for gpu_index, data in telemetry:
        markdown.append(
            f"| TP={topology} "
            f"| {gpu_index} "
            f"| {fmt(data.get('power_average'), 2, ' W')} "
            f"| {fmt(data.get('power_peak'), 2, ' W')} "
            f"| {fmt(data.get('memory_peak'), 2, ' MiB')} "
            f"| {fmt(data.get('memory_percent_average'), 2, '%')} |"
        )


add_markdown_telemetry(1, tp1_telemetry)
add_markdown_telemetry(tpn, tpn_telemetry)

highest = max(common_concurrencies)
highest_base = tp1_results[highest]
highest_target = tpn_results[highest]

markdown.extend([
    "",
    "## Takeaway",
    "",
])

if (
    highest_base.get("tg") not in (None, 0)
    and highest_target.get("tg") is not None
):
    markdown.append(
        f"- At C{highest}, TP={tpn} delivered "
        f"{highest_target['tg'] / highest_base['tg']:.2f}x "
        "total decode throughput versus TP=1."
    )

if (
    highest_base.get("pp") not in (None, 0)
    and highest_target.get("pp") is not None
):
    markdown.append(
        f"- At C{highest}, TP={tpn} delivered "
        f"{highest_target['pp'] / highest_base['pp']:.2f}x "
        "prompt-processing throughput versus TP=1."
    )

highest_ttft_reduction = reduction(
    highest_base.get("ttft"),
    highest_target.get("ttft"),
)

if highest_ttft_reduction is not None:
    if highest_ttft_reduction >= 0:
        markdown.append(
            f"- At C{highest}, TP={tpn} reduced TTFT by "
            f"{highest_ttft_reduction:.1f}% versus TP=1."
        )
    else:
        markdown.append(
            f"- At C{highest}, TP={tpn} increased TTFT by "
            f"{abs(highest_ttft_reduction):.1f}% versus TP=1."
        )

Path(output_markdown).write_text(
    "\n".join(markdown) + "\n"
)

#
# Original-style dynamic terminal presentation.
#
USE_COLOR = (
    sys.stdout.isatty()
    and os.environ.get("NO_COLOR") is None
)

RESET = "\033[0m" if USE_COLOR else ""
CYAN = "\033[96m" if USE_COLOR else ""
GREEN = "\033[92m" if USE_COLOR else ""
YELLOW = "\033[93m" if USE_COLOR else ""
BOLD = "\033[1m" if USE_COLOR else ""


def color(text, selected_color):
    if USE_COLOR and selected_color:
        return f"{selected_color}{text}{RESET}"

    return str(text)


def visible_length(text):
    return len(
        re.sub(
            r"\x1b\[[0-9;]*m",
            "",
            str(text),
        )
    )


def pad(text, width, alignment="<"):
    text = str(text)
    remaining = max(0, width - visible_length(text))

    if alignment == ">":
        return (" " * remaining) + text

    if alignment == "^":
        left = remaining // 2
        right = remaining - left
        return (" " * left) + text + (" " * right)

    return text + (" " * remaining)


TABLE_WIDTH = 108


def full_line(width=TABLE_WIDTH, character="="):
    print("+" + (character * width) + "+")


def full_title(text):
    full_line()
    print(
        "|"
        + pad(
            color(text, BOLD + CYAN),
            TABLE_WIDTH,
            "^",
        )
        + "|"
    )
    full_line()


def full_message(text, selected_color=None):
    print(
        "|"
        + pad(
            " " + color(text, selected_color),
            TABLE_WIDTH,
        )
        + "|"
    )


def separator(widths, character="-"):
    print(
        "+"
        + "+".join(
            character * (width + 2)
            for width in widths
        )
        + "+"
    )


def row(values, widths, alignments=None):
    alignments = alignments or ["<"] * len(widths)

    print(
        "|"
        + "|".join(
            " " + pad(value, width, alignment) + " "
            for value, width, alignment in zip(
                values,
                widths,
                alignments,
            )
        )
        + "|"
    )


print()

full_title(
    f"{model_label} | TP=1 vs TP={tpn}"
)

full_message(
    f"Workload: {workload_label} | "
    "Performance: llama-benchy | "
    "Hardware: XPU-SMI"
)

full_line()

print()

full_title("PERFORMANCE COMPARISON")

performance_widths = [5, 28, 28, 36]

separator(performance_widths)

row(
    [
        "C",
        "TP=1",
        f"TP={tpn}",
        f"TP={tpn} vs TP=1",
    ],
    performance_widths,
    ["^", "^", "^", "^"],
)

separator(performance_widths, "=")

for concurrency in concurrencies:
    base = tp1_results.get(concurrency, {})
    target = tpn_results.get(concurrency, {})

    if (
        base.get("tg") not in (None, 0)
        and target.get("tg") is not None
    ):
        tg_comparison = (
            f"{target['tg'] / base['tg']:.2f}x "
            f"({percent_change(base['tg'], target['tg']):+.1f}%)"
        )
    else:
        tg_comparison = "N/A"

    if (
        base.get("pp") not in (None, 0)
        and target.get("pp") is not None
    ):
        pp_comparison = (
            f"{target['pp'] / base['pp']:.2f}x "
            f"({percent_change(base['pp'], target['pp']):+.1f}%)"
        )
    else:
        pp_comparison = "N/A"

    ttft_change = reduction(
        base.get("ttft"),
        target.get("ttft"),
    )

    if ttft_change is None:
        ttft_comparison = "N/A"
    elif ttft_change >= 0:
        ttft_comparison = f"-{ttft_change:.1f}%"
    else:
        ttft_comparison = f"+{abs(ttft_change):.1f}%"

    row(
        [
            color(f"C{concurrency}", YELLOW),
            f"TG {fmt(base.get('tg'))} tok/s",
            f"TG {fmt(target.get('tg'))} tok/s",
            (
                color(tg_comparison, GREEN)
                if tg_comparison != "N/A"
                else "N/A"
            ),
        ],
        performance_widths,
    )

    row(
        [
            "",
            f"PP {fmt(base.get('pp'))} tok/s",
            f"PP {fmt(target.get('pp'))} tok/s",
            (
                color(pp_comparison, GREEN)
                if pp_comparison != "N/A"
                else "N/A"
            ),
        ],
        performance_widths,
    )

    row(
        [
            "",
            f"TTFT {fmt(base.get('ttft'))} ms",
            f"TTFT {fmt(target.get('ttft'))} ms",
            (
                color(ttft_comparison, GREEN)
                if ttft_comparison != "N/A"
                else "N/A"
            ),
        ],
        performance_widths,
    )

    row(
        [
            "",
            f"TG/req {fmt(base.get('tg_request'))} tok/s",
            f"TG/req {fmt(target.get('tg_request'))} tok/s",
            "",
        ],
        performance_widths,
    )

    separator(performance_widths)

print()

full_title("SATURATION ANALYSIS")

if tp1_knee:
    full_message(
        f"TP=1 | Knee C{tp1_knee[0]} -> C{tp1_knee[1]}, "
        f"TG change {tp1_knee[2]:+.1f}%.",
        YELLOW,
    )
else:
    full_message(
        "TP=1 | Saturation not detected.",
        GREEN,
    )

if tpn_knee:
    full_message(
        f"TP={tpn} | Knee C{tpn_knee[0]} -> C{tpn_knee[1]}, "
        f"TG change {tpn_knee[2]:+.1f}%.",
        YELLOW,
    )
else:
    full_message(
        f"TP={tpn} | Saturation NOT reached "
        "at highest concurrency tested.",
        GREEN,
    )

full_line()

print()

full_title("GPU TELEMETRY")

telemetry_widths = [
    10,
    7,
    15,
    15,
    17,
    20,
]

separator(telemetry_widths)

row(
    [
        "Topology",
        "GPU",
        "Avg Power",
        "Peak Power",
        "Peak Memory",
        "Avg Memory Util",
    ],
    telemetry_widths,
    ["^"] * 6,
)

separator(telemetry_widths, "=")


def telemetry_row(topology, gpu_index, data):
    row(
        [
            f"TP={topology}",
            f"GPU {gpu_index}",
            fmt(
                data.get("power_average"),
                2,
                " W",
            ),
            fmt(
                data.get("power_peak"),
                2,
                " W",
            ),
            fmt(
                data.get("memory_peak"),
                2,
                " MiB",
            ),
            fmt(
                data.get("memory_percent_average"),
                2,
                " %",
            ),
        ],
        telemetry_widths,
        ["^", "^", ">", ">", ">", ">"],
    )


for gpu_index, data in tp1_telemetry:
    telemetry_row(
        1,
        gpu_index,
        data,
    )

separator(telemetry_widths)

for gpu_index, data in tpn_telemetry:
    telemetry_row(
        tpn,
        gpu_index,
        data,
    )

separator(telemetry_widths)

print(
    "| "
    + pad(
        "N/A means unavailable; it is never treated as zero.",
        sum(telemetry_widths) + (2 * len(telemetry_widths)) + 4,
    )
    + " |"
)

separator(telemetry_widths, "=")

print()

full_title("TAKEAWAY")

if (
    highest_base.get("tg") not in (None, 0)
    and highest_target.get("tg") is not None
):
    full_message(
        f"At C{highest}, TP={tpn} delivered "
        f"{highest_target['tg'] / highest_base['tg']:.2f}x "
        "total decode throughput.",
        GREEN,
    )

if (
    highest_base.get("pp") not in (None, 0)
    and highest_target.get("pp") is not None
):
    full_message(
        f"At C{highest}, TP={tpn} delivered "
        f"{highest_target['pp'] / highest_base['pp']:.2f}x "
        "prompt-processing throughput.",
        GREEN,
    )

if highest_ttft_reduction is not None:
    if highest_ttft_reduction >= 0:
        full_message(
            f"At C{highest}, TP={tpn} reduced TTFT by "
            f"{highest_ttft_reduction:.1f}%.",
            GREEN,
        )
    else:
        full_message(
            f"At C{highest}, TP={tpn} increased TTFT by "
            f"{abs(highest_ttft_reduction):.1f}%.",
            YELLOW,
        )

if tp1_knee:
    full_message(
        "TP=1 reaches a throughput plateau "
        "beyond its useful concurrency knee.",
        YELLOW,
    )

if not tpn_knee:
    full_message(
        f"TP={tpn} was still scaling at the "
        "highest concurrency tested.",
        GREEN,
    )

full_line()

print()
print(f"CSV report:      {output_csv}")
print(f"Markdown report: {output_markdown}")
print()
PY
