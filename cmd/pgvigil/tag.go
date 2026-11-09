package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// runTag fixes an instance's tags in the repository without a config deploy, as the repository owner
// (the config's repository dsn):
//
//	pgvigil tag -config pgvigil.yaml <instance>                       the merged tags, each with its source
//	pgvigil tag -config pgvigil.yaml <instance> env=prod team=a,b     replace every value the config gives env / team
//	pgvigil tag -config pgvigil.yaml <instance> -env                  hide the key env whatever the config says
//	pgvigil tag -config pgvigil.yaml -reset <instance> env [team]     drop the override: the config's values return
//
// A plain word's key is "tag" (tag=prod,erp replaces the plain words). The overrides live in
// pgvigil.instance_tag_overrides (0032) and are merged over the config's tags in pgvigil.instance_tags_merged,
// which the UI reads.
func runTag(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("tag", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	reset := fs.Bool("reset", false, "drop the overrides of the named keys")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) == 0 {
		return errors.New("usage: pgvigil tag [-config f] [-reset] <instance> [key=value[,value...]] [-key] [key]")
	}
	ops, err := tagOps(rest[1:], *reset)
	if err != nil {
		return err
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	conn, err := pgx.Connect(ctx, cfg.Repository.DSN())
	if err != nil {
		return fmt.Errorf("repository: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	return applyTags(ctx, conn, rest[0], ops, os.Stdout)
}

// tagOp is one change: Vals set (a replacement), Hide (vals NULL), or Reset (the row dropped).
type tagOp struct {
	Key   string
	Vals  []string
	Hide  bool
	Reset bool
}

// tagOps reads the arguments after the instance name.
func tagOps(args []string, reset bool) ([]tagOp, error) {
	var out []tagOp
	seen := map[string]bool{}
	for _, a := range args {
		var op tagOp
		switch {
		case reset:
			op = tagOp{Key: strings.ToLower(strings.TrimSpace(a)), Reset: true}
		case strings.HasPrefix(a, "-"):
			op = tagOp{Key: strings.ToLower(strings.TrimSpace(a[1:])), Hide: true}
		case strings.Contains(a, "="):
			k, v, _ := strings.Cut(a, "=")
			op.Key = strings.ToLower(strings.TrimSpace(k))
			for _, x := range strings.Split(v, ",") {
				t, err := config.ParseTag(op.Key + ":" + x)
				if err != nil {
					return nil, fmt.Errorf("%s: %w", a, err)
				}
				if !hasString(op.Vals, t.Value) {
					op.Vals = append(op.Vals, t.Value)
				}
			}
			if len(op.Vals) > 20 {
				return nil, fmt.Errorf("%s: at most 20 values per key", a)
			}
		default:
			return nil, fmt.Errorf("%q: want key=value[,value...], -key, or -reset with the keys", a)
		}
		if !config.ValidTagKey(op.Key) {
			return nil, fmt.Errorf("%q: the key must be lower-case letters, digits, '_', '.' or '-' (1..40)", a)
		}
		if seen[op.Key] {
			return nil, fmt.Errorf("key %q named twice", op.Key)
		}
		seen[op.Key] = true
		out = append(out, op)
	}
	if reset && len(out) == 0 {
		return nil, errors.New("-reset needs the keys to drop")
	}
	return out, nil
}

func hasString(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

// tagDB is what applyTags needs of the repository connection.
type tagDB interface {
	Begin(ctx context.Context) (pgx.Tx, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// applyTags writes the changes in one transaction, then prints the merged tags.
func applyTags(ctx context.Context, db tagDB, instance string, ops []tagOp, w io.Writer) error {
	var id int
	if err := db.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, instance).Scan(&id); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("no instance %q in the repository (it appears after its first collection)", instance)
		}
		return ownerHint(err)
	}
	if len(ops) > 0 {
		tx, err := db.Begin(ctx)
		if err != nil {
			return err
		}
		defer func() { _ = tx.Rollback(ctx) }()
		for _, op := range ops {
			var err error
			switch {
			case op.Reset:
				_, err = tx.Exec(ctx, `DELETE FROM pgvigil.instance_tag_overrides WHERE instance_id = $1 AND key = $2`, id, op.Key)
			case op.Hide:
				_, err = tx.Exec(ctx, `INSERT INTO pgvigil.instance_tag_overrides (instance_id, key, vals) VALUES ($1, $2, NULL)
				  ON CONFLICT (instance_id, key) DO UPDATE SET vals = NULL, set_at = now(), set_by = current_user`, id, op.Key)
			default:
				_, err = tx.Exec(ctx, `INSERT INTO pgvigil.instance_tag_overrides (instance_id, key, vals) VALUES ($1, $2, $3)
				  ON CONFLICT (instance_id, key) DO UPDATE SET vals = EXCLUDED.vals, set_at = now(), set_by = current_user`, id, op.Key, op.Vals)
			}
			if err != nil {
				return ownerHint(err)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return ownerHint(err)
		}
	}
	return printTags(ctx, db, id, instance, w)
}

// printTags lists the merged tags (source config or override) and the hidden keys.
func printTags(ctx context.Context, db tagDB, id int, instance string, w io.Writer) error {
	rows, err := db.Query(ctx, `
SELECT key, value, source FROM pgvigil.instance_tag_pairs WHERE instance_id = $1
UNION ALL
SELECT key, NULL, 'hidden' FROM pgvigil.instance_tag_overrides WHERE instance_id = $1 AND vals IS NULL
 ORDER BY 1, 2 NULLS FIRST`, id)
	if err != nil {
		return ownerHint(err)
	}
	type line struct{ key, val, src string }
	var ls []line
	for rows.Next() {
		var k, src string
		var v *string
		if err := rows.Scan(&k, &v, &src); err != nil {
			return err
		}
		l := line{key: k, src: src}
		if v != nil {
			l.val = (config.Tag{Key: k, Value: *v}).String()
		}
		ls = append(ls, l)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	sort.SliceStable(ls, func(i, j int) bool { return ls[i].key < ls[j].key })
	if len(ls) == 0 {
		_, err := fmt.Fprintf(w, "%s: no tags\n", instance)
		return err
	}
	for _, l := range ls {
		var err error
		if l.src == "hidden" {
			_, err = fmt.Fprintf(w, "%s  %-24s hidden (override)\n", instance, l.key+":*")
		} else {
			_, err = fmt.Fprintf(w, "%s  %-24s %s\n", instance, l.val, l.src)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// ownerHint names the fix when the login is not the repository owner or the schema is behind.
func ownerHint(err error) error {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "42501":
			return fmt.Errorf("%w: pgvigil tag runs as the repository owner (the config's repository dsn)", err)
		case "42P01":
			return fmt.Errorf("%w: run 'pgvigil migrate' (0032) first", err)
		}
	}
	return err
}
