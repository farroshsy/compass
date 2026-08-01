# Compass at a glance

A habit tracker that produces a record of what you actually did, which you can
hand to a stranger and they can check without trusting you or the app.

| The daily loop | On the home screen |
|---|---|
| <img src="img/today.png" width="300" alt="The Today screen: 7 days recorded, four habit rows, two of them checked in their own colours"> | <img src="img/icon.png" width="300" alt="The Record app icon on a home screen: a cream ground with a three-by-five grid of struck cells, two of them unmade"> |

Both are the real app on a simulator, not mockups. The left screen is a week of
actual data. The number is **total days recorded**, never the current streak —
a number that resets to zero teaches you to start over, and starting over is the
behaviour this project was built against.

The icon is fifteen struck cells, three by five, with two not made. It is
deliberately pale and low-chroma: almost every other icon on a home screen is a
saturated ground with a white glyph, so the odd one out is the easiest thing on
the page to find.

---

## From a tap to something a stranger can check

```mermaid
flowchart TD
    tap["Tap a habit<br/><i>app or widget</i>"] --> toggle["CheckIn.toggle<br/><i>one append API, two writers</i>"]
    toggle --> canon["Canonical bytes<br/><i>hand-written, frozen key order</i>"]
    canon --> hash["content_hash = SHA-256<br/><i>covers the payload</i>"]
    hash --> chain["prev ← this writer's head<br/><i>a per-writer chain</i>"]
    chain --> log[("events.jsonl<br/><i>append-only, one write per event</i>")]

    log --> engine["AchievementEngine<br/><i>a pure fold over the log</i>"]
    engine --> award["A milestone fires<br/><i>recorded as a fact, with the rule that fired</i>"]
    award --> seal["Signer<br/><i>P-256, Secure Enclave</i>"]
    seal --> cert["Certificate<br/><i>'Sealed on this device'</i>"]

    award -. "72 hours later" .-> ots["OpenTimestamps<br/><i>all three calendars</i>"]
    ots -. "when a proof confirms" .-> anchored["Certificate gains one line<br/><i>'Anchored 17 March 2026'</i>"]

    log --> bundle["Export bundle"]
    award --> bundle
    ots --> bundle
    bundle --> verify["compass-verify.py<br/><i>Python 3, no code shared with the app</i>"]

    style log fill:#1B6B7A,color:#F2EFE8
    style verify fill:#1B6B7A,color:#F2EFE8
    style cert fill:#F2EFE8,color:#191917
```

Nothing on the launch path touches the network. The tap is three synchronous
steps and one `write(2)`; everything else happens after the pixel has already
changed.

---

## Two writers, one log

The app and the Home Screen widget are separate processes. They are treated as
two independent writers rather than pretending to be one.

```mermaid
flowchart LR
    subgraph app ["App process"]
        a1["TodayModel.toggle<br/>source: .tap"]
    end
    subgraph wid ["Widget extension"]
        w1["ToggleHabitIntent<br/>source: .widget"]
    end

    a1 --> api["CheckIn.toggle"]
    w1 --> api
    api --> log[("events.jsonl<br/>App Group container")]

    log --> c1["chain A<br/><i>device A · lamport · prev</i>"]
    log --> c2["chain B<br/><i>device B · lamport · prev</i>"]
    c1 --> order["Total order: (lamport, device)<br/><i>never wall-clock</i>"]
    c2 --> order

    style log fill:#1B6B7A,color:#F2EFE8
```

Each writer has its own UUID, its own `lamport` counter and its own `prev`
chain, so `logHeads` carries two heads for one phone. They share the append API
because if they wrote through different paths the chains would diverge — and
the two-writer test found a real defect the day it was written.

---

## What the verifier actually checks

```mermaid
flowchart TD
    b["An exported bundle"] --> re["Recompute canonical bytes<br/><i>from the spec, not the app's code</i>"]
    re --> h{"Every content_hash<br/>matches?"}
    h -- no --> fail1["FAIL — the log was edited"]
    h -- yes --> ch{"Every prev link<br/>intact?"}
    ch -- no --> fail2["FAIL — the chain is broken"]
    ch -- yes --> ev{"evidenceRoot rebuilt<br/>from the counted events?"}
    ev -- no --> fail3["FAIL — the claim does not match the log"]
    ev -- yes --> sig{"P-256 signature<br/>valid?"}
    sig -- no --> fail4["FAIL — not signed by that key"]
    sig -- yes --> ots{"OpenTimestamps proof<br/>attaches to a Bitcoin block?"}
    ots -- yes --> ok["Reports the block height<br/>and the merkle root"]
    ok --> limit["States its own limit:<br/><i>checking the header needs a chain<br/>this script does not ship</i>"]

    style fail1 fill:#B7203D,color:#fff
    style fail2 fill:#B7203D,color:#fff
    style fail3 fill:#B7203D,color:#fff
    style fail4 fill:#B7203D,color:#fff
    style limit fill:#F2EFE8,color:#191917
```

`verifier/compass-verify.py` is Python 3, standard library only, and shares no
code with the app. That independence is the point: a verifier that imported the
app's encoder would only prove the app agrees with itself.

It was estimated at ~200 lines and came out at 579, because re-deriving the
claim from the log and doing P-256 by hand were not in the estimate.

---

## What is deliberately absent

No accounts, no server, no sign-in, no notifications, no gamification, no
streak headline, no social layer, and nothing the user must understand about
blockchains — no wallet, no gas, no chain name, no address, and never the word
"mint". Each of those is a written non-goal with a stated reason in
[product.md](product.md), and the non-goals win over every other document in
this repository.

The one operational dependency, named rather than hidden: the OpenTimestamps
calendars are somebody else's servers. If they vanish during the window, pending
proofs are lost — the local signature survives and the app keeps working. See
[adr/0004](adr/0004-what-goes-on-chain.md).
