# Third-party notices

Dump links or bundles third-party software. Those components remain governed by their own licenses rather than Dump's MIT License.

The versions below come from `project.yml`, `Scripts/fetch-runtime.sh`, and `Runtime/qmd/package-lock.json`.

## Direct components

| Component | Version | Source | License |
| --- | ---: | --- | --- |
| HotKey | 0.2.1 | [soffes/HotKey](https://github.com/soffes/HotKey) | MIT |
| Sparkle | 2.9.1 | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) | MIT and bundled third-party terms |
| Wave | 0.3.4 | [jtrivedi/Wave](https://github.com/jtrivedi/Wave) | MIT |
| Node.js | 22.16.0 | [nodejs.org](https://nodejs.org/dist/v22.16.0/) | MIT and bundled third-party terms |
| qmd | 2.1.0 | [tobi/qmd](https://github.com/tobi/qmd) | MIT |

### HotKey

Copyright (c) 2017-2019 Sam Soffes, http://soff.es

### Sparkle

- Copyright (c) 2006-2013 Andy Matuschak.
- Copyright (c) 2009-2013 Elgato Systems GmbH.
- Copyright (c) 2011-2014 Kornel Lesiński.
- Copyright (c) 2015-2017 Mayur Pawashe.
- Copyright (c) 2014 C.W. Betts.
- Copyright (c) 2014 Petroules Corporation.
- Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Sparkle also carries notices for software vendored by the Sparkle project. The complete upstream notice is included at `Resources/ThirdPartyLicenses/Sparkle-LICENSE.txt`.

### Wave

Copyright (c) 2022 Janum Trivedi

### Node.js

Copyright Node.js contributors. All rights reserved.

Node.js includes software from other projects under MIT, BSD, ISC, Apache, and other licenses. The complete Node.js license and bundled third-party notices are preserved as `runtime/node/LICENSE` inside a built Dump app.

### qmd

Copyright (c) 2024-2026 Tobi Lutke

qmd's npm dependency tree is pinned in `Runtime/qmd/package-lock.json`. Individual package license files are preserved alongside those packages under `runtime/qmd/node_modules/` in a built Dump app.

## Complete direct-license texts

Exact upstream license texts for HotKey, Sparkle, Wave, and qmd are kept in `Resources/ThirdPartyLicenses/` and bundled into Dump by Xcode. Node.js and qmd's transitive package licenses are also preserved inside the bundled runtime.

## Updating these notices

When a dependency or runtime version changes:

1. Update this file from the exact resolved version.
2. Review the upstream license and copyright notice for changes.
3. Confirm runtime packaging preserves dependency license files.
4. Regenerate any complete machine-readable inventory used for release review.

This file is a convenience summary. The license files shipped by each third-party component are authoritative.
