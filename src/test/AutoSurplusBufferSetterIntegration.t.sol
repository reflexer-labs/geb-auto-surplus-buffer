pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import {GebDeployTestBase} from "geb-deploy/test/GebDeploy.t.base.sol";
import "../AutoSurplusBufferSetter.sol";

// contract Feed {
//     uint256 public priceFeedValue;
//     bool public hasValidValue;
//     constructor(uint256 initPrice, bool initHas) public {
//         priceFeedValue = uint(initPrice);
//         hasValidValue = initHas;
//     }
//     function set_val(uint newPrice) external {
//         priceFeedValue = newPrice;
//     }
//     function set_has(bool newHas) external {
//         hasValidValue = newHas;
//     }
//     function getResultWithValidity() external returns (uint256, bool) {
//         return (priceFeedValue, hasValidValue);
//     }
// }
abstract contract WethLike {
    function balanceOf(address) virtual public view returns (uint);
    function approve(address, uint) virtual public;
    function transfer(address, uint) virtual public;
    function transferFrom(address, address, uint) virtual public;
    function deposit() virtual public payable;
    function withdraw(uint) virtual public;
}

contract AutoSurplusBufferSetterTest is GebDeployTestBase {
    // Feed sysCoinFeed;

    AutoSurplusBufferSetter setter;

    uint256 minimumBufferSize = 20000E45;
    uint256 minimumGlobalDebtChange = 900;
    uint256 coveredDebt = 50;
    uint256 updateDelay = 3600;

    uint256 periodSize = 3600;
    uint256 baseUpdateCallerReward = 5E18;
    uint256 maxUpdateCallerReward  = 10E18;
    uint256 perSecondCallerRewardIncrease = 1000192559420674483977255848; // 100% per hour

    uint256 coinsToMint = 500000E18;

    uint RAY = 10 ** 27;

    function setUp() public override {
        super.setUp();
        hevm.warp(604411200);

        deployIndexWithCreatorPermissions(bytes32(""));

        safeEngine.modifyParameters("globalDebtCeiling", uint(-1));
        safeEngine.modifyParameters("ETH", "debtCeiling", uint(-1));

        // sysCoinFeed = new Feed(2.015 ether, true);

        setter = new AutoSurplusBufferSetter(
            address(stabilityFeeTreasury),
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

        // generating coin to feed StabilityFeeTreasury
        WethLike(address(ethJoin.collateral())).deposit{value: 1000000 ether}();
        WethLike(address(ethJoin.collateral())).approve(address(ethJoin), 1000000 ether);
        ethJoin.join(address(this), 1000000 ether);
        safeEngine.modifySAFECollateralization(
            "ETH",
            address(this),
            address(this),
            address(this),
            1000000 ether,
            int(coinsToMint)
        );
        safeEngine.approveSAFEModification(address(coinJoin));
        coinJoin.exit(address(stabilityFeeTreasury), coinsToMint);

        // auth in stabilityFeeTreasury
        address      usr = address(govActions);
        bytes32      tag;  assembly { tag := extcodehash(usr) }
        bytes memory fax = abi.encodeWithSignature("addAuthorization(address,address)", address(stabilityFeeTreasury), address(this));
        uint         eta = now;
        pause.scheduleTransaction(usr, tag, fax, eta);
        pause.executeTransaction(usr, tag, fax, eta);

        // setting allowances
        stabilityFeeTreasury.setTotalAllowance(address(setter), uint(-1));
        stabilityFeeTreasury.setPerBlockAllowance(address(setter), 10E45);

        // authing the setter in accountingEngine
        accountingEngine.addAuthorization(address(setter));
    }

    function test_setup() public {
        assertTrue(address(setter.treasury()) == address(stabilityFeeTreasury));
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
        assertEq(setter.getNewBuffer(0), minimumBufferSize);
    }
    function test_calculateNewBuffer_max_debt_no_max_buffer_size() public {
        assertEq(setter.getNewBuffer(uint(-1)), uint(-1));
    }
    function test_getNewBuffer() public {
        assertEq(setter.getNewBuffer(10000000E45), 500000E45);
    }
    function test_adjustSurplusBuffer() public {
        setter.adjustSurplusBuffer(address(0));
        assertEq(accountingEngine.surplusBuffer(), 25000E45);
    }
    function test_adjustSurplusBuffer_result_above_max_limit() public {
        setter.modifyParameters("maximumBufferSize", 24000E45);
        setter.adjustSurplusBuffer(address(0));
        assertEq(accountingEngine.surplusBuffer(), 24000E45);
    }
    function testFail_adjustSurplusBuffer_positive_debt_change_under_threshold() public {
        setter.adjustSurplusBuffer(address(0));
        hevm.warp(now + periodSize);
        safeEngine.modifySAFECollateralization(
            "ETH",
            address(this),
            address(this),
            address(this),
            0,
            int(1 ether)
        );
        setter.adjustSurplusBuffer(address(0));
    }
    function testFail_adjustSurplusBuffer_negative_debt_change_under_threshold() public {
        setter.adjustSurplusBuffer(address(0));
        hevm.warp(now + periodSize);
        safeEngine.modifySAFECollateralization(
            "ETH",
            address(this),
            address(this),
            address(this),
            0,
            int(-1 ether)
        );
        setter.adjustSurplusBuffer(address(0));
    }
    function testFail_adjustSurplusBuffer_twice_same_slot() public {
        setter.adjustSurplusBuffer(address(0));
        setter.adjustSurplusBuffer(address(0));
    }
    function test_adjustSurplusBuffer_self_reward() public {
        assertEq(safeEngine.coinBalance(address(this)), 0);
        setter.adjustSurplusBuffer(address(this));
        assertEq(safeEngine.coinBalance(address(this)), 5e18 * RAY);
    }
    function test_adjustSurplusBuffer_other_reward() public {
        assertEq(safeEngine.coinBalance(address(0xabc)), 0);
        setter.adjustSurplusBuffer(address(0xabc));
        assertEq(safeEngine.coinBalance(address(0xabc)), 5e18 * RAY);
    }
}
