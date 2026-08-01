#!/usr/bin/env python3
"""compass-verify — check a Compass export bundle without trusting Compass.

    python3 verifier/compass-verify.py <bundle-directory>

`docs/product.md`'s mission sentence promises "a record of what you actually
did, which you can hand to a stranger and they can check without trusting you
or the app". That is only true if there is something to run, and it is not
achievable if the stranger has to reimplement a hand-written encoder from a
document first. This is that something. `docs/technical.md` §10a,
`docs/adr/0004`, `docs/achievement-protocol.md` §6 and §9.

It shares **no code** with the application. Every byte string it builds is
written from the documents — `docs/technical.md` §3 for the event form and
`docs/achievement-protocol.md` §6 for the achievement form — so agreement
between this file and the app is evidence rather than tautology. Python 3
standard library only: no pip install, no Xcode, no Swift.

What it checks, and it prints every one of these as a line you can read:

  1.  manifest.json — every file's SHA-256.
  2.  events.jsonl  — canonical bytes, content_hash, and each writer's `prev`
                      chain from genesis to its head.
  3.  awards.jsonl  — the achievement canonical form, its SHA-256 digest, and
                      whether the log still supports the claim: the qualifying
                      days are re-derived and the Merkle evidence root is
                      recomputed from the events that were counted.
  4.  attestations  — the P-256 signature over the canonical bytes, verified
                      here in pure Python against the public key in the bundle,
                      and **what the record says backed the key that made it**:
                      Secure Enclave or software. Reported per record and again
                      for the bundle as a whole, because a reader who reads only
                      the summary is still a reader — and reported as the
                      issuer's unverified claim, never as a check that passed,
                      because `backing` sits outside the digest.
  5.  anchors.jsonl — the OpenTimestamps proof: every operation is replayed
                      from the digest, and each attestation it reaches is
                      reported as a pending calendar promise or as a Bitcoin
                      block commitment.

What it deliberately does **not** do, and says so at the end of every run
rather than leaving it to be assumed:

  *   It does not fetch Bitcoin block headers. A Bitcoin attestation commits a
      merkle root at a stated height; confirming that root is that block's
      requires a Bitcoin node or a header chain, and shipping either inside a
      200-line script would be a bigger act of trust than the one it removes.
      The height and the root are printed so they can be checked by hand.
  *   It does not decide whether the person named in the record is who they say
      they are. Nothing in Compass ever claimed it could — the declared name is
      self-declared and unverified by construction.
  *   It does not establish what hardware held the signing key. `backing` is
      outside the digest, so on a bundle from anyone else it is unsigned text,
      and no signature can prove what made it in any case. Every reading of that
      field is printed as a claim, never as a passed check.
"""

import base64
import binascii
import datetime
import hashlib
import json
import os
import sys

# --------------------------------------------------------------------------
# Canonical bytes — `docs/technical.md` §3, `docs/achievement-protocol.md` §6
#
# Hand-written, never a JSON library. Key order is the whole point: a verifier
# recomputing this in three years must produce byte-identical output, and no
# JSON encoder promises an order across releases.
# --------------------------------------------------------------------------


def quoted(text, field):
    """A JSON string escaped per §6.3: backslash, quote, newline — nothing else.

    Any other control character is rejected rather than escaped, which is what
    keeps the rule finite. Two spellings of one character would be two digests
    for one record.
    """
    out = ['"']
    for character in text:
        code = ord(character)
        if character == "\\":
            out.append("\\\\")
        elif character == '"':
            out.append('\\"')
        elif character == "\n":
            out.append("\\n")
        elif code < 0x20 or code == 0x7F or 0x80 <= code <= 0x9F:
            raise ValueError("control character U+%04X in %s" % (code, field))
        else:
            out.append(character)
    out.append('"')
    return "".join(out)


def canonical_map(values, field):
    """§6.3: keys sorted by UTF-8 byte value, ascending. Not by Unicode collation,
    which depends on tables shipped with the operating system."""
    keys = sorted(values, key=lambda k: k.encode("utf-8"))
    return "{%s}" % ",".join(
        "%s:%s" % (quoted(k, field), canonical_value(values[k], field)) for k in keys
    )


def canonical_value(value, field):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return quoted(value, field)
    if value is None:
        return "null"
    if isinstance(value, list):
        return "[%s]" % ",".join(canonical_value(v, field) for v in value)
    if isinstance(value, dict):
        return canonical_map(value, field)
    raise ValueError("no canonical spelling for %r in %s" % (type(value), field))


