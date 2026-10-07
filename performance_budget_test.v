module vfile_transfer

import os
import vperf_core

fn test_batch_options_from_resource_budget_enables_adaptive_limits() {
	opts := batch_options_from_resource_budget(250, 'stop.flag', vperf_core.ResourceBudget{
		min_workers:        2
		max_workers:        6
		max_memory_bytes:   300 * 1024 * 1024
		target_cpu_percent: 70
	})
	assert opts.max_files == 250
	assert opts.stop_file == 'stop.flag'
	assert opts.adaptive.enabled
	assert opts.adaptive.min_workers == 2
	assert opts.adaptive.max_workers == 6
	assert opts.adaptive.max_memory_mb == 300
	assert opts.adaptive.max_cpu_percent == 70
}

fn test_resource_wrappers_expose_disk_budget_snapshots() ! {
	snapshot := disk_space(os.temp_dir())!
	assert snapshot.path.len > 0
	assert snapshot.total_bytes >= snapshot.free_bytes
	assert snapshot.ok

	required := require_free_space(os.temp_dir(), 1, 'test write')!
	assert required.needed_bytes == 1
	assert required.ok
}
