# SPMLocal
Pin Swift Package dependencies at exact versions in a local `ThirdParty/` checkout, so later Xcode resolution and builds read those directories. Business repositories commit only `versions.json` and `lock.json`. This repository ships the installer and the sync script. It does not carry a project-specific dependency list.
