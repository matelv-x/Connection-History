# Connection History

Adds a web page and API for recent Stargate connection history.

This repository is private while it is being checked and verified.

## Install

```bash
cd /home/pi/Stargate-Final_Patches
rm -rf Connection-History
git clone https://github.com/matelv-x/Connection-History.git
cd Connection-History
chmod +x *.sh
sudo ./install.sh /home/pi/sg1_v4
sudo systemctl restart stargate.service
```

## Restore / uninstall

```bash
cd /home/pi/Stargate-Final_Patches/Connection-History
chmod +x restore.sh
sudo ./restore.sh /home/pi/sg1_v4
sudo systemctl restart stargate.service
```

## What it changes

- Adds web/connection_history.htm and web/js/connection_history.js.
- Adds GET /get/dialing_history support.
- Extends dialing log/history integration.

## Attribution and originality

Original base project: StargateProject SG1 software from the BuildAStargate/Jordan/Kristian/Jonnerd project lineage.

Additional source/idea credit: Feature idea by Marcin/Codex, implemented on top of StargateProject dialing log behavior.

How much is copied or changed: Medium patch. It adds a new page/API and modifies selected SG1 runtime files.

The included `*.patch` file, when present, shows the exact text-level changes against the base software used while packaging.
