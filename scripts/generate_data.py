#!/usr/bin/env python3
"""
Generate a realistic PayFlow dataset as CSV files for LOAD DATA INFILE.

The dataset is a simulation, not random rows: events are generated in time
order and every wallet balance is tracked, so the output obeys the same rules
the stored procedures enforce:

  * customer wallets never go negative (a remittance with too little balance
    is preceded by a top-up deposit, as real customers do)
  * every completed money movement has balanced ledger entries, so per
    currency SUM(wallets.balance) = 0 and each wallet's balance equals its
    ledger total
  * failed remittances are refunded by a later 'reversal' transaction
  * customers only transact after onboarding, remittances only by
    KYC-verified customers, to their own beneficiaries

Volume follows patterns a remittance business sees: a growing customer base,
salary-week peaks (25th to 5th), a surge before each Eid, evening peaks, and a
heavy-tailed split of activity across customers.

Standard library only. Deterministic for a given --seed.

    python3 scripts/generate_data.py --transactions 10000000          # full
    python3 scripts/generate_data.py --transactions 200000 --customers 20000   # quick
"""

import argparse
import bisect
import csv
import heapq
import math
import os
import random
import sys
import time
from datetime import date, datetime, timedelta

NULL = r"\N"   # LOAD DATA reads an unquoted \N as NULL
US_PER_DAY = 86_400_000_000
EPOCH = date(1970, 1, 1)

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

CURRENCIES = [
    ("USD", "US Dollar"), ("GBP", "Pound Sterling"), ("EUR", "Euro"),
    ("AED", "UAE Dirham"), ("SAR", "Saudi Riyal"), ("CAD", "Canadian Dollar"),
    ("AUD", "Australian Dollar"), ("PKR", "Pakistani Rupee"), ("INR", "Indian Rupee"),
    ("BDT", "Bangladeshi Taka"), ("PHP", "Philippine Peso"),
]

# code, name, currency, dial code, share of customers living there
SEND_COUNTRIES = [
    ("GB", "United Kingdom", "GBP", "+44", 0.28),
    ("AE", "United Arab Emirates", "AED", "+971", 0.22),
    ("SA", "Saudi Arabia", "SAR", "+966", 0.15),
    ("US", "United States", "USD", "+1", 0.12),
    ("CA", "Canada", "CAD", "+1", 0.07),
    ("AU", "Australia", "AUD", "+61", 0.06),
    ("DE", "Germany", "EUR", "+49", 0.04),
    ("IT", "Italy", "EUR", "+39", 0.03),
    ("ES", "Spain", "EUR", "+34", 0.03),
]

# code, name, currency, dial code, share of customers originally from there
RECEIVE_COUNTRIES = [
    ("PK", "Pakistan", "PKR", "+92", 0.70),
    ("IN", "India", "INR", "+91", 0.12),
    ("BD", "Bangladesh", "BDT", "+880", 0.10),
    ("PH", "Philippines", "PHP", "+63", 0.08),
]

SEND_CURRENCIES = ["GBP", "EUR", "USD", "AED", "SAR", "CAD", "AUD"]
PAYOUT_CURRENCY = {c[0]: c[2] for c in RECEIVE_COUNTRIES}

# Units of currency per 1 USD at the start of the simulation, and daily
# volatility / drift for the random walk. AED and SAR are pegged.
USD_RATES = {
    "USD": (1.0, 0.0, 0.0), "GBP": (0.79, 0.004, 0.0), "EUR": (0.92, 0.004, 0.0),
    "AED": (3.6725, 0.0, 0.0), "SAR": (3.75, 0.0, 0.0), "CAD": (1.37, 0.003, 0.0),
    "AUD": (1.52, 0.005, 0.0), "PKR": (279.5, 0.0015, 0.00008), "INR": (84.0, 0.002, 0.00005),
    "BDT": (119.5, 0.002, 0.00005), "PHP": (57.0, 0.003, 0.0),
}
FX_MARGIN = {"PK": 0.008, "IN": 0.010, "BD": 0.012, "PH": 0.011}

# Fee bands in send-currency units: [0, 100) -> small fee, [100, 500) -> smaller, 500+ -> free
FEE_TIERS = {
    "GBP": (1.99, 0.99), "EUR": (1.99, 0.99), "USD": (2.99, 1.99), "AED": (15.00, 10.00),
    "SAR": (15.00, 10.00), "CAD": (3.99, 1.99), "AUD": (3.99, 1.99),
}
FEE_BAND_EDGES = (0, 100, 500, 1_000_000_000)

