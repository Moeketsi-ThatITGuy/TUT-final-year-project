<?php
// Dumps the demo `visits` table as JSON to stdout (piped to gzip + S3).
// Uses PHP mysqlnd so it speaks MySQL 8.4's caching_sha2_password over TLS.
$cfg = json_decode(file_get_contents('/etc/univen/db.json'), true);

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
$m = mysqli_init();
$m->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
$m->options(MYSQLI_OPT_SSL_VERIFY_SERVER_CERT, true);
$m->ssl_set(null, null, '/etc/univen/rds-ca.pem', null, null);
$m->real_connect($cfg['host'], $cfg['username'], $cfg['password'], $cfg['dbname'], 3306, null, MYSQLI_CLIENT_SSL);

$rows = [];
$rs = $m->query('SELECT id, region, app_host, created_at FROM visits ORDER BY id');
while ($r = $rs->fetch_assoc()) {
    $rows[] = $r;
}

echo json_encode([
    'source_db'  => $cfg['host'],
    'table'      => 'visits',
    'row_count'  => count($rows),
    'taken_at'   => gmdate('c'),
    'rows'       => $rows,
], JSON_UNESCAPED_SLASHES), "\n";
