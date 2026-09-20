#!/usr/bin/env python3
"""Writes the invented notes and dictation log that `demo-data.sh` puts in place.

Everything here is fiction: the meetings never happened, the people do not exist, and
the company is made up. What is *not* fiction is the file format — these are written
exactly as `MeetingTranscript.markdown` and `HistoryStore` write them, front matter,
headings, speaker turns and all, so the app parses them without knowing the difference.
If either format changes, this file changes with it or the screenshots start lying.

Dates are relative to the moment it runs, so the list always looks current: a note
timestamped last March reads as an abandoned app.
"""

import json
import os
import uuid
from datetime import datetime, timedelta, timezone

NOTES_DIR = os.environ["NOTES_DIR"]
HISTORY_FILE = os.environ["HISTORY_FILE"]

NOW = datetime.now().astimezone()


def at(days_ago, hour, minute):
    """A local wall-clock time, N days back — what the filename and the UI both show."""
    day = NOW - timedelta(days=days_ago)
    return day.replace(hour=hour, minute=minute, second=0, microsecond=0)


def iso(moment):
    """`ISO8601DateFormatter` with `.withInternetDateTime` — no fractional seconds."""
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clock(seconds):
    """`mm:ss`, or `h:mm:ss` past the hour — `MeetingTranscript.clock`."""
    total = int(seconds)
    if total >= 3600:
        return f"{total // 3600}:{(total % 3600) // 60:02d}:{total % 60:02d}"
    return f"{total // 60}:{total % 60:02d}"


# ---------------------------------------------------------------------------
# Notes
# ---------------------------------------------------------------------------

