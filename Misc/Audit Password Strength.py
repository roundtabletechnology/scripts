#!/usr/bin/env python3
"""
Audit Password Strength.py

SYNOPSIS
    Offline password strength and policy-compliance audit.

DESCRIPTION
    Audits a list of passwords entirely offline (no network calls, standard
    library only) and reports, for every password:

      * Estimated strength in bits, a rating, and an estimated offline crack time
        (pattern-aware, zxcvbn-style: dictionary words, leetspeak, keyboard walks,
        sequences, repeats, years and dates are scored as the cheap guesses they are)
      * Weakness findings (common/breached password, trivially mutated common word,
        context words such as the username or company name, reuse within the list)
      * PASS/FAIL against each standard below

    Standards evaluated (current as of October 2026):

      NIST      NIST SP 800-63B-4 (final, Aug 2025) section 3.1.1.2.
                Password-only: >= 15 characters.  Used with MFA: >= 8 characters.
                Whole password must not be on a blocklist of commonly used,
                expected or compromised values (breach corpuses, dictionary words,
                context-specific words such as the service name or username).
                Length is counted in Unicode code points after NFC normalization.
                Composition rules (forced upper/lower/digit/symbol mixes) and
                periodic rotation are explicitly prohibited.
      CIS       CIS Password Policy Guide / CIS Controls v8.1 Safeguard 5.2.
                Password-only: >= 14 characters.  With MFA: >= 8.  Deny-list check.
      PCI       PCI DSS v4.0.1 Requirement 8.3.6.
                >= 12 characters, containing both letters and digits.
      ASVS      OWASP ASVS 5.0 V6.2 (Level 2).
                >= 8 characters (15 strongly recommended), not in a common-password
                list of at least the top 3,000 (6.2.4), not a context-specific word
                (6.2.11), not a breached password (6.2.12).
      WinCx     Legacy Windows "Password must meet complexity requirements".
                >= 6 characters, 3 of 5 character categories, does not contain the
                account name.  Informational only - NIST and ASVS now prohibit
                composition rules like this.
      BEST      Recommended baseline: passes NIST password-only, has no weakness
                findings, and estimates at >= 65 bits.

    Blocklist sources: a small built-in list of common passwords and base words is
    always used.  For an authoritative audit, also supply:
      --wordlist FILE   any plaintext password list, one per line (e.g. SecLists
                        "10-million-password-list-top-1000000.txt", rockyou.txt).
                        Files are streamed, so multi-GB lists are fine.
      --hibp PATH       an offline copy of Have I Been Pwned "Pwned Passwords"
                        in SHA-1 format, downloaded once with the official
                        PwnedPasswordsDownloader: either the single sorted file
                        (HASH:COUNT lines) or the --split directory of prefix files.

INPUT
    No input file      Hidden interactive prompt (or lines piped on stdin).
    Plain list         One password per line.  Leading/trailing spaces are kept.
    CSV/TSV            Pick the password column with --column (header name or
                       1-based index).  Auto-detected if a header is named like
                       "password".  --user-column (auto-detected for "username",
                       "email", "upn" etc.) supplies context words per row.

OUTPUT
    Console table + summary.  Passwords and matched fragments are masked unless
    --show-passwords is given.  --output writes a .csv or .json report.

EXIT CODES
    0  every password passes the --standard (default: nist)
    1  error (bad input, unreadable file)
    2  one or more passwords fail the --standard

EXAMPLES
    python "Audit Password Strength.py"
    python "Audit Password Strength.py" passwords.txt
    python "Audit Password Strength.py" export.csv --column "Password" --user-column "Email" --context "Contoso"
    python "Audit Password Strength.py" export.csv -c 3 -w rockyou.txt --hibp D:\\pwnedpasswords.txt -o report.csv
    python "Audit Password Strength.py" passwords.txt --standard pci --summary-only

SOURCES
    https://pages.nist.gov/800-63-4/sp800-63b.html
    https://github.com/OWASP/ASVS (5.0, V6 Authentication)
    https://www.cisecurity.org/insights/white-papers/cis-password-policy-guide
    PCI DSS v4.0.1 (PCI Security Standards Council), Requirement 8.3.6
    https://github.com/HaveIBeenPwned/PwnedPasswordsDownloader
"""
from __future__ import annotations

import argparse
import csv
import getpass
import hashlib
import io
import itertools
import json
import math
import os
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

REFERENCE_YEAR = date.today().year
OFFLINE_GUESSES_PER_SEC = 1e11   # fast unsalted hash (NTLM/MD5) on one modern GPU
BEST_PRACTICE_MIN_BITS = 65
MAX_ANALYZE_LEN = 128            # pattern analysis is capped; length checks use the full value
MIN_WORD_LEN = 4                 # shortest dictionary word matched inside a password
MAX_WORD_LEN = 20

RATINGS = [(30, "Very Weak"), (50, "Weak"), (65, "Fair"), (80, "Strong"), (math.inf, "Very Strong")]

