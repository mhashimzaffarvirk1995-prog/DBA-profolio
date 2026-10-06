#!/usr/bin/env bash
# EXPLAIN ANALYZE for the workload queries, on an otherwise idle server.
# EXPLAIN ANALYZE really executes each query and reports actual rows and time
# per plan step.
#   tuning/explain.sh <label>   -> docs/evidence/phase4/<label>-explain.txt
set -euo pipefail
COMPOSE_FILE="$(cd "$(dirname "$0")/../docker/standalone" && pwd)/docker-compose.yml"
source "$(dirname "$0")/../scripts/lib/common.sh"
LABEL="${1:?usage: explain.sh <label>}"
OUT="$ROOT/docs/evidence/phase4/$LABEL-explain.txt"
mkdir -p "$(dirname "$OUT")"

# A typical customer: the wallet and customer the loadgen sample starts with.
read -r W C < <(q mysql "SELECT w.wallet_id, w.customer_id FROM payflow.wallets w JOIN payflow.customers c USING (customer_id)
                         WHERE w.wallet_type = 'customer' AND c.kyc_status = 'verified' AND w.wallet_id % 50 = 7 LIMIT 1")
AS_OF="'2026-09-30 00:00:00'"

declare -a NAMES SQLS
add() { NAMES+=("$1"); SQLS+=("$2"); }
add "Q1 statement (wallet $W)" "SELECT le.created_at, t.txn_ref, t.txn_type, t.status, le.entry_type, le.amount, le.balance_after FROM ledger_entries le JOIN transactions t ON t.txn_id = le.txn_id WHERE le.wallet_id = $W AND le.created_at >= '2026-08-01' AND le.created_at < '2026-09-01' ORDER BY le.entry_id"
add "Q2 recent activity, original (customer $C)" "SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at FROM transactions t WHERE t.source_wallet_id IN (SELECT wallet_id FROM wallets WHERE customer_id = $C) OR t.dest_wallet_id IN (SELECT wallet_id FROM wallets WHERE customer_id = $C) ORDER BY t.created_at DESC LIMIT 20"
add "Q2 recent activity, UNION ALL rewrite (customer $C)" "SELECT txn_ref, txn_type, status, amount, currency_code, created_at FROM ((SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at FROM wallets w JOIN transactions t ON t.source_wallet_id = w.wallet_id WHERE w.customer_id = $C ORDER BY t.created_at DESC LIMIT 20) UNION ALL (SELECT t.txn_ref, t.txn_type, t.status, t.amount, t.currency_code, t.created_at FROM wallets w JOIN transactions t ON t.dest_wallet_id = w.wallet_id WHERE w.customer_id = $C ORDER BY t.created_at DESC LIMIT 20)) recent ORDER BY created_at DESC LIMIT 20"
add "Q3 corridor volume" "SELECT DATE(t.created_at) AS day, t.currency_code, t.payout_currency_code, COUNT(*), SUM(t.amount), SUM(t.fee_amount) FROM transactions t WHERE t.txn_type = 'remittance' AND t.created_at >= $AS_OF - INTERVAL 30 DAY GROUP BY DATE(t.created_at), t.currency_code, t.payout_currency_code"
add "Q4 AML 30-day" "SELECT w.customer_id, t.currency_code, COUNT(*), SUM(t.amount) AS total_sent FROM transactions t JOIN wallets w ON w.wallet_id = t.source_wallet_id WHERE t.txn_type = 'remittance' AND t.status <> 'failed' AND t.created_at >= $AS_OF - INTERVAL 30 DAY GROUP BY w.customer_id, t.currency_code HAVING SUM(t.amount) > 10000"
add "Q5 stuck remittances" "SELECT t.txn_id, t.txn_ref, t.amount, t.currency_code, t.created_at FROM transactions t WHERE t.status = 'pending' AND t.txn_type = 'remittance' AND t.created_at < $AS_OF - INTERVAL 1 DAY ORDER BY t.created_at"
add "Q6 expired KYC" "SELECT c.customer_id, c.customer_ref, k.doc_type, k.expiry_date FROM kyc_documents k JOIN customers c ON c.customer_id = k.customer_id WHERE k.status = 'expired' AND EXISTS (SELECT 1 FROM wallets w JOIN transactions t ON t.source_wallet_id = w.wallet_id WHERE w.customer_id = c.customer_id AND t.txn_type = 'remittance' AND t.created_at >= $AS_OF - INTERVAL 30 DAY)"
add "Q7 fee revenue" "SELECT DATE_FORMAT(le.created_at, '%Y-%m') AS month, w.currency_code, SUM(IF(le.entry_type = 'credit', le.amount, -le.amount)) FROM ledger_entries le JOIN wallets w ON w.wallet_id = le.wallet_id WHERE w.wallet_type = 'fee_revenue' GROUP BY month, w.currency_code"

: > "$OUT"
for i in "${!NAMES[@]}"; do
    t0=$(date +%s)
    {
        echo "=== ${NAMES[$i]}"
        sql mysql payflow -e "EXPLAIN ANALYZE ${SQLS[$i]}\G" | sed -n 's/^EXPLAIN: //p; /^ *->/p'
        echo
    } >> "$OUT"
    # The top line of each plan carries the total actual time.
    printf '%-52s %s\n' "${NAMES[$i]}" "$(grep -A1 "=== ${NAMES[$i]}" "$OUT" | tail -1 | grep -oE 'actual time=[0-9.]+\.\.[0-9.]+' | head -1 | sed 's/.*\.\.//; s/$/ ms/')"
done
echo "saved: ${OUT#$ROOT/}"
