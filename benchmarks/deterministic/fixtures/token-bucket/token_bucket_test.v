module tokenbucket

fn test_bucket_starts_full_and_spends() {
	mut b := new_bucket(3, 1, 100)
	assert b.allow(2, 100)
	assert b.available() == 1
	assert b.allow(1, 100)
	assert !b.allow(1, 100)
}

fn test_bucket_rejects_cost_above_capacity() {
	mut b := new_bucket(2, 1, 100)
	assert !b.allow(3, 100)
	assert b.available() == 2
}

fn test_bucket_refills_with_elapsed_time() {
	mut b := new_bucket(3, 2, 100)
	assert b.allow(3, 100)
	assert !b.allow(1, 100)
	// Two seconds later the bucket must hold min(3, 0 + 2*2) = 3 tokens.
	assert b.allow(3, 102)
	assert b.available() == 0
}

fn test_bucket_refill_caps_at_capacity() {
	mut b := new_bucket(2, 10, 0)
	assert b.allow(1, 0)
	// A long idle gap refills only up to capacity (2), never beyond.
	assert b.allow(2, 3600)
	assert b.available() == 0
	assert !b.allow(1, 3600)
}

fn test_limiter_tracks_keys_independently() {
	mut l := new_limiter(1, 1)
	assert l.allow('client-a', 50)
	assert !l.allow('client-a', 50)
	assert l.allow('client-b', 50)
	// After one second client-a has a fresh token again.
	assert l.allow('client-a', 51)
}
