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
| `Egg<Rarity>` (e.g. `EggLegendary`) or `Egg` | eggs (rarity-specific name is tried first) |
| `Shark` (`Config.Bots.ModelName`) | the chaser bots (Milestone 3) |

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
| 4 | **Speed & treadmill** (Speed stat, training, treadmill tiers 1–10 defined) | 🔨 testing |
| 5 | Hatching and pets | |
| 6 | Upgrades and economy, including **buying treadmill tiers** with money (`SpeedService.SetTreadmillTier`) | |
| 7 | Saving (money, Speed stat, owned treadmill tier, upgrades, pets) | |
| 8 | UI and polish | |
| 9 | Monetization (Robux); Speed boosts plug into `SpeedService.SetGainMultiplier` | |

## Studio test commands

Only work while play-testing in Studio. Type them in the chat:

| Command | What it does |
|---|---|
| `!speed 5000` | set your Speed stat to 5000 |
| `!speed zone 4` | set your Speed stat to just enough to outrun zone 4's shark |
| `!tier 7` | rebuild your treadmill as tier 7 (Neon) |

If chat commands don't do anything, open **View → Command Bar**, set its dropdown to
**Server**, and run, for example:
```lua
game.Players:GetPlayers()[1]:SetAttribute("DebugCommand", "!speed zone 4")
```
