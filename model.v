module vfile_transfer

pub const default_buffer_bytes = 8 * 1024 * 1024
pub const default_queue_depth = 128

pub enum TransferAction {
	copy
	move
	delete
}

pub enum CollisionPolicy {
	overwrite
	skip
	fail
	newer
	resume
}

pub enum VerifyMode {
	none
	size
	blake3
}

pub enum EngineKind {
	portable_stream
	planned_win32_io
}

pub struct EngineConfig {
pub:
	workers              int        = 4
	buffer_bytes         int        = default_buffer_bytes
	queue_depth          int        = default_queue_depth
	engine               EngineKind = .portable_stream
	preserve_times       bool       = true
	preserve_permissions bool       = true
	allow_rename_fast    bool       = true
	progress_interval_ms int
	precreate_dirs       bool
	copy_retries         int = 2
}

pub struct BatchOptions {
pub:
	max_files int = 500
	adaptive  AdaptiveOptions
	stop_file string
}

pub struct AdaptiveOptions {
pub:
	enabled         bool
	min_workers     int = 1
	max_workers     int
	max_memory_mb   int = 768
	max_cpu_percent int = 85
}

pub struct TransferRequest {
pub:
	action            TransferAction
	sources           []string
	dest              string
	collision         CollisionPolicy = .overwrite
	verify            VerifyMode
	dry_run           bool
	exclude_prefixes  []string
	resume_after_unix i64
}

pub struct TransferEntry {
pub:
	src    string
	dst    string
	rel    string
	size   u64
	mtime  i64
	mode   int
	is_dir bool
}

pub struct TransferPlan {
pub:
	action      TransferAction
	sources     []string
	dest        string
	files       []TransferEntry
	dirs        []TransferEntry
	skipped     []TransferEntry
	notes       []string
	total_bytes u64
	total_files int
	dry_run     bool
}

pub struct EntryResult {
pub:
	src      string
	dst      string
	rel      string
	bytes    u64
	skipped  bool
	verified bool
	error    string
}

pub struct TransferReceipt {
pub:
	action          TransferAction
	total_bytes     u64
	copied_bytes    u64
	moved_bytes     u64
	deleted_bytes   u64
	verified_files  int
	skipped_files   int
	failed_files    int
	elapsed_seconds f64
	results         []EntryResult
	notes           []string
}

pub fn default_config() EngineConfig {
	return EngineConfig{}
}

pub fn (receipt TransferReceipt) ok() bool {
	return receipt.failed_files == 0
}
