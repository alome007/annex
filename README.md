# HAOS Runner

A small native macOS app that runs [Home Assistant OS](https://github.com/home-assistant/operating-system) in a lightweight virtual machine on Apple silicon — no Raspberry Pi, no Docker Desktop, no UTM. Open it, click **Install Home Assistant**, and a few minutes later you have a working address you can open from any browser on your network.

## Requirements

- An Apple silicon Mac running macOS 14 or newer
- Nothing else — the app downloads the official Home Assistant OS image itself

## Install

Download the latest zip from [Releases](../../releases), unzip, and move **HAOS Runner** to Applications. The app is not notarized yet: the first time, **right-click → Open → Open** to get past Gatekeeper.

Or build from source (needs Xcode command line tools):

```sh
./build.sh
open "$HOME/Desktop/HAOS Runner.app"
```

## Using it

- **First run** — click **Install Home Assistant**. The app fetches the latest official image (~350 MB), builds the machine, boots it, and walks through every stage on screen. The whole install takes 15–25 minutes, most of it Home Assistant downloading itself inside the machine. When the address appears, open it and run Home Assistant's onboarding.
- **After that** — quitting the app suspends the machine and the next start resumes it in seconds. **Stop** is a full shutdown; the next start takes about a minute. Closing the window keeps Home Assistant running in the menu bar.
- **Apps** — the Apps list links straight into Home Assistant's own add-on store pages for popular add-ons (ESPHome, Mosquitto, Node-RED, …), where installs, progress, and configuration are native.
- **Your own image** — advanced users can point the app at a downloaded `generic-aarch64` `.img.xz`, `.img`, or `.qcow2` in settings (qcow2 conversion requires `brew install qemu`).

## How it works

Everything runs in-process through `Virtualization.framework`; the app owns the VM for as long as it runs.

**Image download.** The app asks the GitHub API for the latest `home-assistant/operating-system` release, downloads the `generic-aarch64` `.img.xz`, and unpacks it with Apple's Compression framework (the xz container's built-in CRC catches corrupt downloads). The raw image is grown to a 64 GB sparse file; HAOS expands its data partition into that space on first boot. The archive is cached so **Erase and start over** rebuilds without re-downloading.

**Networking.** The VM uses NAT (`VZNATNetworkDeviceAttachment`), which needs no special entitlement. The guest's IP is found by looking up its (persistent) MAC address in `/var/db/dhcpd_leases`, with the ARP table as a second source. The MAC is kept stable across launches so DHCP keeps assigning the same address.

**When Home Assistant never downloads.** Supervisor decides whether it has internet from one short-timeout request to `checkonline.home-assistant.io`, and while it believes it does not, it refuses to fetch the version that Core is installed from — logging `No Supervisor connectivity, delaying version fetch` forever. On a slow or intermittent link that check loses the race repeatedly and nothing retries it hard enough to recover. The app therefore points the guest's resolver at the Mac's own VM gateway (HAOS otherwise resolves over DNS-over-TLS, which some networks block), restarts the guest's DNS, and then nudges Supervisor to retry every few minutes until one attempt succeeds. It repairs once automatically and offers **Repair machine network** if it recurs.

**Reaching Home Assistant.** The app surfaces Core's own address, `http://<guest>:8123/`, which works from any browser on your network. Earlier versions ran a `socat` relay inside the guest to make connections look like loopback; that turned out to be unnecessary — the evidence for it came from a machine whose Core was serving on port 80 with nothing on 8123, and from the landingpage's 401 responses being mistaken for Core rejecting WebSockets. Removing it also removed a dependency on Docker Hub, which is unreachable on some networks.

**Readiness probing.** Core must be told apart from the landingpage that stands in for it while it downloads — the landingpage answers 200 on `/` and 401 on every `/api/` path, so neither proves Core is up. Core is detected by `/manifest.json` returning 200, or `/api/onboarding` returning 200 (before onboarding) or 404 (after it), tried on `:8123` first and then `:80` — which port serves Core varies between HAOS builds (some proxy `:80` to Core, others redirect it to `:8123`), and the detected port is what the bridge forwards to. Probes never follow redirects, so a `:80` that merely redirects to `:8123` is never mistaken for Core.

**Console automation.** The serial console is a real terminal into the guest. On first boot the app watches the getty prompt, logs in as `root`, and installs the relay with `docker run`. Depending on the HAOS build, root login lands either directly in a host shell or in the Home Assistant CLI (`ha >`) — in the latter case the app types `login` to reach the shell. Commands are queued and their completion is detected with sentinel echoes, so automation and the interactive console coexist.

**Boot pipeline.** Startup is an explicit state machine — downloading image → preparing disk → starting machine → waiting for network → waiting for Home Assistant → running. Every stage has a watchdog; if a stage stalls, the app tells you which one, for how long, and keeps the console transcript so you can see why. There are no silent failure paths.

**Suspend and resume.** Quitting the app while Home Assistant runs pauses the machine and snapshots its memory to disk (`machine-state.vzvmsave`, roughly the machine's RAM in size). The next start restores that snapshot in a few seconds instead of cold-booting the OS. A snapshot is consumed on resume and discarded whenever it can't safely apply — after Erase, after changing memory/CPU settings, or if the restore fails — in which case the app falls back to a normal boot. The guest's clock jumps forward on resume; Home Assistant OS corrects it via NTP within moments. Pressing Stop is a real shutdown and never leaves a snapshot behind.

## Development

The app is a Swift Package (`Package.swift`); `build.sh` compiles it in release mode and assembles the ad-hoc-signed `.app` bundle with the virtualization entitlement.

```sh
swift test        # parsers, disk-source resolution, console automation logic
swift build       # debug binary
./build.sh        # signed app on the Desktop
```

Two environment variables let a development copy run alongside a real one — a scratch VM instance with its own disk, MAC address and settings:

```sh
HAOS_RUNNER_SUPPORT_DIR=/tmp/haos-scratch \
HAOS_RUNNER_DEFAULTS_SUITE=casa.astrohome.haosrunner.scratch \
"HAOS Runner.app/Contents/MacOS/HAOSRunner"
```

Structured logs are available while it runs:

```sh
log stream --predicate 'subsystem == "casa.astrohome.haosrunner"'
```

The full guest console transcript of the current boot is written to `~/Library/Application Support/HAOSRunner/console.log`.

## Troubleshooting

**The machine starts but produces no boot output.** HAOS tracks boot attempts in a GRUB A/B slot counter on its boot partition. Three interrupted starts in a row (force stops, hard kills) exhaust the counter, and GRUB silently refuses to boot — the app detects this after 90 seconds and offers **Repair startup**, which resets the counter in place. Home Assistant's data is not touched by the repair.

## License

[MIT](LICENSE)
