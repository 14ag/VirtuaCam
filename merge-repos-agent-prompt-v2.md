# Agent Prompt: Unify Two Repos into a Parent-Level Git Repository

## Context

You are working with two sibling repositories inside a shared parent folder:

```
parent-folder/
  driver-project/     <- kernel driver project (DirectShow COM filter DLL)
  software-project/   <- userland capture client
```

The goal is a single unified git repository rooted at `parent-folder/`, with
the full commit history of both projects preserved. The final layout will be:

```
parent-folder/
  .git/         <- unified repo, contains history from both projects
  driver-project/       <- driver source files, no .git folder
  software-project/     <- software source files, no .git folder
```

No source files are moved or deleted. All history manipulation is done on
throwaway clones. The original repos are only touched at one step: their `.git`
folders are removed after the unified repo absorbs their histories.

Read all phases before executing any command.

---

## Critical Constraint

Git will refuse to track the contents of `driver-project/` and `software-project/` from the
parent level as long as those directories contain their own `.git` folders. It
will treat them as nested repositories and ignore their contents entirely.

This means the `.git` folders inside `driver-project/` and `software-project/` MUST be removed
before the parent-level merge is performed. This is not optional. This step is
what makes the parent repo able to write files into those directories during
the merge.

The original repos are safe because throwaway clones are made before anything
is removed.

---

## Pre-flight Checklist

Stop and report if any item cannot be confirmed.

- [ ] Both repos have clean working trees: run `git status` inside each
- [ ] Both repos are on their default branch: note whether it is `main` or `master`
- [ ] `git filter-repo` is available: run `git filter-repo --version`
- [ ] Python 3 is available: run `python3 --version`
- [ ] You are operating from the parent folder: confirm with `pwd`

If `git filter-repo` is not installed:

```bash
pip install git-filter-repo
```

Confirm it is available before proceeding.

Record the default branch name of each repo. Substitute it wherever
`<branch>` appears in this document.

---

## Phase 1 — Conflict Audit

Goal: identify every file path that exists in both repos. This determines what
manual work is needed after the merge.

### Step 1.1 — Enumerate tracked files

Run from the parent folder:

```bash
git -C driver-project ls-files | sort > /tmp/driver-files.txt
git -C software-project ls-files | sort > /tmp/software-files.txt
```

### Step 1.2 — Find overlapping paths

```bash
comm -12 /tmp/driver-files.txt /tmp/software-files.txt > /tmp/conflicts.txt
cat /tmp/conflicts.txt
```

Common overlaps to watch for:

- `README.md`
- `.gitignore`
- `.gitattributes`
- `CMakeLists.txt` / `Makefile` / `meson.build`
- `LICENSE`
- `.github/workflows/*.yml`
- `src/main.c` or `src/main.cpp`
- Headers in `include/` with generic names

### Step 1.3 — Diff each overlapping file

```bash
while IFS= read -r f; do
  echo "=== $f ==="
  diff \
    <(git -C driver-project show HEAD:"$f" 2>/dev/null) \
    <(git -C software-project show HEAD:"$f" 2>/dev/null) || true
done < /tmp/conflicts.txt
```

Note: these paths will not collide at the git level after the merge because
driver files land under `driver-project/` and software files land under `software-project/`.
A file at `README.md` in the driver repo becomes `driver-project/README.md` in the
unified repo. The audit is for your awareness and for the build system
consolidation in Phase 6.

Produce this table before proceeding:

| File | Identical? | Resolution needed |
|------|-----------|-------------------|
| ...  | ...       | ...               |

---

## Phase 2 — Create Throwaway Clones and Rewrite Histories

Goal: produce two clones whose entire commit histories have been rewritten so
that all file paths are prefixed with their respective subdirectory names.

`git filter-repo` requires a fresh clone and will refuse to run on the original
repos. The clones are temporary and will be deleted at the end.

### Step 2.1 — Clone both repos

Run from the parent folder:

```bash
git clone --no-local driver-project  driver-project-rewrite
git clone --no-local software-project software-project-rewrite
```

