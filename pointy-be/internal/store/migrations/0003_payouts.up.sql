-- PayPal payouts: money leaving Pointy's business account for a real
-- PayPal account. Where each person is paid out, and which expenses a
-- payout paid.
ALTER TABLE users ADD COLUMN IF NOT EXISTS paypal_email text NOT NULL DEFAULT '';
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS payee_email text NOT NULL DEFAULT '';
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS payout_id text NOT NULL DEFAULT '';
CREATE TABLE IF NOT EXISTS payouts (
	id text PRIMARY KEY,
	user_id text NOT NULL REFERENCES users(id),
	body jsonb NOT NULL,
	created_at timestamptz NOT NULL,
	seq bigserial
);
