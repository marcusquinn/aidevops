# dispatch-stage-aggregate.awk — Per-stage percentile computation (t3034)
# Invoked twice by dispatch-stage-instrument.sh::_ds_report, around a sort:
#
#   awk -v mode=filter -v cutoff=<ISO8601 UTC> -f this.awk dispatch-stages.tsv |
#     LC_ALL=C sort -t TAB -k1,1 -k2,2n |
#     awk -v mode=aggregate -f this.awk
#
# mode=filter reads the raw log, TSV columns:
#   $1 = ISO8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)
#   $2 = #issue_number
#   $3 = repo_slug
#   $4 = stage_name
#   $5 = elapsed_ms
#   $6 = event (start|complete; absent on legacy rows)
# It prints "stage<TAB>elapsed_ms" for completed rows with a positive elapsed
# time and a timestamp at or after cutoff. Fixed-width ISO-8601 UTC timestamps
# compare correctly as strings, so no date parsing is needed (GH#35935).
#
# mode=aggregate (default) reads that output sorted by stage, then elapsed
# time ascending, and prints p50/p95/p99/max/n per stage in one O(n) pass.
# Percentile indexes are unchanged from the original insertion-sort version.

BEGIN {
	FS = "\t"
	if (mode != "filter") {
		printf "%-30s %8s %8s %8s %8s %6s\n", "STAGE", "p50", "p95", "p99", "max", "n"
		printf "%-30s %8s %8s %8s %8s %6s\n", "-----", "---", "---", "---", "---", "-"
	}
}

function percentile_index(count, fraction,    idx) {
	idx = int(count * fraction)
	if (idx < 1) idx = 1
	return idx
}

function flush_stage() {
	if (n < 1) return
	printf "%-30s %7dms %7dms %7dms %7dms %6d\n", \
		current, vals[percentile_index(n, 0.50)], vals[percentile_index(n, 0.95)], \
		vals[percentile_index(n, 0.99)], vals[n], n
	n = 0
}

mode == "filter" {
	if ($1 ~ /^[0-9][0-9][0-9][0-9]-/ && $1 >= cutoff && $6 != "start" && ($5 + 0) > 0)
		print $4 "\t" ($5 + 0)
	next
}

{
	if (n > 0 && $1 != current) flush_stage()
	current = $1
	vals[++n] = $2 + 0
}

END {
	if (mode != "filter") flush_stage()
}
