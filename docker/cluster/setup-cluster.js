// Build the InnoDB Cluster with MySQL Shell's AdminAPI.
// Runs inside the tools container:  mysqlsh --no-defaults --js --file /cluster/setup-cluster.js
// Safe to re-run: existing accounts, cluster and members are left alone.

const rootPw  = os.getenv('MYSQL_ROOT_PASSWORD');
const adminPw = os.getenv('CLUSTER_ADMIN_PASSWORD');
const NODES   = ['node1', 'node2', 'node3'];
const admin   = host => ({host: host, port: 3306, user: 'clusteradmin', password: adminPw});

// 1. Check each server meets Group Replication's requirements, fix what it
//    can, and create the cluster admin account (replicated later via clone).
for (const host of NODES) {
  println(`\n-- configureInstance ${host}`);
  try {
    dba.configureInstance({host: host, port: 3306, user: 'root', password: rootPw},
                          {clusterAdmin: "'clusteradmin'@'%'", clusterAdminPassword: adminPw, restart: false});
  } catch (e) {
    if (String(e.message).indexOf('already exists') >= 0) println(`clusteradmin already exists on ${host}`);
    else throw e;
  }
}

// 2. Create the cluster on node1 (which holds the data), unless it exists.
shell.connect(admin('node1'));
let cluster;
try {
  cluster = dba.getCluster('payflow');
  println('\n-- cluster payflow already exists');
} catch (e) {
  println('\n-- createCluster payflow on node1');
  cluster = dba.createCluster('payflow', {communicationStack: 'MYSQL'});
}

// 3. Add node2 and node3. recoveryMethod 'clone' copies node1's data
//    directory, then the node catches up from the group's binary logs.
for (const host of ['node2', 'node3']) {
  if (cluster.status().defaultReplicaSet.topology[`${host}:3306`]) {
    println(`\n-- ${host} is already a member`);
    continue;
  }
  println(`\n-- addInstance ${host} (clone)`);
  const t0 = Date.now();
  cluster.addInstance(admin(host), {recoveryMethod: 'clone'});
  println(`${host} joined in ${Math.round((Date.now() - t0) / 1000)}s`);
}

println('\n-- cluster status');
const st = cluster.status();
println(`${st.clusterName}: ${st.defaultReplicaSet.status} — ${st.defaultReplicaSet.statusText}`);
