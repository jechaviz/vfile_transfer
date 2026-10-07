module vfile_transfer

import crypto.blake3
import encoding.hex
import os

pub fn hash_file_blake3(path string, buffer_bytes int) !string {
	mut digest := blake3.Digest.new_hash()!
	mut file := os.open(path)!
	defer {
		file.close()
	}
	mut buffer := []u8{len: normalize_buffer_size(buffer_bytes)}
	for {
		read := file.read(mut buffer) or {
			if err is os.Eof {
				break
			}
			return err
		}
		if read <= 0 {
			break
		}
		digest.write(buffer[..read])!
	}
	return hex.encode(digest.checksum(blake3.size256))
}

pub fn verify_entry(entry TransferEntry, mode VerifyMode, buffer_bytes int) !bool {
	match mode {
		.none {
			return true
		}
		.size {
			return os.file_size(entry.dst) == entry.size
		}
		.blake3 {
			src_hash := hash_file_blake3(entry.src, buffer_bytes)!
			dst_hash := hash_file_blake3(entry.dst, buffer_bytes)!
			return src_hash == dst_hash
		}
	}
}
