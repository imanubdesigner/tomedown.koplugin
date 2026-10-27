# Remotely Save sync direction: which one to pick

**Remotely Save** — the Obsidian plugin that syncs your vault — has an
experimental setting called **Sync Direction**. It decides which side of
the sync is allowed to write, and what happens to deletions. This page
says which of its five options fits Tomedown, and where your edits
actually live.

The setting is free for every Remotely Save user: no PRO plan involved,
it sits right in the plugin's options under *Sync Direction
(experimental)*.

## The short answer

**Leave it on `Bidirectional (default)` and forget it.** Nothing in the
Tomedown flow asks for a different choice; the other four options exist
for other habits.

## Why it barely matters with Tomedown

Tomedown only ever **pushes**: an export uploads the book note and the
index into your cloud folder — it never downloads, never rewrites a
remote folder listing and never deletes anything. So the direction
setting really controls one thing: what *your side* (the vault behind
Remotely Save) is allowed to do back.

## The five options

The labels are Remotely Save's own wording:

| Remotely Save says | What it does | With Tomedown |
|---|---|---|
| **Bidirectional (default)** | Changes on both sides are synced to the other side. | **Keep this.** Exports flow in, your edits flow out. |
| **Incremental Push (aka backup mode)** | Locally created or modified files are copied to remote. | New exports from KOReader would **never arrive** in your vault: not useful for this flow. |
| **Incremental Pull** | Remotely created or modified files are copied to local. | A **read-only mirror**: exports arrive, but nothing you write in the vault is ever uploaded — and the next export replaces your local copy anyway. |
| **Incremental Push And Delete** | Locally created or modified files are copied to remote, **and local deletions run on remote too**. | Deleting a note from Obsidian deletes it in the cloud — then KOReader re-uploads it on the next export. Churn without a gain. |
| **Incremental Pull And Delete** | Remotely created or modified files are copied to local, **and remote deletions run on local too**. | **Avoid.** Cleaning the cloud folder from a browser or another device would wipe files inside your vault. |

## Warnings that apply to every option

- **Only changed files sync.** Remotely Save's own words: *"only CHANGED
  files (based on time and size) are synced regardless any option"* —
  picking a direction never makes it re-copy a whole folder.
- **Abort Sync If Modification Above Percentage → `100`.** Tomedown
  re-exports in bulk (first export, toggling *Include book covers*,
  migrations), which trips the default `50` guard; the vault is
  regenerated from KOReader at any time, so disabling the protection is
  safe. Configured in step 2 of the
  [Obsidian section](README.md#obsidian-optional).
- **Ignore `*.json`** in Remotely Save's *Ignore list* if AnnotationSync
  files share the folder, so only the notes reach the vault — see the
  [tutorial](TUTORIAL.md).
- **Your edits under the heading are merged, not overwritten**: an export
  folds its new render into the file already in your vault (and keeps a
  `.bak` next to it). See [Keep my notes](README.md#keep-my-notes).

## Where do your edits live?

**Setup A — the folder you chose *is* your vault.** The device folder
Tomedown writes to is the same one your editor watches (mounted, synced
or copied by hand). Edits are first class: the next export merges around
them, everything stays on one copy.

**Setup B — the vault lives behind the cloud.** KOReader never downloads,
so your edits stay on the remote/Obsidian side until something carries
them back into the device folder (USB, KOReader's cloud browser). Until
then the next export wins on the remote — Remotely Save will show it as a
conflict, and your vault receives the device version on the following
sync. Edit freely, but carry the file back before re-exporting if you
want the text to survive.

## See also

- [README — Obsidian (optional)](README.md#obsidian-optional): the full
  cloud setup, step by step.
- [TUTORIAL.md](TUTORIAL.md): the same flow in tutorial form.
- [Remotely Save](https://github.com/remotely-save/remotely-save): the
  plugin itself, where the setting lives.
