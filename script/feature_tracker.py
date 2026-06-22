#!/usr/bin/env python3
"""Canonical feature-status tracker for Waves.

Single source of truth: docs/feature-status.json
Canonical spreadsheet (rendered from the JSON): FEATURE_STATUS.csv

Usage:
  python3 script/feature_tracker.py ingest <workflow_output_file>   # Phase 1: build JSON+CSV from the user-story workflow result
  python3 script/feature_tracker.py render                          # regenerate FEATURE_STATUS.csv from the JSON
  python3 script/feature_tracker.py stats                           # print status distribution
"""
import csv
import json
import os
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(ROOT, "docs", "feature-status.json")
CSV_PATH = os.path.join(ROOT, "FEATURE_STATUS.csv")

# Phase-tracking fields seeded for every row at ingest time.
PHASE_DEFAULTS = {
    "testStatus": "Not yet tested",
    "errorsFound": "",
    "fixStatus": "",
    "fixNotes": "",
    "retestStatus": "",
}

CSV_COLUMNS = [
    ("id", "ID"),
    ("area", "Area"),
    ("feature", "Feature"),
    ("priority", "Priority"),
    ("userStory", "User Story"),
    ("expectedBehavior", "Expected Behavior"),
    ("acceptanceCriteria", "Acceptance Criteria"),
    ("codeRefs", "Code Refs"),
    ("implStatus", "Impl Status"),
    ("implNotes", "Impl Notes"),
    ("testStatus", "Test Status"),
    ("errorsFound", "Errors Found"),
    ("fixStatus", "Fix Status"),
    ("fixNotes", "Fix Notes"),
    ("retestStatus", "Retest Status"),
]


def _join_list(v):
    if isinstance(v, list):
        return "\n".join(f"• {x}" for x in v)
    return v or ""


