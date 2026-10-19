# Steal A Fish

A Roblox "steal an egg / pet tycoon" game. Run into the danger zone, grab a fish egg,
escape the sharks, hatch it into a sea creature, and earn money.

All code lives in this folder. **Rojo** syncs it into Roblox Studio automatically, so you
never copy-paste code into Studio.

---

## Folder layout

```
steal-a-fish/
├── default.project.json   ← tells Rojo where each folder goes inside Roblox
├── rokit.toml             ← pins the Rojo version (Rokit installs it)
├── src/
│   ├── server/            → ServerScriptService.Server          (runs on Roblox's servers)
│   │   ├── init.server.luau   the one server Script: starts every service
│   │   ├── Services/          PlotService, EggService, BotService, PetService, ...
│   │   └── Util/              helpers (RateLimiter, ...)
│   ├── client/            → StarterPlayer.StarterPlayerScripts.Client (runs on each player's device)
│   │   ├── init.client.luau   the one LocalScript: starts every controller
│   │   └── Controllers/       UIController, ...
│   └── shared/            → ReplicatedStorage.Shared            (used by both sides)
│       ├── Config.luau        ⭐ ALL balancing numbers: edit this to tweak the game
│       ├── Types.luau         shared type definitions
│       └── Net.luau           creates/finds RemoteEvents
└── (ReplicatedStorage.Assets) a folder you fill in Studio with real models later
```

**Swapping in real models later:** put a Model (or Part) in `ReplicatedStorage > Assets` in
Studio with one of the names below. The game places it on top of the placeholder block and
hides the block. If a name is missing, you just see the placeholder.

| Asset name | Where it's used |
|---|---|
| `PlotSign` | the board above each plot's entrance |
| `Treadmill` | the treadmill on each plot |
| `Pad` | each egg/pet pad along the sides of a plot |
| `CollectPad` | the green pad where you collect your pets' money |
| a fish's exact name (e.g. `Pinchy Crab`) | that fish (otherwise the built-in blocky fish) |
| `Egg<Rarity>` (e.g. `EggLegendary`) or `Egg` | eggs (rarity-specific name is tried first) |
| `Shark<zone>` (e.g. `Shark7`) or `Shark` | the sharks (zone-specific name is tried first) |

The model's **pivot** goes to the center of the placeholder, so center your model on its pivot.

---

## One-time setup (Mac)

### 1. Get the code onto your Mac
Open the **Terminal** app (press `Cmd + Space`, type `Terminal`, press Enter) and run:

```sh
cd ~/Documents
git clone -b claude/adoring-bell-qwpma0 https://github.com/MaxSchnidrig/claude_projects.git
```

If your Mac asks to install "command line developer tools", click **Install**, wait for it
to finish, then run the `git clone` line again.

The project is now in `~/Documents/claude_projects/steal-a-fish`.
**To get new code later**, run this:
```sh
cd ~/Documents/claude_projects && git pull
```

### 2. Install Rokit (the tool installer) and Rojo
In Terminal:

```sh
curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
```

**Close Terminal completely (`Cmd + Q`) and open it again**, so it finds Rokit. Then:

```sh
cd ~/Documents/claude_projects/steal-a-fish
rokit install
```

If it asks whether to **trust** `rojo-rbx/rojo`, answer yes. Check that it worked:

```sh
rojo --version
```
You should see `Rojo 7.4.4`.

### 3. Install the Rojo plugin into Roblox Studio
**Close Roblox Studio first** if it's open. Then in Terminal:

```sh
rojo plugin install
```

The next time you open Studio, you'll see a **Rojo** button in the **Plugins** tab.

### 4. Set up VS Code
1. Install VS Code from https://code.visualstudio.com if you don't have it.
2. In VS Code: **File → Open Folder…** → choose `Documents/claude_projects/steal-a-fish`.
3. A popup offers to install the **recommended extensions** (Rojo and Luau Language Server).
   Click **Install**. (If you miss it: open the Extensions panel with `Cmd + Shift + X` and
   search for `Luau Language Server` and `Rojo`.)

