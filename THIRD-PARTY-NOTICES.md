# Third-party notices

GPBar's original code is licensed under the [MIT License](LICENSE).
The following components and changes derived from them remain subject to their respective licenses.

## OpenProtect

OpenProtect provides the Rust authentication and VPN engine.

- Copyright: 2026 Pangolin Contributors
- Source: <https://github.com/kyaky/openprotect>
- License: Apache License 2.0 or MIT License
- Local license texts: [`Vendor/openprotect/LICENSE-APACHE`](Vendor/openprotect/LICENSE-APACHE) and [`Vendor/openprotect/LICENSE-MIT`](Vendor/openprotect/LICENSE-MIT)

GPBar uses a vendored OpenProtect snapshot with local changes.

## OpenConnect

OpenConnect provides the VPN tunnel library.

- Version: 9.21 with GPBar patches; runtime revision `v9.21-gpbar3`
- Source: <https://www.infradead.org/openconnect/download/>
- License: GNU Lesser General Public License 2.1
- Local license text: [`Packaging/Licenses/OpenConnect-LGPL-2.1.txt`](Packaging/Licenses/OpenConnect-LGPL-2.1.txt)

The applied patch is stored in [`Packaging/Patches/openconnect-private-hip.patch`](Packaging/Patches/openconnect-private-hip.patch).
It uses OpenConnect's detach path when handing tunnel recovery to GPBar, preserving the session cookie during renewal.

## vpnc-script

GPBar bundles a reference copy from the OpenConnect vpnc-scripts project.

- Copyright: 2005–2012 Maurice Massar, Jörg Mayer, Antonio Borneo, and contributors
- Copyright: 2009–2022 David Woodhouse, Daniel Lenski, and contributors
- Source: <https://gitlab.com/openconnect/vpnc-scripts>
- License: GNU General Public License 2.0 or later
- Local source and license notice: [`Vendor/vpnc-script/vpnc-script`](Vendor/vpnc-script/vpnc-script)

Application sessions use GPBar's separate network wrapper at [`Packaging/vpnc-script`](Packaging/vpnc-script).

The About GPBar window displays these three components’ licenses from bundled files.
The full vpnc-script GPL text is in [`Packaging/Licenses/vpnc-script-GPL-2.0.txt`](Packaging/Licenses/vpnc-script-GPL-2.0.txt).