# (start, end, speaker, text). Seconds from the top of the meeting.
MEETINGS = [
    dict(
        when=at(0, 9, 32),
        title="Standup",
        duration=11 * 60 + 40,
        cleanup="Meeting notes",
        note="""**Decisions**

- The migration ships behind a flag; default off until Thursday.
- Nils picks up the failing snapshot suite.

**Next**

- [ ] Ava — draft the release note
- [ ] Sam — confirm the staging window with infra""",
        own_notes=None,
        turns=[
            (4, 19, "Them", "Right, quick one. Ava, where did the migration land?"),
            (
                20,
                48,
                "You",
                "It's merged but behind a flag. I'd rather leave it off until Thursday "
                "so we're not debugging it over the weekend.",
            ),
            (49, 61, "Them", "Fine by me. Anything blocking?"),
            (
                62,
                95,
                "You",
                "Only the snapshot suite — three of them go red on the new renderer and "
                "I haven't looked at why yet.",
            ),
            (96, 118, "Them", "Nils can take that. He wrote most of them."),
            (
                119,
                160,
                "You",
                "Then I'll write the release note today and we can sit on it until the "
                "flag flips.",
            ),
        ],
    ),
    dict(
        when=at(0, 14, 5),
        title="Design review — onboarding",
        duration=47 * 60 + 12,
        cleanup="Meeting notes",
        note="""The second permission screen is the drop-off, not the first.

**Agreed**

- Ask for the microphone at the moment of first use, not on page two.
- Screen Recording gets its own page with an explanation, because nobody reads a
  system prompt that says "record your screen" and thinks "meeting audio".
- The model download moves to the background; onboarding no longer waits on it.

**Open**

- Whether to keep the sample dictation step at all. Sam thinks it's the only part
  people remember; Ava thinks it's the part they skip.""",
        own_notes="""ask again about the copy on page 3 — "grant" reads legal
check the drop-off number before we redesign anything""",
        turns=[
            (
                6,
                42,
                "Them",
                "So the funnel says we lose about a third of people between page two "
                "and page three. Page two is where we ask for Accessibility.",
            ),
            (
                43,
                88,
                "You",
                "Which is the one that sounds worst and explains itself least. The "
                "system dialog just says the app wants to control your computer.",
            ),
            (89, 104, "Them", "Can we move it later?"),
            (
                105,
                168,
                "You",
                "We can ask at first use. You hold the hotkey, and the prompt appears "
                "with the thing you were trying to do still on screen. That's the only "
                "moment it makes sense.",
            ),
            (
                169,
                210,
                "Them",
                "I like that. Same for Screen Recording? That one's even stranger out "
                "of context.",
            ),
            (
                211,
                272,
                "You",
                "Screen Recording needs its own page either way. It's how macOS files "
                "the system-audio grant, so it's not really about the screen, but "
                "nobody can be expected to know that.",
            ),
            (
                273,
                316,
                "Them",
                "And the model download? Sitting through six hundred megabytes on page "
                "four is a long time to look at a progress bar.",
            ),
            (
                317,
                372,
                "You",
                "Background it. Onboarding finishes, the download keeps going, and the "
                "first dictation waits if it has to.",
            ),
        ],
    ),
    dict(
        when=at(1, 11, 0),
        title="Pricing call — Harbor",
        duration=32 * 60 + 55,
        cleanup="Meeting notes",
        note="""Harbor want per-seat, annual, invoiced. Forty seats to start, "probably
sixty by spring".

**Sticking points**

- They need the transcript to never leave their network. Local clean-up covers it —
  point them at the Ollama setup.
- Procurement wants a signed DPA before a trial, not after.

**Next**

- [ ] Send the local-only configuration guide
- [ ] Ask legal for the DPA template""",
        own_notes=None,
        turns=[
            (
                8,
                52,
                "Them",
                "The thing our security team will ask first is where the audio goes. "
                "If the answer is a server we don't run, this gets difficult.",
            ),
            (
                53,
                112,
                "You",
                "The audio doesn't go anywhere — transcription runs on the machine. The "
                "only thing that can leave is the text, and only if you configure a "
                "clean-up provider. Point it at your own model and nothing leaves at "
                "all.",
            ),
            (113, 131, "Them", "Our own model meaning what, exactly?"),
            (
                132,
                190,
                "You",
                "Anything that speaks the OpenAI chat API. Ollama on a machine in your "
                "network, LM Studio on the laptop itself. You paste the URL and that's "
                "the whole setup.",
            ),
            (
                191,
                233,
                "Them",
                "That would probably clear it. Forty seats to start, and I'd want "
                "annual invoicing rather than cards.",
            ),
        ],
    ),
    dict(
        when=at(2, 16, 20),
        title="1:1",
        duration=25 * 60 + 8,
        cleanup=None,
        note=None,
        own_notes=None,
        turns=[
            (5, 31, "Them", "How's the week been? Honestly."),
            (
                32,
                84,
                "You",
                "Long. I spent two days on a layout bug that turned out to be one "
                "wrong alignment guide, and I'm still annoyed about it.",
            ),
            (85, 99, "Them", "Did it teach you anything?"),
            (
                100,
                148,
                "You",
                "That I should have looked at the thing instead of reasoning about it. "
                "The arithmetic was right the whole time.",
            ),
        ],
    ),
    dict(
        when=at(4, 10, 0),
        title="Roadmap — Q4",
        duration=61 * 60 + 30,
        cleanup="Meeting notes",
        note="""Three things, in order. Anything else is next year.

1. **Windows.** The speech stack is the whole question; the UI is a rewrite either way.
2. **Shared vocabulary.** Per-team word lists, synced from a file. No account needed.
3. **Meeting search.** The notes are Markdown on disk, so this is an index, not a
   database.

Explicitly not doing: a web app, a mobile client, real-time translation.""",
        own_notes="""push back on Windows if the speech story isn't settled by Oct
search is the one people actually ask for""",
        turns=[
            (
                12,
                68,
                "Them",
                "Every conversation this quarter ended with someone asking for Windows. "
                "I want to know what it actually costs before we promise it.",
            ),
            (
                69,
                142,
                "You",
                "The interface is a rewrite whichever way we go — that part I can "
                "estimate. What I can't estimate is the speech stack. We're on the "
                "Neural Engine, and there isn't a clean equivalent.",
            ),
            (143, 166, "Them", "So the answer is we don't know yet."),
            (
                167,
                228,
                "You",
                "The answer is give me two weeks to try it on one machine, and then "
                "I'll have a number instead of a feeling.",
            ),
            (
                229,
                290,
                "Them",
                "Meanwhile, search. Three customers this month asked how to find a "
                "meeting from six weeks ago.",
            ),
            (
                291,
                348,
                "You",
                "That one's cheap, because the notes are already files. It's an index "
                "over a folder, not a migration.",
            ),
        ],
    ),
    dict(
        when=at(6, 15, 30),
        title="Bug triage",
        duration=18 * 60 + 44,
        cleanup="Meeting notes",
        note="""Eleven open, four closed as not-a-bug.

**Real**

- Panel drifts one pixel per display change on a mixed-DPI setup.
- Hotkey stops firing after the Mac sleeps with an external keyboard attached.
- Clean-up silently falls back to raw when the provider 429s — should say so.

**Not a bug**

- "Notes folder is empty" — the person had moved it in Finder. The app follows
  the folder, not the path, and that surprised them. Worth a line in the docs.""",
        own_notes=None,
        turns=[
            (
                7,
                46,
                "Them",
                "Start with the hotkey one. Two reports now, both with external "
                "keyboards.",
            ),
            (
                47,
                102,
                "You",
                "It's the event tap going stale after sleep. macOS disables it and "
                "doesn't tell you. We should re-arm on wake rather than trusting it.",
            ),
            (103, 124, "Them", "Is that a one-liner or a week?"),
            (
                125,
                163,
                "You",
                "A one-liner to re-arm, a week to be sure we didn't create a duplicate "
                "tap every time the lid opens.",
            ),
        ],
    ),
]


