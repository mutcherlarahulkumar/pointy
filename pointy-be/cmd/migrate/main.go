// Command migrate moves the Postgres schema up or down.
//
//	go run ./cmd/migrate status      # what has been applied
//	go run ./cmd/migrate up          # apply everything pending (the server does this on start too)
//	go run ./cmd/migrate up 1        # apply only the next one
//	go run ./cmd/migrate down        # undo the last one
//	go run ./cmd/migrate down 2      # undo the last two
//
// It reads DATABASE_URL from the environment or .env.
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/config"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/store"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "migrate:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	config.LoadDotEnv(".env")
	if len(args) == 0 || len(args) > 2 {
		return fmt.Errorf("usage: migrate up [n] | down [n] | status")
	}
	steps := 0
	if len(args) == 2 {
		n, err := strconv.Atoi(args[1])
		if err != nil || n < 1 {
			return fmt.Errorf("%q is not a number of steps", args[1])
		}
		steps = n
	}
	url := config.Env("DATABASE_URL", "")
	if url == "" {
		return fmt.Errorf("DATABASE_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return err
	}
	defer pool.Close()

	switch args[0] {
	case "status":
		return status(ctx, pool)
	case "up", "down":
		dir := store.Up
		if args[0] == "down" {
			dir = store.Down
		}
		ran, err := store.Migrate(ctx, pool, dir, steps)
		for _, v := range ran {
			fmt.Printf("%s %04d\n", args[0], v)
		}
		if err != nil {
			return err
		}
		if len(ran) == 0 {
			fmt.Println("nothing to do")
		}
		return status(ctx, pool)
	default:
		return fmt.Errorf("unknown command %q (use up, down or status)", args[0])
	}
}

func status(ctx context.Context, pool *pgxpool.Pool) error {
	all, err := store.Migrations()
	if err != nil {
		return err
	}
	done, err := store.Status(ctx, pool)
	if err != nil {
		return err
	}
	at := map[int]time.Time{}
	for _, a := range done {
		at[a.Version] = a.AppliedAt
	}
	for _, m := range all {
		if t, ok := at[m.Version]; ok {
			fmt.Printf("  %04d_%s  applied %s\n", m.Version, m.Name, t.Format(time.RFC3339))
		} else {
			fmt.Printf("  %04d_%s  pending\n", m.Version, m.Name)
		}
	}
	return nil
}
