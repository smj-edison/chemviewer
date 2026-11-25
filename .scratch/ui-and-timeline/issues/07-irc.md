# 07: The reaction coordinate

**What to build:** A Gaussian IRC log offers its reaction coordinate as an axis. Stepping and playback follow the path; the frame field shows the file's number.

**Blocked by:** 05

**Status:** ready-for-agent

- [ ] Read from the log together with the points `Irc` already orders; reverse is negative, the TS is 0
- [ ] Tested on cut-down, made-up pieces shaped like the user's IRC logs (none of their data in the repo): forward and reverse, reverse only, an unfinished path
- [ ] A log whose frames don't all have a coordinate doesn't offer it, and the menu says why
- [ ] The file's number and the place on the path are both readable, and labelled