def escape(value):
    """`NoteFile.escape`. A colon or a leading quote breaks the `key: value` shape.

    Not hypothetical: one of the meetings below is called "1:1".
    """
    if ":" in value or value.startswith('"') or value.startswith("'"):
        return '"' + value.replace('"', '\\"') + '"'
    return value


def front_matter(title, when, duration, cleanup=None, note=None):
    """`NoteFile.frontMatter`. Order matters: the parser is lenient, a diff is not."""
    lines = [
        "---",
        f"title: {escape(title)}",
        f"date: {iso(when)}",
        f"duration: {int(duration)}",
    ]
    if cleanup:
        lines.append(f"cleanup: {escape(cleanup)}")
    if note:
        lines.append(f"note: {escape(note)}")
    lines.append("---")
    return "\n".join(lines)


def markdown(meeting):
    """`MeetingTranscript.markdown`, reproduced."""
    lines = [
        front_matter(
            meeting["title"],
            meeting["when"],
            meeting["duration"],
            meeting["cleanup"],
            "Meeting notes" if meeting["note"] else None,
        ),
        "",
        f"# {meeting['title']}",
        "",
    ]
    if meeting["note"]:
        lines += [meeting["note"], ""]
    if meeting["own_notes"]:
        lines += ["## My notes", "", meeting["own_notes"], ""]
    if meeting["note"] or meeting["own_notes"]:
        lines += ["## Transcript", ""]
    for start, _end, speaker, text in meeting["turns"]:
        lines += [f"**{speaker}** · `{clock(start)}`", "", text, ""]
    return "\n".join(lines)


written = 0
for meeting in MEETINGS:
    name = meeting["when"].strftime("%Y-%m-%d %H-%M") + " Meeting.md"
    with open(os.path.join(NOTES_DIR, name), "w", encoding="utf-8") as handle:
        handle.write(markdown(meeting))
    written += 1
