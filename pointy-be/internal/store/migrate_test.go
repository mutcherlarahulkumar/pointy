package store

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestMigrationFiles(t *testing.T) {
	all, err := Migrations()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) == 0 || all[0].Version != 1 {
		t.Fatalf("want migrations starting at 0001, got %+v", all)
	}
}

// TestMigrateUpDown needs a throwaway database:
// POINTY_TEST_DATABASE_URL=postgres://... go test ./internal/store
func TestMigrateUpDown(t *testing.T) {
	url := os.Getenv("POINTY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()

	// Work in a schema of its own so this can run alongside the end-to-end
	// test, which uses the same database.
	admin, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	if _, err := admin.Exec(ctx, `DROP SCHEMA IF EXISTS migrate_test CASCADE; CREATE SCHEMA migrate_test`); err != nil {
		t.Fatal(err)
	}
	defer admin.Exec(ctx, `DROP SCHEMA IF EXISTS migrate_test CASCADE`) //nolint:errcheck
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = "migrate_test"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	all, _ := Migrations()
	reset := func() {
		if _, err := pool.Exec(ctx, `DROP TABLE IF EXISTS ledger_postings, ledger_entries, sessions, deposits, expenses, deposit_requests, plans, alerts, money_requests, chat_messages, trips, users, schema_migrations CASCADE`); err != nil {
			t.Fatal(err)
		}
	}
	tableExists := func(name string) bool {
		var ok bool
		if err := pool.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, name).Scan(&ok); err != nil {
			t.Fatal(err)
		}
		return ok
	}
	reset()

	ran, err := Migrate(ctx, pool, Up, 0)
	if err != nil || len(ran) != len(all) {
		t.Fatalf("up: ran %v, err %v", ran, err)
	}
	if !tableExists("users") {
		t.Fatal("users table missing after up")
	}
	if ran, _ := Migrate(ctx, pool, Up, 0); len(ran) != 0 {
		t.Fatalf("second up should do nothing, ran %v", ran)
	}

	ran, err = Migrate(ctx, pool, Down, len(all))
	if err != nil || len(ran) != len(all) {
		t.Fatalf("down: ran %v, err %v", ran, err)
	}
	if tableExists("users") {
		t.Fatal("users table still there after down")
	}
	if done, _ := Status(ctx, pool); len(done) != 0 {
		t.Fatalf("status after down: %v", done)
	}

	// A database made before migrations existed: tables but no
	// schema_migrations. Up must adopt it without losing rows.
	reset()
	if _, err := Migrate(ctx, pool, Up, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO users (id, name, phone, pin_hash, alerts_seen_at, created_at) VALUES ('u_x', 'X', '+919999999999', 'h', now(), now())`); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `DROP TABLE schema_migrations`); err != nil {
		t.Fatal(err)
	}
	if ran, err := Migrate(ctx, pool, Up, 0); err != nil || len(ran) != len(all) {
		t.Fatalf("baseline up: ran %v, err %v", ran, err)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("users after baseline: %d, %v", n, err)
	}
}
