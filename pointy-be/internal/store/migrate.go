package store

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Migrations live in migrations/ as NNNN_name.up.sql and NNNN_name.down.sql
// and are built into the binary. To change the schema, add the next number
// with both files; never edit one that has already run anywhere.
//
//go:embed migrations/*.sql
var migrationFiles embed.FS

// Migration is one numbered schema change.
type Migration struct {
	Version int
	Name    string
	Up      string
	Down    string
}

// Direction for Migrate.
type Direction int

const (
	Up Direction = iota
	Down
)

// lockID is the Postgres advisory lock held while migrating, so two server
// instances starting at once cannot apply the same migration twice.
const lockID = 74_51_20_26

var reMigration = regexp.MustCompile(`^(\d{4})_([a-z0-9_]+)\.(up|down)\.sql$`)

// Migrations returns every migration in version order.
func Migrations() ([]Migration, error) {
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return nil, err
	}
	byVersion := map[int]*Migration{}
	for _, e := range entries {
		m := reMigration.FindStringSubmatch(e.Name())
		if m == nil {
			return nil, fmt.Errorf("migration file %q is not named NNNN_name.up.sql or NNNN_name.down.sql", e.Name())
		}
		v, _ := strconv.Atoi(m[1])
		body, err := migrationFiles.ReadFile("migrations/" + e.Name())
		if err != nil {
			return nil, err
		}
		mg := byVersion[v]
		if mg == nil {
			mg = &Migration{Version: v, Name: m[2]}
			byVersion[v] = mg
		}
		if m[3] == "up" {
			mg.Up = string(body)
		} else {
			mg.Down = string(body)
		}
	}
	out := make([]Migration, 0, len(byVersion))
	for _, m := range byVersion {
		if m.Up == "" || m.Down == "" {
			return nil, fmt.Errorf("migration %04d_%s needs both an up and a down file", m.Version, m.Name)
		}
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	for i, m := range out {
		if m.Version != i+1 {
			return nil, fmt.Errorf("migration versions must run 0001, 0002, … without gaps; found %04d", m.Version)
		}
	}
	return out, nil
}

// Applied is a migration recorded in schema_migrations.
type Applied struct {
	Version   int
	Name      string
	AppliedAt time.Time
}

// Migrate moves the schema up (all pending migrations when steps is 0) or
// down (the last steps migrations; 0 means one). Each migration runs in its
// own transaction together with its schema_migrations row, so a failure
// leaves the database at the last version that fully applied. It returns
// the versions it ran.
func Migrate(ctx context.Context, pool *pgxpool.Pool, dir Direction, steps int) ([]int, error) {
	all, err := Migrations()
	if err != nil {
		return nil, err
	}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, lockID); err != nil {
		return nil, fmt.Errorf("migrate: taking the lock: %w", err)
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, lockID) //nolint:errcheck // released with the session anyway
	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version int PRIMARY KEY,
		name text NOT NULL,
		applied_at timestamptz NOT NULL DEFAULT now()
	)`); err != nil {
		return nil, fmt.Errorf("migrate: creating schema_migrations: %w", err)
	}
	done, err := applied(ctx, conn.Conn())
	if err != nil {
		return nil, err
	}
	isDone := map[int]bool{}
	for _, a := range done {
		isDone[a.Version] = true
	}

	var ran []int
	run := func(m Migration, sql, record string, args ...any) error {
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx) //nolint:errcheck // a no-op after Commit
		if _, err := tx.Exec(ctx, sql); err != nil {
			return fmt.Errorf("migrate: %04d_%s: %w", m.Version, m.Name, err)
		}
		if _, err := tx.Exec(ctx, record, args...); err != nil {
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		ran = append(ran, m.Version)
		return nil
	}

	if dir == Up {
		for _, m := range all {
			if isDone[m.Version] {
				continue
			}
			if steps > 0 && len(ran) == steps {
				break
			}
			if err := run(m, m.Up, `INSERT INTO schema_migrations (version, name) VALUES ($1, $2)`, m.Version, m.Name); err != nil {
				return ran, err
			}
		}
		return ran, nil
	}
	if steps == 0 {
		steps = 1
	}
	byVersion := map[int]Migration{}
	for _, m := range all {
		byVersion[m.Version] = m
	}
	for i := len(done) - 1; i >= 0 && len(ran) < steps; i-- {
		m, ok := byVersion[done[i].Version]
		if !ok {
			return ran, fmt.Errorf("migrate: version %04d is applied but this build has no files for it", done[i].Version)
		}
		if err := run(m, m.Down, `DELETE FROM schema_migrations WHERE version = $1`, m.Version); err != nil {
			return ran, err
		}
	}
	return ran, nil
}

// Status lists the applied migrations in order.
func Status(ctx context.Context, pool *pgxpool.Pool) ([]Applied, error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Release()
	var exists bool
	if err := conn.QueryRow(ctx, `SELECT to_regclass('schema_migrations') IS NOT NULL`).Scan(&exists); err != nil || !exists {
		return nil, err
	}
	return applied(ctx, conn.Conn())
}

func applied(ctx context.Context, conn *pgx.Conn) ([]Applied, error) {
	rows, err := conn.Query(ctx, `SELECT version, name, applied_at FROM schema_migrations ORDER BY version`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Applied
	for rows.Next() {
		var a Applied
		if err := rows.Scan(&a.Version, &a.Name, &a.AppliedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
