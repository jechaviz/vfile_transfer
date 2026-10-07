module vfile_transfer

import vperf_core

pub struct DiskSpaceSnapshot {
pub:
	path         string
	total_bytes  u64
	free_bytes   u64
	used_bytes   u64
	needed_bytes u64
	complete     bool
	ok           bool
}

pub struct ProcessResourceSnapshot {
pub:
	pid          int
	cpu_seconds  f64
	memory_bytes u64
	complete     bool
}

pub fn disk_space(path string) !DiskSpaceSnapshot {
	check := vperf_core.disk_space(path, 0)!
	return disk_space_from_vperf(check)
}

pub fn require_free_space(path string, needed_bytes u64, label string) !DiskSpaceSnapshot {
	check := vperf_core.disk_space(path, needed_bytes)!
	if !check.ok {
		context := if label.trim_space() == '' { 'operation' } else { label.trim_space() }
		return error('not enough free space for ${context}: available=${human_bytes(check.free_bytes)} needed=${human_bytes(needed_bytes)}')
	}
	return disk_space_from_vperf(check)
}

fn disk_space_from_vperf(check vperf_core.DiskSpaceSnapshot) DiskSpaceSnapshot {
	return DiskSpaceSnapshot{
		path:         check.path
		total_bytes:  check.total_bytes
		free_bytes:   check.free_bytes
		used_bytes:   check.used_bytes
		needed_bytes: check.needed_bytes
		complete:     check.complete
		ok:           check.ok
	}
}

pub fn process_resource_snapshot(pid int) ProcessResourceSnapshot {
	snapshot := vperf_core.process_resource_snapshot(pid)
	return ProcessResourceSnapshot{
		pid:          snapshot.pid
		cpu_seconds:  snapshot.cpu_seconds
		memory_bytes: snapshot.memory_bytes
		complete:     snapshot.complete
	}
}

pub fn logical_cpus() int {
	return vperf_core.logical_cpus()
}
