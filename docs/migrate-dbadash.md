# Moving servers from DBA Dash

Admin > Instances has a section **Move from DBA Dash**: the servers a DBA Dash repository of `pgvigil.yaml` collects (the [DBA Dash door](dbadash.md)), moved to pgvigil one at a time, each keeping the history DBA Dash collected. Nothing on this page writes to DBA Dash's repository or to a monitored server: the steps on DBA Dash's side and on the servers are the DBA's, and the page prints what to run.

## The steps

1. **Pick the repository.** The list shows one row per server, as DBA Dash names it (`@@SERVERNAME`): a server DBA Dash lists twice (two connections, or one added again) is one row with all its InstanceIDs. Its state:

   | state | what it means |
   |---|---|
   | not yet | neither collected nor imported by pgvigil |
   | imported only | `pgvigil import dbadash` made an instance of it earlier; pgvigil does not collect it |
   | collected by pgvigil | pgvigil collects a server of that name already, not through a move: not offered |
   | moving | moved here; pgvigil has not read it yet |
   | collecting | moved and read by pgvigil; its history not imported yet |
   | importing | a history import runs now |
   | partial / import failed | the last import's outcome (the rows taken so far stay; run it again) |
   | ready to switch | collected by pgvigil and its history imported |
   | disabled | moved, then disabled above |

2. **Tick servers and Add.** One sign-in serves every ticked server (at most 50 in one add): a SQL login, an Entra service principal, the host's Entra managed identity, or Windows (below). Each server's host and port are DBA Dash's connection (its ConnectionID) when that is a network address - a DNS or NetBIOS name or an IP address, with a named instance (`SQL01\PROD`) and a port (`sql01,14330`, `sql01:14330`, `[fe80::1]:14330`) if it has them - both editable in the server's row. A ConnectionID is often a label instead (a host and a comment, an alias in brackets, two names in one): then the row starts from DBA Dash's Instance (the server's `@@SERVERNAME`) and says which ConnectionID it is and why it is not an address; check the host and type the port if the server does not listen on 1433 (an empty port with a named instance asks the SQL Browser). The add refuses a host that is not a network address (a space, brackets, a comma before no port), naming the server, what was sent and why; a connection DBA Dash makes on its own host (`.`, `(local)`, `localhost`) or over a named pipe is refused, with the words to type the server's network name. Its pgvigil name is the server's name made safe (`SQL01\PROD` becomes `SQL01-PROD`), editable, 63 characters at most. Each server becomes an instance of this page (its credential in a file of its own, as an Add above writes one), collected within 15 seconds; the add is audited. A server pgvigil collects already, a host and port this page has already, a server moved already, or one approved already from a DBA Dash sync source is refused with its reason, and nothing is written for it.
3. **Count, then Import.** Count is a dry run: DBA Dash's rows of each mapping (CPU, drives, database sizes, Agent job outcomes: [the table](dbadash.md#the-way-off-dba-dash-importing-its-history)) up to pgvigil's first read of the server, and what pgvigil holds for that window; the counts are kept on the move. Import takes that history into the moved instance, only after pgvigil's first read of it and only up to that read, whatever else asks; CPU and job outcomes wait for the collector's own first CPU and job reads. It runs in pgvigil serve, in the background, when the repository's `import: true` is set (below); the list shows its rows as they arrive and its end. Without the switch the page prints the exact command for the pgvigil host instead, which does the same:

   ```
   pgvigil import dbadash -config /etc/pgvigil/pgvigil.yaml -repo corp -instance 3,7 -to 2026-11-14T10:00:00Z
   ```

   An import runs once per server at a time (in serve or from the command line: the second is refused with who started the first); a run cut short is run again and goes on where it stopped.
4. **The checklist** (ticks are the DBA's record, audited):
   - **DBA Dash stops collecting the server**: in DBA Dash's service configuration, the DBA's step. Stop DBA Dash's service with the server still configured first: it stops or drops its own Extended Events sessions as it goes. Then take the server out of its configuration and start the service again: while it is stopped, none of its other servers is collected.
   - **DBA Dash's Extended Events sessions dropped**: the page lists the `DBADash_` sessions pgvigil's collector last saw on the server (pgvigil never reads their events and never drops one) with a `DROP EVENT SESSION [<name>] ON SERVER;` line each for the server's DBA. `DBADash_SlowQueries` writes event files: they stay on the server's disk after the drop. When pgvigil has not listed the server's sessions since it began collecting it, the page prints the read to run on the server, beside the last list it holds (if any): `SELECT name FROM sys.server_event_sessions WHERE name LIKE N'DBADash[_]%';`.
   - **The DBA Dash service stopped**: the page reads DBA Dash's services from the repository when it opens (`dbo.DBADashAgent`, through the door's read login) and says `stop the DBA Dash service <name> on <host>` once every server that service collects is ready to switch; until then it names the servers it waits for. A service that also collects an Azure SQL database is never all moved. A failed read is a note, never a guess.

## Configuration

```yaml
dbadash:
  - name: corp
    dsn: env:DBADASH_CORP_DSN
    import: true            # Admin > Instances may run the history import in pgvigil serve; off by default
gmsa: CORP\pgvigil-gmsa$    # the group Managed Service Account the Windows service runs as
```

- `import:` (per repository, off by default): the page's Import button. Off, the page prints the command; the history is the same either way. Serve runs the import on its own one-connection pool of the repository login the actions door writes its audit with (a login in role `pgvigil_collector`): the page needs that door (Admin > Instances itself does).
- `gmsa:` (`DOMAIN\name$`, a NetBIOS domain and an account of at most 15 characters each): the Windows sign-in. It is offered only when pgvigil serve runs on Windows as that gMSA, never when `gmsa:` names the host's own machine account; and with `gmsa:` set, every pgvigil process that signs in as its own Windows account (the service's `pgvigil run`, serve, `pgvigil import dbadash`) refuses to connect while it runs as another account. The service installs as its virtual account `NT SERVICE\pgvigil`, which reaches a server as the machine account: install it as the gMSA before the first move: `pgvigil install -user CORP\pgvigil-gmsa$` (it moves an installed service to the gMSA too; `install.ps1 -ServiceAccount CORP\pgvigil-gmsa$` only for a fresh install - it refuses where the service is installed; the install grants it 'Log on as a service' and a fresh configuration carries `gmsa:`), or set the service's Log On account to the gMSA by hand. `pgvigil install -print-gmsa -user CORP\pgvigil-gmsa$` prints the PowerShell a domain admin runs to make it. Each moved server then needs `CREATE LOGIN [CORP\pgvigil-gmsa$] FROM WINDOWS;` and the rights of [the login](sqlserver.md#the-login). Never the machine account (`DOMAIN\HOST$`): every service of the host shares it. On Linux the Windows sign-in is a Kerberos key ([SQL Server in the cloud](sqlserver-cloud.md)), added above with Add, not here.

## Not proven yet

- The Windows sign-in on a Windows pgvigil serve running as a gMSA (the refusals on a non-Windows serve and without `gmsa:` are proven).
- The whole move on a live page against a real DBA Dash (two servers, both themes): `scripts/proof-migrate.sh`, to come.
- A DBA Dash 4.19 repository: the import and the door are proven on DBA Dash 4.24.1. DBA Dash 4.19.0's source has every table and column the import reads, with the same definitions; `dbo.Instances.CollectionsPausedUntil` and `dbo.Summary`'s Service Broker status are not in 4.19, and the door reads them only where they exist.
