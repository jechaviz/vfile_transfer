module vfile_transfer

import os
import sync
import time

struct ProgressState {
mut:
	last_ms i64 = -1
}

const max_result_samples = 200
const max_live_errors = 50

pub fn run_plan(plan TransferPlan, cfg EngineConfig, verify VerifyMode) !TransferReceipt {
	mut sw := time.new_stopwatch()
	mut notes := plan.notes.clone()
	if plan.action == .delete {
		receipt := run_delete_plan(plan, mut notes)!
		sw.stop()
		return receipt.with_elapsed(sw.elapsed().seconds())
	}
	if plan.action == .move && cfg.allow_rename_fast && can_fast_rename(plan) {
		if receipt := try_fast_rename(plan, mut notes, mut sw) {
			return receipt
		}
	}
	prepare_dirs(plan, cfg)!
	mut receipt := run_file_workers(plan, cfg, verify)!
	if plan.action == .move && receipt.failed_files == 0 && !plan.dry_run {
		delete_sources_after_move(plan, mut receipt)!
	}
	sw.stop()
	return receipt.with_elapsed(sw.elapsed().seconds())
}

fn prepare_dirs(plan TransferPlan, cfg EngineConfig) ! {
	if plan.dry_run || !cfg.precreate_dirs {
		return
	}
	for dir in plan.dirs {
		os.mkdir_all(dir.dst)!
		if cfg.preserve_times {
			os.utime(dir.dst, dir.mtime, dir.mtime) or {}
		}
	}
}

fn run_file_workers(plan TransferPlan, cfg EngineConfig, verify VerifyMode) !TransferReceipt {
	if plan.files.len == 0 {
		return empty_receipt(plan)
	}
	mut sw := time.new_stopwatch()
	mut progress := ProgressState{}
	mut done_bytes := u64(0)
	mut done_files := 0
	mut failed_files := 0
	mut skipped_files := plan.skipped.len
	mut verified_files := 0
	mut sample_results := []EntryResult{cap: max_result_samples}
	workers := bounded_worker_count(cfg.workers, plan.files.len)
	jobs := chan TransferEntry{cap: cfg.queue_depth}
	results := chan EntryResult{cap: cfg.queue_depth}
	mut threads := []thread{}
	mut dir_mutex := sync.new_mutex()
	for id in 0 .. workers {
		threads << spawn copy_worker(id, jobs, results, cfg, verify, plan.dry_run, mut dir_mutex)
	}
	producer_thread := spawn feed_jobs(&plan.files, jobs)
	print_progress(cfg, plan, done_files, done_bytes, failed_files, sw.elapsed().seconds(), mut
		progress, false)
	for _ in 0 .. plan.files.len {
		result := <-results
		done_files++
		if result.error != '' {
			failed_files++
			if sample_results.len < max_result_samples {
				sample_results << result
			}
			if failed_files <= max_live_errors {
				print_live_error(result)
			}
		} else if result.skipped {
			skipped_files++
		} else if !result.skipped {
			done_bytes += result.bytes
			if result.verified {
				verified_files++
			}
		}
		print_progress(cfg, plan, done_files, done_bytes, failed_files, sw.elapsed().seconds(), mut
			progress, done_files == plan.files.len)
	}
	producer_thread.wait()
	for t in threads {
		t.wait()
	}
	return TransferReceipt{
		action:         plan.action
		total_bytes:    plan.total_bytes
		copied_bytes:   done_bytes
		verified_files: verified_files
		skipped_files:  skipped_files
		failed_files:   failed_files
		results:        sample_results
		notes:          plan.notes
	}
}

fn print_progress(cfg EngineConfig, plan TransferPlan, done_files int, done_bytes u64, failed_files int, elapsed_seconds f64, mut progress ProgressState, force bool) {
	if cfg.progress_interval_ms <= 0 {
		return
	}
	elapsed_ms := i64(elapsed_seconds * 1000.0)
	if !force && progress.last_ms >= 0 && elapsed_ms - progress.last_ms < cfg.progress_interval_ms {
		return
	}
	progress.last_ms = elapsed_ms
	pct := if plan.total_bytes == 0 {
		100.0
	} else {
		(f64(done_bytes) / f64(plan.total_bytes)) * 100.0
	}
	println('[progress] action=${plan.action} files=${done_files}/${plan.total_files} bytes=${human_bytes(done_bytes)}/${human_bytes(plan.total_bytes)} pct=${pct:.2f}% rate=${throughput(done_bytes,
		elapsed_seconds)} skipped=${plan.skipped.len} failed=${failed_files}')
	os.flush()
}

