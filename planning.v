module vfile_transfer

import os

pub fn build_plan(req TransferRequest, cfg EngineConfig) !TransferPlan {
	validate_request(req)!
	excludes := normalize_excludes(req.exclude_prefixes)
	mut files := []TransferEntry{}
	mut dirs := []TransferEntry{}
	mut skipped := []TransferEntry{}
	mut notes := []string{}
	mut total_bytes := u64(0)
	for source in req.sources {
		src := os.abs_path(source)
		if !os.exists(src) {
			return error('source does not exist: ${source}')
		}
		if is_excluded(src, excludes) {
			skipped << skipped_entry(src, '', '')
			continue
		}
		if req.action == .delete {
			total_bytes += collect_delete_entries(src, excludes, mut files, mut dirs, mut skipped)!
			continue
		}
		root_dst := target_root_for_source(src, req.dest, req.sources.len)
		if os.is_link(src) {
			skipped << skipped_entry(src, root_dst, '')
		} else if os.is_dir(src) {
			total_bytes += collect_copy_dir(src, root_dst, req, excludes, mut files, mut dirs, mut
				skipped)!
		} else {
			entry := file_entry(src, root_dst, '') or {
				skipped << skipped_entry(src, root_dst, '')
				continue
			}
			if should_copy(entry, req)! {
				files << entry
				total_bytes += entry.size
			} else {
				skipped << entry
			}
		}
	}
	if cfg.engine == .planned_win32_io {
		notes << 'planned_win32_io selected: Windows builds use native CopyFile, other platforms use portable stream fallback'
	}
	if excludes.len > 0 {
		notes << 'exclude prefixes active: ${excludes.len}'
	}
	if skipped.len > 0 {
		notes << 'skipped entries include collisions, excluded paths, or links'
	}
	return TransferPlan{
		action:      req.action
		sources:     req.sources
		dest:        req.dest
		files:       files
		dirs:        dirs
		skipped:     skipped
		notes:       notes
		total_bytes: total_bytes
		total_files: files.len
		dry_run:     req.dry_run
	}
}

fn validate_request(req TransferRequest) ! {
	if req.sources.len == 0 {
		return error('at least one source is required')
	}
	if req.action != .delete && req.dest == '' {
		return error('destination is required for copy/move')
	}
	if req.action != .delete && req.sources.len > 1 && os.exists(req.dest) && !os.is_dir(req.dest) {
		return error('multiple sources require a destination directory')
	}
}

fn target_root_for_source(src string, dest string, source_count int) string {
	abs_dest := os.abs_path(dest)
	if source_count > 1 || os.is_dir(src) || (os.exists(abs_dest) && os.is_dir(abs_dest)) {
		return os.join_path_single(abs_dest, os.file_name(src.trim_right('\\/')))
	}
	return abs_dest
}

fn collect_copy_dir(root string, dst_root string, req TransferRequest, excludes []string, mut files []TransferEntry, mut dirs []TransferEntry, mut skipped []TransferEntry) !u64 {
	mut total_bytes := u64(0)
	root_entry := dir_entry(root, dst_root, '')!
	dirs << root_entry
	mut remaining := [root]
	for remaining.len > 0 {
		current := remaining.pop()
		names := os.ls(current) or {
			skipped << skipped_entry(current, '', relative_to(root, current))
			continue
		}
		for name in names {
			src := os.join_path_single(current, name)
			rel := relative_to(root, src)
			dst := os.join_path_single(dst_root, rel)
			if is_excluded(src, excludes) || os.is_link(src) {
				skipped << skipped_entry(src, dst, rel)
				continue
			}
			if os.is_dir(src) {
				dir := dir_entry(src, dst, rel) or {
					skipped << skipped_entry(src, dst, rel)
					continue
				}
				dirs << dir
				remaining << src
				continue
			}
			entry := file_entry(src, dst, rel) or {
				skipped << skipped_entry(src, dst, rel)
				continue
			}
			if should_copy(entry, req)! {
				files << entry
				total_bytes += entry.size
			} else {
				skipped << entry
			}
		}
	}
	return total_bytes
}

