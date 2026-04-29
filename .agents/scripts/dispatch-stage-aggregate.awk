# dispatch-stage-aggregate.awk — Per-stage percentile computation (t3034)
# Reads the dispatch-stages.tsv log and computes p50/p95/p99 per stage.
# Invoked by dispatch-stage-instrument.sh::_ds_report.
#
# Input: TSV with columns:
#   $1 = ISO8601 timestamp
#   $2 = #issue_number
#   $3 = repo_slug
#   $4 = stage_name
#   $5 = elapsed_ms
#
# Variables passed via -v:
#   cutoff = unix epoch — only include records newer than this
#            (currently unused — full date parsing in awk is fragile;
#            include all records and let the caller control the window
#            by pre-filtering if needed)

BEGIN { OFS = "\t" }

{
	stage = $4
	ms = $5 + 0
	if (ms > 0) {
		data[stage] = data[stage] " " ms
		count[stage]++
	}
}

END {
	printf "%-30s %8s %8s %8s %8s %6s\n", "STAGE", "p50", "p95", "p99", "max", "n"
	printf "%-30s %8s %8s %8s %8s %6s\n", "-----", "---", "---", "---", "---", "-"
	for (s in data) {
		n = split(data[s], arr, " ")
		# Simple insertion sort (n is small per stage)
		for (i = 2; i <= n; i++) {
			key = arr[i] + 0
			j = i - 1
			while (j >= 1 && arr[j] + 0 > key) {
				arr[j+1] = arr[j]
				j--
			}
			arr[j+1] = key
		}
		p50_idx = int(n * 0.50); if (p50_idx < 1) p50_idx = 1
		p95_idx = int(n * 0.95); if (p95_idx < 1) p95_idx = 1
		p99_idx = int(n * 0.99); if (p99_idx < 1) p99_idx = 1
		printf "%-30s %7dms %7dms %7dms %7dms %6d\n", \
			s, arr[p50_idx]+0, arr[p95_idx]+0, arr[p99_idx]+0, arr[n]+0, count[s]
	}
}
