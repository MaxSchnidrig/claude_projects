# How to report to me (Max)

Call me "cuh". I'm not experienced with the terminal or GitHub, and I test on a MacBook in Roblox Studio and on my phone. After every phase, part or fix round, end your message with exactly these sections:

## 1. What changed
Short, plain-language summary. No jargon without a quick explanation. Mention anything you couldn't verify.

## 2. How to get it
Always the same steps, written out:
- GitHub Desktop: Fetch origin, then Pull origin (name the commit I should see).
- Terminal (only if rojo serve isn't running): 
  cd ~/Documents/GitHub/claude_projects/voxel-survival
  rojo serve
- Studio: Plugins > Rojo > Connect BEFORE pressing Play (connecting during Play fails). Check the version in F3.
- Remind me to keep the Output panel from covering the bottom of the game view.

## 3. What to test
A numbered checklist, each step concrete: which key to press, where to look, what I should see if it works. Mac notes: F-keys may need fn, never use Cmd+Q (quits Studio), avoid keys Roblox/Studio already use (F9 etc.).
If something needs a Studio setting, give the exact menu path (Mac menu bar File > Experience Settings > ...).
If I need to edit a file myself, give the exact folder path, file name, what to search with Cmd+F, and what to change.

## 4. Reply template
A ready-to-copy code block I fill in and send back, with [option / option / problem: __] brackets for every test item, plus "Errors in Output" and "Other bugs" lines. End the template with what you'll do next once I confirm (e.g. "If everything works, start Phase X and stop after it for me to test").

# Standing rules
- Replicate Java Edition gameplay as exactly as possible (mechanics, values, recipes, AI, world-gen rules). Excluded: trial chambers, the deep dark and ancient cities, the sulfur cave update content.
- Names Mojang invented, mob designs, textures, sounds, music, structure designs: always our own originals, never copies or slightly altered copies. Propose names and designs for my approval first.
- Audio only from properly licensed sources (Roblox's licensed library, CC0, or files I provide).
- Stop after each phase or part so I can test. Don't start the next one without my go.
- When I report a bug, fix it before moving on, and say honestly if you're guessing at the cause.
- Prefer Sonnet-level effort for routine work to save usage; flag when something is hard enough to need more.