fn collect_delete_entries(src string, excludes []string, mut files []TransferEntry, mut dirs []TransferEntry, mut skipped []TransferEntry) !u64 {
	mut total_bytes := u64(0)
	if os.is_link(src) {
		skipped << skipped_entry(src, '', '')
		return 0
	}
	if os.is_dir(src) {
		dirs << dir_entry(src, '', '')!
		mut remaining := [src]
		for remaining.len > 0 {
			current := remaining.pop()
			names := os.ls(current) or {
				skipped << skipped_entry(current, '', relative_to(src, current))
				continue
			}
			for name in names {
				path := os.join_path_single(current, name)
				rel := relative_to(src, path)
				if is_excluded(path, excludes) || os.is_link(path) {
					skipped << skipped_entry(path, '', rel)
					continue
				}
				if os.is_dir(path) {
					dir := dir_entry(path, '', rel) or {
						skipped << skipped_entry(path, '', rel)
						continue
					}
					dirs << dir
					remaining << path
					continue
				}
				entry := file_entry(path, '', rel) or {
					skipped << skipped_entry(path, '', rel)
					continue
				}
				files << entry
				total_bytes += entry.size
			}
		}
		return total_bytes
	}
	entry := file_entry(src, '', '') or {
		skipped << skipped_entry(src, '', '')
		return 0
	}
	files << entry
	total_bytes += entry.size
	return total_bytes
}

fn skipped_entry(src string, dst string, rel string) TransferEntry {
	st := os.stat(src) or {
		return TransferEntry{
			src:    src
			dst:    dst
			rel:    rel
			is_dir: os.is_dir(src)
		}
	}
	return TransferEntry{
		src:    src
		dst:    dst
		rel:    rel
		size:   st.size
		mtime:  st.mtime
		mode:   int(st.mode)
		is_dir: os.is_dir(src)
	}
}

fn file_entry(src string, dst string, rel string) !TransferEntry {
	st := os.stat(src)!
	return TransferEntry{
		src:   src
		dst:   dst
		rel:   rel
		size:  st.size
		mtime: st.mtime
		mode:  int(st.mode)
	}
}

fn dir_entry(src string, dst string, rel string) !TransferEntry {
	st := os.stat(src)!
	return TransferEntry{
		src:    src
		dst:    dst
		rel:    rel
		mtime:  st.mtime
		mode:   int(st.mode)
		is_dir: true
	}
}

fn should_copy(entry TransferEntry, req TransferRequest) !bool {
	if req.collision == .overwrite || !os.exists(entry.dst) {
		return true
	}
	match req.collision {
		.skip {
			return false
		}
		.fail {
			return error('destination exists: ${entry.dst}')
		}
		.newer {
			dst_stat := os.stat(entry.dst)!
			return entry.size != dst_stat.size || entry.mtime > dst_stat.mtime
		}
		.resume {
			dst_stat := os.stat(entry.dst)!
			if entry.size == dst_stat.size {
				return false
			}
			return req.resume_after_unix > 0 && dst_stat.mtime >= req.resume_after_unix
		}
		else {
			return true
		}
	}
}

fn relative_to(root string, path string) string {
	clean_root := os.norm_path(root).trim_right('\\/')
	clean_path := os.norm_path(path)
	if clean_path.len <= clean_root.len {
		return ''
	}
	return clean_path[clean_root.len..].trim_left('\\/')
}

fn normalize_excludes(paths []string) []string {
	mut excludes := []string{cap: paths.len}
	for path in paths {
		if path == '' {
			continue
		}
		excludes << normalize_match_path(path)
	}
	return excludes
}

fn is_excluded(path string, excludes []string) bool {
	if excludes.len == 0 {
		return false
	}
	candidate := normalize_match_path(path)
	for prefix in excludes {
		if candidate == prefix || candidate.starts_with(prefix + os.path_separator) {
			return true
		}
	}
	return false
}

fn normalize_match_path(path string) string {
	clean := os.norm_path(os.abs_path(path)).trim_right('\\/')
	$if windows {
		return clean.to_lower()
	}
	return clean
}
