pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "./mock/MockTreasury.sol";
import "../AutoSurplusBufferSetter.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract Feed {
    uint256 public priceFeedValue;
    bool public hasValidValue;
    constructor(uint256 initPrice, bool initHas) public {
        priceFeedValue = uint(initPrice);
        hasValidValue = initHas;
    }
    function set_val(uint newPrice) external {
        priceFeedValue = newPrice;
    }
    function set_has(bool newHas) external {
        hasValidValue = newHas;
    }
    function getResultWithValidity() external returns (uint256, bool) {
        return (priceFeedValue, hasValidValue);
    }
}
contract AccountingEngine {
    uint256 public surplusBuffer;

    function modifyParameters(bytes32 parameter, uint data) external {
        if (parameter == "surplusBuffer") surplusBuffer = data;
    }
}
contract SAFEEngine {
    uint256 public globalDebt;

    function modifyParameters(bytes32 parameter, uint data) external {
        globalDebt = data;
    }
}

contract AutoSurplusBufferSetterTest is DSTest {
    Hevm hevm;

    DSToken systemCoin;

    Feed sysCoinFeed;

    AutoSurplusBufferSetter setter;
    AccountingEngine accountingEngine;
    SAFEEngine safeEngine;
    MockTreasury treasury;

    uint256 minimumBufferSize = 200000E45;
    uint256 minimumGlobalDebtChange = 900;
    uint256 coveredDebt = 50;
    uint256 updateDelay = 3600;

    uint256 periodSize = 3600;
    uint256 baseUpdateCallerReward = 5E18;
    uint256 maxUpdateCallerReward  = 10E18;
    uint256 perSecondCallerRewardIncrease = 1000192559420674483977255848; // 100% per hour

    uint256 coinsToMint = 1E40;

    uint RAY = 10 ** 27;
    uint WAD = 10 ** 18;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        systemCoin = new DSToken("RAI");
        treasury = new MockTreasury(address(systemCoin));
        accountingEngine = new AccountingEngine();
        safeEngine = new SAFEEngine();

        sysCoinFeed = new Feed(2.015 ether, true);

        setter = new AutoSurplusBufferSetter(
            address(treasury),
            address(safeEngine),
            address(accountingEngine),
            minimumBufferSize,
            minimumGlobalDebtChange,
            coveredDebt,
            updateDelay,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease
        );

        systemCoin.mint(address(treasury), coinsToMint);

        treasury.setTotalAllowance(address(setter), uint(-1));
        treasury.setPerBlockAllowance(address(setter), 10E45);
    }

    function test_setup() public {
        assertTrue(address(setter.treasury()) == address(treasury));
        assertTrue(address(setter.accountingEngine()) == address(accountingEngine));
        assertTrue(address(setter.safeEngine()) == address(safeEngine));

        assertEq(setter.authorizedAccounts(address(this)), 1);
        assertEq(setter.minimumBufferSize(), minimumBufferSize);
        assertEq(setter.maximumBufferSize(), uint(-1));
        assertEq(setter.coveredDebt(), coveredDebt);
        assertEq(setter.minimumGlobalDebtChange(), minimumGlobalDebtChange);

        assertEq(setter.baseUpdateCallerReward(), baseUpdateCallerReward);
        assertEq(setter.maxUpdateCallerReward(), maxUpdateCallerReward);
        assertEq(setter.perSecondCallerRewardIncrease(), perSecondCallerRewardIncrease);

        assertEq(setter.updateDelay(), periodSize);
        assertEq(setter.maxRewardIncreaseDelay(), uint(-1));
    }
    function test_calculateNewBuffer_zero_debt() public {
        assertEq(setter.calculateNewBuffer(0), minimumBufferSize);
    }
    function test_calculateNewBuffer_max_debt_no_max_buffer_size() public {
        assertEq(setter.calculateNewBuffer(uint(-1)), uint(-1));
    }
    function test_calculateNewBuffer() public {
        assertEq(setter.calculateNewBuffer(10000000E45), 500000E45);
    }
    function test_adjustSurplusBuffer() public {
        safeEngine.modifyParameters("globalDebt", 500000000E45);
        setter.adjustSurplusBuffer(address(0));
        assertEq(accountingEngine.surplusBuffer(), 25000000E45);
    }
    function test_adjustSurplusBuffer_result_above_max_limit() public {
        safeEngine.modifyParameters("globalDebt", 500000000E45);
        setter.modifyParameters("maximumBufferSize", 250000E45);
        setter.adjustSurplusBuffer(address(0));
        assertEq(accountingEngine.surplusBuffer(), 250000E45);
    }
    function testFail_adjustSurplusBuffer_positive_debt_change_under_threshold() public {
        safeEngine.modifyParameters("globalDebt", 500000000E45);
        setter.adjustSurplusBuffer(address(0));
        hevm.warp(now + periodSize);
        safeEngine.modifyParameters("globalDebt", 501000000E45);
        setter.adjustSurplusBuffer(address(0));
    }
    function testFail_adjustSurplusBuffer_negative_debt_change_under_threshold() public {
        safeEngine.modifyParameters("globalDebt", 500000000E45);
        setter.adjustSurplusBuffer(address(0));
        hevm.warp(now + periodSize);
        safeEngine.modifyParameters("globalDebt", 499000000E45);
        setter.adjustSurplusBuffer(address(0));
    }
    function testFail_adjustSurplusBuffer_twice_same_slot() public {
        safeEngine.modifyParameters("globalDebt", 500000000E45);
        setter.adjustSurplusBuffer(address(0));
        setter.adjustSurplusBuffer(address(0));
    }
    function test_adjustSurplusBuffer_self_reward() public {
        assertEq(systemCoin.balanceOf(address(this)), 0);
        safeEngine.modifyParameters("globalDebt", 500000000E45);
        setter.adjustSurplusBuffer(address(this));
        assertEq(systemCoin.balanceOf(address(this)), 5E18);
    }
    function test_adjustSurplusBuffer_other_reward() public {
        assertEq(systemCoin.balanceOf(address(1)), 0);
        safeEngine.modifyParameters("globalDebt", 500000000E45);
        setter.adjustSurplusBuffer(address(1));
        assertEq(systemCoin.balanceOf(address(1)), 5E18);
    }
}
