-- Pointy Parenting: parent and child links (with the consent record) and
-- payments over a child's limit waiting for the parent.
CREATE TABLE IF NOT EXISTS family_links (
	id text PRIMARY KEY,
	parent_id text NOT NULL REFERENCES users(id),
	child_id text NOT NULL REFERENCES users(id),
	body jsonb NOT NULL,
	created_at timestamptz NOT NULL,
	seq bigserial
);
CREATE TABLE IF NOT EXISTS approvals (
	id text PRIMARY KEY,
	child_id text NOT NULL REFERENCES users(id),
	body jsonb NOT NULL,
	created_at timestamptz NOT NULL,
	seq bigserial
);