fn print_live_error(result EntryResult) {
	println('[error] src=${result.src} dst=${result.dst} msg=${result.error}')
	os.flush()
}

fn copy_worker(_id int, jobs chan TransferEntry, results chan EntryResult, cfg EngineConfig, verify VerifyMode, dry_run bool, mut dir_mutex sync.Mutex) {
	for {
		entry := <-jobs or { break }
		results <- copy_entry(entry, cfg, verify, dry_run, mut dir_mutex)
	}
}

fn feed_jobs(files &[]TransferEntry, jobs chan TransferEntry) {
	for entry in *files {
		jobs <- entry
	}
	jobs.close()
}

fn copy_entry(entry TransferEntry, cfg EngineConfig, verify VerifyMode, dry_run bool, mut dir_mutex sync.Mutex) EntryResult {
	if dry_run {
		return EntryResult{
			src:     entry.src
			dst:     entry.dst
			rel:     entry.rel
			skipped: true
		}
	}
	ensure_parent_dir(entry, mut dir_mutex) or { return failed_result(entry, err.msg()) }
	mut copy_error := ''
	for attempt in 0 .. cfg.copy_retries + 1 {
		copy_file(entry, cfg) or {
			copy_error = err.msg()
			if attempt < cfg.copy_retries {
				time.sleep(50 * time.millisecond)
				continue
			}
			return failed_result(entry, copy_error)
		}
		copy_error = ''
		break
	}
	if copy_error != '' {
		return failed_result(entry, copy_error)
	}
	if cfg.preserve_times {
		os.utime(entry.dst, entry.mtime, entry.mtime) or {}
	}
	if cfg.preserve_permissions {
		os.chmod(entry.dst, entry.mode) or {}
	}
	verified := verify_entry(entry, verify, cfg.buffer_bytes) or {
		return failed_result(entry, err.msg())
	}
	if !verified {
		return failed_result(entry, 'verification failed')
	}
	return EntryResult{
		src:      entry.src
		dst:      entry.dst
		rel:      entry.rel
		bytes:    entry.size
		verified: verify != .none
	}
}

fn ensure_parent_dir(entry TransferEntry, mut dir_mutex sync.Mutex) ! {
	dir := os.dir(entry.dst)
	dir_mutex.lock()
	defer {
		dir_mutex.unlock()
	}
	os.mkdir_all(dir) or {
		if os.is_dir(dir) {
			return
		}
		return error('folder: ${dir}, error: ${err}')
	}
}

fn copy_file(entry TransferEntry, cfg EngineConfig) !u64 {
	match cfg.engine {
		.portable_stream {
			return copy_file_stream(entry.src, entry.dst, cfg.buffer_bytes)
		}
		.planned_win32_io {
			return copy_file_win32(entry.src, entry.dst, cfg.buffer_bytes)
		}
	}
}

fn copy_file_win32(src string, dst string, buffer_bytes int) !u64 {
	$if windows {
		os.cp(src, dst)!
		return os.file_size(dst)
	} $else {
		return copy_file_stream(src, dst, buffer_bytes)
	}
}

fn copy_file_stream(src string, dst string, buffer_bytes int) !u64 {
	mut input := os.open(src)!
	defer {
		input.close()
	}
	mut output := os.create(dst)!
	defer {
		output.close()
	}
	mut copied := u64(0)
	mut buffer := []u8{len: normalize_buffer_size(buffer_bytes)}
	for {
		read := input.read(mut buffer) or {
			if err is os.Eof {
				break
			}
			return err
		}
		if read <= 0 {
			break
		}
		unsafe { output.write_full_buffer(buffer.data, usize(read))! }
		copied += u64(read)
	}
	return copied
}

fn run_delete_plan(plan TransferPlan, mut notes []string) !TransferReceipt {
	mut results := []EntryResult{cap: plan.files.len + plan.dirs.len}
	for entry in plan.files {
		if plan.dry_run {
			results << EntryResult{
				src:     entry.src
				rel:     entry.rel
				bytes:   entry.size
				skipped: true
			}
			continue
		}
		remove_file_force(entry.src) or {
			results << failed_result(entry, err.msg())
			continue
		}
		results << EntryResult{
			src:   entry.src
			rel:   entry.rel
			bytes: entry.size
		}
	}
	for i := plan.dirs.len - 1; i >= 0; i-- {
		dir := plan.dirs[i]
		if plan.dry_run {
			results << EntryResult{
				src:     dir.src
				rel:     dir.rel
				skipped: true
			}
			continue
		}
		os.rmdir(dir.src) or {
			results << failed_result(dir, err.msg())
			continue
		}
		results << EntryResult{
			src: dir.src
			rel: dir.rel
		}
	}
	mut receipt := receipt_from_results(plan, results)
	notes << 'delete dirs are removed deepest-first'
	receipt = receipt.with_notes(notes)
	return receipt
}

