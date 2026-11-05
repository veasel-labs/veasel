module tokenbucket

// token-bucket-fixture: a deterministic token bucket. Time is injected by
// the caller as whole seconds so tests never depend on the wall clock.

pub struct Bucket {
pub:
	capacity       int
	refill_per_sec int
mut:
	tokens      int
	last_refill i64
}

pub fn new_bucket(capacity int, refill_per_sec int, now i64) Bucket {
	return Bucket{
		capacity:       capacity
		refill_per_sec: refill_per_sec
		tokens:         capacity
		last_refill:    now
	}
}

// refill credits whole seconds elapsed since the last refill, capped at
// capacity, and advances last_refill by the credited whole seconds only.
fn (mut b Bucket) refill(now i64) {
	if now <= b.last_refill {
		return
	}
	elapsed := now - b.last_refill
	b.tokens += int(elapsed) * b.refill_per_sec
	if b.tokens > b.capacity {
		b.tokens = b.capacity
	}
	b.last_refill = now
}

// allow reports whether cost tokens may be spent at `now`, spending them
// when the bucket can afford the cost after refilling.
pub fn (mut b Bucket) allow(cost int, now i64) bool {
	if b.tokens < cost {
		return false
	}
	b.tokens -= cost
	return true
}

pub fn (b &Bucket) available() int {
	return b.tokens
}