STANDARDS = {
    "nist":     ("NIST",     "NIST SP 800-63B-4, password-only (>=15, blocklist)"),
    "nist-mfa": ("NIST-MFA", "NIST SP 800-63B-4, used with MFA (>=8, blocklist)"),
    "cis":      ("CIS",      "CIS Password Policy Guide, password-only (>=14, deny list)"),
    "cis-mfa":  ("CIS-MFA",  "CIS Password Policy Guide, with MFA (>=8, deny list)"),
    "pci":      ("PCI",      "PCI DSS v4.0.1 Req 8.3.6 (>=12, letters + digits)"),
    "asvs":     ("ASVS",     "OWASP ASVS 5.0 V6.2 L2 (>=8, common/context/breached)"),
    "windows":  ("WinCx",    "Legacy Windows complexity (informational, not best practice)"),
    "best":     ("BEST",     f"Best practice (NIST password-only, no findings, >={BEST_PRACTICE_MIN_BITS} bits)"),
}

PASSWORD_HEADERS = ["password", "passwd", "pass", "pwd", "secret", "credential"]
USER_HEADERS = ["username", "user", "userprincipalname", "upn", "email", "mail",
                "samaccountname", "login", "account", "name"]
STOP_TOKENS = {"com", "net", "org", "edu", "gov", "www", "mail", "the", "and",
               "inc", "llc", "ltd", "corp", "local", "onmicrosoft"}

# Built-in blocklist: most common passwords (ranked) and common base words.
# Deliberately small - supply --wordlist / --hibp for real coverage.
COMMON_PASSWORDS = """
123456 password 123456789 12345678 12345 qwerty 1234567 111111 1234567890 123123
abc123 1234 password1 iloveyou 1q2w3e4r 000000 qwerty123 zaq12wsx dragon sunshine
princess letmein 654321 monkey 1qaz2wsx 123321 qwertyuiop superman asdfghjkl 666666
football baseball welcome admin admin123 administrator master shadow 121212 7777777
888888 555555 123qwe 112233 1q2w3e 1q2w3e4r5t 987654321 michael trustno1 batman
hello charlie access freedom whatever ninja mustang starwars passw0rd p@ssw0rd
p@ssword pa55word pa$$word password12 password123 password1234 password! password1!
welcome1 welcome123 welcome1! changeme changeme123 letmein1 letmein123 default guest
root toor test test123 testing temp temp123 secret secret123 login hunter2 hunter
killer pokemon lovely loveme iloveyou1 flower hottie qazwsx zxcvbnm asdf1234 asdfgh
asdf 1234qwer q1w2e3r4 qwe123 abcd1234 a123456 aa123456 abc12345 123abc 11111111
00000000 12341234 123123123 696969 159753 147258369 11111 computer internet
jennifer jessica ashley daniel thomas soccer hockey basketball cookie chocolate
football1 monkey1 dragon1 baseball1 sunshine1 princess1 qwerty1 abc123456 999999
1111 0000 matrix mercedes ferrari corvette harley yankees cowboys eagles steelers
lakers liverpool arsenal chelsea barcelona blink182 samsung google apple microsoft
iphone android facebook pass1234 pass123 pass mypassword passpass security secure
summer2024 summer2025 summer2026 winter2024 winter2025 winter2026 spring2025
spring2026 fall2025 fall2026 autumn2025 autumn2026 welcome2024 welcome2025
welcome2026 password2024 password2025 password2026 company123 superman1 batman1
q1w2e3r4t5 1qazxsw2 zaq1zaq1 qwerty12 qwerty1234 qwertyui 123654 7654321 147258
password01 passwort motdepasse contraseña senha azerty 1q2w3e4r5t6y iloveu
trustme sexy angel angel1 jordan jordan23 andrew joshua buster tigger soccer1
ginger pepper summer winter spring autumn love123 abc 123 12 1 a
""".split()

COMMON_WORDS = """
password passwort passwd admin administrator welcome letmein login logon master hello
love lover iloveyou monkey dragon shadow sunshine princess football baseball soccer
hockey basketball golf tennis summer winter spring autumn season january february
march april june july august september october november december monday tuesday
wednesday thursday friday saturday sunday secret qwerty company office business
manager user guest test changeme default computer internet security secure access
freedom chocolate cookie coffee family friend friends money happy lucky angel baby
jesus christ mother father mommy daddy sister brother daughter husband heaven
forever flower purple orange yellow silver golden black white green pink diamond
crystal tiger lion eagle falcon wolf bear puppy kitty horse dolphin butterfly
monster killer hunter ninja pirate wizard magic matrix stars starwars superman
batman spiderman pokemon mickey snoopy michael jennifer jessica ashley daniel david
james john robert william thomas matthew joshua andrew christopher joseph charlie
jordan taylor amanda sarah nicole michelle elizabeth maria mary linda patricia
barbara susan karen nancy lisa betty sandra richard charles mark steven paul kevin
brian george edward ronald anthony jason jeffrey ryan eric jacob tyler justin
brandon austin kyle nathan zachary samuel benjamin alexander emily emma olivia
sophia isabella abigail madison hannah samantha rachel lauren megan kayla rebecca
heather amber melissa stephanie christina america texas california florida chicago
boston dallas london paris canada mexico england germany thunder lightning rainbow
sunset ocean beach island mountain river forest garden winner victory champion
legend hero king queen prince knight warrior soldier rocket racing ranger cowboy
cowboys yankees steelers eagles patriots lakers chelsea arsenal liverpool united
madrid barcelona music guitar piano rock metal jazz dance party school college
student teacher doctor nurse church bible faith hope peace grace spirit soul dream
dreams please thanks sorry whatever nothing something anything everything trustno
mustang ferrari porsche mercedes corvette harley honda toyota chevy jeep google
apple microsoft windows samsung iphone android facebook twitter linkedin network
server system backup service support helpdesk temp temporary spring fall
""".split()

