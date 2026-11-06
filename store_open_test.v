module main

import os
import rand

fn test_open_store_corrupt_file_reports_path_and_preserves_it() {
	// Regression: a corrupt session store surfaced only as "unable to
	// configure SQLite journal mode", with no file path and no remedy, so
	// users could not tell which file to move aside to recover.
	root := os.join_path(os.temp_dir(), 'veasel-store-corrupt-${rand.ulid()}')
	defer { os.rmdir_all(root) or {} }
	os.mkdir_all(root) or { panic(err) }
	path := os.join_path(root, 'veasel.sqlite3')
	garbage := 'this is not a sqlite database at all, just text text text'
	os.write_file(path, garbage) or { panic(err) }
	open_store(path) or {
		assert err.msg().contains(path)
		assert err.msg().contains('corrupt')
		// Recovery guidance must not come at the cost of the data: the
		// corrupt file stays exactly as it was for manual inspection.
		assert (os.read_file(path) or { panic(err) }) == garbage
		return
	}
	assert false, 'open_store accepted a corrupt database file'
}