NAMES = {
    "PK": (["Muhammad", "Ahmed", "Ali", "Usman", "Hassan", "Bilal", "Hamza", "Imran", "Faisal", "Zeeshan",
            "Fatima", "Ayesha", "Zainab", "Sana", "Hira", "Maryam", "Amna", "Iqra", "Sadia", "Nadia"],
           ["Khan", "Ahmed", "Malik", "Qureshi", "Chaudhry", "Butt", "Sheikh", "Raza", "Siddiqui", "Hussain",
            "Iqbal", "Shah", "Mirza", "Abbasi", "Javed", "Aslam", "Akhtar", "Rana", "Bhatti", "Awan"]),
    "IN": (["Rahul", "Amit", "Vikram", "Arjun", "Suresh", "Rohan", "Priya", "Anjali", "Neha", "Pooja",
            "Kavya", "Deepa", "Harpreet", "Gurpreet", "Manoj", "Ravi"],
           ["Sharma", "Patel", "Singh", "Kumar", "Gupta", "Reddy", "Nair", "Iyer", "Mehta", "Joshi",
            "Rao", "Verma", "Gill", "Sandhu"]),
    "BD": (["Rahim", "Karim", "Tanvir", "Sakib", "Nazmul", "Rafiq", "Farhana", "Nusrat", "Taslima",
            "Shirin", "Rumana", "Mithila"],
           ["Hossain", "Rahman", "Islam", "Uddin", "Chowdhury", "Ahmed", "Sarkar", "Miah", "Begum", "Akter"]),
    "PH": (["Jose", "Mark", "John", "Paolo", "Miguel", "Angelo", "Maria", "Kristine", "Jasmine",
            "Angelica", "Camille", "Rowena"],
           ["Santos", "Reyes", "Cruz", "Bautista", "Garcia", "Mendoza", "Torres", "Flores", "Ramos",
            "Aquino", "Villanueva", "Castillo"]),
}

# Fictional dataset: real provider names, made-up account numbers.
PROVIDERS = {
    "PK": (["HBL", "MCB Bank", "United Bank Limited", "Meezan Bank", "Allied Bank", "Bank Alfalah",
            "Faysal Bank", "Askari Bank"], ["JazzCash", "Easypaisa"]),
    "IN": (["State Bank of India", "HDFC Bank", "ICICI Bank", "Axis Bank", "Punjab National Bank"],
           ["Paytm", "PhonePe"]),
    "BD": (["Sonali Bank", "Dutch-Bangla Bank", "BRAC Bank", "Islami Bank Bangladesh"], ["bKash", "Nagad"]),
    "PH": (["BDO Unibank", "BPI", "Metrobank", "Landbank"], ["GCash", "Maya"]),
}

FAILURE_REASONS = ["BENEFICIARY_ACCOUNT_INVALID", "PAYOUT_PARTNER_REJECTED", "COMPLIANCE_REJECTED",
                   "BENEFICIARY_NAME_MISMATCH"]
CHANNELS = ["app", "web", "branch", "api"]
CHANNEL_CUM_WEIGHTS = [60, 80, 92, 100]

# Share of evening activity by UTC hour (the diaspora sends after work).
HOUR_WEIGHTS = [2, 1, 1, 1, 1, 2, 3, 4, 5, 6, 6, 6, 6, 6, 6, 7, 8, 9, 10, 10, 9, 7, 5, 3]

# Approximate Eid dates in the simulation window; the 10 days before each see a surge.
EID_DATES = [date(2024, 4, 10), date(2024, 6, 16), date(2025, 3, 30), date(2025, 6, 6),
             date(2026, 3, 20), date(2026, 5, 27), date(2027, 3, 9), date(2027, 5, 16)]

