# Connection History

Adds Connection History UI/API using the current final-patches installer.

This repository is private while it is being checked and verified.

## Install

Clone or unzip this add-on into `/home/pi`, then run:

```bash
cd /home/pi
rm -rf Connection-History
git clone https://github.com/matelv-x/Connection-History.git
cd Connection-History
chmod +x history.sh restore-history.sh
sudo ./history.sh /home/pi/sg1_v4
sudo systemctl restart stargate.service
```

## Restore / uninstall

```bash
cd /home/pi/Connection-History
sudo ./restore-history.sh /home/pi/sg1_v4
sudo systemctl restart stargate.service
```

## What it changes

- Adds or repairs the Connection History page.
- Supports `HISTORY_STYLE=current` and `HISTORY_STYLE=kristian`.
- Adds restore cleanup for installed history files.

## Attribution and originality

Original base project: StargateProject SG1 software from the BuildAStargate/Jordan/Kristian/Jonnerd project lineage.

Additional source/idea credit: Feature idea by matelv-x/Codex over StargateProject dialing log behavior.

Retro UI credit: When this add-on patches Retro navigation/menu links, those Retro UI files come from the Polklabs project:
https://github.com/polklabs/stargate-retro

matelv-x/Codex modification: this repository adds SG1 v4 connection-history pages/API and only adds compatible links into the Polklabs-derived Retro UI when that UI is present.

How much is copied or changed: Script-based patch with embedded/fallback logic; it modifies selected runtime and web files only.
