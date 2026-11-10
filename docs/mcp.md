# The MCP door: pgvigil for an AI client

`pgvigil mcp` serves the [Model Context Protocol](https://modelcontextprotocol.io) on its standard input and output, so an AI client on the same machine (a desktop assistant, an IDE agent, a command-line agent) can read the pgvigil repository through a fixed set of tools. It is optional: nothing in pgvigil needs it, and a site that does not run it has no AI door.

## What it is and what it is not

- Read only. Seven tools, each a read of the repository; none writes, cancels, terminates, runs EXPLAIN or takes SQL. A call to any other tool name, or to any method beyond `initialize`, `ping`, `tools/list` and `tools/call` (the empty `resources/list`, `resources/templates/list` and `prompts/list` answer too), is refused with a JSON-RPC error.
- The same SQL as the web UI's JSON API. Every tool is answered by the API's own handler, called inside the process: the parameter checks, the queries and the results are the API's. The session is the UI's read-only one (`default_transaction_read_only`, a 15 s statement timeout, a 2 s lock timeout).
- A reader login only. Before it reads a message, `pgvigil mcp` checks its login and refuses (exit 3) a superuser, the schema's owner or any login with CREATE on it, a login that may change a repository table, the collector (`pgvigil_collector`) and the UI's password door (`pgvigil_auth`). The login is IN ROLE `pgvigil_reader` and nothing else.
- The query_text policy holds. A tool returns the statement text the repository holds, which is what each instance's `query_text` setting (full, normalized or none) let the collector keep; the door never reads a monitored server.
- No credential in any output. The login's password is scrubbed from every reply, and any `password=` value or URL password that would appear in an error message with it; the repository holds no other credential the reader can see.
- Nothing outbound. No port is opened: the client starts `pgvigil mcp` as its own child process and talks over the pipe. The only connection the process makes is to the repository database. No telemetry, no update check.

## The tools

| Tool | Arguments | What it answers | API read |
|---|---|---|---|
| `fleet_summary` | `severity` (critical, warning) | every instance (platform, version, sessions, failing collections) and the fleet's failing daily checks, with counts per severity | `/api/instances`, `/api/overview` |
| `instance_findings` | `instance` | one instance's failing daily checks and its parameter findings (setting, value, suggested value, why) | `/api/overview`, `/api/findings` |
| `blocking_chain` | `instance`, `at` | the lock-wait chains at the activity snapshot at or before `at` (default the latest): each waiter with its head, depth, the head's state and statement, and the snapshot's session counts | `/api/activity` |
| `top_statements` | `instance`, `from`, `to`, `hours`, `order`, `limit` | the top statements over the window (default the last hour) by time, calls, io, mean, rows, temp or wal; at most 100 | `/api/statements` |
| `plan_findings` | `plan_id`, or `instance` with `queryid`, `from`, `to`, `hours` | one captured plan with the plan rules it hits, or the plans captured in a window (default 24 hours) to find a `plan_id` | `/api/plan`, `/api/plans` |
| `table_state` | `instance`, `table` (name or schema.table), `database` | the table's latest sizes, tuples, bloat, visibility, vacuum and analyze history, scans, XID age and checks, with its database's summary | `/api/tables` |
| `storage_forecast` | `instance` (optional) | volumes with free space, growth per day and days until full; with `instance`, also database and table growth and the storage checks; without it, the fleet and the repository's own size | `/api/storage`, `/api/storage/fleet` |

An instance is named by its name (as `fleet_summary` lists it) or its `instance_id`. Times are RFC 3339 (`2026-11-09T08:00:00Z`). Each list in a reply is cut at 200 rows and each text at 20,000 characters; a cut says so in the reply.

## Setting it up

1. As the repository owner, make the door's login (the output of `pgvigil roles` says the same: an MCP server takes a login IN ROLE `pgvigil_reader` alone):

   ```sql
   CREATE ROLE pgvigil_mcp LOGIN PASSWORD '<set-me>' IN ROLE pgvigil_reader;
   ```

2. Give the login's connection string to the process through the environment (the default, `-dsn env:PGVIGIL_MCP_DSN`) or a file the client's user alone can read (`-dsn file:/path`). Never put the password on a command line other users can list.

3. Point the client at the binary. A client configuration in the common `mcpServers` form (most desktop assistants and IDE agents read this shape from their own settings file):

   ```json
   {
     "mcpServers": {
       "pgvigil": {
         "command": "/usr/local/bin/pgvigil",
         "args": ["mcp", "-config", "/etc/pgvigil/pgvigil.yaml"],
         "env": {
           "PGVIGIL_MCP_DSN": "host=repo.example.internal port=5432 dbname=pgvigil user=pgvigil_mcp sslmode=verify-full"
         }
       }
     }
   }
   ```

   On Windows the command is `C:\\Program Files\\pgvigil\\pgvigil.exe` (each backslash doubled inside the JSON). The password goes in the login's `~/.pgpass` (`%APPDATA%\postgresql\pgpass.conf` on Windows), which libpq-style connection strings read, or in a `file:` DSN, rather than in the client's configuration file. `-config` is optional: it gives the stale-collection check each instance's own intervals, as `serve` has them; without it the defaults apply.

   A command-line agent takes the same command and environment through its own `mcp add` form.

4. Check it by hand: `PGVIGIL_MCP_DSN=... pgvigil mcp < /dev/null` logs `pgvigil mcp ready on stdio` on stderr and exits 0 when its input ends; a login that can do more than read is refused with the reason.

## The protocol

Newline-delimited JSON-RPC 2.0 on stdin and stdout; logs on stderr. Protocol revisions 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05: the client's is answered when it is one of these, the newest otherwise. Tool results are one text item holding JSON (`isError` true with the reason when an argument is wrong or a read fails). A request line may be up to 1 MiB; batches are refused. Each tool is marked `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`, `openWorldHint: false`.

## What an AI client sees, and who decides

The tools return what the web UI shows a reader: instance names, settings, check results, sizes, and statement text as the query_text policy keeps it. Whether that may go to a model hosted elsewhere is the site's decision, made in the client: pgvigil sends nothing anywhere itself. A site that may not send statement text to a hosted model sets `query_text: normalized` or `none` for the instances concerned, or uses a model that runs on its own machines.

## The proof

`scripts/proof-mcp.sh` seeds a demo repository, makes a reader login, and drives one `pgvigil mcp` process with a scripted client: the owner's login refused, `initialize`, `tools/list`, every tool once, a write refused three ways (a tool that would terminate a backend, a write method, and the reader login's own INSERT), the password in no output, no listening socket, and a clean exit when the input closes.