def event_bytes(event):
    """`docs/technical.md` §3, the eleven values in exactly this order.

    `payload` is inside the digest and that is load-bearing: while it was
    outside, editing `habitID` on any line left the content hash unchanged, so
    a meditation streak could be rewritten into a reading streak with every
    proof still verifying.
    """
    payload = event.get("payload")
    if payload is None:
        raise ValueError("payload is REQUIRED and is missing")
    fields = []
    for key in ("habitID", "name", "achievementID", "reason"):
        if payload.get(key) is not None:
            fields.append("%s:%s" % (quoted(key, key), quoted(payload[key], "payload." + key)))
    unknown = set(payload) - {"habitID", "name", "achievementID", "reason"}
    if unknown:
        # §3: `payload` is a closed structure. An unknown key makes the event
        # invalid — it is not ignored and not tolerated.
        raise ValueError("unknown payload key(s): %s" % ", ".join(sorted(unknown)))

    out = '{"v":%d,"id":%s,"device":%s,"lamport":%d,"kind":%s,"day":%s,"recordedAt":%d,"zoneOffset":%d' % (
        event["v"],
        quoted(event["id"], "id"),
        quoted(event["device"], "device"),
        event["lamport"],
        quoted(event["kind"], "kind"),
        quoted(event["day"], "day"),
        event["recordedAt"],
        event["zoneOffset"],
    )
    # Absent optionals are omitted entirely, never emitted as null.
    if event.get("source") is not None:
        out += ',"source":%s' % quoted(event["source"], "source")
    out += ',"payload":{%s}' % ",".join(fields)
    out += ',"prev":%s}' % quoted(event["prev"], "prev")
    return out.encode("utf-8")


def rule_digest_form(rule):
    """§6.2. Display fields omitted, so a typo stays correctable forever without
    breaking a single anchor."""
    out = '{"id":%s,"kind":%s,"scope":%s,"threshold":%d' % (
        quoted(rule["id"], "rule.id"),
        quoted(rule["kind"], "rule.kind"),
        scope_bytes(rule["scope"]),
        rule["threshold"],
    )
    for key in ("window", "requires", "maxBackfillLagDays"):
        if rule.get(key) is not None:
            out += ',"%s":%d' % (key, rule[key])
    out += ',"neutralDaysBridge":%s' % ("true" if rule["neutralDaysBridge"] else "false")
    out += ',"repeatPolicy":%s' % quoted(rule["repeatPolicy"], "rule.repeatPolicy")
    if rule.get("members") is not None:
        out += ',"members":[%s]' % ",".join(
            quoted(m, "rule.members") for m in rule["members"]
        )
    return out + "}"


def scope_bytes(scope):
    """§6.4."""
    out = "{"
    if scope.get("habit") is not None:
        out += '"habit":%s,' % quoted(scope["habit"], "rule.scope.habit")
    return out + '"requiresAll":%s}' % ("true" if scope["requiresAll"] else "false")


def witness_bytes(witness):
    """§6.5. `evidenceRoot` and every `logHeads` value are base64 with padding,
    RFC 4648 §4 — which is exactly how they already sit on disk."""
    return '{"firstDay":%s,"lastDay":%s,"dayCount":%d,"evidenceRoot":%s,"logHeads":%s}' % (
        quoted(witness["firstDay"], "witness.firstDay"),
        quoted(witness["lastDay"], "witness.lastDay"),
        witness["dayCount"],
        quoted(witness["evidenceRoot"], "witness.evidenceRoot"),
        canonical_map(witness["logHeads"], "witness.logHeads"),
    )


def achievement_bytes(achievement):
    """§6.1. `detectedAt` and `extra` are not here, and neither are the rule's
    `version`, `titleKey` and `fallbackTitle`."""
    return (
        '{"v":1,"id":%s,"rule":%s,"earnedOn":%s,"facts":%s,"witness":%s}'
        % (
            quoted(achievement["id"], "id"),
            rule_digest_form(achievement["rule"]),
            quoted(achievement["earnedOn"], "earnedOn"),
            canonical_map(achievement["facts"], "facts"),
            witness_bytes(achievement["witness"]),
        )
    ).encode("utf-8")


def log_heads_bytes(heads):
    """The weekly log-head anchor. `docs/adr/0004`; the form is fixed in
    `docs/technical.md` §6 because no earlier document specified one."""
    return ('{"v":1,"kind":"logHeads","heads":%s}' % canonical_map(heads, "heads")).encode(
        "utf-8"
    )


def sha256(data):
    return hashlib.sha256(data).digest()