print(f"  \033[32m✓\033[0m {written} notes → {NOTES_DIR}")


# ---------------------------------------------------------------------------
# Dictation history
# ---------------------------------------------------------------------------

# (minutes ago, seconds of speech, app name, bundle id, text). The durations are set so
# the words-per-minute figures land where a real person's do — roughly 140 to 170.
DICTATIONS = [
    (
        14,
        11.4,
        "Slack",
        "com.tinyspeck.slackmacgap",
        "Pushed the flag change — it's off by default, so nothing moves until we flip "
        "it on Thursday. Shout if staging looks wrong.",
    ),
    (
        38,
        23.8,
        "Mail",
        "com.apple.mail",
        "Thanks for the call this morning. I've attached the guide for pointing "
        "clean-up at your own model, which is the configuration where nothing at all "
        "leaves your network. Happy to walk your security team through it if that's "
        "easier than reading it.",
    ),
    (
        52,
        8.2,
        "Xcode",
        "com.apple.dt.Xcode",
        "Re-arm the event tap on wake. macOS disables it after sleep without telling us.",
    ),
    (
        96,
        17.1,
        "Linear",
        "com.linear",
        "Panel drifts a pixel per display change on a mixed-DPI setup. Reproduces by "
        "moving the window between the laptop screen and the external one twice.",
    ),
    (
        140,
        13.6,
        "Notes",
        "com.apple.Notes",
        "Look at the thing instead of reasoning about it. Every layout bug so far was "
        "found by eye and missed by arithmetic.",
    ),
    (
        188,
        6.9,
        "Safari",
        "com.apple.Safari",
        "local first dictation macos neural engine benchmark",
    ),
    (
        244,
        29.3,
        "Slack",
        "com.tinyspeck.slackmacgap",
        "Summary of the design review: the microphone prompt moves to first use, Screen "
        "Recording gets its own page because the system dialog is misleading on its "
        "own, and the model download goes to the background so onboarding stops "
        "waiting on it. The sample dictation step is still up for debate.",
    ),
    (
        310,
        9.7,
        "Mail",
        "com.apple.mail",
        "Can you send over the DPA template? Procurement wants it signed before the "
        "trial rather than after.",
    ),
    (
        1_420,
        15.2,
        "Xcode",
        "com.apple.dt.Xcode",
        "The file is the source of truth, not a database. Edit a note in any editor and "
        "the app re-reads it.",
    ),
    (
        1_610,
        11.0,
        "Slack",
        "com.tinyspeck.slackmacgap",
        "Taking the snapshot suite off Nils — I broke them, I'll fix them.",
    ),
    (
        2_890,
        21.5,
        "Notes",
        "com.apple.Notes",
        "Two weeks on one machine to find out what the speech stack costs on Windows. "
        "After that I'll have a number instead of a feeling, and we can promise "
        "something or stop talking about it.",
    ),
    (
        3_020,
        7.8,
        "Safari",
        "com.apple.Safari",
        "How long does an on-device Parakeet model take to load on an M-series Mac?",
    ),
]

records = []
for minutes_ago, duration, app, bundle, text in DICTATIONS:
    records.append(
        {
            "id": str(uuid.uuid4()).upper(),
            "date": iso(NOW - timedelta(minutes=minutes_ago)),
            "audioDuration": duration,
            "rawText": text,
            "finalText": text,
            "usedRawFallback": False,
            "promptName": "Default",
            "targetAppName": app,
            "targetBundleID": bundle,
        }
    )

# Oldest first: the log is appended to and never rewritten, so that is the order a
# real file is in.
records.sort(key=lambda record: record["date"])

os.makedirs(os.path.dirname(HISTORY_FILE), exist_ok=True)
with open(HISTORY_FILE, "w", encoding="utf-8") as handle:
    for record in records:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
print(f"  \033[32m✓\033[0m {len(records)} dictations → {HISTORY_FILE}")
