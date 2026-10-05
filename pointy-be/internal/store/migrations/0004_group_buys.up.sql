-- Group purchases found by a trip's AI shopping agent. Each holds every
-- member's share (held in the trip wallet or authorized on PayPal) until
-- all are in.
CREATE TABLE IF NOT EXISTS group_buys (
	id text PRIMARY KEY,
	trip_id text NOT NULL REFERENCES trips(id),
	body jsonb NOT NULL,
	created_at timestamptz NOT NULL,
	seq bigserial
);
