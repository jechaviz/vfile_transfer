module vfile_transfer

import os
import time

fn temp_test_root(prefix string) string {
	return os.join_path_single(os.temp_dir(), '${prefix}_${time.now().unix_milli()}')
}

fn test_copy_verify_and_delete() ! {
	root := temp_test_root('vfile_transfer_test')
	src := os.join_path_single(root, 'src')
	dst := os.join_path_single(root, 'dst')
	os.mkdir_all(os.join_path_single(src, 'nested'))!
	os.write_file(os.join_path(src, 'nested', 'hello.txt'), 'vfile_transfer')!
	plan := build_plan(TransferRequest{
		action:  .copy
		sources: [src]
		dest:    dst
		verify:  .size
	}, default_config())!
	assert plan.total_files == 1
	receipt := run_plan(plan, default_config(), .size)!
	assert receipt.ok()
	copied := os.join_path(dst, 'src', 'nested', 'hello.txt')
	assert os.read_file(copied)! == 'vfile_transfer'
	delete_plan := build_plan(TransferRequest{
		action:  .delete
		sources: [dst]
	}, default_config())!
	delete_receipt := run_plan(delete_plan, default_config(), .none)!
	assert delete_receipt.ok()
	assert !os.exists(dst)
	os.rmdir_all(root) or {}
}

fn test_collision_skip() ! {
	root := temp_test_root('vfile_transfer_skip')
	src := os.join_path_single(root, 'src.txt')
	dst := os.join_path_single(root, 'dst.txt')
	os.mkdir_all(root)!
	os.write_file(src, 'new')!
	os.write_file(dst, 'old')!
	plan := build_plan(TransferRequest{
		action:    .copy
		sources:   [src]
		dest:      dst
		collision: .skip
	}, default_config())!
	assert plan.total_files == 0
	assert plan.skipped.len == 1
	os.rmdir_all(root) or {}
}

fn test_exclude_prefix_skips_subtree() ! {
	root := temp_test_root('vfile_transfer_exclude')
	src := os.join_path_single(root, 'src')
	dst := os.join_path_single(root, 'dst')
	keep := os.join_path_single(src, 'keep')
	skip := os.join_path_single(src, 'skip')
	os.mkdir_all(keep)!
	os.mkdir_all(skip)!
	os.write_file(os.join_path_single(keep, 'a.txt'), 'a')!
	os.write_file(os.join_path_single(skip, 'b.txt'), 'b')!
	plan := build_plan(TransferRequest{
		action:           .copy
		sources:          [src]
		dest:             dst
		exclude_prefixes: [skip]
	}, default_config())!
	assert plan.total_files == 1
	assert plan.skipped.len == 1
	assert plan.files[0].src.ends_with('a.txt')
	os.rmdir_all(root) or {}
}

fn test_resume_collision_recopies_only_new_partial() ! {
	root := temp_test_root('vfile_transfer_resume')
	src := os.join_path_single(root, 'src.txt')
	dst := os.join_path_single(root, 'dst.txt')
	os.mkdir_all(root)!
	os.write_file(src, 'complete-data')!
	os.write_file(dst, 'partial')!
	checkpoint := time.now().unix() - 5
	os.utime(dst, checkpoint + 1, checkpoint + 1)!
	plan := build_plan(TransferRequest{
		action:            .copy
		sources:           [src]
		dest:              dst
		collision:         .resume
		resume_after_unix: checkpoint
	}, default_config())!
	assert plan.total_files == 1
	os.rmdir_all(root) or {}
}

fn test_batched_move_reports_moved_bytes() ! {
	root := temp_test_root('vfile_transfer_batch')
	src := os.join_path_single(root, 'src')
	dst := os.join_path_single(root, 'dst')
	os.mkdir_all(os.join_path_single(src, 'nested'))!
	for i in 0 .. 5 {
		os.write_file(os.join_path(src, 'nested', 'file_${i}.txt'), 'batch ${i}')!
	}
	receipt := run_request_batched(TransferRequest{
		action:  .move
		sources: [src]
		dest:    dst
		verify:  .size
	}, default_config(), .size, BatchOptions{
		max_files: 2
	})!
	assert receipt.ok()
	assert receipt.total_bytes > 0
	assert receipt.moved_bytes == receipt.total_bytes
	assert receipt.copied_bytes == 0
	assert !os.exists(src)
	assert os.exists(os.join_path(dst, 'src', 'nested', 'file_4.txt'))
	os.rmdir_all(root) or {}
}

