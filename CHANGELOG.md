# Changelog

## [0.10.0](https://github.com/misterbisson/conflux/compare/v0.9.0...v0.10.0) (2026-11-14)


### Features

* Apple's on-device model answers in a response_format schema ([#91](https://github.com/misterbisson/conflux/issues/91)) ([4234da1](https://github.com/misterbisson/conflux/commit/4234da1c885d06fb24fd0653b0a2e7172862a1c6))
* let a mesh's gateways use Apple's model on a device that also serves a model file ([#90](https://github.com/misterbisson/conflux/issues/90)) ([ed7466a](https://github.com/misterbisson/conflux/commit/ed7466ab625c91d4b1e2260f66001d632cfc3045))

## [0.9.0](https://github.com/misterbisson/conflux/compare/v0.8.0...v0.9.0) (2026-11-14)


### Features

* change a Mac's slots while it serves, down to none ([#83](https://github.com/misterbisson/conflux/issues/83)) ([a93011d](https://github.com/misterbisson/conflux/commit/a93011df0a56d9a27156eb2f3dd106b1b2031c67))
* rest a device's models while its heat is serious, with a Cool down box ([#87](https://github.com/misterbisson/conflux/issues/87)) ([7bd6c64](https://github.com/misterbisson/conflux/commit/7bd6c641ebdf94825e88a4fb86707daa104b7409))
* show each host's chip, GPU cores and memory ([#86](https://github.com/misterbisson/conflux/issues/86)) ([5eacd53](https://github.com/misterbisson/conflux/commit/5eacd535befaa34834390b9e51e200bbafbc9a09))


### Bug Fixes

* free a model's memory when the device runs short, instead of being ended by iPadOS ([#89](https://github.com/misterbisson/conflux/issues/89)) ([96ca521](https://github.com/misterbisson/conflux/commit/96ca521e1567f32794436ff10f5ca0ac5e673f18))
* **ipad:** say a model file is missing when it has been deleted, not "not connected" ([#80](https://github.com/misterbisson/conflux/issues/80)) ([e01a549](https://github.com/misterbisson/conflux/commit/e01a54911fcf4b795d7b20146924593bcb35fc86))
* send a request to the quickest free host, not the one that joined first ([#84](https://github.com/misterbisson/conflux/issues/84)) ([544494e](https://github.com/misterbisson/conflux/commit/544494e7641f8baedc48401f3430f5338ebf2386))

## [0.8.0](https://github.com/misterbisson/conflux/compare/v0.7.0...v0.8.0) (2026-11-13)


### Features

* a Mac offers the model it serves to the devices it trusts ([#78](https://github.com/misterbisson/conflux/issues/78)) ([057a226](https://github.com/misterbisson/conflux/commit/057a22637095a1f297a434e3fb243c571d5fcace))
* chart requests, tokens, memory and heat over the last hour or day ([#73](https://github.com/misterbisson/conflux/issues/73)) ([c6257bb](https://github.com/misterbisson/conflux/commit/c6257bb5b80489b20bb7ab3fd8af937c49a5b99b))
* **ipad:** open models from Files and other apps, and use them in place ([#72](https://github.com/misterbisson/conflux/issues/72)) ([8cae412](https://github.com/misterbisson/conflux/commit/8cae4123dabdceb5533b39b9c171a80e051a5bec))
* **ipad:** pull a model and its projector from a Mac in the mesh ([#79](https://github.com/misterbisson/conflux/issues/79)) ([872d7b3](https://github.com/misterbisson/conflux/commit/872d7b373fd6b29524a9db7c155698f1e0e2aee9))
* **ipad:** say which models will likely fit before loading them ([#77](https://github.com/misterbisson/conflux/issues/77)) ([6f45b58](https://github.com/misterbisson/conflux/commit/6f45b587392af1cedaea0b63a7563b2c68963926))
* tell projectors from models by what's in the file, and suggest the one that fits ([#76](https://github.com/misterbisson/conflux/issues/76)) ([5eff6ba](https://github.com/misterbisson/conflux/commit/5eff6ba1c17097774995a337b17af931a7910612))


### Bug Fixes

* stop a request when its client closes the connection ([#71](https://github.com/misterbisson/conflux/issues/71)) ([5fa09fa](https://github.com/misterbisson/conflux/commit/5fa09fa4fa0c950b97b466902b880357ab7b9cbc))

## [0.7.0](https://github.com/misterbisson/conflux/compare/v0.6.1...v0.7.0) (2026-11-13)


### Features

* show the same status on the Mac and the iPad, and bring the Mac's recent fixes to the iPad ([#63](https://github.com/misterbisson/conflux/issues/63)) ([bead08e](https://github.com/misterbisson/conflux/commit/bead08e0e6aef762e2e96ca3cd27f37a86ccb871))


### Bug Fixes

* **gateway:** a refusal names the model that refused ([#65](https://github.com/misterbisson/conflux/issues/65)) ([3de0419](https://github.com/misterbisson/conflux/commit/3de04195455daf08d18a1f84cb172fdfad55ccda))
* **ipad:** shorten the host socket's path so the iPad's mesh starts ([#62](https://github.com/misterbisson/conflux/issues/62)) ([522951d](https://github.com/misterbisson/conflux/commit/522951da4b29e35773139956aee9cfb192db4267))
* **self-check:** count two swapped letters as one mistake ([#61](https://github.com/misterbisson/conflux/issues/61)) ([ec10858](https://github.com/misterbisson/conflux/commit/ec10858d3e7e854ff84cb9e62228e00cc74ca4d7))
* separate pairing by hand from the device list, and show mesh errors in red ([#66](https://github.com/misterbisson/conflux/issues/66)) ([d1dbc10](https://github.com/misterbisson/conflux/commit/d1dbc10e7ac3c8374e47ffb8b5a37d55c45d15d3))

## [0.6.1](https://github.com/misterbisson/conflux/compare/v0.6.0...v0.6.1) (2026-11-13)


### Bug Fixes

* stop keep-alive connections from holding every request they've carried ([#59](https://github.com/misterbisson/conflux/issues/59)) ([3d49e12](https://github.com/misterbisson/conflux/commit/3d49e12e931c7313c6a2abc183ddabc6758d2137))

## [0.6.0](https://github.com/misterbisson/conflux/compare/v0.5.0...v0.6.0) (2026-11-12)


### Features

* **ipad:** serve the iPad's model to the Macs' gateways ([#57](https://github.com/misterbisson/conflux/issues/57)) ([2acd678](https://github.com/misterbisson/conflux/commit/2acd678bf2492edc735996b65d7069b2ee646c94))

## [0.5.0](https://github.com/misterbisson/conflux/compare/v0.4.3...v0.5.0) (2026-11-12)


### Features

* show the app's version and build in its window ([#45](https://github.com/misterbisson/conflux/issues/45)) ([340bf40](https://github.com/misterbisson/conflux/commit/340bf40753ecb952c06539219a2ef5238a8ba405))


### Bug Fixes

* ask before stopping while requests are running ([#51](https://github.com/misterbisson/conflux/issues/51)) ([1b1f38e](https://github.com/misterbisson/conflux/commit/1b1f38e5898b6e78e62660964de36e8801c45971))
* choose context and image sizes from a list instead of stepping ([#47](https://github.com/misterbisson/conflux/issues/47)) ([6daba6a](https://github.com/misterbisson/conflux/commit/6daba6a34d624592663aa33651af90cfa25c0f93))
* explain slots in the app instead of pointing at a repository file ([#49](https://github.com/misterbisson/conflux/issues/49)) ([1568d3a](https://github.com/misterbisson/conflux/commit/1568d3a09c458ae0006b9ffae5b29b5c77040fb8))
* name peers the same way in Monitoring as in Mesh ([#50](https://github.com/misterbisson/conflux/issues/50)) ([0c472fb](https://github.com/misterbisson/conflux/commit/0c472fb46a3a2fef544a926e7c1bb4873e558cf2))
* open one conflux window, not several ([#48](https://github.com/misterbisson/conflux/issues/48)) ([83f7cab](https://github.com/misterbisson/conflux/commit/83f7cabb9e8d2fe41175788d0c1452e6ce8f9ee8))
* say why settings are locked while conflux runs ([#53](https://github.com/misterbisson/conflux/issues/53)) ([0043b38](https://github.com/misterbisson/conflux/commit/0043b38df46988b4038ab541bb77d1ddcc877dfa))
* show when a Copy button has copied ([#52](https://github.com/misterbisson/conflux/issues/52)) ([bccd111](https://github.com/misterbisson/conflux/commit/bccd111c911bcfcc169be2bc9ae8a8b530cfd86e))

## [0.4.3](https://github.com/misterbisson/conflux/compare/v0.4.2...v0.4.3) (2026-11-11)


### Bug Fixes

* stop the app crashing when a request waits for a slot ([#43](https://github.com/misterbisson/conflux/issues/43)) ([56f4a29](https://github.com/misterbisson/conflux/commit/56f4a29df8b9189771672e21db6c3467844cd677))

## [0.4.2](https://github.com/misterbisson/conflux/compare/v0.4.1...v0.4.2) (2026-11-09)


### Bug Fixes

* remove the long download retries added during GitHub's outage ([#42](https://github.com/misterbisson/conflux/issues/42)) ([490e2f2](https://github.com/misterbisson/conflux/commit/490e2f27a2a78cd49e833d915f1d619a3beb1338))


### Documentation

* say how a change only Xcode Cloud can test gets released ([#40](https://github.com/misterbisson/conflux/issues/40)) ([bbce5ba](https://github.com/misterbisson/conflux/commit/bbce5ba8a5b2f2b8f1060a0717e2170d9546db5b))

## [0.4.1](https://github.com/misterbisson/conflux/compare/v0.4.0...v0.4.1) (2026-11-09)


### Bug Fixes

* follow response_format's JSON schema when the app runs the model ([#35](https://github.com/misterbisson/conflux/issues/35)) ([cf2e8e8](https://github.com/misterbisson/conflux/commit/cf2e8e89bc26ee1677f4d292f77607ad61436d2b))

## [0.4.0](https://github.com/misterbisson/conflux/compare/v0.3.0...v0.4.0) (2026-11-08)


### ⚠ BREAKING CHANGES

* conflux now needs macOS 27 or iPadOS 27. It no longer installs on macOS 15 to 26 or iPadOS 18 to 26.

### Features

* serve Apple's on-device model alongside the model file, and send what it declines elsewhere ([#31](https://github.com/misterbisson/conflux/issues/31)) ([3ca1aa3](https://github.com/misterbisson/conflux/commit/3ca1aa3569aec77f86c5b829999f81eaa672bc40))


### Build System

* require macOS 27 and iPadOS 27, the first to read images with Apple's on-device model ([#30](https://github.com/misterbisson/conflux/issues/30)) ([6a3d829](https://github.com/misterbisson/conflux/commit/6a3d8294e2d20bf514a300bd2454e7bf577402a8))

## [0.3.0](https://github.com/misterbisson/conflux/compare/v0.2.0...v0.3.0) (2026-11-08)


### Features

* **app:** include a small starter model, so a first request works before choosing one ([#29](https://github.com/misterbisson/conflux/issues/29)) ([f41d232](https://github.com/misterbisson/conflux/commit/f41d232281d8183025d1ba51fac7343eb0be3408))
* **ipad:** add an iPad build of the app that checks whether a model fits ([#25](https://github.com/misterbisson/conflux/issues/25)) ([aef5b87](https://github.com/misterbisson/conflux/commit/aef5b87711c0fac16794a8a139c24740de76c1ca))

## [0.2.0](https://github.com/misterbisson/conflux/compare/v0.1.2...v0.2.0) (2026-11-08)


### Features

* **gateway:** count throughput, failures and idle-with-work per host and for the mesh ([#19](https://github.com/misterbisson/conflux/issues/19)) ([83259c2](https://github.com/misterbisson/conflux/commit/83259c2f4b57f263c9cd83954a658590a35a5500))
* **mesh:** find the user's other Macs through iCloud Keychain ([#20](https://github.com/misterbisson/conflux/issues/20)) ([1c3d997](https://github.com/misterbisson/conflux/commit/1c3d9979e2c7c836bd488223bf05f8d263d84b0e))
* **scheduler:** hedge stragglers at the tail onto idle hosts, and cancel the copy that loses ([#22](https://github.com/misterbisson/conflux/issues/22)) ([4c51e1e](https://github.com/misterbisson/conflux/commit/4c51e1e1703640a5f86f5b34a28a7b5bc9b337b9))
* **scheduler:** hosts say when a slot frees, and fast hosts take one request ahead ([#21](https://github.com/misterbisson/conflux/issues/21)) ([5d24c34](https://github.com/misterbisson/conflux/commit/5d24c3494f1042e8f7d95541475a8af7b5908f30))
* serve hosts to peers over iroh ([#16](https://github.com/misterbisson/conflux/issues/16)) ([b35e95c](https://github.com/misterbisson/conflux/commit/b35e95c8110959b6a09b08dcab0eaf1e7e8faca8))


### Bug Fixes

* **app:** ship llama.cpp's licences in the About window ([#17](https://github.com/misterbisson/conflux/issues/17)) ([7fd937a](https://github.com/misterbisson/conflux/commit/7fd937af34bc311bcf868559f6d0131c6aef4ee3))

## [0.1.2](https://github.com/misterbisson/conflux/compare/v0.1.1...v0.1.2) (2026-11-08)


### Bug Fixes

* **app:** keep access to chosen model files across launches ([#13](https://github.com/misterbisson/conflux/issues/13)) ([17375bc](https://github.com/misterbisson/conflux/commit/17375bcdbb077f40a65722609e194416b9bc8a18))

## [0.1.1](https://github.com/misterbisson/conflux/compare/v0.1.0...v0.1.1) (2026-11-08)


### Bug Fixes

* keep Xcode Cloud building when CI_TEAM_ID isn't a Team ID ([#11](https://github.com/misterbisson/conflux/issues/11)) ([390e854](https://github.com/misterbisson/conflux/commit/390e85400b824213b471f28d7f66746302598d15))

## 0.1.0 (2026-11-08)


### Features

* **app:** build the Mac app for TestFlight with Xcode Cloud ([#5](https://github.com/misterbisson/conflux/issues/5)) ([85f34ce](https://github.com/misterbisson/conflux/commit/85f34ce7fcaed27cbfeafef9d1f874b7e3475987))
* **bench:** add the Phase 0 benchmark and CI ([#2](https://github.com/misterbisson/conflux/issues/2)) ([78d951a](https://github.com/misterbisson/conflux/commit/78d951a013409b368be6e4df440f341c4b07bb8c))
* run models in-process with llama.cpp ([#4](https://github.com/misterbisson/conflux/issues/4)) ([171c715](https://github.com/misterbisson/conflux/commit/171c715f8cb02992e81af2bcc441369a46a8665c))
* serve a model on one Mac through an OpenAI-compatible gateway ([#3](https://github.com/misterbisson/conflux/issues/3)) ([e727a27](https://github.com/misterbisson/conflux/commit/e727a2764b5d42b1da451cda424061f901d9fee6))


### Bug Fixes

* **app:** add a privacy manifest and check the export-compliance answer ([#6](https://github.com/misterbisson/conflux/issues/6)) ([3d3727d](https://github.com/misterbisson/conflux/commit/3d3727de5c35ed2b917b66ffb147b6d1e0101122))


### Documentation

* correct the Xcode Cloud setup steps ([#7](https://github.com/misterbisson/conflux/issues/7)) ([a04acba](https://github.com/misterbisson/conflux/commit/a04acba7a2ec38534e0de56cdfc6f5e88254d970))
* document the design, client requirements and plan ([#1](https://github.com/misterbisson/conflux/issues/1)) ([41eda98](https://github.com/misterbisson/conflux/commit/41eda98875661cac072d8cc2c8107c94a9e82924))


### Continuous Integration

* tag releases with release-please and check commit messages ([#8](https://github.com/misterbisson/conflux/issues/8)) ([45b524f](https://github.com/misterbisson/conflux/commit/45b524fc6a1a4f2c4f2c785320807b00e0234c2f))