### 5. Create the place file in Studio
1. Open **Roblox Studio** → **New** → **Baseplate**.
2. **File → Save to File As…** → save it as `StealAFish.rbxl` inside the `steal-a-fish`
   folder. (`.rbxl` files are ignored by git on purpose.)

---

## Every time you work on the game

1. **Start the sync server.** In VS Code, open the terminal (**Terminal → New Terminal**)
   and run:
   ```sh
   rojo serve
   ```
   Leave it running. You should see `Rojo server listening on port 34872`.
   (You can also click **Rojo** in VS Code's bottom bar and start it from there.)
2. **Connect Studio.** In Studio, open your `StealAFish.rbxl`, go to the **Plugins** tab →
   click **Rojo** → click **Connect**. The panel turns green and says *Connected*.
3. The scripts now show up in Studio's **Explorer** (`ServerScriptService > Server`, etc.).
   Every time a `.luau` file changes on disk, Studio updates within a second.
4. Press **Play** (or `F5`) to test. Press **Stop** (`Shift + F5`) when done.

> **Note:** Rojo syncs only while it's connected. Make code changes while the game is
> **stopped**; changes made during Play mode are thrown away when you press Stop.

### Troubleshooting
| Problem | Fix |
|---|---|
| `rojo: command not found` | Quit Terminal (`Cmd + Q`) and reopen it. Still broken? Rerun the Rokit install line. |
| Studio can't connect | Make sure `rojo serve` is still running in VS Code, and that the address is `localhost` and the port is `34872`. |
| No Rojo button in Studio | Close Studio, run `rojo plugin install` again, then reopen Studio. |
| Scripts in Studio look old | Disconnect and reconnect Rojo in Studio. |

---

## Tweaking the game
Open `src/shared/Config.luau`. Every number that changes how the game feels is in there
(egg odds, hatch times, pet income, upgrade prices, bot speeds, ...), with a comment
explaining what it does. Save the file, and Rojo syncs it right away.

**Studs not showing?** The stud look comes from one texture ID in
`Config.Visuals.StudTexture`. If you see plain parts, open Studio's **Toolbox** → **Creator
Store** → **Images**, search for `studs`, right-click one you like → **Copy Asset ID**, and
paste it into that setting as `"rbxassetid://<the number>"`. Adjust
`Config.Visuals.StudsPerTile` if the studs look too big or too small.

---

## Roadmap

| # | Milestone | Status |
|---|---|---|
| 0 | Project setup | ✅ |
| 1 | Plots | ✅ |
| 2 | Eggs and the danger zone | ✅ |
| 3 | Chaser bots (sharks) | ✅ |
| 4 | Speed & treadmill (Speed stat, training, treadmill tiers 1–10 defined) | ✅ |
| 5 | Hatching and pets (eggs hatch on their pad, pets earn money, collect pad) | ✅ |
| 6 | Upgrades and economy: plot space (pads), treadmill tiers, pet levels, selling pets | ✅ |
| 7 | Saving (money, Speed stat, treadmill tier, pads, eggs and pets) | ✅ |
| 8 | UI and polish: Pets window, colored notifications, sounds, effects, screen scaling, tutorial | ✅ |
| 8b | Gameplay changes: egg hotbar inventory, carry pose, hold-E hatching, caught = drop, one alerted shark | ✅ |
| 8c | 80 fish + visual makeover: 8 fish per zone, eggs remember their zone, blocky fish/eggs/sharks with effects and animation | ✅ |
| 8d | **Balance + design batch**: new HUD, Shop (Daily Gift), Index, Eggs and Fish panels, zone banners, speed signs, safe zone, red sharks, ocean wall, upgrades in the world | 🔨 testing |
| 9 | Monetization: 6 game passes, boosts, Instant Hatch, Server Luck, Shark Freeze, cash packs | 🔨 testing |

## Sounds

Sound effects are listed in `Config.Sounds`. They start as short placeholder sounds that come
with Roblox. To use your own: Toolbox → Creator Store → **Audio**, pick a sound, right-click →
**Copy Asset ID**, and set e.g. `Pickup = { Id = "rbxassetid://123456", Volume = 0.6 }`.

## Monetization setup (Robux)

Every Robux item is listed in `Config.Shop` (in `src/shared/Config.luau`); what each one does
(multipliers, minutes, luck) is in `Config.Monetization`. The server code is
`src/server/Services/MonetizationService.luau`.

**While an item's `Id` is `0`:** in Studio, clicking its buy button *simulates* the purchase
for free so you can test it; in the live game the button says "Coming soon".

**To sell an item for real:**
1. Publish the game (File → Publish to Roblox).
2. Open the [Creator Dashboard](https://create.roblox.com/dashboard/creations) → your game →
   **Monetization**.
3. **Passes** (2x Money, 2x Speed, VIP, Lucky Pass, Faster Hatching, Auto Collect): **Passes →
   Create a Pass**, give it a name, icon and description, save, then open it → **Sales** → turn
   on **Item for Sale** and set the price.
4. **Developer Products** (all Boosts and Cash items): **Developer Products → Create a
   Developer Product**, set the name, icon and price.
5. Copy each item's **ID** (the number on its page or in its URL) into the matching `Id = 0`
   in `Config.Shop`. The Shop shows the real price automatically.
6. Test in Studio: Roblox shows a *test* purchase window and nothing is charged. Developer
   products only work in a published place with API access on (see Saving below).

Purchases are safe: a developer product is only marked as done after it was given AND saved,
and every purchase ID is remembered so nothing is ever given twice. Passes are checked with
Roblox every time a player joins.

## Saving (DataStores)

Progress is saved automatically: every 60 seconds, when you leave, and when the server shuts
down. Studio uses its own separate save slot (`Config.Data.StudioStoreName`), so testing never
touches real players' data.

**To make saving work in Studio (one time):**
1. **File → Publish to Roblox** (create a new game if asked). DataStores only work in a published place.
2. **Home → Game Settings → Security** → turn on **Enable Studio Access to API Services** → **Save**.

Without these steps the game still runs, but Output says `SAVING IS OFF` and nothing is saved.

## Studio test commands

Only work while play-testing in Studio. Type them in the chat:

| Command | What it does |
|---|---|
| `!speed 5000` | set your Speed stat to 5000 |
| `!speed zone 4` | set your Speed stat to just enough to outrun zone 4's shark |
| `!tier 7` | rebuild your treadmill as tier 7 (Neon) |
| `!egg mythic` | put a Mythic egg in your egg inventory (hotbar), from the zone where Mythic eggs are most common |
| `!egg mythic 4` | ... a Mythic egg from zone 4 (it hatches into zone 4's fish) |
| `!hatch` | make all your eggs on pads READY right now (then hold E on them) |
| `!money 5000` | set your money |
| `!save` | save your progress right now |
| `!wipe` | reset your progress to a brand-new player (and save that) |
| `!tutorial` | show the new-player tutorial again |
| `!showfish 3` | show all 8 fish of zone 3 in a row on your plot |
| `!showeggs` | show one egg of each rarity on your plot (`!showeggs 7`: all from zone 7) |
| `!showsharks` | show all 10 sharks on your plot |
| `!showclear` | remove the preview (it also disappears by itself after 3 minutes) |
| `!gift` | make your Daily Gift ready again |
| `!findall` | mark every fish as found in your Index (`!findall 2`: only zone 2's fish) |
| `!resetindex` | make every Index reward claimable again (found fish stay found) |
| `!buy DoubleMoney` | simulate buying a Shop item for free (any Key from `Config.Shop`, e.g. `!buy BotFreeze`) |
| `!unbuy` | remove the passes you simulated and your running boosts |

If chat commands don't do anything, open **View → Command Bar**, set its dropdown to
**Server**, and run, for example:
```lua
game.Players:GetPlayers()[1]:SetAttribute("DebugCommand", "!speed zone 4")
```
