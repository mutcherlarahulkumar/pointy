-- The AI assistant's conversations, one row per message.
CREATE TABLE IF NOT EXISTS chat_messages (
	id text PRIMARY KEY,
	user_id text NOT NULL REFERENCES users(id),
	body jsonb NOT NULL,
	at timestamptz NOT NULL,
	seq bigserial
);
CREATE INDEX IF NOT EXISTS chat_messages_user ON chat_messages (user_id, seq);
