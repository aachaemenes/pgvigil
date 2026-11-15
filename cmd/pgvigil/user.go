package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/auth"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"golang.org/x/term"
)

// runUser manages the web UI's logins, as the repository owner (the config's repository dsn):
//
//	pgvigil user add     -config pgvigil.yaml [-role viewer|operator|admin] <name>
//	                     asks for the password (or PGVIGIL_PASSWORD, or one line on stdin); without -role the
//	                     repository's first enabled admin, else a viewer
//	pgvigil user role    -config pgvigil.yaml <name> <viewer|operator|admin>
//	pgvigil user passwd  -config pgvigil.yaml <name>
//	pgvigil user disable|enable|remove -config pgvigil.yaml <name>
//	pgvigil user list    -config pgvigil.yaml
//
// The password is hashed here (argon2id) and only the hash reaches the repository.
func runUser(ctx context.Context, log *slog.Logger, args []string) error {
	verb, name, role, path, err := userArgs(args)
	if err != nil {
		return err
	}
	cfg, err := config.Load(path)
	if err != nil {
		return err
	}
	// the password is read before the repository is touched: a typo costs no connection
	hash := ""
	if verb == "add" || verb == "passwd" {
		pw, err := readPassword(verb == "add")
		if err != nil {
			return err
		}
		if hash, err = auth.Hash(pw); err != nil {
			return err
		}
	}
	r, err := repo.Open(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer r.Close()
	switch verb {
	case "list":
		users, err := r.UIUsers(ctx)
		if err != nil {
			return err
		}
		if len(users) == 0 {
			fmt.Println("no UI users; pgvigil user add <name>")
			return nil
		}
		fmt.Printf("%-32s %-8s %-8s %-20s %s\n", "user", "role", "state", "created", "password set")
		for _, u := range users {
			state := "enabled"
			if u.Disabled {
				state = "disabled"
			}
			fmt.Printf("%-32s %-8s %-8s %-20s %s\n", u.Name, u.Role, state, u.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"), u.PasswordSetAt.UTC().Format("2006-01-02 15:04 UTC"))
		}
		return nil
	case "add":
		got, first, err := r.UIUserAdd(ctx, name, hash, role)
		if err != nil {
			return err
		}
		if first {
			fmt.Printf("%s is admin: the first enabled admin of this repository (the next user without -role is a viewer)\n", name)
		} else {
			fmt.Printf("%s is %s %s ('pgvigil user role %s <role>' changes it)\n", name, article(got), got, name)
		}
		log.Info("ui user added", "user", name, "role", got)
	case "role":
		if err := r.UIUserSetRole(ctx, name, role); err != nil {
			return err
		}
		fmt.Printf("%s is now %s %s: an open session follows at its next request\n", name, article(role), role)
		log.Info("ui user role changed", "user", name, "role", role)
	case "passwd":
		if err := r.UIUserSetPassword(ctx, name, hash); err != nil {
			return err
		}
		log.Info("ui password changed", "user", name)
	case "enable", "disable":
		if err := r.UIUserEnable(ctx, name, verb == "enable"); err != nil {
			return err
		}
		log.Info("ui user "+verb+"d", "user", name)
	case "remove":
		if err := r.UIUserRemove(ctx, name); err != nil {
			return err
		}
		log.Info("ui user removed", "user", name)
	default:
		return fmt.Errorf("unknown verb %q: add, role, passwd, enable, disable, remove or list", verb)
	}
	return nil
}

// article is 'an' before admin and operator, 'a' before viewer
func article(role string) string {
	if role == "viewer" {
		return "a"
	}
	return "an"
}

// userArgs reads `<verb> [-config file] [-role r] [name] [role]` with the positionals before or after the flags: Go's
// flag parsing stops at the first positional argument, and `pgvigil user add admin -config f` reads naturally. A role
// is checked here, before a password is asked or the repository touched.
func userArgs(args []string) (verb, name, role, path string, err error) {
	usage := errors.New("usage: pgvigil user <add|role|passwd|enable|disable|remove|list> [-config file] [name]")
	if len(args) < 1 || strings.HasPrefix(args[0], "-") {
		return "", "", "", "", usage
	}
	verb = args[0]
	switch verb {
	case "add", "role", "passwd", "enable", "disable", "remove", "list":
	default:
		return "", "", "", "", fmt.Errorf("unknown verb %q: add, role, passwd, enable, disable, remove or list", verb)
	}
	fs := flag.NewFlagSet("user "+verb, flag.ContinueOnError)
	cfgPath := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	roleFlag := new(string)
	if verb == "add" {
		roleFlag = fs.String("role", "", "viewer, operator or admin (default: the repository's first enabled admin, else viewer)")
	}
	if err := fs.Parse(args[1:]); err != nil {
		return "", "", "", "", err
	}
	var positional []string
	for rest := fs.Args(); len(rest) > 0; rest = fs.Args() {
		positional = append(positional, rest[0])
		if err := fs.Parse(rest[1:]); err != nil {
			return "", "", "", "", err
		}
	}
	want := map[string]int{"list": 0, "role": 2}[verb]
	if verb != "list" && verb != "role" {
		want = 1
	}
	if len(positional) != want {
		return "", "", "", "", fmt.Errorf("usage: pgvigil user %s [-config file]%s", verb,
			map[string]string{"list": "", "role": " <name> <viewer|operator|admin>", "add": " [-role viewer|operator|admin] <name>"}[verb]+
				map[bool]string{true: " <name>", false: ""}[verb != "list" && verb != "role" && verb != "add"])
	}
	if verb != "list" {
		if name, err = repo.UserName(positional[0]); err != nil {
			return "", "", "", "", err
		}
	}
	switch {
	case verb == "role":
		role, err = repo.RoleName(positional[1])
	case verb == "add" && *roleFlag != "":
		role, err = repo.RoleName(*roleFlag)
	}
	if err != nil {
		return "", "", "", "", err
	}
	return verb, name, role, *cfgPath, nil
}

// readPassword takes PGVIGIL_PASSWORD when set, else a prompt without echo (twice for a new
// user), else one line from a piped stdin.
func readPassword(confirm bool) (string, error) {
	if pw, ok := os.LookupEnv("PGVIGIL_PASSWORD"); ok {
		if err := auth.CheckPassword(pw); err != nil {
			return "", fmt.Errorf("PGVIGIL_PASSWORD: %w", err)
		}
		return pw, nil
	}
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprint(os.Stderr, "Password: ")
		b, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", err
		}
		pw := string(b)
		if err := auth.CheckPassword(pw); err != nil {
			return "", err
		}
		if confirm {
			fmt.Fprint(os.Stderr, "Again: ")
			b2, err := term.ReadPassword(int(os.Stdin.Fd()))
			fmt.Fprintln(os.Stderr)
			if err != nil {
				return "", err
			}
			if string(b2) != pw {
				return "", errors.New("the two passwords differ")
			}
		}
		return pw, nil
	}
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && line == "" {
		return "", errors.New("no password: set PGVIGIL_PASSWORD, pipe one line, or run in a terminal")
	}
	pw := strings.TrimRight(line, "\r\n")
	if err := auth.CheckPassword(pw); err != nil {
		return "", err
	}
	return pw, nil
}
