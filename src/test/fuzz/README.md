# Security Tests

The contracts in this folder are the fuzz scripts for the the Auto Surplus Buffer.

To run the fuzzer, set up Echidna (https://github.com/crytic/echidna).

Then run
```
echidna-test src/test/fuzz/<name of file>.sol --contract <Name of contract> --config src/test/fuzz/echidna.yaml
```

Configs are in this folder (echidna.yaml).

The contracts in this folder are modified versions of the originals in the _src_ folder. They have assertions added to test for invariants, visibility of functions modified. Running the Fuzz against modified versions without the assertions is still possible, general properties on the Fuzz contract can be executed against unmodified contracts.

For all contracts being fuzzed, we tested the following:

1. (FuzzBounds.sol) We test it against the mock version, forcing failures on overflows. This test should be run with a short ```seqLen``` and with ```checkAsserts: true``` in the config file. It will fail on overflows and give insights on bounds where calculations fail. Each failure should then be analyzed against expected running conditions.
2. (FuzzProperties.sol) We test invariants and properties on the contract, including correct surplus buffer calculation.

Echidna will generate random values and call all functions failing either for violated assertions, or for properties (functions starting with echidna_) that return false. Sequence of calls is limited by seqLen in the config file. Calls are also spaced over time (both block number and timestamp) in random ways. Once the fuzzer finds a new execution path, it will explore it by trying execution with values close to the ones that opened the new path.

# Results

## IncreasingDiscountCollateralAuctionHouse

### Fuzzing Bounds
```
Analyzing contract: /Users/fabio/Documents/reflexer/geb-auto-surplus-buffer/src/test/fuzz/AutoSurplusBufferSetterFuzz.sol:FuzzBounds
assertion in percentageDebtChange: passed! 🎉
assertion in rmultiply: failed!💥
  Call sequence:
    rmultiply(7293315615994232703302491026086910371530,16910500997487113128437779194162002151)

assertion in lastRecordedGlobalDebt: passed! 🎉
assertion in ray: failed!💥
  Call sequence:
    ray(116098598129525483531118501184029272994238259830032694649613414410819)

assertion in multiply: failed!💥
  Call sequence:
    multiply(2463520957720469649429370181087377987842898485287719,49328667505561995329228593)

assertion in baseUpdateCallerReward: passed! 🎉
assertion in maxRewardIncreaseDelay: passed! 🎉
assertion in authorizedAccounts: passed! 🎉
assertion in coveredDebt: passed! 🎉
assertion in fuzz_globalDebt: passed! 🎉
assertion in treasuryAllowance: passed! 🎉
assertion in addAuthorization: passed! 🎉
assertion in wmultiply: failed!💥
  Call sequence:
    wmultiply(2305,51644612059400071983337152714012232835438397409786602194727103949022106643)

assertion in subtract: failed!💥
  Call sequence:
    subtract(0,1)

assertion in getNewBuffer: passed! 🎉
assertion in perSecondCallerRewardIncrease: passed! 🎉
assertion in rad: failed!💥
  Call sequence:
    rad(115839148095432418001567420253076247722396684679455)

assertion in addition: failed!💥
  Call sequence:
    addition(78570697217229045471931252822158432930145558119188412233086326986353074246496,38156651655815894161257969902943980598539001713367785844363912149655298285360)

assertion in RAY: passed! 🎉
assertion in updateDelay: passed! 🎉
assertion in minimumGlobalDebtChange: passed! 🎉
assertion in treasury: passed! 🎉
assertion in modifyParameters: passed! 🎉
assertion in safeEngine: passed! 🎉
assertion in maxUpdateCallerReward: passed! 🎉
assertion in WAD: passed! 🎉
assertion in stopAdjustments: passed! 🎉
assertion in removeAuthorization: passed! 🎉
assertion in accountingEngine: passed! 🎉
assertion in maximumBufferSize: passed! 🎉
assertion in rdivide: failed!💥
  Call sequence:
    rdivide(0,0)

assertion in lastUpdateTime: passed! 🎉
assertion in minimumBufferSize: passed! 🎉
assertion in rpower: failed!💥
  Call sequence:
    rpower(66020,16,1)

assertion in minimum: passed! 🎉
assertion in getCallerReward: failed!💥
  Call sequence:
    getCallerReward(1,0)

assertion in wdivide: failed!💥
  Call sequence:
    wdivide(115976661590182272772399465919083475338865439362876145973977,3477625551459524826438997009344)

assertion in modifyParameters: passed! 🎉

Seed: 8775887530203249450
```

Several of the failures are expected, known limitations of safeMath, as follows:

- rmultiply
- ray
- multiply
- wmultiply
- subtract
- rad
- addition
- rdivide:
- rpower
- getCallerReward (previously tested on the ```increasingTreasuryReimbursement```)
- wdivide

None other calls failed.


### Conclusion: No exceptions found.

### Fuzz Execution

In this case we setup an environment and test for properties.

The globalDebt in SAFEEngine is fuzzed in between calls (haphazardly) so we have different scenarios where the surplus buffer is calculated.

Here we are not looking for bounds, but instead checking the properties that either should remain constant, or that move as the auction evolves:

- stopAdjustments
- updateDelay
- minimumBufferSize
- maximumBufferSize
- minimumGlobalDebtChange
- coveredDebt
- surplus buffer calculation
- surplus buffer setting in AccountingEngine

These properties are verified in between all calls.

```
Analyzing contract: /Users/fabio/Documents/reflexer/geb-auto-surplus-buffer/src/test/fuzz/AutoSurplusBufferSetterFuzz.sol:FuzzProperties
echidna_surplusBufferAdjustment: passed! 🎉
echidna_minimumGlobalDebtChange: passed! 🎉
echidna_stopAdjustments: passed! 🎉
echidna_maximumBufferSize: passed! 🎉
echidna_minimumBufferSize: passed! 🎉
echidna_updateDelay: passed! 🎉
echidna_coveredDebt: passed! 🎉
```

#### Conclusion: No exceptions found.

