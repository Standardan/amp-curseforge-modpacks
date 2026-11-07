# AMP template: Minecraft CurseForge Modpack

A custom template for [AMP](https://cubecoders.com/AMP)'s Generic module. It installs and updates any
CurseForge Minecraft modpack (Forge, NeoForge or Fabric) from AMP's own **Update** button. The install
engine is [itzg/mc-image-helper](https://github.com/itzg/mc-image-helper) `install-curseforge`, the same
engine the `itzg/minecraft-server` Docker image uses for `AUTO_CURSEFORGE`. You don't need Docker
for this. The instance gets AMP's normal console, backups, scheduler and start/stop.

What one Update does:

1. Downloads `ampmodpack.sh` (this repo), a Java runtime (Eclipse Temurin) and mc-image-helper into the instance.
2. Backs up the world and configs (from the second update onwards).
3. Downloads the modpack (latest release or a pinned version), its server-side mods and the right Forge/NeoForge/Fabric loader.
4. Removes mods the new version dropped, keeps the files you edited, and works out the start command.

Linux only. Tested target: Debian 12, AMP running instances in Docker containers.

---

## 1. Add this repo to AMP

The repo must be **public**. AMP's Configuration Repository setting has no field for GitHub
credentials, and the Update step downloads `ampmodpack.sh` anonymously from
`raw.githubusercontent.com`. Nothing secret lives in the repo: an optional CurseForge API key is stored only
in the instance's settings inside AMP.

1. Log in to AMP's main (ADS) panel.
2. Go to **Configuration → Instance Deployment**.
3. Under **Configuration Repositories**, add `Standardan/amp-curseforge-modpacks:main`.
4. Click **Fetch**, then refresh the browser page.

The template now appears in the application list when you create an instance, as
**!CF / Minecraft CurseForge Modpack** (the repo prefix `!CF` sorts it to the top).

After you change this repo, click **Fetch** again so AMP picks up the new template. `ampmodpack.sh`
itself is downloaded fresh on every Update.

## 2. CurseForge API key (optional)

You normally don't need one. mc-image-helper's release builds include their own CurseForge API key,
and that's what itzg's Docker image uses by default. Leave **CurseForge API Key** blank.

Set your own key only if the built-in one stops working:

1. Go to <https://console.curseforge.com/>, sign in, open **API keys** and copy your key. It looks
   like `$2a$10$...`, 60 characters. The `$` signs are part of the key.
2. Paste it into the instance's **CurseForge API Key** setting, or save it in a text file named
   `curseforge-api-key.txt` in the instance's `curseforge-modpack/` folder. The file keeps the key
   out of AMP's logs: AMP logs setting changes in plain text, password fields included. Never put it in this repo.

On every Update the template first tries your key on a CurseForge mod search. It logs the key's length and
first 7 characters (`$2a$10$`, the same for every key), never the key itself. If CurseForge refuses
it, the template warns and falls back to the built-in key.

This fallback exists because some personal keys are accepted by parts of the API but refused with
"API Key missing or invalid" on the mod search mc-image-helper needs. That happened during testing with a key
that was otherwise valid.

## 3. Create a modpack instance

1. In ADS: **Create Instance**, choose **!CF / Minecraft CurseForge Modpack**, give it a name, create it.
2. Open the instance. Under **Configuration → CurseForge Modpack**, set:
   - **Modpack**: the pack page URL, e.g. `https://www.curseforge.com/minecraft/modpacks/all-the-mods-10`, or just `all-the-mods-10`.
   - **Pinned Version**: blank for the latest release, or a file ID / file page URL / part of the file name.
   - **CurseForge API Key**: leave blank (see step 2).
   - **Accept the Minecraft EULA**: tick it.
   - **Java Version**: leave it on *Automatic* unless you have a reason not to.
   - **Max RAM**: e.g. `8192` MB for ATM10.
3. The game port is under the instance's **Configuration → Network/Ports** (AMP picks a free one).
   Point your playit.gg tunnel at `127.0.0.1:<that port>`.
4. Press **Update**. The first install of a large pack takes several minutes; progress shows in the console.
5. Press **Start**. AMP shows *Running* once the server prints `Done (...)! For help, type "help"`.
   **Stop** sends `stop`, so the world is saved properly.

## Minecraft server settings

The instance's **Configuration → Minecraft Server** page is the one place to configure the server itself:

| Section | What's there |
|---|---|
| Server List | MOTD, server icon, max players, whitelist, online mode |
| Gameplay | game mode, difficulty, hardcore, PvP, allow flight, spawn protection, op level, command blocks, idle kick |
| World | world folder name, seed, world type, structures, Nether |
| Performance | view distance, simulation distance, watchdog timeout |
| More Properties | hide player list, signed chat, resource pack, chunk writes, world border, entity range, compression, plus **Extra server.properties** for any other key |
| Sleep | sleep when empty, minutes before sleeping, start asleep, the sleeping/waking messages (see below) |
| Game Rules | keep inventory, fire spread, mob griefing, daylight/weather cycle, mob spawning, phantoms, instant respawn, announcements, death messages, regeneration, traders, patrols, sleeping percentage, random tick speed, spawn radius, plus **Other Game Rules** for any other rule |

Everything applies the next time the server starts.

### How server.properties is written

- On every start, only the keys you set in AMP are written into `server/server.properties`. Every other line
  stays, including your own edits and pack-specific lines (for example a skyblock pack's `level-type`).
- **Blank** text fields and **Leave as is** switches don't touch the file. Leave **World Type** blank for modpacks.
- Keys you set in AMP win. If you edit one of them by hand, AMP overwrites it on the next start.
- `server-port` always comes from AMP's port setting.
- **Allow Flight** defaults to on, because modded flight (jetpacks, rings, wings) otherwise gets players kicked.

### Colourful MOTD

Use the **[MOTD Workbench](https://claude.ai/artifact/NSTcMdVkFBP7CfSHSQd4x3)** (the same page is
`motd-editor.html` in this repo). It has colour and effect buttons, a rainbow tool, centring, a
width meter and a live preview drawn like the multiplayer list. Copy its output into **Message of
the Day**. The output uses `\u00A7` colour codes and `\n` for the second line, which is the safe
form for both AMP and Java. Only the 16 classic colours and 5 effects work in `server.properties`.

### Server icon

Paste a link to a **64x64 PNG** into **Server Icon URL**. It's downloaded on the next start and only
again when you change the link. Bigger images are resized only if ImageMagick exists on the
server; otherwise they're rejected with a message in the console. Blank keeps the current icon.

### Game rules

Game rules live in the world, not in `server.properties`. The template writes them into a tiny
datapack, `world/datapacks/amp-settings`, whose load function runs `gamerule …` on every start. So the
AMP values win, and **Leave as is** keeps whatever the world has. Each rule runs on its own,
so a rule your Minecraft version doesn't know only skips itself. This works on Minecraft
1.16.2 to 1.21.10. On other versions, set rules in the console, e.g. `gamerule keepInventory true`.
Clearing every game rule setting removes the datapack again.

### Sleep when empty

With **Sleep When Empty** on (the default), the server shuts itself down after **Minutes Before
Sleeping** with nobody online, and starts again when someone joins from Minecraft:

- While asleep, the Java server process is gone. Only a ~40 MB watcher stays, so the RAM and CPU are free for your other instances.
- The server stays in everyone's multiplayer list with the **Sleeping MOTD**, its icon and its version.
- The first player to join wakes it. They see **Waking Up Message** and join again once it's up.
  Big packs take a minute or two. During that time the list shows the **Waking Up MOTD**.
- Server-list pings don't wake it. Only a real join does, and when the whitelist is on, only a
  whitelisted player or op.
- AMP shows the instance as running the whole time, and the console stays live. While asleep it
  answers `!wake` (start now), `!sleep` (sleep now if empty) and `!status`. Other commands typed
  while asleep are not run. **Stop**, **Restart** and **Update** work the same as without sleep.
- **Start Asleep** makes AMP's Start skip booting the server until someone joins. That's handy when the
  host restarts and AMP brings every instance back.

How it works: AMP starts `AmpSleep` (a small Java program, source in `sleep/AmpSleep.java`), not the server.
It listens on the instance's port. It runs the real server as a child process on a private port and passes
connections through, counting players. This is also why AMP's own *Sleep Mode* is turned off in this template.
AMP's version stops the whole app and only works for servers that boot in seconds.

Things to know:

- The server sees every player coming from `127.0.0.1`, so IP bans don't work. With playit.gg
  that was already the case.
- Scheduled AMP backups don't wake a sleeping server. A scheduled restart boots it (unless
  **Start Asleep** is on), and it falls asleep again once the idle time passes.
- The jar is downloaded once from this repo's GitHub release `amp-sleep-1.0.0` and checked against
  a SHA-256 in `ampmodpack.sh`. If that fails, the server starts normally without sleep, with a
  warning in the console.

## 4. Update a pack

Stop the server, then press **Update**. That's all:

- **Pinned Version blank**: you get the newest release of the pack.
- **Pinned Version set**: you get exactly that version. This is also how you roll back. Set the
  previous file ID and press Update. The update log prints the installed file ID, e.g. `Installed: All the Mods 10 4.14 (file 6834521)`.
- If nothing changed, Update finishes quickly and touches nothing.

You can schedule it with AMP's scheduler (for example a nightly *Stop → Update → Start*), but
reading the pack's changelog first is safer for big packs.

### What is kept and what changes

| What | On update |
|---|---|
| World (`world/`, `world_nether/`, `world_the_end/`, or your `level-name`) | Never touched. Even world folders shipped in the pack's overrides are skipped if the world exists. |
| `server.properties`, `ops.json`, `whitelist.json`, `banned-*.json`, `usercache.json`, `eula.txt` | Always kept. Only `server-port` in `server.properties` is set from AMP's port setting on each start. |
| Pack mods (`mods/*.jar` that the pack installed) | Updated, added or **removed** to match the new pack version. |
| Mods you added yourself to `mods/` | Kept. The tool only removes files it installed. |
| Pack config files you **didn't** edit | Replaced with the new pack version. |
| Pack config files you **did** edit | Kept (with the default *Keep files I changed* setting). The pack's new copy is saved in `pack-new-configs/` so you can merge changes by hand. |

How it decides you edited a file: after each successful update it records a SHA-256 of every
non-mod file the pack installed (`tools/state/pack-files.sha256`). On the next update, any of
those files whose content differs was changed by you, and it gets put back after the pack is
installed. The other modes:

- **Never overwrite any existing file**: runs mc-image-helper with `--overrides-skip-existing`. The pack never updates a config that already exists. Safe, but you miss config fixes the pack author ships.
- **Always use the pack's files**: plain mc-image-helper behaviour. Pack files overwrite your edits (the server-operator files in the table above are still kept).

### How mc-image-helper handles removed and changed mods

This comes from reading mc-image-helper 1.76.0 (`CurseForgeInstaller`, `OverridesFromZipApplier`, `Manifests`):

- It keeps a manifest of everything it installed in `server/.curseforge-manifest.json`: the pack's
  mod files plus every file it copied from the pack's `overrides/` folder, and the pack/Minecraft/loader versions.
- **Same version requested and every file still present**: it reports "already installed" and changes nothing (apart from confirming the loader).
- **New version**: it downloads each mod file in the new manifest. It skips mods that CurseForge
  marks client-only, plus anything on the exclude list. It copies `overrides/` over the server
  directory, overwriting existing files, except inside an existing world. Then it installs/upgrades the loader.
- **Then cleanup**: every file listed in the *old* manifest but not the *new* one is deleted.
  That's how removed mods, and config files the pack stopped shipping, disappear. Files it never installed are never deleted.
- **Changed mods**: CurseForge mod jars have the version in the file name. An updated mod is a new
  file and the old file is removed by the cleanup above.
- **Loader**: if the Forge/NeoForge/Fabric version changed, it reruns the official installer. The old
  loader's files in `libraries/` are left behind. That's harmless: the start command always uses the
  version the current `run.sh` points to. It only costs some disk space over many upgrades.
- **Mods whose authors block third-party downloads**: the install stops and lists them (also in
  `server/MODS_NEED_DOWNLOAD.txt`). See below.

## 5. If an update fails

The world isn't touched by a failed update. Read the last lines of the AMP console (`[modpack]` lines come from this template):

| Message | Fix |
|---|---|
| `Set 'Modpack'...` | Fill in the setting and Update again. |
| `CurseForge refused your API key for mod searches` | Only a warning: the built-in key is used instead. Clear the setting to silence it. |
| HTTP 403 `forbidden or rate-limit` from mc-image-helper with the built-in key | CurseForge is refusing or rate-limiting the built-in key. Wait an hour and retry, or set your own working key (step 2). |
| `Some mod authors disallow automated downloads` | Download each listed file from its CurseForge page and put it in `server/manual-downloads/mods/` (worlds: `manual-downloads/worlds/`), then Update again. |
| `The server is still running` | Stop the server first. |
| Forge/NeoForge installer fails | Usually a Java mismatch. For packs on Minecraft 1.16.5 and older, set **Java Version** to *Java 8*; for 1.17–1.20.4, *Java 17*. Then Update. |
| Server crashes on start with a client-only class error (e.g. `net/minecraft/client/...`) | A client-only mod slipped through. Add its slug to **Extra Mods To Exclude** and Update. |
| `Unknown start option: --sleep` (or `Ignoring unknown start option`) when starting | The template is newer than the instance's script. Press **Update** once. |
| `Could not open port ...` from `[AMP Sleep]` | Something else uses the port, often a server left over from a crash. The script stops a leftover server automatically on the next start. Otherwise, check with `ss -ltnp`. |
| Anything strange after a half-finished update | Tick **Repair On Next Update**, press Update, then untick it. |

To roll back a bad pack version: set **Pinned Version** to the previous file ID and Update.

To restore the world/configs from a pre-update backup, stop the server and run this over SSH as root
(replace `<Instance>` and the backup name):

```bash
cd /home/amp/.ampdata/instances/<Instance>/curseforge-modpack/server
mv world world.broken-$(date +%s)
tar -xzf ../backups/pre-update-YYYYMMDD-HHMMSS.tar.gz
chown -R --reference=. .
```

The `tar` command restores the world, config folders, `server.properties`, ops and whitelist exactly
as they were before that update. Use `tar -tzf <file>` first to see what's inside.

To see what's installed: `bash /home/amp/.ampdata/instances/<Instance>/curseforge-modpack/tools/ampmodpack.sh status`

## 6. Backup plan

Two layers:

1. **Automatic pre-update snapshot (this template).** With **Back Up Before Updating** on (the default),
   every Update of an installed pack first writes `backups/pre-update-<date>.tar.gz`. It contains
   the world, `config/`, `defaultconfigs/`, `kubejs/`, `server.properties`, ops, whitelist and bans,
   and keeps the newest 3 (configurable). It lives next to the server folder, not inside it.
2. **AMP's own backups** for everything else. In the instance, use **Backups** to take one by hand
   before risky changes. Under **Schedule**, add a daily *Take a backup* trigger. If you schedule
   automatic updates, put *Take a backup* before *Update* in the same schedule. AMP's backups cover the whole instance
   including mods, so they are the full rollback; the pre-update snapshot is the quick one.

Large worlds make the pre-update snapshot slow. If you rely on AMP's scheduled backups only, turn **Back Up Before Updating** off.

---

## Files and layout

Repo (flat, lowercase, as AMP requires):

| File | Purpose |
|---|---|
| `curseforge-modpack.kvp` | Template: start command, console regexes, stop method, ports, update stages |
| `curseforge-modpackconfig.json` | The settings page |
| `curseforge-modpackupdates.json` | Update stages: fetch `ampmodpack.sh`, then run `ampmodpack.sh update` |
| `curseforge-modpackports.json` | The Minecraft TCP port |
| `curseforge-modpackmetaconfig.json` | Empty. AMP doesn't rewrite `server.properties`; only the port is set, on each start |
| `manifest.json` | Identifies this repo to AMP |
| `ampmodpack.sh` | Does the actual work (install/update/start/status) |
| `sleep/AmpSleep.java`, `sleep/build.sh` | Source of the sleep supervisor. `build.sh` makes the release jar; the same source gives the same jar. |

Inside an instance:

```
curseforge-modpack/
  server/            the Minecraft server (world, mods, config, server.properties)
    manual-downloads/  drop files here for mods that block automated downloads
  tools/             ampmodpack.sh, amp-sleep-<version>.jar, java/<version>, mc-image-helper/<version>, state/
  backups/           pre-update-*.tar.gz
  pack-new-configs/  the pack's new copies of configs you edited
```

## How starting works

`ampmodpack.sh start` runs from AMP, sets `server-port`, writes `eula.txt`, then **execs** Java
directly, so AMP owns the Java process (console, `stop`, CPU/RAM graphs):

- **NeoForge, and Forge 1.17+**: `java -Xms.. -Xmx.. <JVM args> @libraries/net/<loader>/<version>/unix_args.txt nogui`. The `unix_args.txt` path is read from the `run.sh` the installer generated. The installer's `user_jvm_args.txt` is ignored; use **Max RAM** and **Extra JVM Arguments** instead.
- **Forge 1.16.5 and older**: `java ... -jar forge-<version>.jar nogui`
- **Fabric**: `java ... -jar <fabric server launcher>.jar nogui`

With **Sleep When Empty** on, the same Java command is handed to the sleep supervisor rather than exec'd:
`java -Xmx48M -jar amp-sleep-<v>.jar --port <AMP port> ... -- setpriv --pdeathsig TERM -- java -Xmx.. ... nogui`.
The supervisor is what AMP sees; it forwards the console and `stop`. Before each launch it rewrites
`server-port` to a free private port. `setpriv` makes sure the server gets a clean `SIGTERM` if the
supervisor is ever killed. Without sleep, `server-port` goes back to the AMP port on the next start.