fn delete_sources_after_move(plan TransferPlan, mut receipt TransferReceipt) ! {
	mut failed := receipt.failed_files
	mut moved := u64(0)
	mut samples := receipt.results.clone()
	for file in plan.files {
		remove_file_force(file.src) or {
			failed++
			if samples.len < max_result_samples {
				samples << failed_result(file, err.msg())
			}
			continue
		}
		moved += file.size
	}
	for i := plan.dirs.len - 1; i >= 0; i-- {
		if plan.dirs[i].dst != '' && !os.exists(plan.dirs[i].dst) {
			continue
		}
		os.rmdir(plan.dirs[i].src) or {}
	}
	remaining_copied := if receipt.copied_bytes >= moved {
		receipt.copied_bytes - moved
	} else {
		u64(0)
	}
	receipt = TransferReceipt{
		...receipt
		moved_bytes:  moved
		copied_bytes: remaining_copied
		failed_files: failed
		results:      samples
	}
}

fn remove_file_force(path string) ! {
	os.rm(path) or {
		os.chmod(path, 0o666) or {}
		os.rm(path)!
	}
}

fn can_fast_rename(plan TransferPlan) bool {
	return plan.sources.len == 1 && plan.files.len + plan.dirs.len > 0 && !plan.dry_run
}

fn try_fast_rename(plan TransferPlan, mut notes []string, mut sw time.StopWatch) ?TransferReceipt {
	source := os.abs_path(plan.sources[0])
	target := if plan.dirs.len > 0 { plan.dirs[0].dst } else { plan.files[0].dst }
	os.mkdir_all(os.dir(target)) or { return none }
	os.rename(source, target) or { return none }
	notes << 'rename fast path completed before streaming copy'
	sw.stop()
	return TransferReceipt{
		action:          .move
		total_bytes:     plan.total_bytes
		moved_bytes:     plan.total_bytes
		elapsed_seconds: sw.elapsed().seconds()
		notes:           notes
		results:         [
			EntryResult{
				src:   source
				dst:   target
				bytes: plan.total_bytes
			},
		]
	}
}

fn receipt_from_results(plan TransferPlan, results []EntryResult) TransferReceipt {
	mut copied := u64(0)
	mut deleted := u64(0)
	mut skipped := 0
	mut failed := 0
	mut verified := 0
	for result in results {
		if result.error != '' {
			failed++
			continue
		}
		if result.skipped {
			skipped++
			continue
		}
		if result.verified {
			verified++
		}
		if plan.action == .delete {
			deleted += result.bytes
		} else {
			copied += result.bytes
		}
	}
	return TransferReceipt{
		action:         plan.action
		total_bytes:    plan.total_bytes
		copied_bytes:   copied
		deleted_bytes:  deleted
		verified_files: verified
		skipped_files:  skipped
		failed_files:   failed
		results:        results
		notes:          plan.notes
	}
}

fn empty_receipt(plan TransferPlan) TransferReceipt {
	return TransferReceipt{
		action:        plan.action
		total_bytes:   plan.total_bytes
		skipped_files: plan.skipped.len
		results:       []EntryResult{}
		notes:         plan.notes
	}
}

fn (receipt TransferReceipt) with_elapsed(seconds f64) TransferReceipt {
	return TransferReceipt{
		...receipt
		elapsed_seconds: seconds
	}
}

fn (receipt TransferReceipt) with_notes(notes []string) TransferReceipt {
	return TransferReceipt{
		...receipt
		notes: notes
	}
}

fn failed_result(entry TransferEntry, message string) EntryResult {
	return EntryResult{
		src:   entry.src
		dst:   entry.dst
		rel:   entry.rel
		bytes: entry.size
		error: message
	}
}

fn bounded_worker_count(configured int, file_count int) int {
	workers := normalize_workers(configured)
	if file_count < workers {
		return file_count
	}
	return workers
}