# What the record says backed its key. `docs/technical.md` §8,
# `docs/achievement-protocol.md` §7.
#
# **`backing` is outside the digest.** §6.1 freezes the canonical form and does
# not list it, deliberately — a signature cannot prove what hardware held the key
# that made it. So on a bundle received from someone else the field is
# attacker-controlled text that no signature covers, and *no reading of it is a
# check that passed*. §9 Invariant 8: undigested fields are never rendered as
# part of a verified claim, and where undigested text is shown at all it is
# visibly marked unverified.
#
# The two directions are not symmetric, and that is why they print differently:
#
#   * `secureEnclave` is the **strongest** claim the format can make and
#     therefore the one a forger writes. Flipping "software" to "secureEnclave"
#     on a genuine bundle and recomputing the manifest costs nothing and leaves
#     every other check on this run passing, so this reading is reported as
#     UNCHECKED — the same marker a record that says nothing gets — and it lands
#     in the end-of-run list of things this run could not do. Until 2026-08-01 it
#     printed with the same `ok` marker as the P-256 signature and the chain,
#     which is the one line on the page a forger would have chosen.
#   * `software` is a claim **against** the record's own strength. Nobody forges
#     downward, so believing it costs a reader nothing. It prints unmarked, with
#     wording that attributes it to the record rather than to this run.
#
# Spelled once each so the per-record line and the summary cannot drift into
# saying two different things about the same fact.
SOFTWARE_KEY_NOTE = (
    "  the key is SOFTWARE-backed, per the record — a software key signs just as "
    "validly, and attests to no particular device"
)

ENCLAVE_KEY_CLAIM = (
    "CLAIMS a Secure Enclave key, and nothing here checked that: `backing` is "
    "outside the digest, so it is unsigned text on a bundle from anyone else"
)

EVERY_KEY_CLAIMS_ENCLAVE = (
    "every record here CLAIMS a Secure Enclave key and this run verified none of "
    "those claims — `backing` is outside the digest, a forged one leaves every "
    "other check on this bundle passing, and no signature can prove what "
    "hardware held a key"
)


def evidence_root(content_hashes):
    """§4.1, frozen there. Domain separation on every node, and an odd node is
    **promoted unchanged** rather than paired with itself — duplication is the
    classic construction that admits two leaf sets with one root."""
    if not content_hashes:
        return b"\x00" * 32
    level = [sha256(b"\x00" + h) for h in content_hashes]
    while len(level) > 1:
        nxt = []
        index = 0
        while index + 1 < len(level):
            nxt.append(sha256(b"\x01" + level[index] + level[index + 1]))
            index += 2
        if index < len(level):
            nxt.append(level[index])
        level = nxt
    return level[0]


# --------------------------------------------------------------------------
# P-256 ECDSA, in pure Python
#
# `docs/achievement-protocol.md` §6.7: the signature is over `canonicalBytes`,
# and the DataProtocol overload hashes its argument once — so the signed
# message is SHA-256(canonicalBytes), with no second hash. Verification is the
# mirror. A verifier never signs or verifies over `digest` itself.
# --------------------------------------------------------------------------

_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
_A = _P - 3
_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_G = (
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)


def _point_add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    (x1, y1), (x2, y2) = p, q
    if x1 == x2 and (y1 + y2) % _P == 0:
        return None
    if p == q:
        slope = (3 * x1 * x1 + _A) * pow(2 * y1, _P - 2, _P) % _P
    else:
        slope = (y2 - y1) * pow(x2 - x1, _P - 2, _P) % _P
    x3 = (slope * slope - x1 - x2) % _P
    return (x3, (slope * (x1 - x3) - y1) % _P)


def _point_multiply(scalar, point):
    result = None
    while scalar:
        if scalar & 1:
            result = _point_add(result, point)
        point = _point_add(point, point)
        scalar >>= 1
    return result


def p256_verify(public_key_x963, signature_raw, message):
    """`publicKey.isValidSignature(sig, for: canonicalBytes)`, reimplemented.

    The key is X9.63 (0x04 ‖ X ‖ Y), which is what `Signer.publicKey` writes and
    what `publickey.pem` carries. The signature is the raw representation,
    r ‖ s, 32 bytes each — not DER.
    """
    if len(public_key_x963) != 65 or public_key_x963[0] != 4:
        return False
    if len(signature_raw) != 64:
        return False
    qx = int.from_bytes(public_key_x963[1:33], "big")
    qy = int.from_bytes(public_key_x963[33:65], "big")
    r = int.from_bytes(signature_raw[:32], "big")
    s = int.from_bytes(signature_raw[32:], "big")
    if not (0 < r < _N and 0 < s < _N):
        return False
    z = int.from_bytes(sha256(message), "big")
    w = pow(s, _N - 2, _N)
    point = _point_add(
        _point_multiply(z * w % _N, _G), _point_multiply(r * w % _N, (qx, qy))
    )
    return point is not None and point[0] % _N == r


