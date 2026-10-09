#!/usr/bin/env python3
"""Phase 6 setup, negative privilege checks, and UTC monthly evidence."""
import argparse
import datetime as dt
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCKER = 'docker'

def run(sql, user='root', password=None, tls='VERIFY_IDENTITY', ok=True, host_override=None):
    env = 'MYSQL_ROOT_PASSWORD' if password is None else 'PHASE6_PASSWORD'
    cmd = [DOCKER, 'exec', '-i']
    if password is not None:
        cmd += ['-e', 'PHASE6_PASSWORD=' + password]
    host = host_override or ('localhost' if user == 'root' else 'mysql')
    cmd += ['payflow-mysql', 'sh', '-c',
            f'MYSQL_PWD="${env}" exec mysql --batch --raw -u "$1" --host="$3" --ssl-mode="$2" --ssl-ca=/tls/ca.pem',
            'mysql', user, tls, host]
    result = subprocess.run(cmd, input=sql, text=True, capture_output=True)
    if ok and result.returncode:
        raise RuntimeError(result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['setup', 'harden', 'encrypt', 'verify', 'report'])
    args = parser.parse_args()
    secrets = dict(line.split('=', 1) for line in (ROOT / '.env').read_text().splitlines()
                   if '=' in line and not line.startswith('#'))
    if args.action == 'harden':
        run((ROOT / 'security/owner.sql').read_text())
        for filename, kind in [('02_procedures.sql', 'PROCEDURE'), ('03_triggers.sql', 'TRIGGER')]:
            sql = (ROOT / 'schema' / filename).read_text()
            sql = sql.replace('CREATE ' + kind, "CREATE DEFINER='payflow_owner'@'localhost' " + kind)
            run('USE payflow;\n' + sql)
        run("ALTER USER 'root'@'%' ACCOUNT LOCK; ALTER USER 'exporter'@'%' REQUIRE SSL;")
        # Migrate older phases' global read grants without issuing REVOKE for
        # nonexistent grants on a freshly provisioned scoped account.
        for account, privileges in [('backup', ['SELECT', 'SHOW VIEW', 'TRIGGER', 'EVENT']),
                                    ('exporter', ['SELECT'])]:
            allowed = ','.join("'" + privilege + "'" for privilege in privileges)
            granted = run(f"SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=CONCAT(CHAR(39),'{account}',CHAR(39),'@',CHAR(39),'%',CHAR(39)) AND PRIVILEGE_TYPE IN ({allowed})").stdout.splitlines()[1:]
            if granted:
                run(f"REVOKE {','.join(granted)} ON *.* FROM '{account}'@'%';")
            scoped = (ROOT / f'security/{account}-scope.sql').read_text()
            run('\n'.join(line for line in scoped.splitlines() if not line.startswith('REVOKE ')))
        print('Locked scoped owner installed for routines/triggers; remote root locked')
    elif args.action == 'encrypt':
        result = run("SELECT CONCAT(t.TABLE_SCHEMA,'.',t.TABLE_NAME) FROM information_schema.TABLES t JOIN information_schema.INNODB_TABLESPACES s ON s.NAME=CONCAT(t.TABLE_SCHEMA,'/',t.TABLE_NAME) WHERE t.TABLE_SCHEMA IN ('payflow','ops','payflow_test') AND t.ENGINE='InnoDB' AND s.ENCRYPTION <> 'Y' ORDER BY t.DATA_LENGTH").stdout.splitlines()[1:]
        for table in result:
            schema, name = table.split('.', 1)
            assert schema.replace('_', '').isalnum() and name.replace('_', '').isalnum()
            run(f"ALTER TABLE `{schema}`.`{name}` ENCRYPTION='Y';")
            print('ENCRYPTED: ' + table, flush=True)
        run("ALTER DATABASE payflow DEFAULT ENCRYPTION='Y'; ALTER DATABASE ops DEFAULT ENCRYPTION='Y'; ALTER TABLESPACE mysql ENCRYPTION='Y';")
        print('All application/ops tables and mysql system tablespace encrypted')
    elif args.action == 'setup':
        sql = (ROOT / 'security/setup.sql').read_text()
        for key in ['APP', 'REPORT', 'AUDITOR', 'BENCH']:
            value = secrets[key + '_PASSWORD']
            if not value or not all(c in '0123456789abcdef' for c in value):
                raise ValueError('Use make env to generate hex credentials')
            sql = sql.replace('__' + key + '_PASSWORD__', value)
        run(sql)
        (ROOT / '.private/security-enabled').touch()
        print('Roles, accounts, reporting view and persistent TLS requirement applied')
    elif args.action == 'verify':
        checks = [
            ('app cannot read PII', 'app', 'SELECT * FROM payflow.customers LIMIT 0', 1142),
            ('app cannot mutate wallets', 'app', 'UPDATE payflow.wallets SET balance=balance WHERE 1=0', 1142),
            ('app cannot call ledger helper', 'app', 'CALL payflow.sp_lock_wallets(0,0,0)', 1370),
            ('report cannot read PII', 'report', 'SELECT * FROM payflow.kyc_documents LIMIT 0', 1142),
            ('report cannot write', 'report', 'DELETE FROM payflow.transactions WHERE 1=0', 1142),
            ('auditor cannot alter audit', 'auditor', 'DELETE FROM payflow.audit_log WHERE 1=0', 1142),
            ('report view readable', 'report', 'SELECT * FROM payflow.v_daily_totals LIMIT 0', 0),
            ('audit readable', 'auditor', 'SELECT * FROM payflow.audit_log LIMIT 0', 0),
            ('public API executable', 'app', "CALL payflow.sp_wallet_statement(0, '2026-01-01', '2026-01-02')", 0),
        ]
        for label, account, sql, error in checks:
            r = run(sql, 'payflow_' + account, secrets[account.upper() + '_PASSWORD'], ok=False)
            assert (r.returncode == 0 if error == 0 else r.returncode != 0 and f'ERROR {error} ' in r.stderr), label + ': ' + r.stderr
            print('PASS: ' + label)
        r = run('SELECT 1', 'payflow_app', secrets['APP_PASSWORD'], tls='DISABLED', ok=False)
        assert r.returncode != 0 and ('ERROR 3159 ' in r.stderr or 'ERROR 1045 ' in r.stderr), r.stderr
        print('PASS: plaintext TCP rejected')
        print(run("SHOW SESSION STATUS LIKE 'Ssl_cipher'; SELECT @@require_secure_transport;", 'payflow_app', secrets['APP_PASSWORD']).stdout)
        r = run('SELECT 1', 'root', secrets['MYSQL_ROOT_PASSWORD'], ok=False, host_override='mysql')
        assert r.returncode != 0 and 'ERROR 3118 ' in r.stderr, r.stderr
        print('PASS: remote root account locked')
        result = run("SELECT COUNT(*) FROM mysql.user WHERE User='payflow_owner' AND account_locked='Y';").stdout.splitlines()[-1]
        assert result == '1', 'definer account must be locked'
        print('PASS: scoped definer cannot log in')
        print('PASS: public clients verify server identity against the lab CA')
    else:
        now = dt.datetime.now(dt.timezone.utc)
        queries = [
            ('Accounts (no password hashes)', 'SELECT User,Host,account_locked,password_expired,ssl_type FROM mysql.user ORDER BY User,Host'),
            ('Role memberships', 'SELECT * FROM mysql.role_edges ORDER BY TO_USER,FROM_USER'),
            ('Default roles', 'SELECT * FROM mysql.default_roles ORDER BY USER,DEFAULT_ROLE_USER'),
            ('Global grants', 'SELECT * FROM information_schema.USER_PRIVILEGES ORDER BY GRANTEE,PRIVILEGE_TYPE'),
            ('Dynamic grants', 'SELECT USER,HOST,PRIV,WITH_GRANT_OPTION FROM mysql.global_grants ORDER BY USER,PRIV'),
            ('Column grants', 'SELECT * FROM information_schema.COLUMN_PRIVILEGES ORDER BY GRANTEE,TABLE_NAME,COLUMN_NAME'),
            ('Schema grants', 'SELECT * FROM information_schema.SCHEMA_PRIVILEGES ORDER BY GRANTEE,TABLE_SCHEMA,PRIVILEGE_TYPE'),
            ('Table grants', 'SELECT * FROM information_schema.TABLE_PRIVILEGES ORDER BY GRANTEE,TABLE_NAME,PRIVILEGE_TYPE'),
            ('Routine grants', 'SELECT Host,Db,User,Routine_name,Routine_type,Proc_priv FROM mysql.procs_priv ORDER BY User,Routine_name'),
            ('Trigger definers', "SELECT TRIGGER_NAME,DEFINER FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='payflow'"),
            ('View definers', "SELECT TABLE_NAME,DEFINER FROM information_schema.VIEWS WHERE TABLE_SCHEMA='payflow'"),
            ('Definers', "SELECT ROUTINE_NAME,DEFINER,SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='payflow'"),
            ('Transport', "SELECT @@require_secure_transport,@@tls_version; SHOW SESSION STATUS LIKE 'Ssl_cipher'"),
            ('Encryption settings', 'SELECT @@default_table_encryption,@@innodb_redo_log_encrypt,@@innodb_undo_log_encrypt,@@binlog_encryption'),
            ('Keyring component', 'SELECT STATUS_KEY,STATUS_VALUE FROM performance_schema.keyring_component_status'),
            ('Tablespace encryption', "SELECT NAME,ENCRYPTION FROM information_schema.INNODB_TABLESPACES WHERE NAME='mysql' OR NAME REGEXP '^(payflow|ops|payflow_test)/' ORDER BY NAME"),
            ('Backup outcomes this month UTC', "SELECT job,status,COUNT(*) AS runs,MAX(finished_at) AS latest FROM ops.backup_history WHERE started_at >= DATE_FORMAT(UTC_TIMESTAMP(),'%Y-%m-01') AND started_at < DATE_FORMAT(UTC_TIMESTAMP() + INTERVAL 1 MONTH,'%Y-%m-01') GROUP BY job,status"),
        ]
        output = '# Access review — ' + now.isoformat() + '\n\nGenerated evidence; human approval is recorded separately.\n'
        for title, sql in queries:
            output += '\n## ' + title + '\n\n```text\n' + run(sql).stdout + '```\n'
        path = ROOT / 'docs/evidence/phase6' / ('access-review-' + now.strftime('%Y-%m') + '.md')
        path.write_text(output)
        print(path)

if __name__ == '__main__':
    main()
