---
prompts:
  - prompt: "Our support inbox is connected to InboxParse. Store every email it receives in this app, as soon as InboxParse tells us about it, without missing any if a notification never arrives, and show each one on its own page."
    stack: In-memory store
  - prompt: "On each email page, let a signed-in teammate edit InboxParse's suggested reply and send it from our mailbox. A reply must never go out unless someone pressed send."
    stack: In-memory store
  - prompt: "Our InboxParse webhook endpoint keeps getting disabled and some emails never show up in the app. Find out why."
---

# Prompts

What an operator types after installing this skill, in their own words. An agent eval installs the skill
into an empty Next.js app, gives the agent one of these prompts and no further help, then type-checks, builds
and tests the result; the first prompt runs before every release. The results are the other files in this
folder. Section 10 of [STANDARD.md](https://github.com/timerise-ai/skills/blob/main/STANDARD.md) says how a
run is made. The prompts and the newest runs are on
[the skill's page](https://timerise.ai/skills/inboxparse) on timerise.ai.