### Step 2.2 — Rewrite the driver history

```bash
cd driver-project-rewrite
git filter-repo --to-subdirectory-filter driver-project
cd ..
```

Verify: every file path in the clone now starts with `driver-project/`

```bash
git -C driver-project-rewrite ls-files | head -20
```

### Step 2.3 — Rewrite the software history

```bash
cd software-project-rewrite
git filter-repo --to-subdirectory-filter software-project
cd ..
```

Verify: every file path starts with `software-project/`

```bash
git -C software-project-rewrite ls-files | head -20
```

---

## Phase 3 — Initialize the Unified Repo at Parent Level

Goal: create a fresh git repository at the parent folder.

### Step 3.1 — Init

```bash
git init
```

Run this from the parent folder (not from inside driver/ or software/).

### Step 3.2 — Make an empty initial commit

```bash
git commit --allow-empty -m "init: initialize unified monorepo"
```

This gives the repo a root commit to merge against. Without it, the first
`--allow-unrelated-histories` merge has nothing to attach to.

---

## Phase 4 — Remove the Nested .git Folders

Goal: allow the parent repo to see driver-project/ and software-project/ as ordinary
directories rather than nested repos.

This is the step that makes the merge possible. If skipped, the parent repo
will treat driver-project/ and software-project/ as submodules and the merge will not write
any files into them.

### Step 4.1 — Remove driver-project/.git

```bash
rm -rf driver-project/.git
```

### Step 4.2 — Remove software-project/.git

```bash
rm -rf software-project/.git
```

After this point, `driver-project/` and `software-project/` are plain folders. Their history
is fully preserved inside `driver-project-rewrite/` and `software-project-rewrite/`. The
original source files on disk are untouched.

---

## Phase 5 — Import and Merge Both Histories

Goal: bring the rewritten commit chains into the unified repo so that the
working tree at the parent level reflects both projects correctly.

### Step 5.1 — Import the driver history

```bash
git remote add driver-project-history ./driver-project-rewrite
git fetch driver-project-history
git merge driver-project-history/<branch> \
  --allow-unrelated-histories \
  --no-ff \
  -m "merge: absorb driver project history under driver-project/"
```

After this merge, run:

```bash
git status
git ls-files driver-project/ | head -20
```

Confirm: driver source files are tracked under `driver-project/`, working tree is clean.

### Step 5.2 — Import the software history

```bash
git remote add software-project-history ./software-project-rewrite
git fetch software-project-history
git merge software-project-history/<branch> \
  --allow-unrelated-histories \
  --no-ff \
  -m "merge: absorb software project history under software-project/"
```

After this merge, run:

```bash
git status
git ls-files software-project/ | head -20
```

Confirm: software source files are tracked under `software-project/`, working tree is clean.

---

## Phase 6 — Post-merge Integration

Goal: consolidate shared root-level concerns that now exist in duplicate
across the two subdirectories.

The file-level conflicts from Phase 1 are not git conflicts — they exist as
`driver-project/README.md` and `software-project/README.md` separately. The work here is
about creating unified root-level versions.

### Step 6.1 — Root .gitignore

Create or update a `.gitignore` at the parent root that covers patterns from
both projects. Start by reviewing both:

```bash
cat driver-project/.gitignore
cat software-project/.gitignore
```

Merge them into a single root `.gitignore`, removing exact duplicates and
grouping related patterns with comments. Keep the originals in their
subdirectories unless they are identical to the root version, in which case
they can be removed.

### Step 6.2 — Root README

Create a `README.md` at the parent root that introduces the unified repo and
links to the two sub-projects:

```markdown
# Virtual Camera

Unified repository for the kernel driver and userland capture client.

- [Driver](driver-project/README.md) — DirectShow COM filter DLL
- [Software](software-project/README.md) — capture client
```

### Step 6.3 — LICENSE

If both projects share the same license, create one `LICENSE` at the root.
If they differ, keep both as `driver-project/LICENSE` and `software-project/LICENSE` and
create a root `LICENSE` that states this explicitly. Do not delete a license
file silently.

