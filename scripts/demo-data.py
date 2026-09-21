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
    """A local wall-clock time, N days back — what the filename and the UI both show.

    Always in the past. A meeting at a fixed hour of *today* is in the future whenever
    the script runs before that hour, and a note dated later this afternoon is the one
    detail in a screenshot that tells everyone the data is fake. If the slot has not
    happened yet, it becomes the same time yesterday.
    """
    day = NOW - timedelta(days=days_ago)
    moment = day.replace(hour=hour, minute=minute, second=0, microsecond=0)
    while moment >= NOW:
        moment -= timedelta(days=1)
    return moment


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
    # Not a work meeting. The notetaker gets pointed at a call with a builder or a
    # doctor at least as often as at a standup, and a folder of nothing but sprint
    # ceremonies describes a narrower app than this one.
    dict(
        when=at(6, 18, 15),
        title="Call with the builder",
        duration=16 * 60 + 22,
        cleanup="Meeting notes",
        note="""**Quote**: €4,800 for the kitchen, materials included. Two and a half
weeks, starting the first Monday of next month.

**Watch**

- The €4,800 does not include the electrics. Separate trade, separate quote.
- He wants half up front. Ask whether a third is acceptable.

**Next**

- [ ] Get the electrician's number from him
- [ ] Measure the alcove properly before Friday""",
        own_notes="""half up front feels like a lot — ask around
he mentioned the neighbours' place, go and look at it""",
        turns=[
            (
                9,
                54,
                "Them",
                "So for the kitchen itself, taking out the old units, the plastering "
                "and putting the new run in, you're looking at four thousand eight "
                "hundred with materials.",
            ),
            (55, 71, "You", "And that includes the electrics?"),
            (
                72,
                126,
                "Them",
                "No, that's a separate trade. I can give you a number for the chap I "
                "use, but he'll quote you himself. It's usually six or seven hundred "
                "for a job this size.",
            ),
            (
                127,
                168,
                "You",
                "Right. And how long would the whole thing take, start to finish?",
            ),
            (
                169,
                232,
                "Them",
                "Two and a half weeks if nothing surprises us. I could start the first "
                "Monday of next month. I'd want half up front for the materials.",
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

# (minutes ago, seconds of speech, app name, bundle id, text).
#
# Two constraints that are easy to miss. **Length**: Home draws each of these on one
# line and truncates, so a paragraph shows as a wall of grey ending in an ellipsis —
# the rows have to be short enough to actually read. **Apps**: the icon is looked up by
# bundle id through `AppIconCache`, so an app that is not installed draws a generic
# placeholder and the row looks broken. These five are the ones on the machine the
# screenshots are taken from.
#
# The durations are set so the words-per-minute figures land where a real person's do,
# roughly 130 to 165. `demo-data-tests.swift` fails the build if any of them drifts
# somewhere implausible.
#
# **Half of these are not work.** A list of nothing but git commands and bug reports
# makes the app look like a developer tool, and it is not one — the person dictating a
# shopping list into Notes is the same person rebasing a branch. The lengths are mixed
# on purpose too: a row that truncates proves the list handles a real paragraph, and a
# row of four words proves it does not need one.
DICTATIONS = [
    # — everyday —
    (8, 2.6, "Brave Browser", "com.brave.Browser",
     "best ramen near gare du nord"),
    # — programming —
    (17, 7.2, "Claude", "com.anthropic.claudefordesktop",
     "Write a test that reads the demo notes back through the real parser, not a copy of it."),
    (29, 3.7, "Terminal", "com.apple.Terminal",
     "git rebase onto main and force push with lease"),
    # — everyday —
    (46, 1.8, "Notes", "com.apple.Notes",
     "Milk, olive oil, coffee."),
    # — programming —
    (64, 10.0, "Cursor", "com.todesktop.230313mzl4w4u92",
     "Re-arm the event tap on wake — macOS disables it after sleep without telling us, "
     "and we should not be trusting it to still be live."),
    # — everyday —
    (88, 11.8, "Mail", "com.apple.mail",
     "Thanks for having us on Saturday — the lamb was extraordinary and I am still "
     "thinking about that walnut thing. Let us return the favour in a couple of weeks."),
    (130, 5.6, "Notes", "com.apple.Notes",
     "Dentist Thursday at half four, and pick up the prescription on the way back."),
    # — programming —
    (190, 2.5, "Slack", "com.tinyspeck.slackmacgap",
     "Merged, flag is off until Thursday."),
    (260, 1.7, "Brave Browser", "com.brave.Browser",
     "swiftui imagerenderer vibrancy transparent"),
    # — everyday —
    (1_400, 9.5, "Mail", "com.apple.mail",
     "Sorry to miss the call — I am on a train with no signal until half past. Can we "
     "push to tomorrow morning?"),
    # — programming —
    (1_560, 9.3, "Claude", "com.anthropic.claudefordesktop",
     "Draft the release note for 0.3 — two fixes, the new notes pane, and say plainly "
     "that the builds are not notarized yet."),
    # — everyday —
    (2_900, 4.9, "Brave Browser", "com.brave.Browser",
     "How long should you rest between sets for strength rather than size?"),
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