# --------------------------------------------------------------------------
# OpenTimestamps
#
# A detached proof is a tree: from one message, a chain of operations leads to
# one or more attestations. A **pending** attestation is a calendar's promise
# to aggregate the digest; a **Bitcoin** attestation says the result of the
# operations is the merkle root of a stated block. ADR 0004 is emphatic that
# the first is not a proof and the second is.
# --------------------------------------------------------------------------

_PENDING_TAG = bytes.fromhex("83dfe30d2ef90c8e")
_BITCOIN_TAG = bytes.fromhex("0588960d73d71901")
_OTS_MAGIC = bytes.fromhex("004f70656e54696d657374616d7073000050726f6f6600bf89e2e884e89294")


class _Reader:
    def __init__(self, data):
        self.data, self.index = data, 0

    def byte(self):
        value = self.data[self.index]
        self.index += 1
        return value

    def take(self, count):
        value = self.data[self.index : self.index + count]
        if len(value) != count:
            raise ValueError("truncated proof")
        self.index += count
        return value

    def varuint(self):
        value, shift = 0, 0
        while True:
            byte = self.byte()
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value
            shift += 7

    def varbytes(self):
        return self.take(self.varuint())


def parse_timestamp(reader):
    """The serialization in `python-opentimestamps`: 0xff separates steps, 0x00
    introduces an attestation, anything else is an operation tag.

    The tree is parsed **without** applying anything, so a proof carrying an
    operation this file cannot compute is still read in full and reported,
    rather than truncated at the first unknown byte.
    """
    steps = []

    def step(tag):
        if tag == 0x00:
            kind = reader.take(8)
            payload = _Reader(reader.varbytes())
            if kind == _PENDING_TAG:
                steps.append(("pending", payload.varbytes().decode("utf-8", "replace")))
            elif kind == _BITCOIN_TAG:
                steps.append(("bitcoin", payload.varuint()))
            else:
                steps.append(("unknown-attestation", kind.hex()))
        elif tag in (0xF0, 0xF1):
            steps.append((("append" if tag == 0xF0 else "prepend", reader.varbytes()),
                          parse_timestamp(reader)))
        elif tag in (0x02, 0x03, 0x08, 0x67, 0xF2, 0xF3):
            names = {0x02: "sha1", 0x03: "ripemd160", 0x08: "sha256",
                     0x67: "keccak256", 0xF2: "reverse", 0xF3: "hexlify"}
            steps.append(((names[tag],), parse_timestamp(reader)))
        else:
            raise ValueError("unknown operation tag 0x%02x" % tag)

    tag = reader.byte()
    while tag == 0xFF:
        step(reader.byte())
        tag = reader.byte()
    step(tag)
    return steps


def parse_detached(data):
    """A `.ots` file: magic, version, the file-hash operation and its digest,
    then the timestamp for that digest."""
    reader = _Reader(data)
    if reader.take(len(_OTS_MAGIC)) != _OTS_MAGIC:
        raise ValueError("not an OpenTimestamps detached proof")
    reader.varuint()  # major version
    algorithm = reader.byte()
    if algorithm != 0x08:
        raise ValueError("proof is over a non-SHA-256 file hash (0x%02x)" % algorithm)
    digest = reader.take(32)
    return digest, parse_timestamp(reader)


def apply_operation(operation, message):
    """Returns the new message, or None when this file cannot compute it.

    RIPEMD-160 and Keccak-256 are not in Python's standard library on every
    platform, so a branch using either is reported as unchecked rather than
    guessed at. Calendars aggregate with SHA-256, so this has never been
    reached by a Compass proof.
    """
    name = operation[0]
    if name == "append":
        return message + operation[1]
    if name == "prepend":
        return operation[1] + message
    if name == "sha256":
        return sha256(message)
    if name == "sha1":
        return hashlib.sha1(message).digest()
    if name == "reverse":
        return message[::-1]
    if name == "hexlify":
        return message.hex().encode("ascii")
    if name == "ripemd160":
        try:
            return hashlib.new("ripemd160", message).digest()
        except ValueError:
            return None
    return None


def walk_proof(steps, message, found, unchecked):
    """Replays every operation from `message` and collects what each branch
    reaches. This is the whole verification: the attestation is only about the
    message the operations actually produce."""
    for entry in steps:
        if entry[0] == "pending":
            found.append(("pending", entry[1], message))
        elif entry[0] == "bitcoin":
            found.append(("bitcoin", entry[1], message))
        elif entry[0] == "unknown-attestation":
            unchecked.append("attestation of unknown type %s" % entry[1])
        else:
            operation, children = entry
            result = apply_operation(operation, message)
            if result is None:
                unchecked.append("operation %s is not implemented here" % operation[0])
                continue
            walk_proof(children, result, found, unchecked)


