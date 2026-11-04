# Changelog

## [0.2.0](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.11...0.2.0) (2026-04-16)

### ⚠ BREAKING CHANGES

- **skills**: add support for skills and validation workflows ([#144](https://github.com/gemini-cli-extensions/alloydb/issues/144)) ([b4ec2f8](https://github.com/gemini-cli-extensions/alloydb/commit/b4ec2f880afbd5bc4404022a10e61a609ef7cbdc))

### Features

- **skill:** Attach user agent metadata for generated skill ([mcp-toolbox#​2697](https://redirect.github.com/googleapis/mcp-toolbox/issues/2697)) ([9598a6a](https://redirect.github.com/googleapis/mcp-toolbox/commit/9598a6a32597b9c9abdb0f20c06d86a01b0d011f)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))
- **skill:** Update skill generation logic ([mcp-toolbox#​2646](https://redirect.github.com/googleapis/mcp-toolbox/issues/2646)) ([c233eee](https://redirect.github.com/googleapis/mcp-toolbox/commit/c233eee98cd9621526cb286245f3874f5bd6e7da)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))
- **skills:** Add Claude Code support to generated scripts ([mcp-toolbox#​2966](https://redirect.github.com/googleapis/mcp-toolbox/issues/2966)) ([a1609e1](https://redirect.github.com/googleapis/mcp-toolbox/commit/a1609e10a2eaf4ea68eae36acec3eed355b8a052)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))
- **skills:** Add codex user agent ([mcp-toolbox#​2973](https://redirect.github.com/googleapis/mcp-toolbox/issues/2973)) ([070e939](https://redirect.github.com/googleapis/mcp-toolbox/commit/070e9399c02f088d43175ce6bf343378beb7f584)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))
- **skills:** Tool invocation via npx ([mcp-toolbox#​2916](https://redirect.github.com/googleapis/mcp-toolbox/issues/2916)) ([377dc5b](https://redirect.github.com/googleapis/mcp-toolbox/commit/377dc5b00145a0044eef39314dd6b0ef5966fcd7)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))


### Bug Fixes

- **skill:** Fix env variable propagation ([mcp-toolbox#​2645](https://redirect.github.com/googleapis/mcp-toolbox/issues/2645)) ([5271368](https://redirect.github.com/googleapis/mcp-toolbox/commit/52713687208994c423da64333cb0a04fb483f794)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))
- **skills:** Fix integer parameter parsing through agent skills ([mcp-toolbox#​2847](https://redirect.github.com/googleapis/mcp-toolbox/issues/2847)) ([4564efe](https://redirect.github.com/googleapis/mcp-toolbox/commit/4564efe75436b4081d9f3d1f7c912bc64c13f850)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))
- **skills:** Fix skill generation template ([mcp-toolbox#​2914](https://redirect.github.com/googleapis/mcp-toolbox/issues/2914)) ([a01a15e](https://redirect.github.com/googleapis/mcp-toolbox/commit/a01a15ed1aa9a83eda8362578fed2e3a3c8dde99)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))
- **skills:** Prevent empty strings overriding optional env vars in node scripts ([mcp-toolbox#​2963](https://redirect.github.com/googleapis/mcp-toolbox/issues/2963)) ([c52adeb](https://redirect.github.com/googleapis/mcp-toolbox/commit/c52adeba76fc13d0e6e415f6393def0648e478d6)) ([98ea437](https://github.com/gemini-cli-extensions/alloydb/commit/98ea437b98671bd177dd19a0bff1b02e1e964948))


## [0.1.11](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.10...0.1.11) (2026-02-24)

### Bug Fixes

- remove broken keychain support for password ([#127](https://github.com/gemini-cli-extensions/alloydb/issues/127)) ([65746bb](https://github.com/gemini-cli-extensions/alloydb/commit/65746bb1203afaf4af4e0edd5ce255f428488309))

## [0.1.10](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.9...0.1.10) (2026-01-28)

### Features

- add Configuration settings ([#108](https://github.com/gemini-cli-extensions/alloydb/issues/108)) ([4ec5205](https://github.com/gemini-cli-extensions/alloydb/commit/4ec52055445e917371fe130a2e5054df5b75eca0))
- **deps:** update dependency googleapis/mcp-toolbox to v0.26.0 ([#109](https://github.com/gemini-cli-extensions/alloydb/issues/109)) ([7fa79c2](https://github.com/gemini-cli-extensions/alloydb/commit/7fa79c2c2caf49498190bc59e5712a2837b18aa8))

## [0.1.9](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.8...0.1.9) (2026-01-13)

### Bug Fixes

- **tools/alloydb-wait-for-operation:** Fix connection message generation ([mcp-toolbox#​2228](https://redirect.github.com/googleapis/mcp-toolbox/issues/2228)) ([7053fbb](https://redirect.github.com/googleapis/mcp-toolbox/commit/7053fbb1953653143d39a8510916ea97a91022a6)) ([177e29e](https://github.com/gemini-cli-extensions/alloydb/commit/177e29e7f836e93d8ca5932c6941e99ee34f7faf))
- **tools/alloydbainl:** Only add psv when NL Config Param is defined ([mcp-toolbox#​2265](https://redirect.github.com/googleapis/mcp-toolbox/issues/2265)) ([ef8f3b0](https://redirect.github.com/googleapis/mcp-toolbox/commit/ef8f3b02f2f38ce94a6ba9acf35d08b9469bef4e)) ([177e29e](https://github.com/gemini-cli-extensions/alloydb/commit/177e29e7f836e93d8ca5932c6941e99ee34f7faf))

## [0.1.8](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.7...0.1.8) (2025-12-15)

### Bug Fixes

- List tables tools null fix ([mcp-toolbox#​2107](https://redirect.github.com/googleapis/mcp-toolbox/issues/2107)) ([2b45266](https://redirect.github.com/googleapis/mcp-toolbox/commit/2b452665983154041d4cd0ed7d82532e4af682eb)) ([e8c6640](https://github.com/gemini-cli-extensions/alloydb/commit/e8c6640d0d552bee841a1e59557cf2cd31a9b753))

## [0.1.7](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.6...0.1.7) (2025-12-05)

### Bug Fixes

- **tools/alloydb-postgres-list-tables:** Exclude google_ml schema from list_tables ([mcp-toolbox#​2046](https://redirect.github.com/googleapis/mcp-toolbox/issues/2046)) ([a03984c](https://redirect.github.com/googleapis/mcp-toolbox/commit/a03984cc15254c928f30085f8fa509ded6a79a0c)) ([921f64e](https://github.com/gemini-cli-extensions/alloydb/commit/921f64ef26954dae0a747d4bfb30c85f9aee6d53))
- **tools/alloydbcreateuser:** Remove duplication of project praram ([mcp-toolbox#​2028](https://redirect.github.com/googleapis/mcp-toolbox/issues/2028)) ([730ac6d](https://redirect.github.com/googleapis/mcp-toolbox/commit/730ac6d22805fd50b4a675b74c1865f4e7689e7c)) ([921f64e](https://github.com/gemini-cli-extensions/alloydb/commit/921f64ef26954dae0a747d4bfb30c85f9aee6d53))

## [0.1.6](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.5...0.1.6) (2025-11-19)

### Features

- **tools/postgres:** Add `long_running_transactions`, `list_locks` and `replication_stats` tools ([#1751](https://github.com/googleapis/mcp-toolbox/issues/1751)) ([5abad5d](https://github.com/googleapis/mcp-toolbox/commit/5abad5d56c6cc5ba86adc5253b948bf8230fa830))

### Bug Fixes

- **tools:** Check for query execution error for pgxpool.Pool ([mcp-toolbox#​1969](https://redirect.github.com/googleapis/mcp-toolbox/issues/1969)) ([2bff138](https://redirect.github.com/googleapis/mcp-toolbox/commit/2bff1384a3570ef46bc03ebebc507923af261987)) ([1da5746](https://github.com/gemini-cli-extensions/alloydb/commit/1da57464893c69c063e73f72b4bad342c5a3efd8))
- **tools/alloydbgetinstance:** Remove parameter duplication ([mcp-toolbox#​1993](https://redirect.github.com/googleapis/mcp-toolbox/issues/1993)) ([0e269a1](https://redirect.github.com/googleapis/mcp-toolbox/commit/0e269a1d125eed16a51ead27db4398e6e48cb948)) ([1da5746](https://github.com/gemini-cli-extensions/alloydb/commit/1da57464893c69c063e73f72b4bad342c5a3efd8))

## [0.1.5](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.4...0.1.5) (2025-11-18)

### Features

- **source/alloydb, source/cloud-sql-postgres,source/cloud-sql-mysql,source/cloud-sql-mssql:** Use project from env for alloydb and cloud sql control plane tools ([mcp-toolbox#​1588](https://redirect.github.com/googleapis/mcp-toolbox/issues/1588)) ([12bdd95](https://redirect.github.com/googleapis/mcp-toolbox/commit/12bdd954597e49d3ec6b247cc104584c5a4d1943)) ([7ca7d46](https://github.com/gemini-cli-extensions/alloydb/commit/7ca7d4691fd47ad3081363b288681da0851d9985))
- Added prompt support for toolbox ([mcp-toolbox#​1798](https://redirect.github.com/googleapis/mcp-toolbox/issues/1798)) ([cd56ea4](https://redirect.github.com/googleapis/mcp-toolbox/commit/cd56ea44fbdd149fcb92324e70ee36ac747635db)) ([7ca7d46](https://github.com/gemini-cli-extensions/alloydb/commit/7ca7d4691fd47ad3081363b288681da0851d9985))

## [0.1.4](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.3...0.1.4) (2025-11-07)

### Features

- **tools/alloydbainl:** update AlloyDB AI NL statement order ([mcp-toolbox#​1753](https://redirect.github.com/googleapis/mcp-toolbox/issues/1753)) ([45933f1](https://github.com/gemini-cli-extensions/alloydb/commit/45933f10e4daafb177bd59c069f8880d7a485ed5))

### Bug Fixes

- **tools/alloydbainl:** AlloyDB AI NL execute_sql statement order ([mcp-toolbox#​1753](https://redirect.github.com/googleapis/mcp-toolbox/issues/1753)) ([9723cad](https://redirect.github.com/googleapis/mcp-toolbox/commit/9723cadaa181a76d8fdda65a6254f6c887c3cf57)) ([45933f1](https://github.com/gemini-cli-extensions/alloydb/commit/45933f10e4daafb177bd59c069f8880d7a485ed5))

## [0.1.3](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.2...0.1.3) (2025-10-17)

### Bug Fixes

- update context for install instructions ([#70](https://github.com/gemini-cli-extensions/alloydb/issues/70)) ([2889fe5](https://github.com/gemini-cli-extensions/alloydb/commit/2889fe5243b7c121c5b979a16dea1a60a8c4465b))

## [0.1.2](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.1...0.1.2) (2025-10-13)

### Features

- **deps:** update dependency googleapis/mcp-toolbox to v0.17.0 to Support PSC connection ([#66](https://github.com/gemini-cli-extensions/alloydb/issues/66)) ([1280920](https://github.com/gemini-cli-extensions/alloydb/commit/12809204b2e1053bc8e1a101879580b2857d50f6))

## [0.1.1](https://github.com/gemini-cli-extensions/alloydb/compare/0.1.0...0.1.1) (2025-09-30)

### Features

- additional instructions for the context file ([#51](https://github.com/gemini-cli-extensions/alloydb/issues/51)) ([cef0fb6](https://github.com/gemini-cli-extensions/alloydb/commit/cef0fb68dedb400225347adf3a16cb320ff28d20))
- **deps:** update dependency googleapis/mcp-toolbox to v0.16.0 ([#42](https://github.com/gemini-cli-extensions/alloydb/issues/42)) ([6a25cb6](https://github.com/gemini-cli-extensions/alloydb/commit/6a25cb699264d415eb75f4bfdd25b325a372425e))
- standardize mcp server names ([#49](https://github.com/gemini-cli-extensions/alloydb/issues/49)) ([ab738fc](https://github.com/gemini-cli-extensions/alloydb/commit/ab738fc7f669dc3712777cec969b41084b7e5224))
- update context file to use full table name ([dc565f4](https://github.com/gemini-cli-extensions/alloydb/commit/dc565f427db7611c70155109cfd4010591784af4))
- Update context to recommend other observability extension ([#34](https://github.com/gemini-cli-extensions/alloydb/issues/34)) ([874b148](https://github.com/gemini-cli-extensions/alloydb/commit/874b1489989c5945c81b0eeef1592bb65693f6d6))

## 0.1.0 (2025-09-20)

### Features

- create the AlloyDB Extension ([#21](https://github.com/gemini-cli-extensions/alloydb/issues/21)) ([b71218b](https://github.com/gemini-cli-extensions/alloydb/commit/b71218ba1977b906043621f23cf7fff05937e833))
