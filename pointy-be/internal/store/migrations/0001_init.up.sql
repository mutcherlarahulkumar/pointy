-- 0001 init: the tables Pointy started with. IF NOT EXISTS lets a database
-- created before migrations existed adopt this version without changes.
CREATE TABLE IF NOT EXISTS users (
	id text PRIMARY KEY,
	name text NOT NULL,
	phone text NOT NULL UNIQUE,
	pin_hash text NOT NULL,
	alerts_seen_at timestamptz NOT NULL,
	created_at timestamptz NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS sessions (
	token_hash text PRIMARY KEY,
	user_id text NOT NULL REFERENCES users(id),
	created_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS trips (
	id text PRIMARY KEY,
	name text NOT NULL,
	place text NOT NULL,
	start_at timestamptz NOT NULL,
	end_at timestamptz NOT NULL,
	organiser_id text NOT NULL REFERENCES users(id),
	members jsonb NOT NULL,
	deposit_target bigint NOT NULL,
	budgets jsonb NOT NULL,
	status text NOT NULL,
	created_at timestamptz NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS ledger_entries (
	id text PRIMARY KEY,
	kind text NOT NULL,
	trip_id text NOT NULL,
	ref text NOT NULL,
	at timestamptz NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS ledger_postings (
	entry_id text NOT NULL REFERENCES ledger_entries(id),
	line int NOT NULL,
	account text NOT NULL,
	debit bigint NOT NULL CHECK (debit >= 0),
	credit bigint NOT NULL CHECK (credit >= 0),
	PRIMARY KEY (entry_id, line)
);
CREATE INDEX IF NOT EXISTS ledger_postings_account ON ledger_postings(account);
CREATE TABLE IF NOT EXISTS deposits (
	order_id text PRIMARY KEY,
	id text NOT NULL,
	trip_id text NOT NULL,
	user_id text NOT NULL REFERENCES users(id),
	amount bigint NOT NULL,
	approve_url text NOT NULL,
	status text NOT NULL,
	created_at timestamptz NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS expenses (
	id text PRIMARY KEY,
	trip_id text NOT NULL,
	paid_by text NOT NULL REFERENCES users(id),
	description text NOT NULL,
	category text NOT NULL,
	amount bigint NOT NULL,
	mode text NOT NULL,
	payee text NOT NULL,
	payee_user_id text NOT NULL,
	shares jsonb NOT NULL,
	place_name text NOT NULL,
	place_type text NOT NULL,
	lat double precision NOT NULL,
	lng double precision NOT NULL,
	at timestamptz NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS deposit_requests (
	id text PRIMARY KEY,
	trip_id text NOT NULL REFERENCES trips(id),
	user_id text NOT NULL REFERENCES users(id),
	amount bigint NOT NULL,
	due timestamptz NOT NULL,
	status text NOT NULL,
	reminders jsonb NOT NULL,
	paid_at timestamptz,
	paid_via text NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS plans (
	id text PRIMARY KEY,
	trip_id text NOT NULL REFERENCES trips(id),
	body jsonb NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS alerts (
	id text PRIMARY KEY,
	trip_id text NOT NULL,
	user_id text NOT NULL,
	kind text NOT NULL,
	title text NOT NULL,
	body text NOT NULL,
	at timestamptz NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS money_requests (
	id text PRIMARY KEY,
	requester_id text NOT NULL REFERENCES users(id),
	payer_id text NOT NULL REFERENCES users(id),
	amount bigint NOT NULL,
	note text NOT NULL,
	status text NOT NULL,
	created_at timestamptz NOT NULL,
	closed_at timestamptz,
	seq bigserial
);
