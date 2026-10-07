module vfile_transfer

import os
import time
import vperf_core

struct BatchState {
mut:
	files      []TransferEntry
	skipped    []TransferEntry
	completed  []TransferEntry
	bytes      u64
	index      int
	scanned    int
	total_done u64
	tuner      AdaptiveTuner
	stop_file  string
	safe_stop  bool
}

pub fn run_request_batched(req TransferRequest, cfg EngineConfig, verify VerifyMode, opts BatchOptions) !TransferReceipt {
	validate_request(req)!
	if req.action == .delete {
		plan := build_plan(req, cfg)!
		return run_plan(plan, cfg, verify)!
	}
	excludes := normalize_excludes(req.exclude_prefixes)
	safe_cfg := EngineConfig{
		...cfg
		allow_rename_fast: false
	}
	batch_size := normalize_batch_size(opts.max_files)
	mut state := BatchState{
		files:     []TransferEntry{cap: batch_size}
		skipped:   []TransferEntry{cap: batch_size}
		completed: []TransferEntry{cap: batch_size}
		tuner:     new_adaptive_tuner(opts.adaptive, safe_cfg)
		stop_file: opts.stop_file
	}
	mut receipt := TransferReceipt{
		action: req.action
		notes:  ['batched execution max_files=${batch_size}']
	}
	if opts.adaptive.enabled {
		receipt = TransferReceipt{
			...receipt
			notes: append_note(receipt.notes, 'adaptive transfer tuning enabled')
		}
	}
	mut sw := time.new_stopwatch()
	for source in req.sources {
		if state.safe_stop {
			break
		}
		src := os.abs_path(source)
		if !os.exists(src) {
			return error('source does not exist: ${source}')
		}
		if is_excluded(src, excludes) || os.is_link(src) {
			state.skipped << skipped_entry(src, '', '')
			flush_if_needed(req, safe_cfg, verify, mut state, mut receipt, batch_size)!
			continue
		}
		root_dst := target_root_for_source(src, req.dest, req.sources.len)
		if os.is_dir(src) {
			scan_dir_batches(src, root_dst, req, excludes, safe_cfg, verify, batch_size, mut state, mut
				receipt)!
		} else {
			add_file_to_batch(src, root_dst, '', req, safe_cfg, verify, mut state)!
			flush_if_needed(req, safe_cfg, verify, mut state, mut receipt, batch_size)!
		}
	}
	if !state.safe_stop {
		flush_batch(req, safe_cfg, verify, mut state, mut receipt)!
	}
	if req.action == .move && receipt.failed_files == 0 && !req.dry_run {
		cleanup_empty_source_dirs(req.sources, excludes)
		receipt = TransferReceipt{
			...receipt
			moved_bytes:  receipt.copied_bytes + receipt.moved_bytes
			copied_bytes: 0
		}
	}
	adaptive_note := state.tuner.summary_note()
	if adaptive_note != '' {
		receipt = TransferReceipt{
			...receipt
			notes: append_note(receipt.notes, adaptive_note)
		}
	}
	if state.safe_stop {
		receipt = TransferReceipt{
			...receipt
			notes: append_note(receipt.notes, 'safe stop requested after completed batch')
		}
	}
	sw.stop()
	return receipt.with_elapsed(sw.elapsed().seconds())
}

fn add_file_to_batch(src string, dst string, rel string, req TransferRequest, cfg EngineConfig, verify VerifyMode, mut state BatchState) ! {
	state.scanned++
	entry := file_entry(src, dst, rel) or {
		state.skipped << skipped_entry(src, dst, rel)
		return
	}
	if should_copy(entry, req)! {
		state.files << entry
		state.bytes += entry.size
	} else if can_finish_resumed_move(entry, req, cfg, verify) {
		state.completed << entry
	} else {
		state.skipped << entry
	}
}

fn flush_if_needed(req TransferRequest, cfg EngineConfig, verify VerifyMode, mut state BatchState, mut receipt TransferReceipt, batch_size int) ! {
	if state.files.len + state.completed.len >= batch_size || state.skipped.len >= batch_size {
		flush_batch(req, cfg, verify, mut state, mut receipt)!
	}
}

