<?php
// UNIVEN demo API: reports which region/app server answered and which
// database (region, endpoint, primary or replica) it is talking to.
//
// On a writable DB (primary region) every call records a "visit" row.
// On the read replica (backup region) the same rows are visible because
// they replicate cross-region, which proves the data came from Region 1.

header('Content-Type: application/json');
header('Cache-Control: no-store');

$cfg = json_decode(@file_get_contents('/etc/univen/db.json'), true) ?: [];
$app = json_decode(@file_get_contents('/etc/univen/instance.json'), true) ?: [];

$host = $cfg['host'] ?? '';
$dbRegion = null;
if (preg_match('/\.([a-z]{2}(?:-[a-z]+)+-\d+)\.rds\.amazonaws\.com$/', $host, $mm)) {
    $dbRegion = $mm[1];
}

$out = [
    'app' => $app,
    'db'  => [
        'endpoint'  => $host,
        'region'    => $dbRegion,
        'connected' => false,
    ],
    'generated_at' => gmdate('c'),
];

mysqli_report(MYSQLI_REPORT_OFF);
$m = mysqli_init();
$m->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
$m->options(MYSQLI_OPT_SSL_VERIFY_SERVER_CERT, true);
$m->ssl_set(null, null, '/etc/univen/rds-ca.pem', null, null);

$ok = @$m->real_connect(
    $host,
    $cfg['username'] ?? '',
    $cfg['password'] ?? '',
    $cfg['dbname'] ?? 'univen',
    3306,
    null,
    MYSQLI_CLIENT_SSL
);

if (!$ok) {
    $out['db']['error'] = 'connect failed: ' . mysqli_connect_error();
    echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

$out['db']['connected'] = true;

$info = $m->query('SELECT @@read_only AS ro, @@server_id AS sid, VERSION() AS v')->fetch_assoc();
$readOnly = ((int)$info['ro']) === 1;
$out['db']['read_only'] = $readOnly;
$out['db']['role']      = $readOnly ? 'READ REPLICA (read-only)' : 'PRIMARY (writable)';
$out['db']['server_id'] = (int)$info['sid'];
$out['db']['version']   = $info['v'];

if (!$readOnly) {
    $m->query('CREATE TABLE IF NOT EXISTS visits (
        id         BIGINT AUTO_INCREMENT PRIMARY KEY,
        region     VARCHAR(32)  NOT NULL,
        app_host   VARCHAR(64)  NOT NULL,
        created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
    )');
    $stmt = $m->prepare('INSERT INTO visits (region, app_host) VALUES (?, ?)');
    $region = $app['region'] ?? 'unknown';
    $iid    = $app['instance_id'] ?? 'unknown';
    $stmt->bind_param('ss', $region, $iid);
    $out['db']['wrote_visit'] = $stmt->execute();
    $stmt->close();
} else {
    $rs = @$m->query('SHOW REPLICA STATUS');
    if ($rs && ($row = $rs->fetch_assoc())) {
        $out['db']['replication'] = [
            'source_host'           => $row['Source_Host'] ?? null,
            'io_running'            => $row['Replica_IO_Running'] ?? null,
            'sql_running'           => $row['Replica_SQL_Running'] ?? null,
            'seconds_behind_source' => $row['Seconds_Behind_Source'] ?? null,
        ];
    }
}

$rs = @$m->query('SELECT COUNT(*) AS total, MAX(created_at) AS last_write FROM visits');
if ($rs) {
    $row = $rs->fetch_assoc();
    $out['data']['total_visits']  = (int)$row['total'];
    $out['data']['last_write_at'] = $row['last_write'];
}
$rs = @$m->query('SELECT region FROM visits ORDER BY id DESC LIMIT 1');
if ($rs && ($row = $rs->fetch_assoc())) {
    $out['data']['last_written_by_region'] = $row['region'];
}
if (!isset($out['data'])) {
    $out['data'] = ['note' => 'visits table not created yet (primary has not been visited)'];
}

$m->close();
echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