fn test_batched_resume_move_deletes_completed_sources() ! {
	root := temp_test_root('vfile_transfer_batch_resume')
	src := os.join_path_single(root, 'src')
	dst := os.join_path_single(root, 'dst')
	src_file := os.join_path(src, 'nested', 'done.txt')
	dst_file := os.join_path(dst, 'src', 'nested', 'done.txt')
	os.mkdir_all(os.dir(src_file))!
	os.mkdir_all(os.dir(dst_file))!
	os.write_file(src_file, 'already copied')!
	os.write_file(dst_file, 'already copied')!
	os.chmod(src_file, 0o444)!
	receipt := run_request_batched(TransferRequest{
		action:    .move
		sources:   [src]
		dest:      dst
		collision: .resume
		verify:    .size
	}, default_config(), .size, BatchOptions{
		max_files: 2
	})!
	assert receipt.ok()
	assert receipt.moved_bytes == receipt.total_bytes
	assert !os.exists(src_file)
	assert os.exists(dst_file)
	os.rmdir_all(root) or {}
}

fn test_batched_move_keeps_git_like_directories() ! {
	root := temp_test_root('vfile_transfer_batch_git')
	src := os.join_path_single(root, 'src')
	dst := os.join_path_single(root, 'dst')
	git_file := os.join_path(src, '.git', 'config')
	os.mkdir_all(os.dir(git_file))!
	os.write_file(git_file, 'repo metadata')!
	receipt := run_request_batched(TransferRequest{
		action:  .move
		sources: [src]
		dest:    dst
		verify:  .size
	}, default_config(), .size, BatchOptions{
		max_files: 1
	})!
	assert receipt.ok()
	assert !os.exists(git_file)
	assert os.exists(os.join_path(dst, 'src', '.git', 'config'))
	os.rmdir_all(root) or {}
}

fn test_batched_move_safe_stop_finishes_current_batch() ! {
	root := temp_test_root('vfile_transfer_safe_stop')
	src := os.join_path_single(root, 'src')
	dst := os.join_path_single(root, 'dst')
	stop_file := os.join_path_single(root, 'vfile_transfer.stop')
	os.mkdir_all(src)!
	for i in 0 .. 5 {
		os.write_file(os.join_path(src, 'file_${i}.txt'), 'safe ${i}')!
	}
	os.write_file(stop_file, 'stop after first batch')!
	receipt := run_request_batched(TransferRequest{
		action:  .move
		sources: [src]
		dest:    dst
		verify:  .size
	}, default_config(), .size, BatchOptions{
		max_files: 2
		stop_file: stop_file
	})!
	assert receipt.ok()
	assert receipt.moved_bytes > 0
	assert receipt.moved_bytes < receipt.total_bytes + u64(1000)
	assert receipt.notes.any(it.contains('safe stop'))
	assert !os.exists(stop_file)
	assert os.exists(src)
	assert os.exists(os.join_path(dst, 'src', 'file_0.txt'))
	assert os.exists(os.join_path(src, 'file_4.txt'))
	os.rmdir_all(root) or {}
}

fn test_adaptive_batched_copy_completes() ! {
	root := temp_test_root('vfile_transfer_adaptive')
	src := os.join_path_single(root, 'src')
	dst := os.join_path_single(root, 'dst')
	os.mkdir_all(src)!
	for i in 0 .. 6 {
		os.write_file(os.join_path(src, 'file_${i}.txt'), 'adaptive ${i}')!
	}
	receipt := run_request_batched(TransferRequest{
		action:  .copy
		sources: [src]
		dest:    dst
		verify:  .size
	}, default_config(), .size, BatchOptions{
		max_files: 2
		adaptive:  AdaptiveOptions{
			enabled:         true
			min_workers:     1
			max_workers:     3
			max_memory_mb:   512
			max_cpu_percent: 95
		}
	})!
	assert receipt.ok()
	assert receipt.total_bytes > 0
	assert os.exists(os.join_path(dst, 'src', 'file_5.txt'))
	os.rmdir_all(root) or {}
}