fn flush_batch(req TransferRequest, cfg EngineConfig, verify VerifyMode, mut state BatchState, mut receipt TransferReceipt) ! {
	if state.files.len == 0 && state.skipped.len == 0 && state.completed.len == 0 {
		return
	}
	state.index++
	batch_cfg := state.tuner.config(cfg)
	println('[batch] index=${state.index} files=${state.files.len} resumed=${state.completed.len} skipped=${state.skipped.len} bytes=${human_bytes(state.bytes)} scanned=${state.scanned} workers=${normalize_workers(batch_cfg.workers)}')
	os.flush()
	mut batch_receipt := TransferReceipt{
		action: req.action
	}
	cpu_start := vperf_core.process_cpu_seconds()
	mut batch_sw := time.new_stopwatch()
	if state.files.len > 0 || state.skipped.len > 0 {
		plan := TransferPlan{
			action:      req.action
			sources:     req.sources
			dest:        req.dest
			files:       state.files
			skipped:     state.skipped
			total_bytes: state.bytes
			total_files: state.files.len
			dry_run:     req.dry_run
			notes:       ['batch ${state.index}']
		}
		batch_receipt = run_plan(plan, batch_cfg, verify)!
	}
	resumed_receipt := finish_resumed_moves(state.completed, req.dry_run, batch_cfg, verify)
	batch_sw.stop()
	receipt = merge_receipts(receipt, batch_receipt)
	receipt = merge_receipts(receipt, resumed_receipt)
	batch_transfer_bytes := batch_receipt.copied_bytes + batch_receipt.moved_bytes
	resumed_transfer_bytes := resumed_receipt.moved_bytes
	batch_failed_files := batch_receipt.failed_files + resumed_receipt.failed_files
	batch_file_count := state.files.len + state.completed.len
	batch_elapsed_seconds := batch_sw.elapsed().seconds()
	state.total_done += batch_transfer_bytes + resumed_transfer_bytes
	println('[batch-done] index=${state.index} copied=${human_bytes(batch_transfer_bytes)} resumed=${human_bytes(resumed_transfer_bytes)} failed=${batch_failed_files} skipped=${batch_receipt.skipped_files} total_done=${human_bytes(state.total_done)}')
	os.flush()
	state.tuner.observe(state.index, batch_transfer_bytes, resumed_transfer_bytes,
		batch_file_count, batch_failed_files, batch_elapsed_seconds, cpu_start)
	state.files = []TransferEntry{cap: state.files.cap}
	state.skipped = []TransferEntry{cap: state.skipped.cap}
	state.completed = []TransferEntry{cap: state.completed.cap}
	state.bytes = 0
	if should_safe_stop(state.stop_file) {
		state.safe_stop = true
		acknowledge_safe_stop(state.stop_file)
		println('[safe-stop] requested file=${state.stop_file} completed_batch=${state.index}')
		os.flush()
	}
}

fn should_safe_stop(path string) bool {
	return path != '' && os.exists(path)
}

fn acknowledge_safe_stop(path string) {
	if path == '' {
		return
	}
	os.rm(path) or {}
}

fn can_finish_resumed_move(entry TransferEntry, req TransferRequest, cfg EngineConfig, verify VerifyMode) bool {
	if req.action != .move || req.collision != .resume || req.dry_run || !os.exists(entry.dst) {
		return false
	}
	dst_stat := os.stat(entry.dst) or { return false }
	if dst_stat.size != entry.size {
		return false
	}
	return verify_entry(entry, verify, cfg.buffer_bytes) or { false }
}

fn finish_resumed_moves(entries []TransferEntry, dry_run bool, cfg EngineConfig, verify VerifyMode) TransferReceipt {
	mut moved := u64(0)
	mut verified := 0
	mut skipped := 0
	mut failed := 0
	mut samples := []EntryResult{cap: max_result_samples}
	for entry in entries {
		if dry_run {
			skipped++
			continue
		}
		ok := verify_entry(entry, verify, cfg.buffer_bytes) or { false }
		if !ok {
			failed++
			if samples.len < max_result_samples {
				samples << failed_result(entry, 'resume verification failed')
			}
			continue
		}
		remove_file_force(entry.src) or {
			failed++
			if samples.len < max_result_samples {
				samples << failed_result(entry, err.msg())
			}
			continue
		}
		moved += entry.size
		if verify != .none {
			verified++
		}
	}
	return TransferReceipt{
		action:         .move
		total_bytes:    moved
		moved_bytes:    moved
		verified_files: verified
		skipped_files:  skipped
		failed_files:   failed
		results:        samples
	}
}

fn merge_receipts(left TransferReceipt, right TransferReceipt) TransferReceipt {
	mut samples := left.results.clone()
	for result in right.results {
		if samples.len >= max_result_samples {
			break
		}
		samples << result
	}
	return TransferReceipt{
		action:         left.action
		total_bytes:    left.total_bytes + right.total_bytes
		copied_bytes:   left.copied_bytes + right.copied_bytes
		moved_bytes:    left.moved_bytes + right.moved_bytes
		deleted_bytes:  left.deleted_bytes + right.deleted_bytes
		verified_files: left.verified_files + right.verified_files
		skipped_files:  left.skipped_files + right.skipped_files
		failed_files:   left.failed_files + right.failed_files
		results:        samples
		notes:          left.notes
	}
}

fn cleanup_empty_source_dirs(sources []string, excludes []string) {
	for source in sources {
		src := os.abs_path(source)
		if !os.is_dir(src) || is_excluded(src, excludes) {
			continue
		}
		mut dirs := []string{}
		mut remaining := [src]
		for remaining.len > 0 {
			current := remaining.pop()
			if is_excluded(current, excludes) || os.is_link(current) {
				continue
			}
			dirs << current
			names := os.ls(current) or { continue }
			for name in names {
				child := os.join_path_single(current, name)
				if os.is_dir(child) && !os.is_link(child) {
					remaining << child
				}
			}
		}
		for i := dirs.len - 1; i >= 0; i-- {
			os.rmdir(dirs[i]) or {}
		}
	}
}

fn normalize_batch_size(value int) int {
	if value <= 0 {
		return 500
	}
	return value
}

fn append_note(notes []string, note string) []string {
	mut next := notes.clone()
	next << note
	return next
}
