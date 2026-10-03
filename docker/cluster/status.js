// Compact cluster status, connecting through whichever node is reachable.
// Runs inside the tools container:  mysqlsh --no-defaults --js --file /cluster/status.js
const adminPw = os.getenv('CLUSTER_ADMIN_PASSWORD');
let connected = false;
for (const host of ['node1', 'node2', 'node3']) {
  try {
    shell.connect({host: host, port: 3306, user: 'clusteradmin', password: adminPw, 'connect-timeout': 2000});
    connected = true; break;
  } catch (e) { /* try the next node */ }
}
if (!connected) { println('No cluster node reachable'); }
else {
  const st = dba.getCluster().status();
  const rs = st.defaultReplicaSet;
  println(`${st.clusterName}: ${rs.status} — ${rs.statusText}`);
  println('MEMBER       ROLE       MODE  STATUS        LAG');
  for (const [addr, m] of Object.entries(rs.topology)) {
    // AdminAPI reports 'applier_queue_applied' when nothing is waiting to apply.
    let lag = m.replicationLag;
    if (lag === undefined || lag === null) lag = '-';
    else if (lag === 'applier_queue_applied') lag = '0';
    println(`${addr.padEnd(12)} ${String(m.memberRole || '-').padEnd(10)} ${String(m.mode).padEnd(5)} ${String(m.status).padEnd(13)} ${lag}`);
  }
}