def ingest(output_file):
    wrapper = json.loads(open(output_file, encoding="utf-8").read())
    res = wrapper.get("result", wrapper)
    if isinstance(res, str):
        res = json.loads(res)
    areas = res.get("areas", [])
    critic = res.get("critic") or {}

    rows = []
    for a in areas:
        area_name = a.get("area", "")
        for s in a.get("stories", []):
            row = {
                "id": s.get("id", ""),
                "area": area_name,
                "feature": s.get("feature", ""),
                "priority": s.get("priority", ""),
                "userStory": s.get("userStory", ""),
                "expectedBehavior": s.get("expectedBehavior", []),
                "acceptanceCriteria": s.get("acceptanceCriteria", []),
                "codeRefs": s.get("codeRefs", []),
                "implStatus": s.get("implementationStatus", ""),
                "implNotes": s.get("statusNotes", ""),
                "source": "phase1-story",
            }
            row.update(PHASE_DEFAULTS)
            rows.append(row)

    # critic-identified gaps become first-class rows
    for m in critic.get("missing", []):
        row = {
            "id": m.get("suggestedId", ""),
            "area": m.get("area", ""),
            "feature": m.get("feature", ""),
            "priority": "",
            "userStory": "",
            "expectedBehavior": [],
            "acceptanceCriteria": [],
            "codeRefs": m.get("codeRefs", []),
            "implStatus": m.get("implementationStatus", ""),
            "implNotes": "[critic gap] " + m.get("whyMissing", ""),
            "source": "phase1-critic-gap",
        }
        row.update(PHASE_DEFAULTS)
        rows.append(row)

    data = {
        "meta": {
            "app": "Waves",
            "phase": "1-inventory-complete",
            "totalStories": len(rows),
            "coverageNotes": critic.get("coverageNotes", ""),
            "implDist": dict(Counter(r["implStatus"] for r in rows)),
            "priorityDist": dict(Counter(r["priority"] for r in rows if r["priority"])),
        },
        "rows": rows,
    }
    os.makedirs(os.path.dirname(JSON_PATH), exist_ok=True)
    with open(JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    render()
    return data


def load():
    return json.loads(open(JSON_PATH, encoding="utf-8").read())


def save(data):
    with open(JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def render():
    data = load()
    with open(CSV_PATH, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        w.writerow([h for _, h in CSV_COLUMNS])
        for r in data["rows"]:
            w.writerow([_join_list(r.get(k, "")) if k in ("expectedBehavior", "acceptanceCriteria", "codeRefs")
                        else r.get(k, "") for k, _ in CSV_COLUMNS])
    print(f"Rendered {len(data['rows'])} rows -> {os.path.relpath(CSV_PATH, ROOT)}")


SEV_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
SEV_ABBR = {"critical": "C", "high": "H", "medium": "M", "low": "L"}


def _primary_file(code_ref):
    if not code_ref:
        return ""
    return str(code_ref).split(":")[0].strip()


def merge_phase2(output_file):
    """Merge the phase-2 audit workflow result into the tracker rows."""
    wrapper = json.loads(open(output_file, encoding="utf-8").read())
    res = wrapper.get("result", wrapper)
    if isinstance(res, str):
        res = json.loads(res)
    # id -> {verdict, issues(kept, non-rejected, sorted by severity)}
    by_id = {}
    rejected_count = 0
    for g in res.get("groups", []):
        for s in g.get("storyResults", []):
            kept = []
            for i in s.get("issues", []):
                if i.get("confidence") == "rejected":
                    rejected_count += 1
                    continue
                kept.append(i)
            kept.sort(key=lambda i: SEV_RANK.get(i.get("severity"), 9))
            by_id[s["id"]] = {"verdict": s.get("verdict"), "issues": kept}

    data = load()
    fixable_total = 0
    for r in data["rows"]:
        info = by_id.get(r["id"])
        if not info:
            r["testStatus"] = "Not audited"
            r["issues"] = []
            continue
        issues = info["issues"]
        for it in issues:
            it["primaryFile"] = _primary_file(it.get("codeRef"))
            it["disposition"] = ""  # filled in phase 3
        r["issues"] = issues
        fixable_total += len(issues)
        if not issues:
            r["testStatus"] = "PASS"
            r["errorsFound"] = ""
        else:
            c = Counter(i.get("severity") for i in issues)
            tag = " ".join(f"{c[k]}{SEV_ABBR[k]}" for k in ("critical", "high", "medium", "low") if c.get(k))
            r["testStatus"] = f"{len(issues)} issue(s) [{tag}]"
            r["errorsFound"] = "\n".join(
                f"• [{i.get('severity','?').upper()}/{i.get('type','?')}] {i.get('title','')} "
                f"({i.get('codeRef','')}) — {i.get('detail','')} | Fix: {i.get('suggestedFix','')}"
                for i in issues
            )

    sev = Counter()
    for r in data["rows"]:
        for i in r.get("issues", []):
            sev[i.get("severity")] += 1
    data["meta"]["phase"] = "2-tested"
    data["meta"]["phase2"] = {
        "confirmedIssues": fixable_total,
        "rejectedFalsePositives": rejected_count,
        "severityDist": dict(sev),
        "storiesWithIssues": sum(1 for r in data["rows"] if r.get("issues")),
    }
    save(data)
    render()
    return data["meta"]["phase2"]


def merge_apply(output_file, tier):
    """Record apply-workflow dispositions onto the tracker rows/issues."""
    plan = json.loads(open(os.path.join(ROOT, "docs", "fix-plan.json"), encoding="utf-8").read())
    unit_uids = {u["unitId"]: u.get("issueUids", []) for u in plan["units"]}
    wrapper = json.loads(open(output_file, encoding="utf-8").read())
    res = wrapper.get("result", wrapper)
    if isinstance(res, str):
        res = json.loads(res)
    status_by_unit = {}
    for r in res.get("results", []):
        for u in r.get("units", []):
            # don't let a 'skipped' from one agent overwrite an 'applied' from the owner agent
            prev = status_by_unit.get(u["unitId"])
            order = {"applied": 3, "partial": 2, "skipped": 1}
            if prev is None or order.get(u["status"], 0) > order.get(prev, 0):
                status_by_unit[u["unitId"]] = u["status"]
    uid_fix = {}
    for unit_id, status in status_by_unit.items():
        for uid in unit_uids.get(unit_id, []):
            uid_fix[uid] = (unit_id, status)
    data = load()
    changed = 0
    for row in data["rows"]:
        units, statuses = set(), []
        for i in row.get("issues", []):
            if i["uid"] in uid_fix:
                unit_id, status = uid_fix[i["uid"]]
                # never downgrade an already-applied fix to partial/skipped from a later overlapping unit
                if i.get("fixStatus") == "applied" and status != "applied":
                    continue
                i["disposition"] = f"{tier}:{status}:{unit_id}"
                i["fixStatus"] = status
                i["fixedBy"] = unit_id
                i["fixTier"] = tier
                units.add(unit_id)
                statuses.append(status)
                changed += 1
        if units:
            applied = sum(1 for s in statuses if s == "applied")
            partial = sum(1 for s in statuses if s == "partial")
            tag = f"{tier}: {applied} applied" + (f", {partial} partial" if partial else "")
            row["fixStatus"] = (row.get("fixStatus") + " | " if row.get("fixStatus") else "") + tag
            row["fixNotes"] = (row.get("fixNotes") + " | " if row.get("fixNotes") else "") + f"{tier}: " + "; ".join(sorted(units))
    data["meta"]["phase"] = f"3-applied-{tier}"
    save(data)
    render()
    return {"changedIssues": changed, "unitsApplied": sum(1 for s in status_by_unit.values() if s == "applied"),
            "unitsPartial": sum(1 for s in status_by_unit.values() if s == "partial")}


def merge_gapfill(output_file):
    """Record gap-fill per-uid dispositions (fixed / deferred / skipped-already-resolved)."""
    wrapper = json.loads(open(output_file, encoding="utf-8").read())
    res = wrapper.get("result", wrapper)
    if isinstance(res, str):
        res = json.loads(res)
    action = {}
    reason = {}
    for r in res.get("results", []):
        for it in r.get("items", []):
            action[it["uid"]] = it["action"]
            reason[it["uid"]] = it.get("reason", "") or it.get("summary", "")
    data = load()
    changed = 0
    for row in data["rows"]:
        for i in row.get("issues", []):
            a = action.get(i["uid"])
            if not a:
                continue
            changed += 1
            if a == "fixed":
                i["fixStatus"] = "applied"
                i["fixedBy"] = "gapfill"
                i["fixTier"] = "gapfill"
                i["disposition"] = "gapfill:fixed"
            elif a == "skipped":
                i["fixStatus"] = "applied"
                i["fixedBy"] = "earlier-tier"
                i["disposition"] = "gapfill:already-resolved"
            elif a == "deferred":
                i["disposition"] = "deferred:" + (reason.get(i["uid"], "")[:200])
    save(data)
    render()
    return {"changed": changed}


def merge_retest(output_file):
    """Record phase-4 retest verdicts onto rows and emit docs/phase4-followups.json."""
    import os as _os
    wrapper = json.loads(open(output_file, encoding="utf-8").read())
    res = wrapper.get("result", wrapper)
    if isinstance(res, str):
        res = json.loads(res)
    canon = {}
    for base in ("Sources", "Tests"):
        for dp, _, fs in _os.walk(_os.path.join(ROOT, base)):
            for f in fs:
                if f.endswith(".swift"):
                    canon.setdefault(f, _os.path.relpath(_os.path.join(dp, f), ROOT))

    def file_of(ref):
        if not ref:
            return ""
        tok = str(ref).split(":")[0].split(" ")[0].strip()
        return canon.get(_os.path.basename(tok), tok)

    verdict_by_id = {}
    followups = []
    for a in res.get("areas", []):
        for s in a.get("storyResults", []):
            verdict_by_id[s["id"]] = s["retestVerdict"]
            for ni in s.get("newIssues", []):
                followups.append({"source": "story", "storyId": s["id"], "file": file_of(ni.get("codeRef")), **ni})
            for uid in s.get("fixedNotConfirmed", []):
                followups.append({"source": "unconfirmed-fix", "storyId": s["id"], "uid": uid,
                                  "severity": "low", "type": "unresolved-fix",
                                  "title": f"fix for {uid} not confirmed in code", "detail": "", "codeRef": "",
                                  "file": "", "suggestedFix": "re-apply / complete the fix"})
    for dd in res.get("diffs", []):
        for r in dd.get("regressions", []):
            followups.append({"source": "diff", "target": dd.get("target"), "file": file_of(r.get("codeRef")), **r})

    data = load()
    for row in data["rows"]:
        v = verdict_by_id.get(row["id"])
        if v:
            row["retestStatus"] = {"pass": "PASS", "fail-fix-not-resolved": "FAIL (fix not resolved)",
                                   "regression": "REGRESSION"}.get(v, v)
    data["meta"]["phase"] = "4-retested"
    data["meta"]["phase4"] = {
        "pass": sum(1 for v in verdict_by_id.values() if v == "pass"),
        "failFix": sum(1 for v in verdict_by_id.values() if v == "fail-fix-not-resolved"),
        "regression": sum(1 for v in verdict_by_id.values() if v == "regression"),
        "followupCount": len(followups),
    }
    save(data)
    with open(_os.path.join(ROOT, "docs", "phase4-followups.json"), "w", encoding="utf-8") as f:
        json.dump({"followups": followups}, f, indent=2, ensure_ascii=False)
    render()
    return data["meta"]["phase4"], Counter(f.get("file") for f in followups)


def merge_iter2(output_file):
    """Record the deferred-reduction pass (fixed / still-deferred / skipped)."""
    wrapper = json.loads(open(output_file, encoding="utf-8").read())
    res = wrapper.get("result", wrapper)
    if isinstance(res, str):
        res = json.loads(res)
    action, reason, cat = {}, {}, {}
    for r in res.get("results", []):
        for it in r.get("items", []):
            action[it["uid"]] = it["action"]
            reason[it["uid"]] = it.get("reason", "") or it.get("summary", "")
            cat[it["uid"]] = it.get("deferCategory", "")
    data = load()
    changed = 0
    for row in data["rows"]:
        for i in row.get("issues", []):
            a = action.get(i["uid"])
            if not a:
                continue
            changed += 1
            if a == "fixed":
                i["fixStatus"] = "applied"
                i["fixedBy"] = "iter2-deferred-reduction"
                i["fixTier"] = "iter2"
                i["disposition"] = "iter2:fixed"
            elif a == "still-deferred":
                c = cat.get(i["uid"]) or "needs-user-decision"
                i["disposition"] = f"deferred:{c}:" + (reason.get(i["uid"], "")[:160])
    data["meta"]["phase"] = "iter2-deferred-reduced"
    save(data)
    render()
    return {"changed": changed}


def stats():
    data = load()
    rows = data["rows"]
    print("Phase:", data["meta"].get("phase"))
    print("Total rows:", len(rows))
    print("Impl status:", dict(Counter(r["implStatus"] for r in rows)))
    print("Test status:", dict(Counter(r["testStatus"] for r in rows)))
    print("Fix status:", dict(Counter(r["fixStatus"] for r in rows if r["fixStatus"])))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "render"
    if cmd == "ingest":
        d = ingest(sys.argv[2])
        print("Ingested", d["meta"]["totalStories"], "rows. Impl dist:", d["meta"]["implDist"])
    elif cmd == "merge_phase2":
        m = merge_phase2(sys.argv[2])
        print("Merged phase 2:", m)
    elif cmd == "merge_apply":
        m = merge_apply(sys.argv[2], sys.argv[3])
        print("Merged apply:", m)
    elif cmd == "merge_gapfill":
        m = merge_gapfill(sys.argv[2])
        print("Merged gapfill:", m)
    elif cmd == "merge_iter2":
        m = merge_iter2(sys.argv[2])
        print("Merged iter2:", m)
    elif cmd == "render":
        render()
    elif cmd == "stats":
        stats()
    else:
        print(__doc__)
        sys.exit(1)