LEET = {"4": "a", "@": "a", "8": "b", "(": "c", "{": "c", "3": "e", "6": "g", "9": "g",
        "#": "h", "1": "il", "!": "i", "|": "il", "0": "o", "5": "s", "$": "s",
        "7": "t", "+": "t", "2": "z", "%": "x"}

KEYBOARD_PATHS = [
    "`1234567890-=", "~!@#$%^&*()_+", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./",
    "1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik,9ol.0p;/", "zaq1xsw2cde3vfr4bgt5nhy6mju7,ki8.lo9/;p0",
    "qazwsxedcrfvtgbyhnujmikolp", "7894561230", "1472583690", "741852963", "159357",
]
KEYBOARD_PATHS += [p[::-1] for p in KEYBOARD_PATHS]


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

@dataclass
class Entry:
    ident: str
    password: str
    user: str = ""


@dataclass
class Match:
    kind: str          # dictionary | context | sequence | keyboard | repeat | year | date
    i: int
    j: int
    bits: float
    token: str
    note: str = ""


@dataclass
class Span:
    """A candidate string carved from a password, looked up in the blocklists."""
    i: int
    j: int
    text: str
    role: str          # whole | core | sub
    leet: int


@dataclass
class Result:
    entry: Entry
    length: int
    classes: list
    bits: float
    rating: str
    crack_time: str
    hibp_count: int | None
    reuse_count: int
    findings: list = field(default_factory=list)   # (category, text) - weaknesses
    patterns: list = field(default_factory=list)   # text - guessable structure
    verdicts: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

def read_text(path):
    for encoding in ("utf-8-sig", "cp1252"):
        try:
            with open(path, encoding=encoding, newline="") as fh:
                return fh.read()
        except UnicodeDecodeError:
            continue
    raise ValueError(f"Could not decode {path} as UTF-8 or Windows-1252")


def find_column(header, spec, candidates, label, required):
    lowered = [h.strip().lower() for h in header]
    if spec:
        if spec.isdigit():
            idx = int(spec) - 1
            if idx < 0 or (header and idx >= len(header)):
                raise ValueError(f"{label} column index {spec} is out of range (1-{len(header)})")
            return idx
        if spec.strip().lower() in lowered:
            return lowered.index(spec.strip().lower())
        raise ValueError(f"{label} column '{spec}' not found. Columns: {', '.join(header)}")
    for cand in candidates:
        if cand in lowered:
            return lowered.index(cand)
    if required:
        raise ValueError(f"Could not detect the {label} column; pass --column. "
                         f"Columns: {', '.join(header) or '(no header)'}")
    return None


def read_csv_entries(path, column, user_column, delimiter, has_header):
    rows = list(csv.reader(io.StringIO(read_text(path), newline=""), delimiter=delimiter))
    if not rows:
        return []
    if has_header:
        header, data, first = [h.strip() for h in rows[0]], rows[1:], 2
    else:
        if not column or not column.isdigit():
            raise ValueError("--no-header requires --column as a 1-based index")
        header, data, first = [], rows, 1
    pw_idx = find_column(header, column, PASSWORD_HEADERS, "password", required=True)
    user_idx = find_column(header, user_column, USER_HEADERS, "user", required=False) if has_header or user_column else None
    if header:
        used = f"password column '{header[pw_idx]}'"
        if user_idx is not None:
            used += f", user column '{header[user_idx]}'"
        print(f"Using {used}", file=sys.stderr)

    entries, skipped = [], 0
    for n, row in enumerate(data, first):
        if pw_idx >= len(row) or row[pw_idx] == "":
            skipped += 1
            continue
        user = row[user_idx].strip() if user_idx is not None and user_idx < len(row) else ""
        entries.append(Entry(ident=user or f"row {n}", password=row[pw_idx], user=user))
    if skipped:
        print(f"Skipped {skipped} row(s) with a blank password", file=sys.stderr)
    return entries


def read_list_entries(lines, label):
    entries = []
    for n, line in enumerate(lines, 1):
        line = line.rstrip("\r\n")
        if line:
            entries.append(Entry(ident=f"{label} {n}", password=line))
    return entries


def prompt_entries():
    print("Enter passwords to audit (input is hidden). Press Enter on a blank prompt to finish.",
          file=sys.stderr)
    entries = []
    while True:
        try:
            pw = getpass.getpass(f"Password {len(entries) + 1}: ")
        except (EOFError, KeyboardInterrupt):
            print(file=sys.stderr)
            break
        if pw == "":
            break
        entries.append(Entry(ident=f"entry {len(entries) + 1}", password=pw))
    return entries


def read_entries(args):
    if args.input is None:
        if sys.stdin.isatty():
            return prompt_entries()
        return read_list_entries(sys.stdin.read().split("\n"), "line")
    if not os.path.isfile(args.input):
        raise ValueError(f"Input file not found: {args.input}")
    ext = os.path.splitext(args.input)[1].lower()
    if args.column or args.user_column or ext in (".csv", ".tsv"):
        delimiter = args.delimiter or ("\t" if ext == ".tsv" else ",")
        return read_csv_entries(args.input, args.column, args.user_column, delimiter, not args.no_header)
    return read_list_entries(read_text(args.input).split("\n"), "line")


