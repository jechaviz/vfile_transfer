module vfile_transfer

import vperf_core

const perf_budget_bytes_per_mib = u64(1024 * 1024)

pub fn adaptive_options_from_resource_budget(budget vperf_core.ResourceBudget) AdaptiveOptions {
	return AdaptiveOptions{
		enabled:         true
		min_workers:     perf_budget_min_workers(budget)
		max_workers:     perf_budget_max_workers(budget)
		max_memory_mb:   perf_budget_memory_mb(budget)
		max_cpu_percent: perf_budget_cpu_percent(budget)
	}
}

pub fn batch_options_from_resource_budget(max_files int, stop_file string, budget vperf_core.ResourceBudget) BatchOptions {
	return BatchOptions{
		max_files: if max_files > 0 { max_files } else { 500 }
		adaptive:  adaptive_options_from_resource_budget(budget)
		stop_file: stop_file
	}
}

fn perf_budget_min_workers(budget vperf_core.ResourceBudget) int {
	return if budget.min_workers > 0 { budget.min_workers } else { 1 }
}

fn perf_budget_max_workers(budget vperf_core.ResourceBudget) int {
	if budget.max_workers > 0 {
		return budget.max_workers
	}
	cores := vperf_core.logical_cpus()
	if cores <= 0 {
		return 4
	}
	return if cores > 16 { 16 } else { cores }
}

fn perf_budget_memory_mb(budget vperf_core.ResourceBudget) int {
	if budget.max_memory_bytes == 0 {
		return 768
	}
	return int((budget.max_memory_bytes + perf_budget_bytes_per_mib - 1) / perf_budget_bytes_per_mib)
}

fn perf_budget_cpu_percent(budget vperf_core.ResourceBudget) int {
	return if budget.target_cpu_percent > 0 { budget.target_cpu_percent } else { 85 }
}
