
# Copyright (c) 2021-2024, PostgreSQL Global Development Group

#
# Tests restarts of postgres due to crashes of a subprocess.
#
# Two longer-running psql subprocesses are used: One to kill a
# backend, triggering a crash-restart cycle, one to detect when
# postmaster noticed the backend died.  The second backend is
# necessary because it's otherwise hard to determine if postmaster is
# still accepting new sessions (because it hasn't noticed that the
# backend died), or because it's already restarted.
#
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $psql_timeout = IPC::Run::timer($PostgreSQL::Test::Utils::timeout_default);

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init(allows_streaming => 1);
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_tde'");
$node->append_conf('postgresql.conf', "default_table_access_method = 'tde_heap'");
$node->start();

# Create and enable tde extension
$node->safe_psql('postgres', 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
$node->safe_psql('postgres',
	"SELECT pg_tde_add_database_key_provider_file('file-vault', '/tmp/unlogged_tables.per');"
);
$node->safe_psql('postgres',
	"SELECT pg_tde_set_key_using_database_key_provider('test-key', 'file-vault');"
);

# by default PostgreSQL::Test::Cluster doesn't restart after a crash
$node->safe_psql(
	'postgres',
	q[ALTER SYSTEM SET restart_after_crash = 1;
				   ALTER SYSTEM SET log_connections = 1;
				   SELECT pg_reload_conf();]);


diag("Creating table and verifying data and encryption");
$node->safe_psql('postgres', <<'SQL');
CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
INSERT INTO t2 VALUES (101, 'Ruskin Bond 007 from t2');
-- Insert large data into the table
INSERT INTO t2(a, b)
SELECT i, 'Large data row ' || i
FROM generate_series(102, 100000) AS i;
SQL


# Expected number of rows in the t2 table to verify after crash
my $expected_row_count = $node->safe_psql('postgres', "SELECT COUNT(*) FROM t2");
# Run psql, keeping session alive, so we have an alive backend to kill.
my ($killme_stdin, $killme_stdout, $killme_stderr) = ('', '', '');
my $killme = IPC::Run::start(
	[
		'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-f', '-', '-d',
		$node->connstr('postgres')
	],
	'<',
	\$killme_stdin,
	'>',
	\$killme_stdout,
	'2>',
	\$killme_stderr,
	$psql_timeout);

# Need a second psql to check if crash-restart happened.
my ($monitor_stdin, $monitor_stdout, $monitor_stderr) = ('', '', '');
my $monitor = IPC::Run::start(
	[
		'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-f', '-', '-d',
		$node->connstr('postgres')
	],
	'<',
	\$monitor_stdin,
	'>',
	\$monitor_stdout,
	'2>',
	\$monitor_stderr,
	$psql_timeout);

#create table, insert row that should survive
$killme_stdin .= q[
CREATE TABLE alive(status text)USING tde_heap;
INSERT INTO alive VALUES($$committed-before-sigquit$$);
SELECT pg_backend_pid();
];
ok( pump_until(
		$killme, $psql_timeout, \$killme_stdout, qr/[[:digit:]]+[\r\n]$/m),
	'acquired pid for SIGQUIT');
my $pid = $killme_stdout;
chomp($pid);
$killme_stdout = '';
$killme_stderr = '';

#insert a row that should *not* survive, due to in-progress xact
$killme_stdin .= q[
BEGIN;
INSERT INTO alive VALUES($$in-progress-before-sigquit$$) RETURNING status;
];
ok( pump_until(
		$killme, $psql_timeout,
		\$killme_stdout, qr/in-progress-before-sigquit/m),
	'inserted in-progress-before-sigquit');
$killme_stdout = '';
$killme_stderr = '';


# Start longrunning query in second session; its failure will signal that
# crash-restart has occurred.  The initial wait for the trivial select is to
# be sure that psql successfully connected to backend.
$monitor_stdin .= q[
SELECT $$psql-connected$$;
SELECT pg_sleep(3600);
];
ok( pump_until(
		$monitor, $psql_timeout, \$monitor_stdout, qr/psql-connected/m),
	'monitor connected');
$monitor_stdout = '';
$monitor_stderr = '';

# kill once with QUIT - we expect psql to exit, while emitting error message first
my $ret = PostgreSQL::Test::Utils::system_log('pg_ctl', 'kill', 'QUIT', $pid);

# Exactly process should have been alive to be killed
is($ret, 0, "killed process with SIGQUIT");

# Check that psql sees the killed backend as having been terminated
$killme_stdin .= q[
SELECT 1;
];
ok( pump_until(
		$killme,
		$psql_timeout,
		\$killme_stderr,
		qr/WARNING:  terminating connection because of unexpected SIGQUIT signal|server closed the connection unexpectedly|connection to server was lost|could not send data to server/m
	),
	"psql query died successfully after SIGQUIT");
$killme_stderr = '';
$killme_stdout = '';
$killme->finish;

# Wait till server restarts - we should get the WARNING here, but
# sometimes the server is unable to send that, if interrupted while
# sending.
ok( pump_until(
		$monitor,
		$psql_timeout,
		\$monitor_stderr,
		qr/WARNING:  terminating connection because of crash of another server process|server closed the connection unexpectedly|connection to server was lost|could not send data to server/m
	),
	"psql monitor died successfully after SIGQUIT");
$monitor->finish;

# Wait till server restarts
is($node->poll_query_until('postgres', undef, ''),
	"1", "reconnected after SIGQUIT");


# restart psql processes, now that the crash cycle finished
($killme_stdin, $killme_stdout, $killme_stderr) = ('', '', '');
$killme->run();
($monitor_stdin, $monitor_stdout, $monitor_stderr) = ('', '', '');
$monitor->run();


# Acquire pid of new backend
$killme_stdin .= q[
SELECT pg_backend_pid();
];
ok( pump_until(
		$killme, $psql_timeout, \$killme_stdout, qr/[[:digit:]]+[\r\n]$/m),
	"acquired pid for SIGKILL");
$pid = $killme_stdout;
chomp($pid);
$killme_stdout = '';
$killme_stderr = '';

# Insert test rows
$killme_stdin .= q[
INSERT INTO alive VALUES($$committed-before-sigkill$$) RETURNING status;
BEGIN;
INSERT INTO alive VALUES($$in-progress-before-sigkill$$) RETURNING status;
];
ok( pump_until(
		$killme, $psql_timeout,
		\$killme_stdout, qr/in-progress-before-sigkill/m),
	'inserted in-progress-before-sigkill');
$killme_stdout = '';
$killme_stderr = '';

# Re-start longrunning query in second session; its failure will signal that
# crash-restart has occurred.  The initial wait for the trivial select is to
# be sure that psql successfully connected to backend.
$monitor_stdin .= q[
SELECT $$psql-connected$$;
SELECT pg_sleep(3600);
];
ok( pump_until(
		$monitor, $psql_timeout, \$monitor_stdout, qr/psql-connected/m),
	'monitor connected');
$monitor_stdout = '';
$monitor_stderr = '';


# kill with SIGKILL this time - we expect the backend to exit, without
# being able to emit an error message
$ret = PostgreSQL::Test::Utils::system_log('pg_ctl', 'kill', 'KILL', $pid);
is($ret, 0, "killed process with KILL");

# Check that psql sees the server as being terminated. No WARNING,
# because signal handlers aren't being run on SIGKILL.
$killme_stdin .= q[
SELECT 1;
];
ok( pump_until(
		$killme,
		$psql_timeout,
		\$killme_stderr,
		qr/server closed the connection unexpectedly|connection to server was lost|could not send data to server/m
	),
	"psql query died successfully after SIGKILL");
$killme->finish;

# Wait till server restarts - we should get the WARNING here, but
# sometimes the server is unable to send that, if interrupted while
# sending.
ok( pump_until(
		$monitor,
		$psql_timeout,
		\$monitor_stderr,
		qr/WARNING:  terminating connection because of crash of another server process|server closed the connection unexpectedly|connection to server was lost|could not send data to server/m
	),
	"psql monitor died successfully after SIGKILL");
$monitor->finish;

# Wait till server restarts
is($node->poll_query_until('postgres', undef, ''),
	"1", "reconnected after SIGKILL");

# Make sure the committed rows survived, in-progress ones not
is( $node->safe_psql('postgres', 'SELECT * FROM alive'),
	"committed-before-sigquit\ncommitted-before-sigkill",
	'data survived');

is( $node->safe_psql(
		'postgres',
		'INSERT INTO alive VALUES($$before-orderly-restart$$) RETURNING status'
	),
	'before-orderly-restart',
	'can still write after crash restart');

# Just to be sure, check that an orderly restart now still works
$node->restart();

is( $node->safe_psql('postgres', 'SELECT * FROM alive'),
	"committed-before-sigquit\ncommitted-before-sigkill\nbefore-orderly-restart",
	'data survived');

is( $node->safe_psql(
		'postgres',
		'INSERT INTO alive VALUES($$after-orderly-restart$$) RETURNING status'
	),
	'after-orderly-restart',
	'can still write after orderly restart');

is( $node->safe_psql('postgres', "SELECT pg_tde_is_encrypted('alive')"),
	't',
	'pg_tde is enabled');

is( $node->safe_psql('postgres', "SELECT pg_tde_is_encrypted('t2')"),
	't',
	't2 is encrypted');
is( $node->safe_psql('postgres', "SELECT * FROM t2 ORDER BY a LIMIT 5"),
    "101|Ruskin Bond 007 from t2\n102|Large data row 102\n103|Large data row 103\n104|Large data row 104\n105|Large data row 105",
    'First 5 rows of t2 are as expected');
# Compare the count of all rows in the t2 table before and after crash
my $actual_row_count = $node->safe_psql('postgres', "SELECT COUNT(*) FROM t2");

is($actual_row_count, $expected_row_count, "Row count in t2 is as expected: $expected_row_count");

$node->stop();

done_testing();
