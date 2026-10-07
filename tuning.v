module vfile_transfer

import vperf_core

struct AdaptiveTuner {
mut:
	enabled         bool
	min_workers     int
	max_workers     int
	max_memory_mb   int
	max_cpu_percent int
	workers         int
	best_workers    int
	best_rate       f64
	best_score      f64
	best_file_rate  f64
	last_rate       f64
	last_score      f64
	last_file_rate  f64
	last_reason     string
}

const small_file_score_bytes = u64(256 * 1024)

fn new_adaptive_tuner(opts AdaptiveOptions, cfg EngineConfig) AdaptiveTuner {
	if !opts.enabled {
		return AdaptiveTuner{}
	}
	max_workers := normalize_max_workers(opts.max_workers)
	min_workers := clamp_int(opts.min_workers, 1, max_workers)
	start_workers := clamp_int(normalize_workers(cfg.workers), min_workers, max_workers)
	return AdaptiveTuner{
		enabled:         true
		min_workers:     min_workers
		max_workers:     max_workers
		max_memory_mb:   normalize_limit(opts.max_memory_mb, 768)
		max_cpu_percent: normalize_limit(opts.max_cpu_percent, 85)
		workers:         start_workers
		best_workers:    start_workers
	}
}

fn (t AdaptiveTuner) config(base EngineConfig) EngineConfig {
	if !t.enabled {
		return base
	}
	return EngineConfig{
		...base
		workers: t.workers
	}
}

fn (mut t AdaptiveTuner) observe(batch_index int, copied_bytes u64, resumed_bytes u64, file_count int, failed int, elapsed_seconds f64, cpu_start f64) {
	if !t.enabled {
		return
	}
	cpu_end := vperf_core.process_cpu_seconds()
	cpu_pct := vperf_core.process_cpu_percent(cpu_start, cpu_end, elapsed_seconds)
	mem_mb := vperf_core.process_memory_mb()
	free_mb := vperf_core.free_memory_mb()
	rate_bytes := if copied_bytes > 0 { copied_bytes } else { resumed_bytes }
	rate := if elapsed_seconds <= 0 { 0.0 } else { f64(rate_bytes) / elapsed_seconds }
	file_rate := if elapsed_seconds <= 0 { 0.0 } else { f64(file_count) / elapsed_seconds }
	score_bytes := rate_bytes + u64(file_count) * small_file_score_bytes
	score := if elapsed_seconds <= 0 { 0.0 } else { f64(score_bytes) / elapsed_seconds }
	current_workers := t.workers
	mut reason := 'hold'
	mut next_workers := current_workers
	if copied_bytes == 0 && resumed_bytes == 0 && failed == 0 {
		reason = 'resume-cleanup'
	} else {
		sample := vperf_core.WorkSample{
			items:           file_count
			bytes:           rate_bytes
			errors:          failed
			elapsed_ms:      i64(elapsed_seconds * 1000.0)
			cpu_percent:     cpu_pct
			used_memory_mb:  mem_mb
			free_memory_mb:  free_mb
			current_workers: current_workers
		}
		next_state := vperf_core.next_adaptive(vperf_core.AdaptiveState{
			workers:      current_workers
			best_workers: t.best_workers
			best_score:   t.best_score
			last_score:   t.last_score
			last_reason:  t.last_reason
		}, sample, vperf_core.ResourceBudget{
			min_workers:        t.min_workers
			max_workers:        t.max_workers
			max_memory_bytes:   u64(t.max_memory_mb) * 1024 * 1024
			target_cpu_percent: t.max_cpu_percent
		})
		next_workers = next_state.workers
		reason = next_state.last_reason
		if next_state.best_score > t.best_score {
			t.best_rate = rate
			t.best_file_rate = file_rate
		}
		t.best_score = next_state.best_score
		t.best_workers = next_state.best_workers
	}
	t.last_rate = rate
	t.last_score = score
	t.last_file_rate = file_rate
	t.last_reason = reason
	t.workers = next_workers
	gc_collect()
	free_label := if free_mb > 0 { ' free=${free_mb}MB' } else { '' }
	println('[adaptive] batch=${batch_index} workers=${current_workers}->${next_workers} rate=${throughput(u64(rate_bytes),
		elapsed_seconds)} files=${file_rate:.1f}/s score=${throughput(u64(score), 1.0)} cpu=${cpu_pct:.1f}% ram=${mem_mb}MB${free_label} best_workers=${t.best_workers} reason=${reason}')
}

fn (t AdaptiveTuner) summary_note() string {
	if !t.enabled {
		return ''
	}
	return 'adaptive best_workers=${t.best_workers} best_rate=${throughput(u64(t.best_rate), 1.0)} best_files=${t.best_file_rate:.1f}/s limits_ram=${t.max_memory_mb}MB limits_cpu=${t.max_cpu_percent}%'
}

fn normalize_max_workers(value int) int {
	if value > 0 {
		return clamp_int(value, 1, 128)
	}
	cores := vperf_core.logical_cpus()
	if cores <= 0 {
		return 4
	}
	return clamp_int(cores * 2, 1, 32)
}

fn normalize_limit(value int, fallback int) int {
	if value <= 0 {
		return fallback
	}
	return value
}

fn clamp_int(value int, min_value int, max_value int) int {
	if value < min_value {
		return min_value
	}
	if value > max_value {
		return max_value
	}
	return value
}
