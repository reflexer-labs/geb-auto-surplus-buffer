pragma solidity ^0.6.7;

import "./AutoSurplusBufferSetterMock.sol";
import "./MockTreasury.sol";
// import "ds-test/test.sol";

contract AccountingEngineMock {
    uint256 public surplusBuffer;

    function modifyParameters(bytes32 parameter, uint data) external {
        if (parameter == "surplusBuffer") surplusBuffer = data;
    }
}
contract SAFEEngineMock {
    uint256 public globalDebt;

    function modifyParameters(bytes32 parameter, uint data) external {
        globalDebt = data;
    }
}

contract TokenMock {
    uint constant maxUint = uint(0) - 1;
    mapping (address => uint256) public received;
    mapping (address => uint256) public sent;

    function totalSupply() public view returns (uint) {
        return maxUint;
    }
    function balanceOf(address src) public view returns (uint) {
        return maxUint;
    }
    function allowance(address src, address guy) public view returns (uint) {
        return maxUint;
    }

    function transfer(address dst, uint wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad)
        public
        returns (bool)
    {
        received[dst] += wad;
        sent[src]     += wad;
        return true;
    }

    function approve(address guy, uint wad) virtual public returns (bool) {
        return true;
    }
}

// @notice Fuzz the whole thing, assess the results to see if failures make sense
contract FuzzBounds is AutoSurplusBufferSetterMock {
    constructor() public
        AutoSurplusBufferSetterMock(
            address(new MockTreasury(address(new TokenMock()))),
            address(new SAFEEngineMock()),
            address(new AccountingEngineMock()),
            200000E45,                   // minimumBufferSize
            900,                         // minimumGlobalDebtChange
            50,                          // coveredDebt
            3600,                        // updateDelay
            5E18,                        // baseUpdateCallerReward
            10E18,                       // maxUpdateCallerReward
            1000192559420674483977255848 // perSecondCallerRewardIncrease
        ){}

    // aux
    function fuzz_globalDebt(uint globalDebt) public {
        SAFEEngineMock(address(safeEngine)).modifyParameters("globalDebt", globalDebt);
    }
}

// @notice Will fuzz the contract and check for invariants/properties
contract FuzzProperties is AutoSurplusBufferSetterMock {

    constructor() public
        AutoSurplusBufferSetterMock(
            address(new MockTreasury(address(new TokenMock()))),
            address(new SAFEEngineMock()),
            address(new AccountingEngineMock()),
            200000E45,                   // minimumBufferSize
            900,                         // minimumGlobalDebtChange
            50,                          // coveredDebt
            3600,                        // updateDelay
            5E18,                        // baseUpdateCallerReward
            10E18,                       // maxUpdateCallerReward
            1000192559420674483977255848 // perSecondCallerRewardIncrease
        ){}

    // aux
    function fuzz_globalDebt(uint globalDebt) public {
        SAFEEngineMock(address(safeEngine)).modifyParameters("globalDebt", globalDebt);
    }

    // properties
    function echidna_stopAdjustments() public returns (bool) {
        return stopAdjustments == 0;
    }

    function echidna_updateDelay() public returns (bool) {
        return updateDelay == 3600;
    }


    function echidna_minimumBufferSize() public returns (bool) {
        return minimumBufferSize == 200000E45;
    }

    function echidna_maximumBufferSize() public returns (bool) {
        return maximumBufferSize == uint(-1);
    }

    function echidna_minimumGlobalDebtChange() public returns (bool) {
        return minimumGlobalDebtChange == 900;
    }

    function echidna_coveredDebt() public returns (bool) {
        return coveredDebt == 50;
    }

    function echidna_surplusBufferAdjustment() public returns (bool) {
        adjustSurplusBuffer(address(0xdeadbeef));

        if (safeEngine.globalDebt() >= uint(-1) / coveredDebt) return accountingEngine.surplusBuffer() == maximumBufferSize;

        uint newBuffer = multiply(coveredDebt, safeEngine.globalDebt()) / THOUSAND;
        newBuffer = both(newBuffer > maximumBufferSize, maximumBufferSize > 0) ? maximumBufferSize : newBuffer;
        newBuffer = (newBuffer < minimumBufferSize) ? minimumBufferSize : newBuffer;
        return newBuffer == accountingEngine.surplusBuffer();
    }
}