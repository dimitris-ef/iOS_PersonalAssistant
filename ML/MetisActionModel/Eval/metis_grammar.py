"""Python port of Sources/AIProviderLocal/Semantic/SemanticActionGrammar.swift
and the action system prompt, for evaluating a model off-device.

Written line-for-line against the Swift so the output string is identical.
`gbnf(relaxed_changes=True)` is the proposed fix for Problem 1: requestedChanges
keys may appear in any order, each at most once. Everything else is unchanged.
"""
from itertools import permutations

# LocalSemanticField.allCases order — the order `ordered(_:)` uses.
FIELD_ORDER = ["title", "timeExpression", "content", "targetDescription",
               "durationExpression", "locationExpression"]

# LocalSemanticIntent.allCases filtered to isAction — LocalSemanticActionSchema.universal.
INTENTS = ["reminder.create", "memory.store", "task.create", "task.complete",
           "calendar.create", "calendar.update"]

# LocalSemanticContract.contract(for:)
CONTRACTS = {
    "reminder.create": (["title", "timeExpression"], [], []),
    "memory.store":    (["content"], [], []),
    "task.create":     (["title"], ["timeExpression"], []),
    "task.complete":   (["targetDescription"], [], []),
    "calendar.create": (["title", "timeExpression"], ["durationExpression", "locationExpression"], []),
    "calendar.update": (["targetDescription"], [], ["timeExpression", "durationExpression",
                                                    "locationExpression", "title"]),
}

def ordered(fields):
    return [f for f in FIELD_ORDER if f in fields]

def rule_name(intent):
    return intent.replace(".", "-")

def key(name):
    return '"\\"' + name + '\\""'

literal = key

def pair(field):
    return key(field) + ' ws ":" ws string'

def arguments_rule(intent):
    req, opt, _ = CONTRACTS[intent]
    required, optional = ordered(req), ordered(opt)
    if not required:
        return '"{" ws "}"'
    body = ' ws "," ws '.join(pair(f) for f in required)
    for f in optional:
        body += ' ( ws "," ws ' + pair(f) + ' )?'
    return '"{" ws ' + body + ' ws "}"'

def at_least_one(fields):
    """The app's rule: one alternative per possible first field, later fields optional, fixed order."""
    alternatives = []
    for i, f in enumerate(fields):
        alt = pair(f)
        for later in fields[i + 1:]:
            alt += ' ( ws "," ws ' + pair(later) + ' )?'
        alternatives.append(alt)
    return "( " + " | ".join(alternatives) + " )"

def any_order_at_least_one(fields):
    """Proposed fix: every non-empty ordering of distinct fields (64 alternatives for 4)."""
    alternatives = []
    for k in range(1, len(fields) + 1):
        for perm in permutations(fields, k):
            alternatives.append(' ws "," ws '.join(pair(f) for f in perm))
    return "( " + " | ".join(alternatives) + " )"

def rules(intent, relaxed_changes):
    name = rule_name(intent)
    members = [
        key("intent") + ' ws ":" ws ' + literal(intent),
        '"," ws ' + key("arguments") + ' ws ":" ws ' + name + "-args",
    ]
    extra = []
    changeable = ordered(CONTRACTS[intent][2])
    if changeable:
        members.append('"," ws ' + key("requestedChanges") + ' ws ":" ws ' + name + "-changes")
        body = any_order_at_least_one(changeable) if relaxed_changes else at_least_one(changeable)
        extra.append(name + '-changes ::= "{" ws ' + body + ' ws "}"')
    return [
        name + ' ::= "{" ws ' + " ws ".join(members) + ' ws "}"',
        name + "-args ::= " + arguments_rule(intent),
    ] + extra

JSON_PRIMITIVES = [
    'string ::= "\\"" char* "\\""',
    'char ::= [^"\\\\] | "\\\\" ["\\\\/bfnrt]',
    'ws ::= [ \\t\\n]{0,2}',
]

def gbnf(relaxed_changes=False):
    lines = ["root ::= action",
             "action ::= " + " | ".join(rule_name(i) for i in INTENTS),
             ""]
    for intent in INTENTS:
        lines += rules(intent, relaxed_changes)
        lines.append("")
    lines += JSON_PRIMITIVES
    return "\n".join(lines) + "\n"

# ---- the app's action prompt (SemanticActionGenerator.actionSystemPrompt) ----

MODEL_FACING = {
    "reminder.create": "Create a future reminder. Fields: title, timeExpression.",
    "memory.store": "Store a lasting fact about the user. Field: content.",
    "task.create": "Create a task. Fields: title, optional timeExpression.",
    "task.complete": "Complete an existing task. Field: targetDescription.",
    "calendar.create": "Create a calendar event. Fields: title, timeExpression.",
    "calendar.update": "Change an existing event. Fields: targetDescription, requestedChanges.",
}

REMINDER_EXAMPLE = ('{"intent":"reminder.create","arguments":'
                    '{"title":"change the bottles","timeExpression":"in 10 minutes"}}')

RULES = (
    "Rules:\n"
    "- Use only the fields listed for the intent. There are no other fields.\n"
    "- Never write dates, times or identifiers. Put the person's own words in "
    "timeExpression (\"in 10 minutes\", \"tomorrow at 3\") and let the app work "
    "out the date.\n"
    "- Never invent a title, a note, a list or a reason. If they did not say "
    "it, leave it out.\n"
    "- To change or finish something that already exists, describe it in "
    "targetDescription in the person's words. The app finds it.\n"
    "- If no action is needed, reply with ordinary text and no JSON."
)

def instructions():
    lines = ["## Actions", "",
             "When the person asks you to do something, reply with a single JSON object "
             "and nothing else. The app carries the action out; you never do.",
             "", "Intents:"]
    for intent in INTENTS:
        lines.append(f"- {intent}: {MODEL_FACING[intent]}")
    lines += ["", "Example:", REMINDER_EXAMPLE, "", RULES]
    return "\n".join(lines)

ACTION_SYSTEM_PROMPT = (
    "You turn a person's request into one action for the app to carry out. "
    "Reply with the JSON object and nothing else.\n\n" + instructions()
)

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "prompt":
        print(ACTION_SYSTEM_PROMPT)
    else:
        print(gbnf(relaxed_changes=len(sys.argv) > 1 and sys.argv[1] == "relaxed"), end="")