# ---------------------------------------------------------------------------
# Candidate generation and blocklist scanning
# ---------------------------------------------------------------------------

def leet_variants(lower):
    """De-leeted versions of a lowercase string: substitute all, symbols only, digits only."""
    out = set()
    for mode in ("all", "symbols", "digits"):
        idx = [k for k, c in enumerate(lower) if c in LEET and
               (mode == "all" or (mode == "digits") == c.isdigit())]
        if not idx:
            continue
        for combo in itertools.islice(itertools.product(*(LEET[lower[k]] for k in idx)), 8):
            chars = list(lower)
            for k, ch in zip(idx, combo):
                chars[k] = ch
            out.add("".join(chars))
    out.discard(lower)
    return sorted(out)


def core_bounds(lower):
    """(i, j) slices with leading and/or trailing non-letters stripped ('!Summer2026!' -> 'summer')."""
    n = len(lower)
    i = 0
    while i < n and not lower[i].isalpha():
        i += 1
    j = n
    while j > i and not lower[j - 1].isalpha():
        j -= 1
    return {(i, j), (0, j), (i, n)} - {(0, n)}


def build_spans(lower):
    spans = {}

    def add(i, j, text, role):
        key = (i, j, text)
        if key not in spans or role == "whole":
            leet = sum(1 for a, b in zip(text, lower[i:j]) if a != b)
            spans[key] = Span(i, j, text, role, leet)

    n = len(lower)
    variants = [lower] + leet_variants(lower)
    for v in variants:
        add(0, n, v, "whole")
    for i, j in core_bounds(lower):
        if j - i >= 3:
            for v in [lower[i:j]] + leet_variants(lower[i:j]):
                add(i, j, v, "core")
    for v in variants:
        for i in range(n):
            for j in range(i + MIN_WORD_LEN, min(n, i + MAX_WORD_LEN) + 1):
                sub = v[i:j]
                if sub.isalpha():
                    add(i, j, sub, "sub")
    return list(spans.values()), variants


