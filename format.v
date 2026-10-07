module vfile_transfer

pub fn human_bytes(value u64) string {
	units := ['B', 'KB', 'MB', 'GB', 'TB', 'PB']
	mut amount := f64(value)
	mut unit_idx := 0
	for amount >= 1024.0 && unit_idx < units.len - 1 {
		amount /= 1024.0
		unit_idx++
	}
	if unit_idx == 0 {
		return '${value} ${units[unit_idx]}'
	}
	return '${amount:.2f} ${units[unit_idx]}'
}

pub fn throughput(bytes u64, seconds f64) string {
	if seconds <= 0 {
		return 'n/a'
	}
	per_second := u64(f64(bytes) / seconds)
	return '${human_bytes(per_second)}/s'
}

pub fn normalize_buffer_size(size int) int {
	if size <= 0 {
		return default_buffer_bytes
	}
	if size < 64 * 1024 {
		return 64 * 1024
	}
	return size
}

pub fn normalize_workers(workers int) int {
	if workers <= 0 {
		return 1
	}
	if workers > 64 {
		return 64
	}
	return workers
}
