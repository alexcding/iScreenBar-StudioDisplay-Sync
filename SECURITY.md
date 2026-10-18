# Security

Please report security issues privately through GitHub Security Advisories for
this repository. Do not include passwords, access tokens, device serial numbers,
or personal logs in a public issue.

The application has no analytics, updater, cloud service or remote-control
interface. Its only networking is the optional Philips Hue sync:

- It finds a Hue Bridge on the local network with Bonjour (`_hue._tcp`) and
  talks to it over HTTPS, bypassing any system proxy. macOS asks for Local
  Network permission the first time.
- The bridge uses a self-signed certificate. The app only accepts a
  certificate whose common name matches the bridge ID advertised over Bonjour,
  or, if none is advertised, the ID seen on the first connection.
- Pairing requires pressing the bridge's link button. The resulting Hue API key
  is stored in the app's local `UserDefaults`, not the Keychain.
- Unpairing in the Hue Lights window forgets the key, the bridge address and
  the bridge ID.

