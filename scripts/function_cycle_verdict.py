"""Pure completion decision. Missing, repeated or failed evidence cannot pass."""


def evaluate(requirements, events, exit_code):
    checks = []
    for key, description in requirements.items():
        observed = [event for event in events if event.get("id") == key]
        passed = len(observed) == 1 and observed[0].get("status") == "PASS"
        checks.append({"id": key, "description": description,
                       "status": "PASS" if passed else "FAIL", "observations": observed})
    known = set(requirements)
    unexpected = [event for event in events if event.get("id") not in known]
    complete = bool(checks) and exit_code == 0 and not unexpected and all(
        check["status"] == "PASS" for check in checks)
    return {"status": "PASS" if complete else "FAIL", "complete": complete,
            "checks": checks, "unexpected": unexpected}
