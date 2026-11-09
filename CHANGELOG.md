# Changelog

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