def iter_wordlist(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            yield line.rstrip("\r\n")


def scan_blocklists(needles, sources):
    """Stream every source once; return {needle: (rank, source)} using the best rank seen."""
    hits = {}
    sizes = {}
    for name, words in sources:
        count = 0
        for rank, word in enumerate(words, 1):
            count = rank
            w = unicodedata.normalize("NFC", word).lower()
            if w in needles and (w not in hits or rank < hits[w][0]):
                hits[w] = (rank, name)
        sizes[name] = count
    return hits, sizes


class HibpStore:
    """Offline Have I Been Pwned SHA-1 lookup: sorted single file or --split prefix directory."""

    def __init__(self, path):
        self.path = path
        self.is_dir = os.path.isdir(path)
        if self.is_dir:
            if not any(name.lower().endswith(".txt") for name in os.listdir(path)):
                raise ValueError(f"No HIBP prefix files (*.txt) found in {path}")
            return
        if not os.path.isfile(path):
            raise ValueError(f"HIBP path not found: {path}")
        self.fh = open(path, "rb")
        self.size = os.path.getsize(path)
        key = self.fh.readline().split(b":")[0].strip()
        if len(key) == 32:
            raise ValueError("HIBP file is NTLM format; download the SHA-1 version instead")
        if len(key) != 40:
            raise ValueError(f"{path} does not look like an HIBP SHA-1 file (HASH:COUNT lines)")

    def count(self, password):
        digest = hashlib.sha1(password.encode("utf-8")).hexdigest().upper().encode()
        if self.is_dir:
            prefix_file = os.path.join(self.path, digest[:5].decode() + ".txt")
            if not os.path.isfile(prefix_file):
                return 0
            with open(prefix_file, "rb") as fh:
                for line in fh:
                    if line[:35].upper() == digest[5:]:
                        return int(line.split(b":")[1])
            return 0
        return self._search(digest)

    def _line_after(self, pos):
        # First full line starting after byte pos (or the first line when pos is 0)
        self.fh.seek(pos)
        if pos:
            self.fh.readline()
        return self.fh.readline()

    def _search(self, digest):
        lo, hi = 0, self.size
        while lo < hi:
            mid = (lo + hi) // 2
            line = self._line_after(mid)
            if not line or line[:40].upper() >= digest:
                hi = mid
            else:
                lo = mid + 1
        line = self._line_after(lo)
        if line[:40].upper() == digest:
            return int(line.split(b":")[1])
        return 0


# ---------------------------------------------------------------------------
# Pattern detection and strength estimate
# ---------------------------------------------------------------------------

def char_pool(s):
    pool = 0
    if any("a" <= c <= "z" for c in s):
        pool += 26
    if any("A" <= c <= "Z" for c in s):
        pool += 26
    if any("0" <= c <= "9" for c in s):
        pool += 10
    if any(c.isascii() and not c.isalnum() for c in s):
        pool += 33
    if any(not c.isascii() for c in s):
        pool += 100
    return max(pool, 10)


def case_bits(s):
    upper = sum(c.isupper() for c in s)
    lower = sum(c.islower() for c in s)
    if upper == 0:
        return 0.0
    if lower == 0 or (upper == 1 and s[0].isupper()):
        return 1.0
    return math.log2(sum(math.comb(upper + lower, k) for k in range(1, min(upper, lower) + 1)))


def char_class(c):
    if "a" <= c <= "z":
        return "lower"
    if "A" <= c <= "Z":
        return "upper"
    if "0" <= c <= "9":
        return "digit"
    return None


def find_sequences(pw):
    out, n, i = [], len(pw), 0
    while i < n - 2:
        delta = ord(pw[i + 1]) - ord(pw[i])
        cls = char_class(pw[i])
        if delta in (1, -1) and cls and char_class(pw[i + 1]) == cls:
            j = i + 1
            while j + 1 < n and ord(pw[j + 1]) - ord(pw[j]) == delta and char_class(pw[j + 1]) == cls:
                j += 1
            if j - i + 1 >= 3:
                first = pw[i]
                base = 1.0 if first in "aAzZ019" else math.log2(10 if cls == "digit" else 26)
                bits = base + (1 if cls == "upper" else 0) + (1 if delta < 0 else 0) + math.log2(j - i + 1)
                out.append(Match("sequence", i, j + 1, bits, pw[i:j + 1]))
            i = j
        else:
            i += 1
    return out


def find_keyboard(pw):
    out, lower, n = [], pw.lower(), len(pw)
    for path in KEYBOARD_PATHS:
        i = 0
        while i < n:
            j = i + 1
            while j <= n and lower[i:j] in path:
                j += 1
            length = j - 1 - i
            if length >= 4:
                out.append(Match("keyboard", i, i + length, math.log2(47 * length) + case_bits(pw[i:i + length]),
                                 pw[i:i + length]))
                i += length
            else:
                i += 1
    return out


def find_repeats(pw):
    out, n = [], len(pw)
    for i in range(n):
        for unit_len in range(1, (n - i) // 2 + 1):
            unit = pw[i:i + unit_len]
            k = 1
            while pw[i + k * unit_len:i + (k + 1) * unit_len] == unit:
                k += 1
            if k >= 2 and unit_len * k >= 3 and (unit_len > 1 or k >= 3):
                bits = unit_len * math.log2(char_pool(unit)) + math.log2(k)
                out.append(Match("repeat", i, i + unit_len * k, bits, pw[i:i + unit_len * k]))
    return out


def year_bits(year):
    return math.log2(max(abs(year - REFERENCE_YEAR), 20))


def parse_date(digits):
    """Return a plausible 4-digit year if the digit string reads as a date, else None."""
    layouts = {8: [(0, 2, 2, 4, 4, 8), (2, 4, 0, 2, 4, 8), (4, 6, 6, 8, 0, 4)],
               6: [(0, 2, 2, 4, 4, 6), (2, 4, 0, 2, 4, 6), (2, 4, 4, 6, 0, 2)]}
    for mi, mj, di, dj, yi, yj in layouts.get(len(digits), []):
        month, day, year = int(digits[mi:mj]), int(digits[di:dj]), int(digits[yi:yj])
        if yj - yi == 2:
            year += 2000 if year <= REFERENCE_YEAR % 100 else 1900
        if 1 <= month <= 12 and 1 <= day <= 31 and 1900 <= year <= 2099:
            return year
    return None


def find_dates(pw):
    out, n = [], len(pw)
    for i in range(n - 3):
        s = pw[i:i + 4]
        if s.isdigit() and s.isascii() and 1900 <= int(s) <= 2099:
            out.append(Match("year", i, i + 4, year_bits(int(s)), s))
    for length in (6, 8):
        for i in range(n - length + 1):
            s = pw[i:i + length]
            if s.isdigit() and s.isascii():
                year = parse_date(s)
                if year:
                    out.append(Match("date", i, i + length, math.log2(365) + year_bits(year), s))
    # Dates with separators: 1/2/1990, 01-02-90, 1990.01.02
    for i in range(n):
        for length in range(6, 11):
            s = pw[i:i + length]
            if len(s) < length or s[0] in "-/._" or s[-1] in "-/._":
                continue
            seps = [c for c in s if c in "-/._"]
            if len(seps) == 2 and seps[0] == seps[1]:
                parts = s.split(seps[0])
                if len(parts) == 3 and all(p.isdigit() and p.isascii() for p in parts):
                    padded = "".join(p.zfill(4 if len(p) > 2 else 2) for p in parts)
                    year = parse_date(padded)
                    if year:
                        out.append(Match("date", i, i + length, math.log2(365) + year_bits(year) + 2, s))
    return out


def estimate_bits(pw, matches):
    """Cheapest decomposition of pw into brute-force characters and pattern matches."""
    n = len(pw)
    bf = math.log2(char_pool(pw))
    by_end = defaultdict(list)
    for m in matches:
        by_end[m.j].append(m)
    best = [0.0] + [math.inf] * n
    back = [None] * (n + 1)
    for j in range(1, n + 1):
        best[j] = best[j - 1] + bf
        back[j] = None
        for m in by_end[j]:
            cost = best[m.i] + max(m.bits, 1.0)
            if cost < best[j]:
                best[j] = cost
                back[j] = m
    used, brute, j = [], 0, n
    while j > 0:
        m = back[j]
        if m is None:
            brute += 1
            j -= 1
        else:
            used.append(m)
            j = m.i
    return best[n], list(reversed(used)), brute


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def context_tokens(*values):
    tokens = set()
    for value in values:
        if not value:
            continue
        low = unicodedata.normalize("NFC", value).lower()
        word = []
        for c in low + " ":
            if c.isalnum():
                word.append(c)
            else:
                t = "".join(word)
                if len(t) >= 3 and t not in STOP_TOKENS and not t.isdigit():
                    tokens.add(t)
                word = []
        account = "".join(c for c in low.split("\\")[-1].split("@")[0] if c.isalnum())
        if len(account) >= 3:
            tokens.add(account)
    return tokens


def account_name(user):
    return user.split("\\")[-1].split("@")[0].lower()


def fmt_duration(seconds):
    if seconds < 1:
        return "instant"
    for unit, size in (("second", 60), ("minute", 60), ("hour", 24), ("day", 365.25)):
        if seconds < size:
            return f"{seconds:.0f} {unit}{'' if round(seconds) == 1 else 's'}"
        seconds /= size
    if seconds < 1e3:
        return f"{seconds:.0f} year{'' if round(seconds) == 1 else 's'}"
    if seconds < 1e6:
        return f"{seconds / 1e3:.0f} thousand years"
    if seconds < 1e9:
        return f"{seconds / 1e6:.0f} million years"
    return "> 1 billion years"


def describe(m, reveal):
    label = {"dictionary": "common word", "context": "context word", "sequence": "sequence",
             "keyboard": "keyboard pattern", "repeat": "repetition", "year": "year", "date": "date"}[m.kind]
    shown = m.kind == "context" or reveal
    text = f"{label} '{m.token}'" if shown else f"{label} ({len(m.token)} chars)"
    return text + (f" {m.note}" if m.note else "")


def analyze(entry, norm, spans, variants, hits, global_tokens, hibp_count, reuse_count, reveal):
    length = len(norm)
    pw = norm[:MAX_ANALYZE_LEN]
    lower = pw.lower()
    tokens = global_tokens | context_tokens(entry.user)

    classes = [name for name, test in (
        ("lower", lambda c: c.islower()), ("upper", lambda c: c.isupper()),
        ("digit", lambda c: c.isdigit()), ("symbol", lambda c: not c.isalnum()),
        ("other-letter", lambda c: c.isalpha() and not c.islower() and not c.isupper()),
    ) if any(test(c) for c in norm)]

    findings = []
    matches = find_sequences(pw) + find_keyboard(pw) + find_repeats(pw) + find_dates(pw)

    # Blocklist matches (whole password, trivially-mutated core, embedded words)
    exact_hit, core_hit = None, None
    for span in spans:
        hit = hits.get(span.text)
        if not hit:
            continue
        rank, source = hit
        segment = pw[span.i:span.j]
        note = " ".join(x for x in ("(leet)" if span.leet else "",
                                    "(capitalized)" if case_bits(segment) else "") if x)
        matches.append(Match("dictionary", span.i, span.j,
                             math.log2(rank) + case_bits(segment) + span.leet, segment, note))
        if span.role == "whole" and span.text == lower and exact_hit is None:
            exact_hit = hit
        elif span.role in ("whole", "core") and core_hit is None:
            core_hit = (span, hit)

    # Context words (username, company, service name)
    context_whole = None
    for token in sorted(tokens):
        for v in variants:
            start = v.find(token)
            while start != -1:
                segment = pw[start:start + len(token)]
                matches.append(Match("context", start, start + len(token),
                                     math.log2(len(tokens) + 1) + case_bits(segment), segment))
                start = v.find(token, start + 1)
        for span in spans:
            if span.role in ("whole", "core") and span.text == token:
                context_whole = token

    bits, used, brute = estimate_bits(pw, matches)
    if length > MAX_ANALYZE_LEN:
        bits += (length - MAX_ANALYZE_LEN) * math.log2(char_pool(norm))

    blocklisted = False
    if exact_hit:
        blocklisted = True
        findings.append(("blocklist", f"exact match on blocklist ({exact_hit[1]}, rank {exact_hit[0]:,})"))
    if hibp_count:
        blocklisted = True
        bits = min(bits, 20.0)
        findings.append(("hibp", f"found in Have I Been Pwned breach corpus ({hibp_count:,} times)"))
    if context_whole:
        blocklisted = True
        findings.append(("context", f"password is a context word or derivative ('{context_whole}')"))
    elif any(m.kind == "context" for m in matches):
        found = sorted({m.token.lower() for m in matches if m.kind == "context"})
        findings.append(("context", f"contains context word(s): {', '.join(found)}"))
    if core_hit and not exact_hit:
        span, (rank, source) = core_hit
        what = f" ('{span.text}')" if reveal else ""
        findings.append(("mutated", f"common password/word with trivial changes{what} ({source})"))
    if used and brute == 0 and all(m.kind in ("sequence", "keyboard", "repeat", "year", "date") for m in used):
        findings.append(("pattern", "entirely sequential, repetitive or keyboard pattern"))
    if reuse_count > 1:
        findings.append(("reused", f"same password used by {reuse_count} entries in this list"))
    if norm != norm.strip():
        findings.append(("whitespace", "leading/trailing whitespace (check the source data)"))

    rating = next(label for limit, label in RATINGS if bits < limit)
    crack = "instant (on wordlists)" if blocklisted else fmt_duration(2 ** (bits - 1) / OFFLINE_GUESSES_PER_SEC)

    # Standards
    has_alpha = any(c.isalpha() for c in norm)
    has_digit = any(c.isdigit() for c in norm)
    categories = sum([any(c.isupper() for c in norm), any(c.islower() for c in norm),
                      any("0" <= c <= "9" for c in norm), any(not c.isalnum() for c in norm),
                      any(c.isalpha() and not c.isupper() and not c.islower() for c in norm)])
    account = account_name(entry.user)
    win_name_ok = not (len(account) >= 3 and account in norm.lower()) and \
        not any(t in norm.lower() for t in context_tokens(entry.user))
    weak = any(cat in ("blocklist", "hibp", "context", "mutated", "pattern", "reused") for cat, _ in findings)

    verdicts = {
        "nist": length >= 15 and not blocklisted,
        "nist-mfa": length >= 8 and not blocklisted,
        "cis": length >= 14 and not blocklisted,
        "cis-mfa": length >= 8 and not blocklisted,
        "pci": length >= 12 and has_alpha and has_digit,
        "asvs": length >= 8 and not blocklisted,
        "windows": length >= 6 and categories >= 3 and win_name_ok,
    }
    verdicts["best"] = verdicts["nist"] and not weak and bits >= BEST_PRACTICE_MIN_BITS

    if length < 8:
        findings.insert(0, ("short8", "shorter than 8 characters (fails every standard)"))
    elif length < 15:
        findings.insert(0, ("short15", "shorter than 15 characters (NIST password-only minimum)"))

    return Result(entry=entry, length=length, classes=classes, bits=round(bits, 1), rating=rating,
                  crack_time=crack, hibp_count=hibp_count, reuse_count=reuse_count,
                  findings=findings, patterns=[describe(m, reveal) for m in used], verdicts=verdicts)


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

class Style:
    def __init__(self, enabled):
        self.enabled = enabled

    def __call__(self, text, code):
        return f"\033[{code}m{text}\033[0m" if self.enabled else text


def enable_ansi():
    if os.name != "nt":
        return True
    try:
        import ctypes
        kernel = ctypes.windll.kernel32
        handle = kernel.GetStdHandle(-11)
        mode = ctypes.c_uint32()
        if kernel.GetConsoleMode(handle, ctypes.byref(mode)):
            kernel.SetConsoleMode(handle, mode.value | 0x0004)
            return True
    except Exception:
        pass
    return False


FINDING_LABELS = {
    "short8": "Shorter than 8 characters",
    "short15": "Shorter than 15 characters (NIST password-only minimum)",
    "blocklist": "Exact match on a common/breached password list",
    "hibp": "Found in Have I Been Pwned breach corpus",
    "mutated": "Common password/word with trivial changes",
    "context": "Contains a context word (username, company, service)",
    "pattern": "Entirely sequential/repetitive/keyboard pattern",
    "reused": "Reused by more than one entry in this list",
    "whitespace": "Leading/trailing whitespace",
}


def print_report(results, args, source_sizes, hibp_used, style):
    keys = list(STANDARDS)
    if not args.summary_only:
        id_width = min(max([len(r.entry.ident) for r in results] + [2]), 28)
        pw_width = min(max([len(r.entry.password) for r in results] + [8]), 28) if args.show_passwords else 0
        head = f"{'#':>4}  {'ID':<{id_width}}  "
        if pw_width:
            head += f"{'Password':<{pw_width}}  "
        head += f"{'Len':>4} {'Bits':>6}  {'Rating':<11}  " + " ".join(STANDARDS[k][0] for k in keys)
        print(style(head, "1"))
        print("-" * len(head))
        for n, r in enumerate(results, 1):
            line = f"{n:>4}  {r.entry.ident[:id_width]:<{id_width}}  "
            if pw_width:
                line += f"{r.entry.password[:pw_width]:<{pw_width}}  "
            rating_color = {"Very Weak": "31", "Weak": "31", "Fair": "33", "Strong": "32", "Very Strong": "32"}[r.rating]
            line += f"{r.length:>4} {r.bits:>6.1f}  {style(f'{r.rating:<11}', rating_color)}  "
            cells = []
            for k in keys:
                width = len(STANDARDS[k][0])
                text = ("pass" if r.verdicts[k] else "FAIL").ljust(width)
                color = "90" if k == "windows" else ("32" if r.verdicts[k] else "31")
                cells.append(style(text, color))
            print(line + " ".join(cells))
            for _, text in r.findings:
                print(f"{'':6}{style('!', '31')} {text}")
            if r.patterns:
                print(f"{'':6}- structure: {', '.join(r.patterns)}; offline crack ~{r.crack_time}")
        print()

    total = len(results)
    print(style(f"SUMMARY - {total} password(s) audited {date.today().isoformat()}", "1"))
    sources = ", ".join(f"{name} ({size:,})" for name, size in source_sizes.items())
    print(f"Blocklists: {sources}; HIBP: {'yes' if hibp_used else 'not used'}")
    print()
    name_width = max(len(desc) for _, desc in STANDARDS.values())
    print(f"  {'Standard':<{name_width}}  {'Pass':>5}  {'Fail':>5}  {'Pass %':>6}")
    for k in keys:
        passed = sum(r.verdicts[k] for r in results)
        marker = "*" if k == args.standard else " "
        print(f"{marker} {STANDARDS[k][1]:<{name_width}}  {passed:>5}  {total - passed:>5}  {100 * passed / total:>5.0f}%")
    print(f"  (* = --standard used for the exit code)")
    print()
    dist = Counter(r.rating for r in results)
    print("Strength:  " + " | ".join(f"{label} {dist.get(label, 0)}" for _, label in RATINGS))
    issues = Counter(cat for r in results for cat in {c for c, _ in r.findings})
    if issues:
        print("Findings:")
        for cat, count in issues.most_common():
            print(f"  {count:>5}  {FINDING_LABELS[cat]}")
    builtin_only = all(name.startswith("built-in") for name in source_sizes)
    if builtin_only and not hibp_used:
        print()
        print(style("NOTE: only the small built-in blocklist was used. NIST requires checking breached/common "
                    "passwords and ASVS 6.2.4 expects at least the top 3,000; add --wordlist and/or --hibp "
                    "for an authoritative audit.", "33"))


def write_output(path, results, show_passwords):
    rows = []
    for n, r in enumerate(results, 1):
        row = {"index": n, "id": r.entry.ident, "user": r.entry.user}
        if show_passwords:
            row["password"] = r.entry.password
        row.update({"length": r.length, "character_classes": " ".join(r.classes), "entropy_bits": r.bits,
                    "rating": r.rating, "offline_crack_time": r.crack_time,
                    "hibp_count": "" if r.hibp_count is None else r.hibp_count, "reuse_count": r.reuse_count})
        for k in STANDARDS:
            row[k] = "PASS" if r.verdicts[k] else "FAIL"
        row["findings"] = "; ".join(text for _, text in r.findings)
        row["structure"] = "; ".join(r.patterns)
        rows.append(row)
    if path.lower().endswith(".json"):
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"generated": date.today().isoformat(),
                       "standards": {k: v[1] for k, v in STANDARDS.items()},
                       "results": rows}, fh, indent=2, ensure_ascii=False)
    else:
        with open(path, "w", encoding="utf-8-sig", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    print(f"Report written to {path}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Offline password strength and compliance audit (NIST SP 800-63B-4, CIS, PCI DSS 4.0.1, OWASP ASVS 5.0).",
        epilog="With no input file, prompts for passwords (hidden) or reads lines piped on stdin. "
               "See the script header for standards, blocklist sources and examples.")
    parser.add_argument("input", nargs="?", help="Plain list (one password per line) or CSV/TSV file")
    parser.add_argument("-c", "--column", help="CSV password column: header name or 1-based index")
    parser.add_argument("-u", "--user-column", help="CSV username/email column used for context-word checks")
    parser.add_argument("--delimiter", help="CSV delimiter (default ',' or tab for .tsv)")
    parser.add_argument("--no-header", action="store_true", help="CSV has no header row (--column must be an index)")
    parser.add_argument("-w", "--wordlist", action="append", default=[],
                        help="Extra blocklist file, one password per line (repeatable)")
    parser.add_argument("--hibp", help="Offline HIBP Pwned Passwords SHA-1 file or --split directory")
    parser.add_argument("--context", action="append", default=[],
                        help="Context words to block, comma-separated (company, service, domain); repeatable")
    parser.add_argument("-s", "--standard", choices=list(STANDARDS), default="nist",
                        help="Standard that decides the exit code (default: nist)")
    parser.add_argument("-o", "--output", help="Write a .csv or .json report")
    parser.add_argument("--show-passwords", action="store_true",
                        help="Show plaintext passwords and matched fragments (masked by default)")
    parser.add_argument("--summary-only", action="store_true", help="Print only the summary")
    parser.add_argument("--no-color", action="store_true", help="Disable colored output")
    return parser.parse_args()


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    args = parse_args()

    try:
        entries = read_entries(args)
        if not entries:
            print("No passwords to audit.", file=sys.stderr)
            return 1

        global_tokens = context_tokens(*[w for value in args.context for w in value.split(",")])

        prepared, needles = [], set()
        for entry in entries:
            norm = unicodedata.normalize("NFC", entry.password)
            spans, variants = build_spans(norm[:MAX_ANALYZE_LEN].lower())
            prepared.append((entry, norm, spans, variants))
            needles.update(span.text for span in spans)

        sources = [("built-in common", COMMON_PASSWORDS), ("built-in words", COMMON_WORDS)]
        for path in args.wordlist:
            if not os.path.isfile(path):
                raise ValueError(f"Wordlist not found: {path}")
            print(f"Scanning {path} ...", file=sys.stderr)
            sources.append((os.path.basename(path), iter_wordlist(path)))
        hits, source_sizes = scan_blocklists(needles, sources)

        hibp = HibpStore(args.hibp) if args.hibp else None
        reuse = Counter(norm for _, norm, _, _ in prepared)

        results = []
        for entry, norm, spans, variants in prepared:
            hibp_count = hibp.count(entry.password) if hibp else None
            results.append(analyze(entry, norm, spans, variants, hits, global_tokens,
                                   hibp_count, reuse[norm], args.show_passwords))

        style = Style(not args.no_color and sys.stdout.isatty() and enable_ansi())
        print_report(results, args, source_sizes, hibp is not None, style)
        if args.output:
            write_output(args.output, results, args.show_passwords)
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    return 0 if all(r.verdicts[args.standard] for r in results) else 2


if __name__ == "__main__":
    sys.exit(main())
