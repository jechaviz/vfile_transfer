module vfile_transfer

import os
import vsearch

const scan_record_cap = 2_000_000_000
const scan_depth_cap = 1024

fn scan_dir_batches(root string, dst_root string, req TransferRequest, excludes []string, cfg EngineConfig, verify VerifyMode, batch_size int, mut state BatchState, mut receipt TransferReceipt) ! {
	mut walker := vsearch.new_index_walker(root, vsearch.IndexOptions{
		max_depth:             scan_depth_cap
		max_records:           scan_record_cap
		include_dirs:          false
		include_hidden:        true
		follow_symlinks:       false
		disable_default_skips: true
		exclude_paths:         excludes
	})!
	for {
		batch := walker.next_batch(batch_size)
		for warning in batch.warnings {
			state.skipped << skipped_entry(root, '', warning)
			flush_if_needed(req, cfg, verify, mut state, mut receipt, batch_size)!
			if state.safe_stop {
				return
			}
		}
		for record in batch.records {
			if state.safe_stop {
				return
			}
			if record.is_dir {
				continue
			}
			src := record.path
			rel := clean_record_rel(record.rel)
			dst := os.join_path_single(dst_root, rel)
			if is_excluded(src, excludes) || os.is_link(src) {
				state.skipped << skipped_entry(src, dst, rel)
				flush_if_needed(req, cfg, verify, mut state, mut receipt, batch_size)!
				if state.safe_stop {
					return
				}
				continue
			}
			add_file_to_batch(src, dst, rel, req, cfg, verify, mut state)!
			flush_if_needed(req, cfg, verify, mut state, mut receipt, batch_size)!
			if state.safe_stop {
				return
			}
		}
		if batch.done {
			break
		}
	}
}

fn clean_record_rel(rel string) string {
	if rel == '.' {
		return ''
	}
	return rel
}
