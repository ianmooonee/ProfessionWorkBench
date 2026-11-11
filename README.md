# Profession Workbench

A cleaner, flat dark replacement for the profession window in **World of Warcraft: Forever**.

Open any profession as usual and Profession Workbench appears instead of the default window, with a searchable recipe list, skill-up colors at a glance, reagent counts that include your bank, and crafting cooldowns tracked across all your characters.

> **Status:** early version (0.7.0), not yet widely tested in-game. Bug reports are welcome; see [Troubleshooting](#troubleshooting).

## Features

**Recipe list**
- Search by recipe name *or* reagent name (typing "silk" finds everything that uses silk).
- Recipes grouped by category; click a category to collapse it, or use **Collapse all / Expand all**. Collapsed categories are remembered per profession.
- Each recipe shows how many you can craft, including extra crafts possible with bank materials (shown in blue, e.g. `0+1`), or the time left if it's on cooldown.
- Shift-click a recipe to link it in chat.

**Skill-up guide**
- Recipes are colored by difficulty: orange (guaranteed skill-up), yellow (likely), green (unlikely), gray (none).
- Color chips filter the list by difficulty.
- A summary shows how many orange, yellow and green recipes you have, and points out the best skill-up you can craft right now. Click it to jump to that recipe.

**Reagents**
- Shows `bags / needed` for each reagent: green when your bags have enough, yellow when you'd need items from the bank, red when you're short.
- Bank contents are remembered from your last bank visit, so counts work anywhere. Your character's own bank tabs are counted; the account-wide bank is not.
- **Have materials** filter shows only what you can craft now; **Count bank** includes bank items in counts and in that filter.

**Crafting**
- Quantity box with `-` / `+`, **Create** and **Create all** buttons.
- Enchants that go on gear get an item slot instead: click it to pick an item from your equipped gear or bags (or drag an item onto it), then click **Enchant**. Right-click the slot to clear it. Needs a client with `C_TradeSkillUI.CraftEnchant`.

**Cost and profit**
- The details panel shows what one craft costs in reagents, what the result sells for after the 5% auction house cut, and the profit. Recipes missing a price say so rather than showing a fake number.
- **Sort by profit** ranks the whole list by what one craft earns instead of grouping by category. Recipes with no price go last.
- **Prices on item tooltips.** Hover any reagent, product or disenchant material and its vendor price, auction price (with age when it is over two days old) and disenchant value appear at the bottom. Hold **Alt** on any item to also see which of your recipes use it and what they earn.
- **Scan prices**, a button on the auction house window — prices every reagent and product of your known recipes, plus the disenchant materials, while the auction house is open. It sends a single browse query and reads every page, so it runs in seconds rather than minutes; the button shows how many of your items it has priced and stops it. `/pwb ahstop` also stops it, and `/pwb ahitem` prices just the item you are hovering.
- Merchant visits fill in vendor prices automatically, and `/pwb price` or `/pwb scanitem` record anything you want by hand.
- A manual price is never overwritten by learning, so it always wins.
- Prices are saved per account, so the numbers work on any character and away from the auction house.

**Craft queue and shopping list**
- Select a recipe, set the amount and click **Queue**, or use `/pwb queue <count> <recipe name>`. The queue is remembered per profession.
- The **Queue** button in the toolbar opens the list: what is queued, and for each reagent how many you have and how many you still need to buy.
- Intermediates are followed automatically. Queuing 10 Azure Silk Hoods with 47 Silk Cloth in your bags asks for the bolts too, and tells you that you are 33 Silk Cloth short rather than 33 bolts.
- Missing reagents are listed first and marked in red, so the shopping list reads top-down.

**Disenchant or sell**
- For a craft whose result is a green, blue or purple weapon or armor piece, the details panel also shows what its materials are worth, and whether disenchanting beats selling. Profit is then measured against whichever pays more.
- The item tooltip shows all three for anything you hover, and the details panel shows them for each recipe's result. `/pwb de [item]` prints the comparison to chat when that is easier to read.
- Disenchant values are averages from the WoW Forever disenchanting guide, resolved by item level. A single disenchant can come out better or worse, and an item whose materials have no price yet shows a `+` instead of a number.

**Cooldowns**
- Cooldown recipes (transmutes, Mooncloth and so on) are recorded whenever you open the profession, for every character.
- The bottom of the window lists them with time left or **Ready**, and you get a chat reminder at login the first time each one becomes ready. Entries are cleared a day after they finish, so the reminder doesn't repeat.

## Installation

1. Download the addon:
   - **Zip:** on the GitHub page, click **Code > Download ZIP** and extract it, or
   - **Git:** `git clone https://github.com/ianmooonee/ProfessionWorkBench.git`
2. Find your WoW Forever AddOns folder. It's usually:
   ```
   World of Warcraft\_forever_\Interface\AddOns\
   ```
   Create the `AddOns` folder if it doesn't exist yet.
3. Copy the **`ProfessionWorkbench`** folder (the one containing `ProfessionWorkbench.toc`) into `AddOns`. The result should be:
   ```
   Interface\AddOns\ProfessionWorkbench\ProfessionWorkbench.toc
   ```
   Copy the inner folder, not the whole downloaded folder (which is named `ProfessionWorkBench-main` for zip downloads), or WoW won't find the addon.
4. Start the game (or type `/reload` if you're already in), and check that **Profession Workbench** is enabled in the AddOns list on the character select screen.

### Updating

Replace the `ProfessionWorkbench` folder with the new one and `/reload`. Your settings and tracked cooldowns are kept; they're stored in WoW's saved variables, not in the addon folder.

## Usage

Open a profession the normal way (spellbook or action bar). The window is movable by dragging and closes with **Esc** or the **X** button. Use the `-` / `+` buttons next to **X** to make it bigger or smaller. Drag the grip in the bottom-right corner to resize it (more room for the recipe list and details). **Default UI** switches to the default Blizzard window; click **Use Workbench** on top of that window to come back. Your choice is remembered.

| Command | What it does |
| --- | --- |
| `/pwb` | Show the command list |
| `/pwb blizz` | Switch between Profession Workbench and the default Blizzard window (same as the **Default UI** / **Use Workbench** buttons) |
| `/pwb cd` | List tracked cooldowns for all characters |
| `/pwb scale <0.6-2>` | Change the window size (e.g. `/pwb scale 1.3`); the `-` / `+` buttons in the title bar do the same |
| `/pwb price <itemID> <gold>` | Set an item's price by hand, e.g. `/pwb price 2592 1.5` for Wool Cloth at 1g 50s |
| `/pwb price clear <itemID>` | Forget a manually set price |
| `/pwb scanitem <gold>` | Record the price of the item you are hovering (an auction listing or a bag item), e.g. `/pwb scanitem 1.5` |
| `/pwb queue [<count>] [<recipe>]` | Add to the craft queue; with no arguments it queues the selected recipe once |
| `/pwb ahscan` | At the auction house, price your recipes' reagents and products (the button is easier) |
| `/pwb ahstop` | Stop a running scan |
| `/pwb reset` | Move the window back to the center of the screen and restore its default size |
| `/pwb debug` | Print client version and API info (useful for bug reports) |

## Compatibility

- Built for WoW Forever, client 1.60.1 (`## Interface: 16001`).
- Supports both the classic-style trade skill API and the newer `C_TradeSkillUI` API (which WoW Forever uses). If neither is available, the addon leaves the default window alone and prints a message asking you to run `/pwb debug`.
- Linked and guild profession windows are left to the default UI.

## Troubleshooting

- **The addon doesn't show in the AddOns list:** check the folder layout in step 3 of [Installation](#installation).
- **It's marked "out of date":** tick **Load out of date AddOns** on the AddOns screen, or open an issue with the output of `/pwb debug`.
- **Lua errors:** turn on error display with `/console scriptErrors 1`, then [open an issue](https://github.com/ianmooonee/ProfessionWorkBench/issues) with the error text and the output of `/pwb debug`.
- **Something looks wrong and you just want to craft:** `/pwb blizz` switches back to the default window.
