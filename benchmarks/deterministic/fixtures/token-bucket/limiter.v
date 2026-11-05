module tokenbucket

// Limiter keeps one Bucket per key (for example per client), creating a
// full bucket the first time a key is seen.
pub struct Limiter {
	capacity       int
	refill_per_sec int
mut:
	buckets map[string]Bucket
}

pub fn new_limiter(capacity int, refill_per_sec int) Limiter {
	return Limiter{
		capacity:       capacity
		refill_per_sec: refill_per_sec
	}
}

pub fn (mut l Limiter) allow(key string, now i64) bool {
	mut bucket := l.buckets[key] or { new_bucket(l.capacity, l.refill_per_sec, now) }
	allowed := bucket.allow(1, now)
	l.buckets[key] = bucket
	return allowed
}
