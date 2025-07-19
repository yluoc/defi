## StableCoin DeFi Protocol

**1. (Relatived Stability) Anchored -> $1.00 (Chainlink Price Feed)**  
**2. Stability Mechanism: Algorithmic (Decentralized)**  
**3. Collateral: Exogenous (Crypto): wETH, wBTC**  

## Documentation

https://book.getfoundry.sh/

## Dependencies
```
cyfrin/foundry-devops@latest-version
smartcontractkit/chainlink-brownie-contracts@latest-version
foundry-rs/forge-std@latest-version
openzeppelin/openzeppelin-contracts@latest-version
```

## Scope  
### defi source code
```
src/
|--libraries
    |--OracleLib.sol
|--DecentralizedStableCoin.sol
|--DSCEngine.sol
```
### deploy code
```
script/
|--DeployDSC.s.sol
|--DeployDSCEngine.s.ol
|--HelperConfig.s.sol
```
### test code
```
test/
|--fuzz
    |--Handler.t.sol
    |--Invariants.t.sol
|--mocks
    |--MockV3Aggregator.sol
|--unit
    |--DSCEngineTest.t.sol
```
## Usage
make sure to add your own api keys in .env file:  
1. etherscan api key
2. private key
3. sepolia rpc url
4. eth rpc url
### Build
**discover more useages in Makefile**
```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/DeployDSC.s.sol:DeployDSC $(NETWORK_ARGS)
```

### Coverage

```shell
$ forge coverage --report debug > coverage-report.txt
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