### Step 6.4 — CI workflows

Rename any overlapping workflow files to prevent confusion:

```
driver-project/.github/workflows/ci.yml   -> driver-project/.github/workflows/driver-ci.yml
software-project/.github/workflows/ci.yml -> software-project/.github/workflows/software-ci.yml
```

Or create a single root `.github/workflows/` that calls jobs from both.

### Step 6.5 — Build system

If you want the parent root to build both projects together, add a root-level
`CMakeLists.txt` or `Makefile` that delegates to the subdirectories:

CMakeLists.txt example:

```cmake
cmake_minimum_required(VERSION 3.20)
project(virtual-camera)
add_subdirectory(driver-project)
add_subdirectory(software-project)
```

Makefile example:

```makefile
.PHONY: all driver software

all: driver software

driver:
	$(MAKE) -C driver-project

software:
	$(MAKE) -C software-project
```

Only do this if the two build systems are compatible. If they are meant to
remain independently buildable, skip this and document it in the root README.

### Step 6.6 — Implicit conflicts

Scan for issues git will not flag automatically:

Check for colliding preprocessor defines across both codebases:

```bash
grep -rh "^#define " --include="*.h" driver-project/ software-project/ \
  | awk '{print $2}' | sort | uniq -d
```

Report any matches.

Check for shared include paths that assume a flat structure and now need
updating to use the full relative path from the repo root.

---

## Phase 7 — Final Commit and Cleanup

### Step 7.1 — Stage all integration changes

```bash
git add -A
git status
```

Review the staging area. Confirm no unintended files are staged.

### Step 7.2 — Commit

```bash
git commit -m "integrate: unify root-level concerns after history merge

- add root README.md linking to both sub-projects
- merge .gitignore from both projects
- add root build system delegating to driver-project/ and software-project/
- rename CI workflows to avoid ambiguity"
```

Adjust the body to reflect what was actually changed.

### Step 7.3 — Remove temporary remotes

```bash
git remote remove driver-project-history
git remote remove software-project-history
```

### Step 7.4 — Delete throwaway clones

```bash
rm -rf driver-project-rewrite
rm -rf software-project-rewrite
```

---

## Phase 8 — Verification

### Step 8.1 — Inspect the merged graph

```bash
git log --oneline --graph | head -50
```

You should see two independent chains of commits converging at two merge
commits, which sit above the empty root commit.

### Step 8.2 — Verify file layout

```bash
git ls-files | grep "^driver-project/"   | wc -l
git ls-files | grep "^software-project/" | wc -l
git ls-files | grep -v "^driver-project/" | grep -v "^software-project/"
```

The last command shows files at the root level (README, .gitignore, LICENSE,
build files). Confirm nothing unexpected is there.

### Step 8.3 — Verify commit count integrity

Before starting this task, record the commit counts of each original repo:

```bash
git -C driver-project log --oneline | wc -l     # record this number before Phase 4
git -C software-project log --oneline | wc -l   # record this number before Phase 4
```

After the merge, check:

```bash
git log --oneline | wc -l
```

The final count should be:
driver_commits + software_commits + 2 merge commits + 1 root empty commit

### Step 8.4 — Verify git log follows file history

Pick any source file that existed in the original driver repo and confirm
its full history is visible:

```bash
git log --oneline -- driver-project/<any-source-file>
```

The output should show commits going back to the file's creation in the
original driver repo. Repeat for a software file.

### Step 8.5 — Attempt a build

Run the normal build command from the parent root. Report any errors but do
not attempt to fix errors that pre-existed the merge. Scope only to
merge-caused breakage.

---

## Reporting

After all phases complete, produce a summary with:

1. Commit counts absorbed from each project and the final total
2. Every file overlap found in Phase 1 and how it was resolved
3. Any build errors encountered and whether they pre-existed the merge
4. Any judgement calls made, with rationale
5. Remaining manual steps (updating remote origin URL, CI environment
   secrets, any include paths that need updating in source code)
