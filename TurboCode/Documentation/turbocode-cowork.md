# Studio

Studio is TurboCode's multi-purpose mode. It works on things beyond Swift
development, such as React and other web apps, Python scripts and data
processing, documents, rendered pages, and screenshots, inside an isolated
Linux virtual machine. Coding and Studio are peers: TurboCode without the VM
remains a complete local-LLM harness.

## Enable Studio

Open **Settings › Studio** and turn on **Enable Studio**. After you confirm,
TurboCode downloads about 760 MB (a Linux kernel and a Debian 12 image) and
uses about 2.2 GB of disk space. Installation takes a few minutes and verifies
the guest with its own self-test, including a headless Chromium render with the
browser sandbox enabled. Studio requires a Mac with Apple silicon.

The same tab sets processors, memory, and network access for the VM, resets the
VM, and removes Studio completely.

## Start a Studio session

Use the **Coding | Studio** switch at the top of the sidebar. In Studio, New
Chat creates a Studio session and the list shows only Studio sessions. Each
session belongs to exactly one mode for its whole life.

A new Studio session opens on a home view. Its cards name what Studio is good
at (web pages and apps, data and scripts, documents, your files) and each one
starts a draft in the message field for you to finish; nothing is sent until
you send it. Once earlier sessions have produced files, the latest artifacts
appear above the cards and open the session that made them.

Studio works with the on-device, Llama, and DeepSeek profiles. Codex runs its
own shell on the Mac, so it is not available in Studio.

## Connectors

**Connectors** in the sidebar lists the built-in connectors. Turn one on to let
the current session work with that app, for example to block out a sculpture in
Prassitele. A connector is off until you turn it on, the choice belongs to that
session only, and it cannot be changed while the agent is working. The app must
be running on this Mac with its MCP server on; the page shows whether it
answers. A connector gives the model that app's own operations and nothing
else: it is not a way out of the VM for commands or files.

You can also turn a connector on from the home view of a new Studio session,
before writing the first message. A connector may bring a skill with it:
Prassitele adds `prassitele-sculpting`, its method for blocking out a head or a
bust. The skill is only made available; the model loads it when a request
calls for it.

## What the agent can do

The VM is a Debian 12 system with Node.js 24, Python 3.11, headless Chromium,
`rg`, `fd`, `jq`, `git`, and compilers. The agent uses four tools:

- `vm_exec` runs commands in the VM as an unprivileged user.
- `vm_file` reads, writes, and lists files; writes appear in the chat as a diff.
- `vm_export` reports the finished files waiting for your review.
- `vm_view_image` lets a model with vision look at a screenshot or picture it
  created or downloaded in the VM.

Each session has its own working directory in the VM. The VM itself is shared
by all Studio sessions and keeps installed packages until you reset it.

## Share a folder

Use **Share a folder** under the message field to share one Mac folder with
the session; once shared, the same menu shows the folder name.
The VM sees it at `/work` and can read it but never change it. Sharing your
whole disk or home folder is refused. Without a shared folder the VM sees
nothing of your Mac.

## Look at the work

**Artifacts** in the sidebar opens a grid with one card for each Studio session
that placed files in `/out`. The card shows the session's main file, usually
its web page, and says how many files came with it. Choose a card to preview
that file at full size; the strip under the preview reaches the session's other
files, and **Show in Session** returns to the chat that made them. The card's
context menu has **Open Session** as well. The Artifacts button in the
toolbar shows the active session's files in the inspector beside the chat, and
follows new files as the agent creates them.

The inspector also lists servers the agent left running in the VM, marked
**Live**, and opens them as a page. A server appears only when it listens on
`0.0.0.0`; ask the agent to start it that way if it is missing.

Looking at an artifact never copies it to your Mac.

## Get the results

The agent puts finished files in `/out`. When files are waiting, the composer
shows **N in /out · Review & Export**. The review lists every file and copies
nothing until you choose **Export**:

- New files are selected; existing files are skipped unless you choose
  **Replace** or **Keep Both**, and text conflicts can be compared with **Diff**.
- `node_modules`, virtual environments, `.git`, and symbolic links are never
  exported.
- Files that changed after you reviewed them are reported, not copied.
- Exported files are not executable and carry the macOS quarantine attribute.

## Safety summary

- Commands run only inside the VM; there is no fallback to the Mac shell.
- Your folders are read-only to the VM; results arrive only through your review.
- No API keys, Keychain items, SSH keys, or Mac environment variables enter the
  VM.
- Resetting the VM discards everything the agent changed inside it; your
  sessions and Mac files are not affected.