# --------------------------------------------------------------------------
# Re-deriving the claim from the log
#
# The signature proves the record came from a key. It does not prove the record
# follows from the events, and that is the claim a stranger actually cares
# about. `docs/achievement-protocol.md` §5.1 defines both shipped rule kinds.
# --------------------------------------------------------------------------


def ordinal(iso_day):
    year, month, day = (int(part) for part in iso_day.split("-"))
    return datetime.date(year, month, day).toordinal()


def qualifying_cells(events):
    """The winning `checkedIn` event per (habit, day), resolved last-writer-wins
    under the total order `(lamport, device)`. **Never wall-clock** — clocks move
    backwards, so `recordedAt` is not a safe sort key."""
    cells = {}
    for event in sorted(events, key=lambda e: (e["lamport"], e["device"])):
        habit = (event.get("payload") or {}).get("habitID")
        if habit is None:
            continue
        if event["kind"] == "checkedIn":
            cells.setdefault(habit, {})[event["day"]] = event
        elif event["kind"] == "checkInRevoked":
            cells.get(habit, {}).pop(event["day"], None)
    return cells


def counted_days(rule, cells):
    """`streak` takes the **earliest** window of `threshold` consecutive days, so
    the answer is a fact about the log rather than about when the rule shipped.
    `total` takes the first `threshold` qualifying days."""
    habit = rule["scope"].get("habit")
    if habit is not None:
        days = sorted(cells.get(habit, {}), key=ordinal)
    else:
        days = sorted({day for byDay in cells.values() for day in byDay}, key=ordinal)

    threshold = rule["threshold"]
    if rule["kind"] == "streak":
        start = 0
        for index in range(len(days)):
            if index > 0 and ordinal(days[index]) != ordinal(days[index - 1]) + 1:
                start = index
            if index - start + 1 == threshold:
                return days[start : index + 1]
        return None
    if rule["kind"] == "total":
        return days[:threshold] if len(days) >= threshold else None
    return None


def evidence_for(rule, days, cells):
    """The qualifying events, **in `(lamport, device)` order** — §4.1 freezes the
    evidence leaves in that order and in no other.

    The sort is the whole point of this function and it is applied to the *whole*
    set, not per day. Collecting day by day and concatenating produces day order,
    which coincides with `(lamport, device)` order only when every day's events
    were appended in day sequence. Two writers make that untrue routinely: the
    widget and the app interleave, and a day checked in late lands after a later
    day's events. On such a log a day-ordered reader computes a different root
    from the app and disagrees with a bundle that is correct — which is worse than
    not checking, because it is a verifier that agrees only when the data is tidy.

    `device` is compared as the ASCII UUID string it is on disk, which is the same
    comparison `EventOrder` makes in `CompassDomain/Event.swift`.
    """
    habit = rule["scope"].get("habit")
    events = []
    for day in days:
        if habit is not None:
            if day in cells.get(habit, {}):
                events.append(cells[habit][day])
        else:
            events.extend(byDay[day] for byDay in cells.values() if day in byDay)
    return sorted(events, key=lambda e: (e["lamport"], e["device"]))


# --------------------------------------------------------------------------
# The report
# --------------------------------------------------------------------------


class Report:
    def __init__(self):
        self.failures = 0
        self.unchecked = []

    def section(self, title):
        print("\n%s\n%s" % (title, "-" * len(title)))

    def ok(self, message):
        print("  ok       %s" % message)

    def bad(self, message):
        self.failures += 1
        print("  FAILED   %s" % message)

    def note(self, message):
        print("           %s" % message)

    def cannot(self, message):
        self.unchecked.append(message)
        print("  unknown  %s" % message)


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, "rb") as handle:
        return [json.loads(line) for line in handle.read().split(b"\n") if line.strip()]


