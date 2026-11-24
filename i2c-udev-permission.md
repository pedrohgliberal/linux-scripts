# i2c (DDC/CI) permission with a udev rule

Fixes the `EACCES` errors that PowerDevil (via libddcutil) logs when it opens
`/dev/i2c-*` right after waking from sleep.

Tested on: Fedora 45, KDE Plasma 6.8.3, ddcutil 3.0.2, ASUS TUF F15 (Intel + NVIDIA in Hybrid mode).

## What's already there

The `ddcutil` package installs `/usr/lib/udev/rules.d/60-ddcutil-i2c.rules`:

```
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", TAG+="uaccess"
```

- **`SUBSYSTEM=="i2c-dev"`**: applies to the `/dev/i2c-*` devices created by
  the `i2c_dev` module, which ddcutil already loads via
  `/usr/lib/modules-load.d/ddcutil.conf`.
- **`ATTRS{class}=="0x03*"`**: limits it to i2c buses that belong to a
  graphics card (PCI class 0x03). The touchpad, sensor etc. i2c buses are left
  out and stay `crw-------`.
- **`TAG+="uaccess"`**: systemd-logind gives a read/write ACL to the user
  seated in the active session. That's the `+` in `ls -l` and the
  `user:<you>:rw-` in `getfacl`. No group or password needed.

## Why it fails after sleep

On resume, the graphics card's i2c devices are recreated. The `uaccess` ACLs
are applied by logind **a few moments later**. PowerDevil tries to open the
bus right at resume, finds the device with only `root:root 0600` and gets
`EACCES`. In the journal it looks like this:

```
org_kde_powerdevil: Open failed for /dev/i2c-16, errno=EACCES(-13): Permission denied
org_kde_powerdevil:    Group i2c does not exist
```

The ddcutil rule file itself mentions this problem ("Some systems have been
seen to exhibit transitory EACCES errors on return from sleep when tag uaccess
is relied on") and suggests using a group.

## The fix

With a group, the permission is set as the device is created, so there's no
time window:

```sh
sudo groupadd --system i2c
sudo usermod -aG i2c $USER
echo 'SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", GROUP="i2c", MODE="0660"' \
  | sudo tee /etc/udev/rules.d/60-ddcutil-i2c-group.rules
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=i2c-dev
```

- **`GROUP="i2c", MODE="0660"`**: the owner stays root, the `i2c` group can
  also read and write, and other users have no access. The
  `ATTRS{class}=="0x03*"` filter stays so non-graphics i2c buses aren't opened
  up (the commented-out rule in ddcutil doesn't have this filter).
- **`/etc/udev/rules.d/`**: rules in this directory take precedence over
  `/usr/lib/` and survive package updates. The original `uaccess` rule still
  applies alongside it, with no conflict.
- **`udevadm trigger`**: applies the rule to devices that already exist,
  without rebooting.

After running it, log out and back in (or reboot) for the new group to take
effect.

### Check

```sh
id                       # should list i2c
ls -l /dev/i2c-*         # the graphics ones should show "root i2c"
ddcutil detect --brief
```

### Undo

```sh
sudo rm /etc/udev/rules.d/60-ddcutil-i2c-group.rules
sudo gpasswd -d $USER i2c
sudo groupdel i2c
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=i2c-dev
```

## What might not be worth it

With the permission working, `ddcutil detect` showed both screens as
**"Invalid display"**:

- **eDP-1 (`/dev/i2c-11`)**: the laptop's internal panel, which never has
  DDC/CI. Its brightness comes from `intel_backlight`, and that already works.
- **DP-1 (`/dev/i2c-12`, ARZOPA)**: ddcutil finds the bus, but the monitor
  doesn't respond to DDC/CI. Many portable monitors don't support DDC/CI, and
  on some it's turned off in the on-screen menu (OSD).

So the udev rule only gets rid of the `EACCES` errors in the log after resume.
It **won't make** the ARZOPA brightness control the actual backlight. For that
the monitor would need DDC/CI or a menu option to enable it. Without DDC/CI,
KWin controls DP-1's brightness by darkening the image, not by changing the
backlight.

If the monitor's menu has a DDC/CI option, it's worth enabling it and running
`ddcutil detect` again before applying the rule.

## Related

- [`fix-dim-after-resume.sh`](fix-dim-after-resume.sh): another resume
  problem, where automatic dimming stays stuck and the screens remain dark
  even with brightness at 100%.