HOUSE_CUSTOMER_ID = 1


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def money(cents):
    """Integer cents -> 'D.CC' (works for negative house balances)."""
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}{cents // 100}.{cents % 100:02d}"


class Clock:
    """Formats microseconds-since-epoch as DATETIME(6) without datetime objects per row."""

    def __init__(self):
        self._day_cache = {}

    def fmt(self, us):
        day, rem = divmod(us, US_PER_DAY)
        d = self._day_cache.get(day)
        if d is None:
            d = (EPOCH + timedelta(days=day)).isoformat()
            self._day_cache[day] = d
        secs, micro = divmod(rem, 1_000_000)
        h, secs = divmod(secs, 3600)
        m, s = divmod(secs, 60)
        return f"{d} {h:02d}:{m:02d}:{s:02d}.{micro:06d}"


def day_number(d):
    return (d - EPOCH).days


class CountingWriter:
    """csv writer that counts rows and, for big tables, rotates to a new
    numbered file every chunk_rows rows (name_0001.csv, name_0002.csv, ...)
    so each LOAD DATA statement stays a manageable transaction."""

    def __init__(self, out_dir, name, header, chunk_rows=None):
        self.out_dir, self.name, self.header, self.chunk_rows = out_dir, name, header, chunk_rows
        self.count = 0
        self.chunk = 0
        self.f = None
        self._rotate()

    def _rotate(self):
        if self.f:
            self.f.close()
        self.chunk += 1
        fname = f"{self.name}_{self.chunk:04d}.csv" if self.chunk_rows else f"{self.name}.csv"
        self.f = open(os.path.join(self.out_dir, fname), "w", newline="", encoding="utf-8")
        self.f.write(",".join(self.header) + "\n")
        self._w = csv.writer(self.f, lineterminator="\n")

    def writerow(self, values):
        if self.chunk_rows and self.count and self.count % self.chunk_rows == 0:
            self._rotate()
        self._w.writerow(values)
        self.count += 1

    def close(self):
        self.f.close()


class Writers:
    def __init__(self, out_dir, chunk_rows):
        self.out_dir = out_dir
        self.chunk_rows = chunk_rows
        self.writers = {}

    def open(self, name, header, chunked=False):
        w = CountingWriter(self.out_dir, name, header, self.chunk_rows if chunked else None)
        self.writers[name] = w
        return w

    def row(self, name, values):
        self.writers[name].writerow(values)

    def counts(self):
        return {name: w.count for name, w in self.writers.items()}

    def close(self):
        for w in self.writers.values():
            w.close()


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------

class Generator:
    def __init__(self, args):
        self.args = args
        self.rng = random.Random(args.seed)
        self.clock = Clock()
        self.out = Writers(args.out, args.chunk_rows)
        self.start = date.fromisoformat(args.start)
        self.end = self.start + timedelta(days=args.days)        # exclusive
        self.start_us = day_number(self.start) * US_PER_DAY
        self.end_us = day_number(self.end) * US_PER_DAY

        self.next_wallet_id = 1
        self.next_txn_id = 1
        self.next_entry_id = 1
        self.balances = {}              # wallet_id -> cents
        self.wallet_meta = {}           # wallet_id -> [customer_id, currency, type, created_us, last_us]
        self.house = {}                 # (currency, 'settlement'|'fee_revenue') -> wallet_id

    # -- reference data -----------------------------------------------------

    def write_reference(self):
        w = self.out.open("currencies", ["currency_code", "name", "minor_units"])
        for code, name in CURRENCIES:
            w.writerow([code, name, 2])

        w = self.out.open("countries", ["country_code", "name", "currency_code", "dial_code",
                                        "is_send_market", "is_receive_market"])
        for code, name, ccy, dial, _ in SEND_COUNTRIES:
            w.writerow([code, name, ccy, dial, 1, 0])
        for code, name, ccy, dial, _ in RECEIVE_COUNTRIES:
            w.writerow([code, name, ccy, dial, 0, 1])

        w = self.out.open("remittance_fees", ["fee_id", "currency_code", "dest_country_code",
                                              "min_amount", "max_amount", "fee_amount"])
        self.fees = {}
        fee_id = 1
        for ccy in SEND_CURRENCIES:
            small, mid = FEE_TIERS[ccy]
            for country, *_ in RECEIVE_COUNTRIES:
                for lo, hi, fee in zip(FEE_BAND_EDGES, FEE_BAND_EDGES[1:], (small, mid, 0.0)):
                    w.writerow([fee_id, ccy, country, f"{lo}.0000", f"{hi}.0000", f"{fee:.4f}"])
                    fee_id += 1
                self.fees[(ccy, country)] = (round(small * 100), round(mid * 100))

    def fee_cents(self, ccy, country, amount_cents):
        small, mid = self.fees[(ccy, country)]
        if amount_cents < 100_00:
            return small
        if amount_cents < 500_00:
            return mid
        return 0

    def write_exchange_rates(self):
        """One rate per corridor per day, published at 00:00 UTC."""
        w = self.out.open("exchange_rates", ["rate_id", "base_currency_code", "quote_currency_code",
                                             "mid_rate", "customer_rate", "source", "valid_from"])
        level = {ccy: v[0] for ccy, v in USD_RATES.items()}
        self.rates = {}                  # (day_number, send_ccy, country) -> (rate_id, customer_rate)
        rate_id = 1
        for offset in range(self.args.days):
            d = self.start + timedelta(days=offset)
            dn = day_number(d)
            for ccy, (_, vol, drift) in USD_RATES.items():
                if vol:
                    level[ccy] *= math.exp(drift + self.rng.gauss(0, vol))
            for send in SEND_CURRENCIES:
                for country, _, payout, _, _ in RECEIVE_COUNTRIES:
                    mid = level[payout] / level[send]
                    cust = mid * (1 - FX_MARGIN[country])
                    w.writerow([rate_id, send, payout, f"{mid:.8f}", f"{cust:.8f}", "SIMULATED",
                                f"{d.isoformat()} 00:00:00"])
                    self.rates[(dn, send, country)] = (rate_id, cust)
                    rate_id += 1

    # -- customers, KYC, wallets, beneficiaries -----------------------------

    def add_wallet(self, customer_id, ccy, wtype, created_us):
        wid = self.next_wallet_id
        self.next_wallet_id += 1
        self.balances[wid] = 0
        self.wallet_meta[wid] = [customer_id, ccy, wtype, created_us, created_us]
        return wid

    def write_customers(self):
        rng = self.rng
        n = self.args.customers
        cust_w = self.out.open("customers", [
            "customer_id", "customer_ref", "customer_type", "first_name", "last_name", "email", "phone",
            "date_of_birth", "nationality_country_code", "residence_country_code", "national_id_number",
            "status", "kyc_status", "risk_rating", "created_at", "updated_at"])
        kyc_w = self.out.open("kyc_documents", [
            "kyc_document_id", "customer_id", "doc_type", "doc_number", "issuing_country_code",
            "issue_date", "expiry_date", "status", "rejection_reason", "file_sha256", "verified_at",
            "created_at"])
        ben_w = self.out.open("beneficiaries", [
            "beneficiary_id", "customer_id", "full_name", "country_code", "currency_code", "payout_method",
            "provider_name", "account_number", "mobile_number", "relationship", "is_active",
            "created_at", "updated_at"])

        # PayFlow's own house account, with settlement + fee wallets per send currency.
        house_created = self.start_us - 400 * US_PER_DAY
        ts = self.clock.fmt(house_created)
        cust_w.writerow([HOUSE_CUSTOMER_ID, "PAYFLOW-HOUSE", "system", "PayFlow", "House Account",
                         "treasury@payflow.example", "+440000000000", NULL, "GB", "GB", NULL,
                         "active", "verified", "low", ts, ts])
        all_ccys = SEND_CURRENCIES + sorted(set(PAYOUT_CURRENCY.values()))
        for ccy in all_ccys:
            for wtype in ("settlement", "fee_revenue"):
                self.house[(ccy, wtype)] = self.add_wallet(HOUSE_CUSTOMER_ID, ccy, wtype, house_created)

        send_codes = [c[0] for c in SEND_COUNTRIES]
        send_weights = [c[4] for c in SEND_COUNTRIES]
        send_ccy = {c[0]: c[2] for c in SEND_COUNTRIES}
        send_dial = {c[0]: c[3] for c in SEND_COUNTRIES}
        origin_codes = [c[0] for c in RECEIVE_COUNTRIES]
        origin_weights = [c[4] for c in RECEIVE_COUNTRIES]
        recv_dial = {c[0]: c[3] for c in RECEIVE_COUNTRIES}

        # 40% of customers already exist when the simulation starts; the rest
        # sign up over the window, which is what makes volume grow.
        window = self.end_us - self.start_us
        created = []
        for _ in range(n):
            if rng.random() < 0.4:
                created.append(self.start_us - rng.randrange(365 * US_PER_DAY))
            else:
                created.append(self.start_us + int(window * rng.random() ** 0.8) - US_PER_DAY)
        created.sort()

        # Sorted by created_at so "customers who exist by time T" is a prefix.
        self.cust_created = []          # created_us per eligible customer (sorted)
        self.cust_ids = []
        self.cust_cum_weight = []
        self.cust_wallets = {}          # customer_id -> [primary wallet, optional second]
        self.cust_benes = {}            # customer_id -> [(beneficiary_id, country)]
        self.wallets_by_ccy = {}        # ccy -> ([created_us], [wallet_id]) for transfer counterparties
        cum = 0.0
        kyc_id = 1
        ben_id = 1
        today = self.end

        for i, c_us in enumerate(created):
            cid = i + 2                          # 1 is the house account
            residence = rng.choices(send_codes, send_weights)[0]
            origin = rng.choices(origin_codes, origin_weights)[0]
            first = rng.choice(NAMES[origin][0])
            last = rng.choice(NAMES[origin][1])
            nationality = origin if rng.random() < 0.75 else residence   # some have naturalised
            dob = date(1960, 1, 1) + timedelta(days=rng.randrange(365 * 45))
            r = rng.random()
            kyc_status = "verified" if r < 0.88 else "pending" if r < 0.95 else "rejected" if r < 0.97 else "not_started"
            r = rng.random()
            status = "active" if r < 0.96 else "suspended" if r < 0.985 else "closed"
            risk = rng.choices(["low", "medium", "high"], [80, 17, 3])[0]
            ts = self.clock.fmt(c_us)
            cust_w.writerow([
                cid, f"CUS{cid:09d}", "individual", first, last,
                f"{first.lower()}.{last.lower()}{cid}@example.com",
                f"{send_dial[residence]}{rng.randrange(10**9, 10**10)}",
                dob.isoformat(), nationality, residence, self.national_id(origin),
                status, kyc_status, risk, ts, ts])

            # KYC documents consistent with the customer's KYC status.
            if kyc_status != "not_started":
                docs = [("passport", nationality)]
                if kyc_status == "verified":
                    docs.append(("residence_permit" if nationality != residence else "national_id", residence))
                    if rng.random() < 0.6:
                        docs.append(("proof_of_address", residence))
                for doc_type, issuer in docs:
                    up_us = c_us + rng.randrange(3600_000_000)
                    issue = (EPOCH + timedelta(days=up_us // US_PER_DAY)) - timedelta(days=rng.randrange(30, 3000))
                    expiry = NULL
                    doc_status, reason, verified = "pending", NULL, NULL
                    if doc_type != "proof_of_address":
                        exp_date = issue + timedelta(days=365 * (10 if doc_type == "passport" else 5))
                        expiry = exp_date.isoformat()
                    if kyc_status == "verified":
                        doc_status = "verified"
                        verified = self.clock.fmt(up_us + rng.randrange(600_000_000, 86_400_000_000))
                        if expiry != NULL and exp_date < today:
                            doc_status = "expired"
                    elif kyc_status == "rejected":
                        doc_status = "rejected"
                        reason = rng.choice(["IMAGE_UNREADABLE", "NAME_MISMATCH", "DOCUMENT_EXPIRED"])
                    kyc_w.writerow([
                        kyc_id, cid, doc_type,
                        NULL if doc_type == "proof_of_address" else self.doc_number(doc_type),
                        issuer, issue.isoformat(), expiry, doc_status, reason,
                        f"{rng.getrandbits(256):064x}", verified, self.clock.fmt(up_us)])
                    kyc_id += 1

            # Wallets: home currency, plus a USD wallet for some.
            ccy = send_ccy[residence]
            wallets = [self.add_wallet(cid, ccy, "customer", c_us)]
            if ccy != "USD" and rng.random() < 0.12:
                wallets.append(self.add_wallet(cid, "USD", "customer", c_us + 1))
            self.cust_wallets[cid] = wallets

            # Beneficiaries, mostly family back home. At least one is active.
            benes = []
            for k in range(rng.choices([1, 2, 3, 4], [45, 30, 15, 10])[0]):
                country = origin if rng.random() < 0.95 else rng.choice(origin_codes)
                relationship = "self" if rng.random() < 0.05 else rng.choices(
                    ["family", "friend", "business", "other"], [80, 10, 5, 5])[0]
                if relationship == "self":
                    name = f"{first} {last}"
                else:
                    name = f"{rng.choice(NAMES[country][0])} {rng.choice(NAMES[country][1])}"
                method = rng.choices(["bank_deposit", "mobile_wallet", "cash_pickup"], [60, 25, 15])[0]
                banks, mwallets = PROVIDERS[country]
                provider = account = mobile = NULL
                if method == "bank_deposit":
                    provider = rng.choice(banks)
                    account = self.account_number(country)
                elif method == "mobile_wallet":
                    provider = rng.choice(mwallets)
                    mobile = f"{recv_dial[country]}3{rng.randrange(10**8, 10**9)}"
                active = 1 if k == 0 or rng.random() < 0.9 else 0
                b_ts = self.clock.fmt(c_us + rng.randrange(1, 3600_000_000))
                ben_w.writerow([ben_id, cid, name, country, PAYOUT_CURRENCY[country], method, provider,
                                account, mobile, relationship, active, b_ts, b_ts])
                if active:
                    benes.append((ben_id, country))
                ben_id += 1
            self.cust_benes[cid] = benes

            # Only active customers transact; remittances additionally need KYC.
            if status == "active":
                # Heavy-tailed but capped: the busiest sender is ~11x the average,
                # not one account doing a tenth of all business.
                weight = min(rng.paretovariate(1.3), 40.0) if kyc_status == "verified" else 0.0
                cum += weight
                self.cust_created.append(c_us)
                self.cust_ids.append(cid)
                self.cust_cum_weight.append(cum)
                if kyc_status == "verified":
                    for wid in wallets:
                        wc = self.wallet_meta[wid][1]
                        lst = self.wallets_by_ccy.setdefault(wc, ([], []))
                        lst[0].append(c_us)
                        lst[1].append(wid)

            if (i + 1) % 50_000 == 0:
                log(f"  customers: {i + 1:,}/{n:,}")

    def national_id(self, origin):
        r = self.rng.randrange
        if origin == "PK":
            return f"{r(10000, 99999)}-{r(1000000, 9999999)}-{r(0, 10)}"
        if origin == "IN":
            return f"{r(1000, 9999)} {r(1000, 9999)} {r(1000, 9999)}"
        if origin == "BD":
            return f"{r(10**9, 10**10)}"
        return f"{r(1000, 9999)}-{r(1000, 9999)}-{r(1000, 9999)}"

    def doc_number(self, doc_type):
        letters = "ABCDEFGHJKLMNPRSTUVWXYZ"
        prefix = self.rng.choice(letters) + self.rng.choice(letters)
        return f"{prefix}{self.rng.randrange(10**6, 10**7)}" if doc_type == "passport" else \
            f"{prefix}{self.rng.randrange(10**8, 10**9)}"

    def account_number(self, country):
        r = self.rng.randrange
        if country == "PK":
            bank_code = "".join(self.rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(4))
            return f"PK{r(10, 99)}{bank_code}{r(10**15, 10**16)}"
        if country == "IN":
            return f"{r(10**10, 10**15)}"
        if country == "BD":
            return f"{r(10**12, 10**13)}"
        return f"{r(10**9, 10**12)}"

    # -- transactions -------------------------------------------------------

    def day_weights(self):
        weights = []
        for offset in range(self.args.days):
            d = self.start + timedelta(days=offset)
            w = 1.0
            if d.day >= 25 or d.day <= 5:                    # salary week
                w *= 1.35
            if d.weekday() in (4, 5):                        # Fri/Sat
                w *= 1.1
            for eid in EID_DATES:
                if 0 < (eid - d).days <= 10:
                    w *= 1.8
            # Each day's volume also scales with the customers that exist by then.
            day_us = self.start_us + offset * US_PER_DAY
            k = bisect.bisect_right(self.cust_created, day_us - US_PER_DAY)
            w *= max(k, 1)
            weights.append(w)
        total = sum(weights)
        return [w / total for w in weights]

    def pick_customer(self, before_us):
        """Weighted pick among eligible customers onboarded at least a day before."""
        k = bisect.bisect_right(self.cust_created, before_us - US_PER_DAY)
        if k == 0 or self.cust_cum_weight[k - 1] == 0:
            return None
        r = self.rng.random() * self.cust_cum_weight[k - 1]
        return self.cust_ids[bisect.bisect_right(self.cust_cum_weight, r, 0, k)]

    def lognormal_cents(self, ccy, median_usd, sigma, lo_usd, hi_usd, round_to=None):
        fx = USD_RATES[ccy][0]
        v = median_usd * math.exp(self.rng.gauss(0, sigma))
        v = min(max(v, lo_usd), hi_usd) * fx
        if round_to and self.rng.random() < 0.45:
            v = max(round_to, round(v / round_to) * round_to)
        return max(1_00, int(round(v * 100)))

    def emit_txn(self, ts, txn_type, status, source, dest, beneficiary, reversal_of, amount, ccy,
                 fee=0, rate=None, payout=None, payout_ccy=None, failure=None, completed=None, channel=None):
        tid = self.next_txn_id
        self.next_txn_id += 1
        self.out.row("transactions", [
            tid, f"PF{self.clock.fmt(ts)[2:10].replace('-', '')}{tid:010X}",
            f"{self.rng.getrandbits(128):032x}", txn_type, status,
            channel or self.rng.choices(CHANNELS, cum_weights=CHANNEL_CUM_WEIGHTS)[0],
            source or NULL, dest or NULL, beneficiary or NULL, reversal_of or NULL,
            money(amount), ccy, money(fee), rate or NULL,
            NULL if payout is None else f"{payout:.2f}", payout_ccy or NULL,
            failure or NULL, self.clock.fmt(ts), NULL if completed is None else self.clock.fmt(completed)])
        return tid

    def post(self, tid, wallet_id, entry_type, cents, ts):
        bal = self.balances[wallet_id] + (cents if entry_type == "credit" else -cents)
        self.balances[wallet_id] = bal
        self.wallet_meta[wallet_id][4] = ts
        self.out.row("ledger_entries", [self.next_entry_id, tid, wallet_id, entry_type, money(cents),
                                        money(bal), self.clock.fmt(ts)])
        self.next_entry_id += 1

    def deposit(self, ts, wallet_id, cents, channel=None):
        ccy = self.wallet_meta[wallet_id][1]
        if self.rng.random() < 0.01:   # card declined: recorded, no money moves
            self.emit_txn(ts, "deposit", "failed", None, wallet_id, None, None, cents, ccy,
                          failure="CARD_DECLINED", completed=ts, channel=channel)
            return False
        tid = self.emit_txn(ts, "deposit", "completed", None, wallet_id, None, None, cents, ccy,
                            completed=ts, channel=channel)
        self.post(tid, self.house[(ccy, "settlement")], "debit", cents, ts)
        self.post(tid, wallet_id, "credit", cents, ts)
        return True

    def reversal(self, ts, orig_tid, wallet_id, amount, fee):
        ccy = self.wallet_meta[wallet_id][1]
        tid = self.emit_txn(ts, "reversal", "completed", None, wallet_id, None, orig_tid, amount + fee, ccy,
                            completed=ts, channel="api")
        self.post(tid, self.house[(ccy, "settlement")], "debit", amount, ts)
        if fee:
            self.post(tid, self.house[(ccy, "fee_revenue")], "debit", fee, ts)
        self.post(tid, wallet_id, "credit", amount + fee, ts)

    def write_transactions(self):
        rng = self.rng
        args = self.args
        self.out.open("transactions", [
            "txn_id", "txn_ref", "idempotency_key", "txn_type", "status", "channel", "source_wallet_id",
            "dest_wallet_id", "beneficiary_id", "reversal_of_txn_id", "amount", "currency_code", "fee_amount",
            "fx_rate_id", "payout_amount", "payout_currency_code", "failure_reason", "created_at",
            "completed_at"], chunked=True)
        self.out.open("ledger_entries", [
            "entry_id", "txn_id", "wallet_id", "entry_type", "amount", "balance_after", "created_at"], chunked=True)

        weights = self.day_weights()
        target = args.transactions
        reversals = []                    # heap of (due_us, seq, orig_tid, wallet_id, amount, fee)
        seq = 0
        pending_window_us = 2 * US_PER_DAY
        started = time.time()
        last_log = 0

        for offset in range(args.days):
            day_us = self.start_us + offset * US_PER_DAY
            quota = int(round(target * weights[offset]))
            # Oversample: some candidate events are skipped (e.g. nothing to withdraw).
            hours = rng.choices(range(24), HOUR_WEIGHTS, k=int(quota * 1.3) + 1)
            times = sorted(day_us + h * 3_600_000_000 + rng.randrange(3_600_000_000) for h in hours)
            last_ts = day_us
            emitted_at_start = self.next_txn_id

            for ts in times:
                if self.next_txn_id - emitted_at_start >= quota:
                    break
                # Refunds for remittances that failed earlier fall due in time order.
                while reversals and reversals[0][0] <= ts:
                    due, _, orig, wid, amt, fee = heapq.heappop(reversals)
                    self.reversal(due, orig, wid, amt, fee)
                    last_ts = due

                cid = self.pick_customer(ts)
                if cid is None:
                    continue
                wallets = self.cust_wallets[cid]
                wid = wallets[0] if len(wallets) == 1 or rng.random() < 0.9 else wallets[1]
                ccy = self.wallet_meta[wid][1]
                kind = rng.random()

                if kind < 0.60:                                     # remittance
                    benes = self.cust_benes[cid]
                    ben_id, country = benes[0] if rng.random() < 0.7 else rng.choice(benes)
                    amount = self.lognormal_cents(ccy, 250, 0.8, 10, 8000, round_to=10)
                    fee = self.fee_cents(ccy, country, amount)
                    if self.balances[wid] < amount + fee:
                        # Customer tops up first, a little before sending.
                        top_up = amount + fee - self.balances[wid] + self.lognormal_cents(ccy, 40, 1.0, 0, 2000)
                        dep_ts = last_ts + int((ts - last_ts) * rng.random())
                        if not self.deposit(dep_ts, wid, top_up):
                            last_ts = ts
                            continue
                    rate_id, rate = self.rates[(ts // US_PER_DAY, ccy, country)]
                    payout = amount / 100 * rate
                    r = rng.random()
                    if ts > self.end_us - pending_window_us and r < 0.4:
                        status, completed, failure = "pending", None, None
                    elif r < 0.002:                                 # stuck: should trip an alert
                        status, completed, failure = "pending", None, None
                    elif r < 0.022:
                        status, failure = "failed", rng.choice(FAILURE_REASONS)
                        completed = ts + rng.randrange(600_000_000, 2 * US_PER_DAY)
                    else:
                        status, failure = "completed", None
                        completed = ts + rng.randrange(60_000_000, 5_400_000_000)
                    if completed is not None and completed >= self.end_us:
                        status, completed, failure = "pending", None, None   # outcome not known yet
                    tid = self.emit_txn(ts, "remittance", status, wid, None, ben_id, None, amount, ccy, fee,
                                        rate_id, payout, PAYOUT_CURRENCY[country], failure, completed)
                    self.post(tid, wid, "debit", amount + fee, ts)
                    self.post(tid, self.house[(ccy, "settlement")], "credit", amount, ts)
                    if fee:
                        self.post(tid, self.house[(ccy, "fee_revenue")], "credit", fee, ts)
                    if status == "failed":
                        seq += 1
                        heapq.heappush(reversals, (completed, seq, tid, wid, amount, fee))

                elif kind < 0.78:                                   # standalone deposit
                    self.deposit(ts, wid, self.lognormal_cents(ccy, 400, 0.9, 10, 15000, round_to=50))

                elif kind < 0.92:                                   # P2P transfer
                    pool = self.wallets_by_ccy.get(ccy)
                    k = bisect.bisect_right(pool[0], ts - US_PER_DAY)
                    dest = pool[1][rng.randrange(k)] if k > 1 else None
                    amount = self.lognormal_cents(ccy, 80, 0.9, 5, 3000, round_to=5)
                    if dest is None or dest == wid or self.balances[wid] < amount:
                        last_ts = ts
                        continue
                    tid = self.emit_txn(ts, "transfer", "completed", wid, dest, None, None, amount, ccy,
                                        completed=ts)
                    self.post(tid, wid, "debit", amount, ts)
                    self.post(tid, dest, "credit", amount, ts)

                else:                                               # withdrawal
                    bal = self.balances[wid]
                    if bal < 10_00:
                        last_ts = ts
                        continue
                    amount = min(bal, self.lognormal_cents(ccy, 150, 0.8, 10, 5000, round_to=10))
                    tid = self.emit_txn(ts, "withdrawal", "completed", wid, None, None, None, amount, ccy,
                                        completed=ts)
                    self.post(tid, wid, "debit", amount, ts)
                    self.post(tid, self.house[(ccy, "settlement")], "credit", amount, ts)
                last_ts = ts

            done = self.next_txn_id - 1
            if done - last_log >= 500_000 or offset == args.days - 1:
                last_log = done
                rate = done / max(time.time() - started, 1e-6)
                log(f"  transactions: {done:,} (day {offset + 1}/{args.days}, {rate:,.0f}/s)")

        # Refunds that fell due after the last event of the window.
        while reversals:
            due, _, orig, wid, amt, fee = heapq.heappop(reversals)
            self.reversal(due, orig, wid, amt, fee)

    def write_wallets(self):
        w = self.out.open("wallets", ["wallet_id", "customer_id", "currency_code", "wallet_type", "balance",
                                      "status", "created_at", "updated_at"])
        for wid in range(1, self.next_wallet_id):
            cid, ccy, wtype, created, last = self.wallet_meta[wid]
            w.writerow([wid, cid, ccy, wtype, money(self.balances[wid]), "active",
                        self.clock.fmt(created), self.clock.fmt(last)])

    def verify(self):
        """Sanity-check the invariants the database will also be checked for."""
        per_ccy = {}
        for wid, bal in self.balances.items():
            cid, ccy, wtype, *_ = self.wallet_meta[wid]
            if wtype == "customer" and bal < 0:
                raise AssertionError(f"wallet {wid} negative: {bal}")
            per_ccy[ccy] = per_ccy.get(ccy, 0) + bal
        bad = {c: v for c, v in per_ccy.items() if v != 0}
        if bad:
            raise AssertionError(f"ledger out of balance: {bad}")

    def run(self):
        os.makedirs(self.args.out, exist_ok=True)
        for f in os.listdir(self.args.out):          # never mix chunks from an older run
            if f.endswith(".csv"):
                os.remove(os.path.join(self.args.out, f))
        t0 = time.time()
        log("reference data and exchange rates ...")
        self.write_reference()
        self.write_exchange_rates()
        log(f"customers ({self.args.customers:,}) ...")
        self.write_customers()
        log(f"transactions (target {self.args.transactions:,}) ...")
        self.write_transactions()
        self.write_wallets()
        self.verify()
        self.out.close()
        log(f"done in {time.time() - t0:,.0f}s -> {self.args.out}")
        for name, count in self.out.counts().items():
            log(f"  {name:<16} {count:>12,}")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--transactions", type=int, default=10_000_000, help="target transaction rows")
    p.add_argument("--customers", type=int, default=200_000)
    p.add_argument("--start", default="2024-10-01", help="first simulated day (UTC)")
    p.add_argument("--days", type=int, default=730)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--chunk-rows", type=int, default=1_000_000,
                   help="rows per CSV file for transactions and ledger_entries")
    p.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data", "generated"),
                   help="output directory (existing .csv files in it are deleted first)")
    args = p.parse_args()
    args.out = os.path.abspath(args.out)
    Generator(args).run()


if __name__ == "__main__":
    main()