def verify(bundle):
    report = Report()
    print("compass-verify — %s" % os.path.abspath(bundle))

    # 1. The manifest. -----------------------------------------------------
    report.section("manifest.json")
    manifest_path = os.path.join(bundle, "manifest.json")
    if not os.path.exists(manifest_path):
        report.bad("no manifest.json — this is not a Compass bundle")
        return report
    with open(manifest_path, "rb") as handle:
        manifest = json.loads(handle.read())
    when = datetime.datetime.fromtimestamp(
        manifest["exportedAt"] / 1000.0, datetime.timezone.utc
    )
    report.note("exported %s UTC" % when.strftime("%Y-%m-%d %H:%M:%S"))
    for name in sorted(manifest["files"]):
        path = os.path.join(bundle, name)
        if not os.path.exists(path):
            report.bad("%s is listed in the manifest and missing" % name)
            continue
        with open(path, "rb") as handle:
            actual = hashlib.sha256(handle.read()).hexdigest()
        if actual == manifest["files"][name]:
            report.ok("%s  %s" % (actual[:16], name))
        else:
            report.bad("%s digest does not match the manifest" % name)

    # 2. The log. ----------------------------------------------------------
    report.section("events.jsonl — canonical bytes and the per-writer chain")
    events = read_lines(os.path.join(bundle, "events.jsonl"))
    report.note("%d events" % len(events))

    hashes, by_writer = {}, {}
    for event in events:
        try:
            content_hash = sha256(event_bytes(event))
        except ValueError as error:
            report.bad("event %s cannot be canonicalised: %s" % (event.get("id"), error))
            continue
        hashes[event["id"]] = content_hash
        by_writer.setdefault(event["device"], []).append(event)

    heads = {}
    for writer, written in sorted(by_writer.items()):
        # Restricted to one writer the total order is `lamport` alone.
        written.sort(key=lambda e: e["lamport"])
        expected = b"\x00" * 32
        broken = 0
        for event in written:
            if base64.b64decode(event["prev"]) != expected:
                broken += 1
                report.bad(
                    "writer %s: prev at lamport %d does not match its predecessor"
                    % (writer[:8], event["lamport"])
                )
            expected = hashes.get(event["id"], expected)
        heads[writer] = expected
        if not broken:
            report.ok(
                "writer %s: %d events chain unbroken from genesis to %s"
                % (writer[:8], len(written), base64.b64encode(expected).decode())
            )

    # 3 and 4. The awards and their signatures. ----------------------------
    report.section("awards.jsonl — the record, the claim, and the signature")
    records = read_lines(os.path.join(bundle, "awards.jsonl"))
    achievements = [r for r in records if "witness" in r]
    revocations = [r for r in records if "newLogHeads" in r]
    report.note("%d achievements, %d revocations" % (len(achievements), len(revocations)))

    attestations = {}
    for line in read_lines(os.path.join(bundle, "attestations.jsonl")):
        attestations[line["achievement"]] = line  # last write wins

    cells = qualifying_cells(events)
    digests = {}
    for achievement in achievements:
        name = achievement["id"]
        try:
            canonical = achievement_bytes(achievement)
        except ValueError as error:
            report.bad("%s cannot be canonicalised: %s" % (name, error))
            continue
        digest = sha256(canonical)
        digests[name] = digest
        report.note("%s" % name)
        report.ok("  sha-256 %s" % digest.hex())

        # The deterministic identifier — "<rule.id>@<earnedOn>", §3.1.
        if name != "%s@%s" % (achievement["rule"]["id"], achievement["earnedOn"]):
            report.bad("  the identifier does not match its own rule and day")

        # The claim, re-derived from the log rather than believed.
        days = counted_days(achievement["rule"], cells)
        if achievement["rule"]["scope"].get("requiresAll"):
            report.cannot("  %s uses requiresAll, which this file does not re-derive" % name)
        elif days is None:
            report.bad("  the log does not support this claim")
        elif days[-1] != achievement["earnedOn"]:
            report.bad(
                "  the log says this was earned on %s, the record says %s"
                % (days[-1], achievement["earnedOn"])
            )
        else:
            counted = evidence_for(achievement["rule"], days, cells)
            root = evidence_root([hashes[e["id"]] for e in counted])
            if root != base64.b64decode(achievement["witness"]["evidenceRoot"]):
                report.bad("  the evidence root does not cover the days the log shows")
            elif len(days) != achievement["witness"]["dayCount"]:
                report.bad("  dayCount disagrees with the log")
            else:
                report.ok(
                    "  the log supports it: %d days, %s to %s, evidence root recomputed"
                    % (len(days), days[0], days[-1])
                )

        # The head it committed to must be a real point on that writer's chain.
        for writer, head in achievement["witness"]["logHeads"].items():
            if base64.b64decode(head) in set(hashes.values()):
                report.ok("  witnesses writer %s at a head this log contains" % writer[:8])
            else:
                report.bad("  witnesses a head for %s that is not in this log" % writer[:8])

        attestation = attestations.get(name)
        if attestation is None:
            report.cannot("  %s has no attestation: nothing is signed" % name)
            continue
        signed = p256_verify(
            base64.b64decode(attestation["publicKey"]),
            base64.b64decode(attestation["signature"]),
            canonical,
        )
        if signed:
            report.ok("  P-256 signature verifies")
        else:
            report.bad("  the P-256 signature does NOT verify")

        # **What the record says backed the key, printed whether or not the
        # signature verified.** `docs/technical.md` §8 is about what a reader
        # concludes, so this line cannot sit inside the `if` above — a bundle
        # whose signature fails is exactly a bundle whose provenance a reader
        # wants to know.
        #
        # None of the three branches is an `ok`. `ok` is reserved for a check
        # that recomputed something: the manifest digests, the chain, the
        # evidence root, the P-256 signature. `backing` is read, not checked.
        # See the constants above for why the strongest reading is the one that
        # had to change.
        #
        # A record that does not say is reported as not saying. It is never
        # assumed to be the stronger of the two, and it is not a crash: an older
        # or newer build's line is the ordinary case this whole file is written
        # to survive.
        backing = attestation.get("backing")
        if backing == "secureEnclave":
            report.cannot("  %s %s" % (name, ENCLAVE_KEY_CLAIM))
        elif backing == "software":
            report.note(SOFTWARE_KEY_NOTE)
        else:
            report.cannot(
                "  %s does not say what backed its key: it may be software, and a "
                "software key is not a device attestation" % name
            )
        report.note("  anchor state: %s" % attestation["state"])

    for revocation in revocations:
        report.note(
            "%s was revoked: %s" % (revocation["achievement"], revocation["reason"])
        )

    # How many keys signed this bundle, and what that means.
    #
    # `docs/technical.md` §8 and `docs/adr/0004`: the enclave key does not survive
    # device replacement, and by the time a new phone exists the old key is
    # unreachable, so it cannot sign its successor. A bundle spanning a
    # replacement therefore carries two unrelated public keys, and a verifier
    # "must report those two cases differently" rather than quietly accepting
    # both. Reporting it is the whole obligation here — deciding it is not
    # available to anyone.
    keys = {a["publicKey"] for a in attestations.values()}
    if len(keys) == 1:
        report.ok("every record here was signed by one key")
    elif len(keys) > 1:
        report.cannot(
            "this bundle carries %d unrelated public keys — a device replacement. "
            "Each signature verifies under its own key; that they belong to one "
            "person is asserted, not proven" % len(keys)
        )

    # **What the records say backed those keys, said once, at the level of the
    # whole bundle.**
    #
    # `docs/technical.md` §8 is a statement about what a reader concludes, so it
    # has to survive a reader who skims the per-record lines and reads only the
    # summary. Without this, a bundle every one of whose signatures came from a
    # software key ended a clean run with "Every check that could run, passed."
    # and nothing else.
    #
    # **Neither branch is an `ok`.** Both are readings of an undigested field.
    # The enclave branch was an `ok` until 2026-08-01, which made the strongest
    # and most forgeable claim in the bundle the one rendered with the same
    # marker as the P-256 signature — while the two weaker branches hedged
    # correctly. Nothing here is a *failure* either: a software key is not a
    # forgery and its signature is perfectly valid; a claimed enclave key may
    # well be one. What neither can support is a conclusion about which device
    # made this bundle, and that distinction is the whole content of these lines.
    backings = [a.get("backing") for a in attestations.values()]
    if backings:
        weak = [b for b in backings if b != "secureEnclave"]
        if not weak:
            report.cannot(EVERY_KEY_CLAIMS_ENCLAVE)
        else:
            report.cannot(
                "%d of %d signature(s) here were NOT made by a Secure Enclave key — a "
                "software key signs just as validly and attests to no particular "
                "device, so this bundle is not evidence that one phone made it"
                % (len(weak), len(backings))
            )

    # publickey.pem is what other tools read. If it disagrees with the keys that
    # actually signed, one of the two is lying about the bundle.
    pem_path = os.path.join(bundle, "publickey.pem")
    if keys and os.path.exists(pem_path):
        with open(pem_path, "rb") as handle:
            pem = handle.read().decode("ascii", "replace")
        exported = set()
        for block in pem.split("-----BEGIN PUBLIC KEY-----")[1:]:
            body = block.split("-----END PUBLIC KEY-----")[0]
            try:
                der = base64.b64decode("".join(body.split()))
            except (ValueError, binascii.Error):
                continue
            # SPKI for P-256 is a fixed 26-byte prefix followed by the X9.63
            # point. Slicing it is enough: the prefix is constant for this curve.
            if len(der) == 91:
                exported.add(base64.b64encode(der[26:]).decode())
        if exported == keys:
            report.ok("publickey.pem holds exactly the keys that signed these records")
        else:
            report.bad("publickey.pem does not match the keys that signed these records")

    # 5. The anchors. ------------------------------------------------------
    report.section("anchors.jsonl and proofs/ — the OpenTimestamps proof")
    # Last write wins per digest, exactly as `attestations.jsonl` is folded above
    # and exactly as the app folds it. Both files are append-only: a state change
    # appends a line rather than rewriting one, so an anchor that has been
    # upgraded appears twice on disk. Reading them unfolded reports one anchor as
    # two — the older line still saying "pending" beside the newer one saying
    # "confirmed" — which reads as two anchors and drags a stale "no Bitcoin
    # attestation yet" into the summary of a bundle that has one.
    latest, order = {}, []
    for anchor in read_lines(os.path.join(bundle, "anchors.jsonl")):
        if anchor["digest"] not in latest:
            order.append(anchor["digest"])
        latest[anchor["digest"]] = anchor
    anchors = [latest[digest] for digest in order]
    proofs = []
    for anchor in anchors:
        proofs.append(("log heads", anchor.get("digest"), anchor.get("otsProof"), anchor))
    for name, attestation in sorted(attestations.items()):
        if attestation.get("otsProof"):
            proofs.append((name, base64.b64encode(digests.get(name, b"")).decode(),
                           attestation["otsProof"], attestation))
    if not proofs:
        report.cannot("no OpenTimestamps proof in this bundle: nothing is anchored yet")

    for label, digest_b64, proof_b64, record in proofs:
        report.note("%s" % label)
        if label == "log heads":
            recomputed = sha256(log_heads_bytes(record["heads"]))
            if recomputed == base64.b64decode(digest_b64):
                report.ok("  the anchored digest is the digest of these heads")
            else:
                report.bad("  the anchored digest is not the digest of these heads")
            for writer, head in record["heads"].items():
                if heads.get(writer) == base64.b64decode(head):
                    report.ok("  writer %s: the anchored head IS this log's head" % writer[:8])
                elif base64.b64decode(head) in set(hashes.values()):
                    report.note(
                        "  writer %s: the anchored head is an earlier point on this chain"
                        % writer[:8]
                    )
                else:
                    report.bad("  writer %s: the anchored head is not in this log" % writer[:8])
        if not proof_b64:
            report.cannot("  no proof bytes: submitted to nothing, or not yet submitted")
            continue
        try:
            stamped, tree = parse_detached(base64.b64decode(proof_b64))
        except ValueError as error:
            report.bad("  the proof will not parse: %s" % error)
            continue
        if stamped != base64.b64decode(digest_b64):
            report.bad("  the proof is over a different digest than the record")
            continue
        report.ok("  the proof is over this record's own digest")

        found, unchecked = [], []
        walk_proof(tree, stamped, found, unchecked)
        for note in unchecked:
            report.cannot("  " + note)
        confirmed = [f for f in found if f[0] == "bitcoin"]
        pending = [f for f in found if f[0] == "pending"]
        for _, uri, _ in pending:
            report.note("  pending at %s — a promise, not yet a proof" % uri)

        if confirmed:
            # **The earliest block is the claim.** A proof submitted to three
            # calendars can reach Bitcoin by three independent paths, each
            # committing its own aggregation root in its own block, and the
            # strongest thing any of them says is the earliest: this record
            # existed before that block. The later paths corroborate; they do not
            # add. The app picks the same one, in `AnchorPipeline.upgrade`.
            confirmed.sort(key=lambda found: found[1])
            _, height, merkle_root = confirmed[0]
            report.ok(
                "  Bitcoin block %d commits merkle root %s"
                % (height, merkle_root[::-1].hex())
            )
            if len(confirmed) > 1:
                report.note(
                    "  %d further independent path(s) in this proof also reach Bitcoin, at "
                    "block(s) %s"
                    % (
                        len(confirmed) - 1,
                        ", ".join(str(found[1]) for found in confirmed[1:]),
                    )
                )
            report.cannot(
                "  whether block %d really has that merkle root — check it against a "
                "Bitcoin header; this file ships no chain" % height
            )
        else:
            report.cannot(
                "  no Bitcoin attestation yet: a fresh submission is an incomplete proof"
            )

    # The summary. ---------------------------------------------------------
    report.section("what this run concluded")
    if report.failures:
        print("  %d CHECK(S) FAILED. Do not believe this bundle." % report.failures)
    else:
        print("  Every check that could run, passed.")
    if report.unchecked:
        print("  %d thing(s) could not be checked here:" % len(report.unchecked))
        for item in report.unchecked:
            print("    - %s" % item.strip())
    print(
        "\n  Not checked by design: whether the declared name belongs to a real person\n"
        "  (nothing in Compass ever verified it), and any Bitcoin header (see above)."
    )
    return report


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().split("\n\n")[1].strip())
        return 2
    return 1 if verify(sys.argv[1]).failures else 0


if __name__ == "__main__":
    sys.exit(main())
