# Cowork

Cowork is TurboCode's multi-purpose mode. It works on things beyond Swift
development, such as React and other web apps, Python scripts and data
processing, documents, rendered pages, and screenshots, inside an isolated
Linux virtual machine. Coding and Cowork are peers: TurboCode without the VM
remains a complete local-LLM harness.

## Enable Cowork

Open **Settings › Cowork** and turn on **Enable Cowork**. After you confirm,
TurboCode downloads about 760 MB (a Linux kernel and a Debian 12 image) and
uses about 2.2 GB of disk space. Installation takes a few minutes and verifies
the guest with its own self-test, including a headless Chromium render with the
browser sandbox enabled. Cowork requires a Mac with Apple silicon.

The same tab sets processors, memory, and network access for the VM, resets the
VM, and removes Cowork completely.

## Start a Cowork session

Use the **Coding | Cowork** switch at the top of the sidebar. In Cowork, New
Chat creates a Cowork session and the list shows only Cowork sessions. Each
session belongs to exactly one mode for its whole life.

Cowork works with the on-device, Llama, and DeepSeek profiles. Codex runs its
own shell on the Mac, so it is not available in Cowork.

## What the agent can do

The VM is a Debian 12 system with Node.js 24, Python 3.11, headless Chromium,
`rg`, `fd`, `jq`, `git`, and compilers. The agent uses three tools:

- `vm_exec` runs commands in the VM as an unprivileged user.
- `vm_file` reads, writes, and lists files; writes appear in the chat as a diff.
- `vm_export` reports the finished files waiting for your review.

Each session has its own working directory in the VM. The VM itself is shared
by all Cowork sessions and keeps installed packages until you reset it.

## Share a folder

Use the folder menu in the toolbar to share one Mac folder with the session.
The VM sees it at `/work` and can read it but never change it. Sharing your
whole disk or home folder is refused. Without a shared folder the VM sees
nothing of your Mac.

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
